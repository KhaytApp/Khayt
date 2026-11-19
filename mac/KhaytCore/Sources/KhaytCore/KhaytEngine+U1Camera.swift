import Foundation

/// A Snapmaker U1's camera kept awake while it is watched, and its chamber
/// light: every decision is `lib/webcam.js`, shared with the desktop and run
/// against `test/fixtures/u1-camera-vectors.json` on both sides.
///
/// The Swift side only moves bytes. It never builds a frame or a G-code line
/// of its own: the one WebSocket frame comes from `keepAwakeRequest`, the two
/// light lines from `chamberLightScript`, and each is checked against the lib
/// gate (`wsMethodAllowed`, `scriptAllowed`) before it is written.
extension KhaytEngine {
    /// What keeping one machine's camera awake takes.
    public struct KeepAwake: Decodable, Sendable, Equatable {
        public let wsUrl: String
        public let headers: [String: String]
        public let method: String
        public let renewMs: Double
        public let deadlineMs: Double
    }

    /// Nil for any camera that refreshes by itself (everything but a
    /// Snapmaker monitor still on Moonraker).
    public func keepAwake(machine: JSONValue) throws -> KeepAwake? {
        try runtime.call2("globalThis.KhaytWebcam.keepAwakeFor(ARG0)",
                          [machine], as: KeepAwake?.self)
    }

    /// The one frame a client may send, for request `id`.
    public func keepAwakeRequest(id: Int) throws -> String? {
        try runtime.call2("globalThis.KhaytWebcam.keepAwakeRequest(ARG0)",
                          [.number(Double(id))], as: String?.self)
    }

    /// `ok` | `error` | `other`, for a frame read back off the socket.
    public func keepAwakeReply(_ text: String, id: Int) throws -> String {
        try runtime.call2("globalThis.KhaytWebcam.keepAwakeReply(ARG0, ARG1)",
                          [.string(text), .number(Double(id))], as: String.self)
    }

    /// The socket's allow-list. Checked against the frame's own `method`.
    public func wsMethodAllowed(_ method: String) throws -> Bool {
        try runtime.call2("globalThis.KhaytWebcam.wsMethodAllowed(ARG0)",
                          [.string(method)], as: Bool.self)
    }

    /// Where to read and switch the chamber light.
    public struct ChamberLight: Decodable, Sendable, Equatable {
        public let queryUrl: String
        public let scriptUrl: String
        public let headers: [String: String]
    }

    public func chamberLight(machine: JSONValue) throws -> ChamberLight? {
        try runtime.call2("globalThis.KhaytWebcam.chamberLightFor(ARG0)",
                          [machine], as: ChamberLight?.self)
    }

    /// On, off, or nil when this printer has no such light.
    public func chamberLightState(_ body: JSONValue) throws -> Bool? {
        try runtime.call2("globalThis.KhaytWebcam.parseChamberLight(ARG0)",
                          [body], as: Bool?.self)
    }

    public func chamberLightScript(on: Bool) throws -> String? {
        try runtime.call2("globalThis.KhaytWebcam.chamberLightScript(ARG0)",
                          [.bool(on)], as: String?.self)
    }

    public func scriptAllowed(_ script: String) throws -> Bool {
        try runtime.call2("globalThis.KhaytWebcam.scriptAllowed(ARG0)",
                          [.string(script)], as: Bool.self)
    }
}
