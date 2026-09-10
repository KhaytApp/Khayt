import Foundation
import Testing
@testable import KhaytCore

/// The camera on a printer, as this app is allowed to fetch it.
///
/// Every decision here is `lib/webcam.js`'s and none is re-derived in Swift.
/// What these pin is that the Mac ASKS — and above all that it asks the one
/// question it must never skip.
@Suite struct WebcamTests {

    static func api(_ type: String, _ host: String, key: String? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["type": .string(type), "host": .string(host)]
        if let key { row["apiKey"] = .string(key) }
        return .object(row)
    }

    /// ── THE SSRF PIN ─────────────────────────────────────────────────────
    ///
    /// A webcam lives on the LAN, so private addresses have to be allowed —
    /// which would be an open hole if the URL were free-form.
    ///
    /// This matters more on the Mac than it reads: a snapshot URL is stored in
    /// the book, and a book arrives by RESTORE and by CLOUD SYNC. The URL on
    /// the record was not necessarily typed by the person sitting in front of
    /// this Mac.
    ///
    /// ── THIS TEST USED TO PIN IT TO THE PRINTER, AND NO LONGER DOES ──────
    ///
    /// `http://192.168.1.99/...` was in the refused list below, for being a
    /// host that is not the printer's. It is allowed now: a camera on its own
    /// address is the ordinary case. Measured on a real floor, a Buddy3D beside
    /// a Prusa CORE One is at .71 with the printer at .79, speaks RTSP only,
    /// and is not reachable through the printer at all.
    ///
    /// What is still refused is everything that can leave the building or reach
    /// something that is not a camera — and, importantly, any NAME that is not
    /// the printer's, because a name resolves and what it resolves to can
    /// change between the check and the fetch.
    @Test("a snapshot may be the printer, or a literal address on this network")
    func theHostIsOnThisNetwork() async throws {
        let engine = try KhaytEngine()
        let printer = Self.api("moonraker", "192.168.1.50")

        // The printer's own host, on any port and path: allowed, as before.
        try await engine.assertWebcamHost("http://192.168.1.50/webcam/?action=snapshot",
                                          printerApi: printer)
        try await engine.assertWebcamHost("http://192.168.1.50:8080/?action=snapshot",
                                          printerApi: printer)
        // A camera that is its own device on the same network: allowed now.
        try await engine.assertWebcamHost("http://192.168.1.99/webcam/?action=snapshot",
                                          printerApi: printer)

        for elsewhere in ["http://169.254.169.254/latest/meta-data/",
                          "http://100.100.100.200/latest/meta-data/",
                          "http://example.com/x.jpg",
                          "http://camera.local/x.jpg",
                          "http://8.8.8.8/x.jpg",
                          "http://2130706433/x.jpg",
                          "http://127.0.0.1:7125/printer/objects/query"] {
            await #expect(throws: (any Error).self,
                          "\(elsewhere) was allowed for a printer at 192.168.1.50") {
                try await engine.assertWebcamHost(elsewhere, printerApi: printer)
            }
        }
    }

    /// ── THE USERINFO BYPASS ──────────────────────────────────────────────
    ///
    /// `http://192.168.1.50@evil.com/x.jpg` reads, to a human skimming it, as
    /// an address on the printer. Its host is `evil.com`. The reverse —
    /// `http://evil.com@192.168.1.50/x.jpg` — reads as somebody else's and IS
    /// the printer.
    ///
    /// This is the case a hand-rolled URL parser gets wrong, and the reason the
    /// engine's `URL` is backed by `URLComponents` rather than by a regex
    /// written to make a test pass. JavaScriptCore has no `URL` of its own.
    @Test("a host smuggled into the userinfo does not become the host")
    func theUserinfoDoesNotDecide() async throws {
        let engine = try KhaytEngine()
        let printer = Self.api("moonraker", "192.168.1.50")

        await #expect(throws: (any Error).self, "the printer's address in the userinfo was believed") {
            try await engine.assertWebcamHost("http://192.168.1.50@evil.com/x.jpg", printerApi: printer)
        }
        // And the mirror image is genuinely the printer, so it is allowed —
        // refusing it would mean the guard was matching text rather than hosts.
        try await engine.assertWebcamHost("http://evil.com@192.168.1.50/webcam/", printerApi: printer)
    }

    /// One guess is demonstrably not enough — checked against a Snapmaker U1 on
    /// stock firmware, where the derived `:8080/?action=snapshot` reaches
    /// nothing and the nginx on port 80 does have a `/webcam/` route.
    @Test("a Klipper printer offers more than one address to try")
    func candidatesArePlural() async throws {
        let engine = try KhaytEngine()
        let found = try await engine.webcamCandidates(printerApi: Self.api("moonraker", "192.168.1.50"))
        #expect(found.count > 1, "only \(found.count) address to try: \(found)")
        // And every one of them is on the printer, or the probe would be the
        // hole the pin exists to close.
        for candidate in found {
            try await engine.assertWebcamHost(candidate, printerApi: Self.api("moonraker", "192.168.1.50"))
        }
    }

    /// A CAMERA WITH NOTHING TO SHOW IS NOT A CAMERA THAT IS BROKEN. PrusaLink
    /// documents 204 as "No Content / No Error" and 503 as temporarily
    /// unavailable — a registered camera warming up, or busy. Both used to
    /// render as "Camera offline", which is the one thing they do not mean.
    @Test("a camera with no frame yet is told apart from one that failed")
    func noFrameIsNotAFault() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.checkSnapshot(status: 204, contentType: nil, contentLength: 0)
                == "no_frame_yet")
        #expect(try await engine.checkSnapshot(status: 503, contentType: nil, contentLength: 0)
                == "no_frame_yet")
        #expect(try await engine.checkSnapshot(status: 200, contentType: "image/jpeg", contentLength: 40_000)
                == nil, "a plain JPEG was refused")
    }

    /// The EXACT content type, not merely something starting with `image/`. A
    /// header value may carry a double quote and survives a fetch intact, so
    /// `image/png" onerror="…` once passed a prefix test and was pasted into a
    /// data: URL the renderer put straight into `src`.
    @Test("a content type that only begins with image/ is refused")
    func theTypeIsMatchedWhole() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.checkSnapshot(status: 200,
                                               contentType: #"image/png" onerror="alert(1)"#,
                                               contentLength: 10) == "not_an_image")
        #expect(try await engine.checkSnapshot(status: 200, contentType: "text/html",
                                               contentLength: 10) == "not_an_image")
        // A redirect is refused outright rather than followed — following one
        // is how a pinned host stops being pinned.
        #expect(try await engine.checkSnapshot(status: 302, contentType: "image/png",
                                               contentLength: 10) == "redirect_refused")
    }

    /// PrusaLink's camera endpoint answers 401 without a key, so a correct URL
    /// that sends nothing fails every time. Moonraker on the LAN needs none,
    /// and sending a junk header is worse than sending none.
    @Test("the credential that fetches a still is the printer's own")
    func authMatchesTheProtocol() async throws {
        let engine = try KhaytEngine()
        let prusa = try await engine.webcamAuthHeaders(
            printerApi: Self.api("prusalink", "192.168.1.50", key: "abc123"))
        #expect(prusa["X-Api-Key"] == "abc123")

        let moonraker = try await engine.webcamAuthHeaders(
            printerApi: Self.api("moonraker", "192.168.1.50"))
        #expect(moonraker.isEmpty, "Moonraker was sent \(moonraker)")
    }

    /// What the owner typed, made absolute against the printer — and bounded.
    @Test("a path becomes an address on the printer, and a bad rotation is dropped")
    func whatIsSavedIsUsable() async throws {
        let engine = try KhaytEngine()
        let clean = try await engine.sanitizeWebcam(
            .object(["enabled": .bool(true),
                     "snapshotUrl": .string("/webcam/?action=snapshot"),
                     "rotate": .number(45)]),
            printerApi: Self.api("moonraker", "192.168.1.50"))
        guard case .object(let w) = clean else { Issue.record("not an object"); return }
        #expect(w["snapshotUrl"] == JSONValue.string("http://192.168.1.50/webcam/?action=snapshot"))
        #expect(w["rotate"] == JSONValue.number(0), "45° is not one of the four and was kept")
    }
}
