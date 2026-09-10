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
    @Test("a camera on another host is refused without a request being made")
    func nothingIsFetchedFromElsewhere() async throws {
        let shop = await Self.shop()
        let machine = try Self.machine(host: "192.168.1.50",
                                       snapshot: "http://192.168.1.99/webcam/?action=snapshot")
        var asked = 0
        let frame = await Camera.fetch(machine, shop: shop) { _ in
            asked += 1
            return (Data(), HTTPURLResponse())
        }
        #expect(asked == 0, "\(asked) request(s) went out to a host the guard refuses")
        #expect(frame == .failed("refused"))
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
