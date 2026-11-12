import Foundation

/// MEASUREMENT ONLY (Nov 11 2026, uncommitted): what each crossing into
/// JavaScript cost, split into its parts. Off unless a harness turns it on.
public enum MeasureProbe {
    public struct Call: Codable, Sendable {
        public var name: String
        public var args: Int
        public var argBytes: Int
        public var resultBytes: Int
        public var encodeNs: UInt64     // Swift values -> JSON text
        public var parseNs: UInt64      // JSON.parse inside JavaScript + binding
        public var ruleNs: UInt64       // the rule itself
        public var stringifyNs: UInt64  // JSON.stringify inside JavaScript + copy out
        public var decodeNs: UInt64     // JSON text -> Swift values
        public var totalNs: UInt64 { encodeNs + parseNs + ruleNs + stringifyNs + decodeNs }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var calls: [Call] = []
    nonisolated(unsafe) private static var engines: [UInt64] = []

    public static var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }
    public static func record(_ call: Call) { lock.lock(); calls.append(call); lock.unlock() }
    public static func engineMade(ns: UInt64) { lock.lock(); engines.append(ns); lock.unlock() }
    /// Everything recorded since the last take.
    public static func take() -> (calls: [Call], engines: [UInt64]) {
        lock.lock(); defer { lock.unlock() }
        let out = (calls, engines)
        calls = []; engines = []
        return out
    }
    /// CPU time of the calling thread, not the wall clock: an engine call runs
    /// on the engine's own thread from start to end, and the machine these
    /// were taken on had other work running.
    public static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
}
