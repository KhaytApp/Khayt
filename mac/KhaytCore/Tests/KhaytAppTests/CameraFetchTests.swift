import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Fetching one still, and the order the two steps happen in.
///
/// `WebcamTests` pins what the shared rules DECIDE. These pin that this app
/// asks them — and above all that it asks the host question BEFORE it opens a
/// connection, which is the difference between a guard and a comment.
@MainActor
struct CameraFetchTests {

    static func machine(host: String, snapshot: String, type: String = "moonraker") throws -> Machine {
        let row: [String: JSONValue] = [
            "id": .string("M1"), "name": .string("Printer"),
            "printerApi": .object(["type": .string(type), "host": .string(host)]),
            "webcam": .object(["enabled": .bool(true), "snapshotUrl": .string(snapshot)]),
        ]
        return try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    /// ── THE REQUEST THAT MUST NOT HAPPEN ─────────────────────────────────
    ///
    /// A snapshot URL lives in the book, and a book arrives by restore and by
    /// cloud sync — so the address on the record was not necessarily typed by
    /// the person sitting at this Mac. If the pin were asked after the fetch,
    /// or not at all, this app would have made the request before deciding it
    /// was not allowed to. Counting the requests is the only way to tell those
    /// apart from outside.
    @Test("a camera off this network is refused without a request being made")
    func nothingIsFetchedFromElsewhere() async throws {
        // ── THIS ADDRESS CHANGED, AND ON PURPOSE ─────────────────────────
        //
        // It used to be `192.168.1.99` — another host on the same private
        // network — refused for not being the printer's. That is allowed now:
        // a camera on its own address is the ordinary case, not an attack.
        // See `assertWebcamHostAllowed`.
        //
        // What must still never be fetched is an address that can leave the
        // building, so that is what this asks about. The COUNT is the point:
        // if the guard ran after the fetch instead of before it, the request
        // would already have gone out carrying the printer's credential, and
        // from outside the only way to tell is to count.
        let shop = await Self.shop()
        let machine = try Self.machine(host: "192.168.1.50",
                                       snapshot: "https://evil.example.com/collect")
        var asked = 0
        let frame = await Camera.fetch(machine, shop: shop) { _ in
            asked += 1
            return (Data(), HTTPURLResponse())
        }
        #expect(asked == 0, "\(asked) request(s) went out to a host the guard refuses")
        #expect(frame == .failed("refused"))
    }

    /// And the case the refusal above used to cover, now that it is allowed.
    @Test("a camera that is its own device on this network is fetched")
    func aCameraOfItsOwnIsAllowed() async throws {
        let shop = await Self.shop()
        let machine = try Self.machine(host: "192.168.1.50",
                                       snapshot: "http://192.168.1.99/webcam/?action=snapshot")
        var asked = 0
        _ = await Camera.fetch(machine, shop: shop) { _ in
            asked += 1
            return (Data(), HTTPURLResponse())
        }
        #expect(asked == 1, "a Buddy3D beside a CORE One is exactly this shape")
    }

    /// And the printer's own host is allowed, or the guard would be a way of
    /// having no cameras at all.
    @Test("a camera on the printer is fetched and shown")
    func thePrintersOwnCameraIsShown() async throws {
        let shop = await Self.shop()
        let machine = try Self.machine(host: "192.168.1.50",
                                       snapshot: "http://192.168.1.50/webcam/?action=snapshot")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let frame = await Camera.fetch(machine, shop: shop) { request in
            (png, HTTPURLResponse(url: request.url!, statusCode: 200,
                                  httpVersion: nil,
                                  headerFields: ["Content-Type": "image/png"])!)
        }
        #expect(frame == .picture(png))
    }

    /// ── A NAME IS JUDGED BY WHAT IT RESOLVES TO ─────────────────────────
    ///
    /// The text rule passes any name, so a synced or restored book naming
    /// `cam.attacker.example` — as the printer's host, or as the camera's —
    /// was fetched with the printer's key on every frame. The poller resolved
    /// and refused it (#1955); the camera did not.
    @Test("a camera or printer NAME that resolves off this network gets no request")
    func aPublicNameIsRefused() async throws {
        let shop = await Self.shop()
        for (host, snap) in [("cam.attacker.example", "http://cam.attacker.example/snap.jpg"),
                             ("192.168.1.50", "http://cam.attacker.example/snap.jpg"),
                             ("192.168.1.50", "http://mixed.example/snap.jpg")] {
            let machine = try Self.machine(host: host, snapshot: snap, type: "octoprint")
            var asked = 0
            let frame = await Camera.fetch(machine, shop: shop, get: { _ in
                asked += 1
                return (Data(), HTTPURLResponse())
            }, lookUp: { name in name == "mixed.example" ? ["192.168.1.9", "93.184.216.34"] : ["93.184.216.34"] })
            #expect(asked == 0, "\(snap) was fetched")
            #expect(frame == .failed("refused"))
        }
    }

    /// And a LAN name is fetched at the address that was checked, so a name
    /// that answers differently to `URLSession`'s own lookup (rebinding) is
    /// never asked.
    @Test("a camera name on this network is fetched at the checked address")
    func aLanNameIsPinned() async throws {
        let shop = await Self.shop()
        let machine = try Self.machine(host: "voron.local",
                                       snapshot: "http://voron.local:8080/webcam/?action=snapshot")
        var seen: [URL] = []
        _ = await Camera.fetch(machine, shop: shop, get: { request in
            seen.append(request.url!)
            return (Data(), HTTPURLResponse())
        }, lookUp: { _ in ["192.168.1.50"] })
        #expect(seen.map(\.absoluteString) == ["http://192.168.1.50:8080/webcam/?action=snapshot"])
    }

    /// A camera password saved before the shared rule refused it is emptied
    /// on disk, through the real write, and nothing else in the book moves.
    @Test("a camera URL with credentials already in a book is emptied, once, and nothing else is touched")
    func credentialsOnDiskAreScrubbed() async throws {
        let url = try SettingsReachDiskTests.scratchBook()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try KhaytEngine()
        let api: JSONValue = .object(["type": .string("octoprint"), "host": .string("192.168.1.50")])
        func cam(_ snap: String, _ stream: String) -> JSONValue {
            .object(["enabled": .bool(true), "snapshotUrl": .string(snap), "streamUrl": .string(stream),
                     "rotate": .number(90)])
        }
        // Planted through the writer, as an older build would have saved them.
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            var rows: [JSONValue] = []
            if case .array(let had)? = root["machines"] { rows = had }
            rows.append(.object(["id": .string("CAM1"), "name": .string("Leaky"), "printerApi": api,
                                 "webcam": cam("http://admin:hunter2@192.168.1.60/snap.jpg",
                                               "http://192.168.1.60/stream")]))
            rows.append(.object(["id": .string("CAM2"), "name": .string("Fine"), "printerApi": api,
                                 "webcam": cam("/snap.jpg?by=a@b", "rtsp://cam@192.168.1.61/live")]))
            root["machines"] = .array(rows)
        }
        let before = try CloudMergeTests.read(url)
        func scrub() async throws -> Int {
            var n = 0
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                n = await Camera.scrubCredentials(&root) { u, a in try? await engine.normalizeWebcamUrl(u, printerApi: a) }
            }
            return n
        }
        #expect(try await scrub() == 2)
        let after = try CloudMergeTests.read(url)
        func webcam(_ root: [String: JSONValue], _ id: String) -> [String: JSONValue] {
            guard let m = CloudMergeTests.record(root, "machines", id), case .object(let w)? = m["webcam"] else { return [:] }
            return w
        }
        #expect(webcam(after, "CAM1")["snapshotUrl"] == .string(""))
        #expect(webcam(after, "CAM1")["streamUrl"] == .string("http://192.168.1.60/stream"))
        #expect(webcam(after, "CAM1")["rotate"] == .number(90) && webcam(after, "CAM1")["enabled"] == .bool(true))
        #expect(webcam(after, "CAM2")["snapshotUrl"] == .string("/snap.jpg?by=a@b"), "an @ after the host is not a login")
        #expect(webcam(after, "CAM2")["streamUrl"] == .string(""))
        // Every other collection exactly as it was.
        for key in before.keys where key != "machines" { #expect(after[key] == before[key], "\(key) moved") }
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("hunter2"))
        #expect(try await scrub() == 0, "the second load finds nothing to do")
    }

    /// ── THE REDIRECT, AND THE KEY THAT USED TO GO WITH IT ───────────────
    ///
    /// A camera is allowed to be its own device now, and the request to it
    /// carries the PRINTER's credential — `X-Api-Key` for OctoPrint and
    /// PrusaLink, the access code for Bambu. `URLSession` follows redirects on
    /// its own, so a permitted camera answering 302 handed that key to whoever
    /// the `Location:` named, and the host check — which runs before the
    /// request — never saw the second hop. It was re-checked afterwards, which
    /// refuses the PICTURE long after the key has gone.
    @Test("a redirect is refused, and reads as a refusal rather than a picture")
    func aRedirectIsRefused() async throws {
        let shop = await Self.shop()
        let machine = try Self.machine(host: "192.168.1.50",
                                       snapshot: "http://192.168.1.99/webcam/?action=snapshot")
        // What the real delegate now delivers: the 3xx itself, unfollowed.
        let frame = await Camera.fetch(machine, shop: shop) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 302,
                                     httpVersion: nil,
                                     headerFields: ["Location": "http://attacker.example/collect"])!)
        }
        // `checkSnapshotHeaders` has always had this rule and it could not fire
        // while `URLSession` was consuming the 3xx on our behalf.
        #expect(frame == .failed("redirect_refused"))
    }

    @Test("the delegate refuses to follow, rather than following and checking after")
    func theDelegateRefusesToFollow() async throws {
        // Returning nil from `willPerformHTTPRedirection` is what stops the
        // second request being made at all. If this ever returns a request, the
        // credential travels again and the test above starts passing for the
        // wrong reason — it would see the REDIRECTED response, not the 3xx.
        let followed = await RefuseRedirects.shared.urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: URL(string: "http://192.168.1.99/")!),
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "http://192.168.1.99/")!, statusCode: 302,
                httpVersion: nil, headerFields: ["Location": "http://attacker.example/"])!,
            newRequest: URLRequest(url: URL(string: "http://attacker.example/")!))
        #expect(followed == nil, "a redirect must not be followed")
    }

    /// A CAMERA WITH NOTHING TO SHOW IS NOT A CAMERA THAT IS BROKEN, and the
    /// tile draws the two differently — so this is the mapping, not the rule.
    /// PrusaLink documents 204 as "No Content / No Error".
    @Test("no frame yet is not a failure")
    func warmingUpIsItsOwnState() async throws {
        let shop = await Self.shop()
        let machine = try Self.machine(host: "192.168.1.50",
                                       snapshot: "http://192.168.1.50/api/v1/cameras/snap",
                                       type: "prusalink")
        let frame = await Camera.fetch(machine, shop: shop) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 204,
                                     httpVersion: nil, headerFields: nil)!)
        }
        #expect(frame == .waiting, "a camera warming up was reported as broken")
    }

    /// An answer that is not an image is refused rather than handed to
    /// `NSImage` — the content-type check is the shared rule's, and this is
    /// that this app honours its verdict rather than trying the bytes anyway.
    @Test("a page where a picture should be is refused")
    func notAnImageIsRefused() async throws {
        let shop = await Self.shop()
        let machine = try Self.machine(host: "192.168.1.50", snapshot: "http://192.168.1.50/webcam/")
        let frame = await Camera.fetch(machine, shop: shop) { request in
            (Data("<html>login</html>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "text/html"])!)
        }
        #expect(frame == .failed("not_an_image"))
    }

    /// A machine with the camera switched off is not asked at all — five
    /// printers polled every few seconds for pictures nobody wants is the
    /// difference between a feature and a nuisance.
    @Test("a camera that is switched off costs nothing")
    func switchedOffIsNotPolled() async throws {
        let shop = await Self.shop()
        let row: [String: JSONValue] = [
            "id": .string("M1"), "name": .string("Printer"),
            "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.1.50")]),
            "webcam": .object(["enabled": .bool(false),
                               "snapshotUrl": .string("http://192.168.1.50/webcam/")]),
        ]
        let machine = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
        var asked = 0
        let frame = await Camera.fetch(machine, shop: shop) { _ in
            asked += 1; return (Data(), HTTPURLResponse())
        }
        #expect(asked == 0)
        #expect(frame == .none)
        #expect(!machine.hasCamera)
    }
}
