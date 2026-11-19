import Foundation
import Testing
@testable import KhaytCore

/// A Snapmaker U1's camera kept awake, and its chamber light, through the
/// engine: `test/fixtures/u1-camera-vectors.json`, the file
/// `test/u1-camera.test.js` holds lib to under node.
@Suite struct U1CameraTests {
    struct Vectors: Decodable {
        struct KeepAwake: Decodable { let why: String; let machine: JSONValue; let want: String? }
        struct Request: Decodable { let id: JSONValue; let want: String? }
        struct Reply: Decodable { let text: String; let id: Int; let want: String }
        struct Method: Decodable { let method: String; let want: Bool }
        struct Script: Decodable { let on: Bool?; let want: String? }
        struct Allowed: Decodable { let script: String; let want: Bool }
        struct LightFor: Decodable {
            struct Want: Decodable, Equatable { let queryUrl: String; let scriptUrl: String }
            let machine: JSONValue; let want: Want?
        }
        struct LightState: Decodable { let why: String; let body: JSONValue; let want: Bool? }
        let keepAwake: [KeepAwake]
        let request: [Request]
        let reply: [Reply]
        let wsMethods: [Method]
        let lightScript: [Script]
        let scriptAllowed: [Allowed]
        let lightFor: [LightFor]
        let lightState: [LightState]
    }

    static func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test/fixtures/u1-camera-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test("keep-awake: only a Snapmaker monitor still on Moonraker, on the API host")
    func keepAwake() async throws {
        let v = try Self.vectors()
        #expect(v.keepAwake.count >= 8)
        let engine = try KhaytEngine()
        for c in v.keepAwake {
            let got = try await engine.keepAwake(machine: c.machine)
            #expect(got?.wsUrl == c.want, Comment(rawValue: c.why))
            if let got {
                #expect(got.method == "camera.start_monitor")
                #expect(got.renewMs == 60_000)
                #expect(got.deadlineMs == 2_000)
            }
        }
    }

    @Test("the one frame, and only replies to our id count")
    func frames() async throws {
        let v = try Self.vectors()
        let engine = try KhaytEngine()
        for c in v.request {
            // The vectors hold a string id and fractions too; the Swift
            // crossing takes an Int, so only whole ids are asked here.
            guard case .number(let n) = c.id, n == n.rounded() else { continue }
            #expect(try await engine.keepAwakeRequest(id: Int(n)) == c.want, "\(n)")
        }
        for c in v.reply {
            #expect(try await engine.keepAwakeReply(c.text, id: c.id) == c.want, Comment(rawValue: c.text))
        }
    }

    /// The socket also carries Snapmaker's firmware methods: the gate allows
    /// one method and nothing else, and every frame the builder makes passes it.
    @Test("the socket allow-list is camera.start_monitor alone")
    func allowList() async throws {
        let v = try Self.vectors()
        let engine = try KhaytEngine()
        for c in v.wsMethods {
            #expect(try await engine.wsMethodAllowed(c.method) == c.want, Comment(rawValue: c.method))
        }
        struct F: Decodable { let method: String }
        let frame = try #require(try await engine.keepAwakeRequest(id: 9))
        let method = try JSONDecoder().decode(F.self, from: Data(frame.utf8)).method
        #expect(try await engine.wsMethodAllowed(method))
    }

    @Test("the chamber light: two scripts, the gate, where to ask, and the reading")
    func light() async throws {
        let v = try Self.vectors()
        let engine = try KhaytEngine()
        for c in v.lightScript {
            guard let on = c.on else { continue }
            #expect(try await engine.chamberLightScript(on: on) == c.want)
        }
        for c in v.scriptAllowed {
            #expect(try await engine.scriptAllowed(c.script) == c.want, Comment(rawValue: c.script))
        }
        for c in v.lightFor {
            let got = try await engine.chamberLight(machine: c.machine)
            #expect(got.map { Vectors.LightFor.Want(queryUrl: $0.queryUrl, scriptUrl: $0.scriptUrl) } == c.want)
        }
        for c in v.lightState {
            #expect(try await engine.chamberLightState(c.body) == c.want, Comment(rawValue: c.why))
        }
    }
}
