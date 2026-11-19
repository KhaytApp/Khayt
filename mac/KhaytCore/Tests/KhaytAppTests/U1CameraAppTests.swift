import Foundation
import Network
import Testing
import KhaytCore
@testable import KhaytApp

/// The U1 keep-awake and chamber light, through the app's own hooks
/// (`exchange`, `get`, `lookUp`): what is sent, where, and what is refused
/// before anything goes out. #2589 security review, Nov 19.
@MainActor
@Suite(.serialized) struct U1CameraAppTests {

    static func machine(host: String,
                        snapshot: String = "http://192.168.1.50:7125/server/files/camera/monitor.jpg") throws -> Machine {
        let row: [String: JSONValue] = [
            "id": .string("M1"), "name": .string("Printer"),
            "printerApi": .object(["type": .string("moonraker"), "host": .string(host)]),
            "webcam": .object(["enabled": .bool(true), "snapshotUrl": .string(snapshot)]),
        ]
        return try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    /// Counts the exchanges and records what each one was handed.
    final class Calls: @unchecked Sendable {
        var requests: [URLRequest] = []
        var frames: [String] = []
        var ids: [Int] = []
    }

    @Test("a U1 on this network: one exchange, to its own API port, with the lib's exact frame")
    func sendsTheOneFrame() async throws {
        let shop = await Self.shop()
        let engine = try #require(shop.engine)
        let calls = Calls()
        let step = await U1Camera.keepAwake(try Self.machine(host: "192.168.1.50"), shop: shop,
                                            exchange: { request, frame, id, _, _ in
                                                calls.requests.append(request); calls.frames.append(frame); calls.ids.append(id)
                                                return .ok
                                            })
        #expect(step?.outcome == .ok)
        #expect(step?.renew == .seconds(60))
        #expect(calls.requests.count == 1)
        #expect(calls.requests.first?.url?.absoluteString == "ws://192.168.1.50:7125/websocket")
        let id = try #require(calls.ids.first)
        #expect(calls.frames.first == (try await engine.keepAwakeRequest(id: id)))
    }

    @Test("a camera that refreshes by itself is not kept awake at all")
    func otherCamerasAreLeftAlone() async throws {
        let shop = await Self.shop()
        let calls = Calls()
        let step = await U1Camera.keepAwake(
            try Self.machine(host: "192.168.1.50", snapshot: "http://192.168.1.50/webcam/?action=snapshot"),
            shop: shop, exchange: { r, _, _, _, _ in calls.requests.append(r); return .ok })
        #expect(step == nil)
        #expect(calls.requests.isEmpty)
    }

    @Test("a printer on a public address: refused, and no socket is opened")
    func publicHostRefused() async throws {
        let shop = await Self.shop()
        let calls = Calls()
        let step = await U1Camera.keepAwake(
            try Self.machine(host: "8.8.8.8", snapshot: "http://8.8.8.8:7125/server/files/camera/monitor.jpg"),
            shop: shop, exchange: { r, _, _, _, _ in calls.requests.append(r); return .ok })
        #expect(step?.outcome == .refused)
        #expect(calls.requests.isEmpty, "a socket was opened to a public address")
    }

    @Test("a name that also resolves off this network: refused before the socket")
    func rebindingNameRefused() async throws {
        let shop = await Self.shop()
        let calls = Calls()
        let step = await U1Camera.keepAwake(
            try Self.machine(host: "printer.local", snapshot: "http://printer.local:7125/server/files/camera/monitor.jpg"),
            shop: shop, exchange: { r, _, _, _, _ in calls.requests.append(r); return .ok },
            lookUp: { _ in ["192.168.1.50", "8.8.8.8"] })
        #expect(step?.outcome == .refused)
        #expect(calls.requests.isEmpty)
    }

    @Test("the gate takes only the lib's exact frame for that id")
    func gateIsExact() async throws {
        let engine = try KhaytEngine()
        let frame = try #require(try await engine.keepAwakeRequest(id: 5))
        #expect(await U1Camera.frameAllowed(frame, id: 5, engine: engine))
        // The right method with something riding along.
        let padded = frame.replacingOccurrences(of: "\"interval\":0", with: "\"interval\":0,\"x\":1")
        #expect(!(await U1Camera.frameAllowed(padded, id: 5, engine: engine)))
        // Another id's frame.
        #expect(!(await U1Camera.frameAllowed(frame, id: 6, engine: engine)))
        // A firmware method.
        let upgrade = frame.replacingOccurrences(of: "camera.start_monitor", with: "machine.system_upgrade")
        #expect(!(await U1Camera.frameAllowed(upgrade, id: 5, engine: engine)))
        // And the live socket refuses before it opens anything.
        let request = URLRequest(url: URL(string: "ws://127.0.0.1:9/websocket")!)
        #expect(await U1Camera.live(request, upgrade, 5, .seconds(1), engine) == .refused)
    }

    @Test("the light: a hostile, huge reply is not believed; a real one is")
    func lightReplyCapped() async throws {
        let shop = await Self.shop()
        let machine = try Self.machine(host: "192.168.1.50")
        let ok = HTTPURLResponse(url: URL(string: "http://192.168.1.50:7125/")!, statusCode: 200,
                                 httpVersion: nil, headerFields: nil)!
        let huge = Data(repeating: 0x20, count: U1Camera.lightReplyCap + 1)
        #expect(await U1Camera.readLight(machine, shop: shop, get: { _ in (huge, ok) }) == nil)
        let real = Data(#"{"result":{"status":{"led cavity_led":{"color_data":[[0,0,0,1]]}}}}"#.utf8)
        let calls = Calls()
        let on = await U1Camera.readLight(machine, shop: shop, get: { r in calls.requests.append(r); return (real, ok) })
        #expect(on == true)
        #expect(calls.requests.first?.url?.absoluteString == "http://192.168.1.50:7125/printer/objects/query?led%20cavity_led")
    }

    @Test("the light is never asked of a public address")
    func lightPublicRefused() async throws {
        let shop = await Self.shop()
        let calls = Calls()
        let state = await U1Camera.readLight(try Self.machine(host: "8.8.8.8"), shop: shop,
                                             get: { r in calls.requests.append(r); return (Data(), HTTPURLResponse()) })
        #expect(state == nil)
        #expect(calls.requests.isEmpty)
    }

    /// A real socket against a local server that answers the WebSocket
    /// handshake with a 302 to a second server: the redirect is refused, and
    /// the second server is never reached.
    @Test("a WebSocket handshake answered with a redirect is refused, not followed")
    func handshakeRedirectRefused() async throws {
        let engine = try KhaytEngine()
        let target = try LocalServer(reply: { _ in "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" })
        let bouncer = try LocalServer(reply: { _ in
            "HTTP/1.1 302 Found\r\nLocation: ws://127.0.0.1:\(target.port)/websocket\r\nContent-Length: 0\r\n\r\n"
        })
        try await bouncer.ready(); try await target.ready()
        defer { bouncer.stop(); target.stop() }
        let frame = try #require(try await engine.keepAwakeRequest(id: 3))
        let request = URLRequest(url: URL(string: "ws://127.0.0.1:\(bouncer.port)/websocket")!)
        let outcome = await U1Camera.live(request, frame, 3, .seconds(2), engine)
        #expect(outcome != .ok)
        #expect(bouncer.hits >= 1, "the bouncer was never asked: the test proved nothing")
        #expect(target.hits == 0, "the redirect was followed")
    }
}

/// A one-shot HTTP responder on loopback, for the handshake test.
final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "u1-test-server")
    private(set) var hits = 0
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(reply: @escaping @Sendable (String) -> String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async { self.hits += 1 }
            conn.start(queue: self.queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                conn.send(content: Data(reply(text).utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func ready() async throws {
        for _ in 0..<100 where port == 0 { try await Task.sleep(for: .milliseconds(20)) }
        if port == 0 { throw CocoaError(.featureUnsupported) }
    }

    func stop() { listener.cancel() }
}
