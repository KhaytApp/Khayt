import Foundation
import MetricKit
import KhaytCore

/// The crashes `LastWords` cannot see, told by the system at the next launch.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// The crash feed was the shared rules' failures and the note `LastWords`
/// leaves for an uncaught Objective-C exception. A SWIFT trap — an index out
/// of range, a force-unwrap of nil, a `precondition` — is neither, and
/// nothing in-process can catch one. So the one real crash the shipped app
/// had in its first ten days of reports (alpha.77, 17 October 2026: Settings
/// ▸ Overhead, `Array._checkSubscript` under `SystemTextField`, fixed by
/// #1911) reached the cloud as nothing at all, and the report said "0
/// crashes" with an opted-in install that had crashed.
///
/// MetricKit is Apple's answer (`MXCrashDiagnostic`, macOS 12+): the system
/// writes the report, and hands it to the app the next time it runs. What is
/// kept of it is the SHAPE — the Mach exception, the signal, the build that
/// crashed, and the crashing thread's frames as `binary +0xoffset` — and it
/// goes through the same scrubber as every other event. Offsets are hex
/// because the scrubber takes a run of nine digits for a card number.
///
/// An Objective-C exception is left to `LastWords`, which has its reason;
/// MetricKit's copy of the same crash would be a second report of one crash.
struct NativeCrash: Equatable, Sendable {
    var exceptionType: Int?
    var signal: Int?
    /// `CFBundleVersion` of the build that crashed — not always this one.
    var build: String?
    var terminationReason: String?
    /// The crashing thread, crashing frame first, `binary +0xoffset`.
    var frames: [String]

    /// The frames of the attributed thread in `MXCallStackTree`'s JSON —
    /// `callStacks[].callStackRootFrames[]`, each frame's caller its one
    /// `subFrames` entry. A tree that does not parse gives no frames rather
    /// than no report: the exception and signal still say what happened.
    nonisolated static func frames(fromCallStackJSON data: Data, limit: Int = 30) -> [String] {
        guard let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        var out: [String] = []
        while let f = frame, out.count < limit {
            let binary = (f["binaryName"] as? String) ?? "?"
            if let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value {
                out.append("\(binary) +0x\(String(offset, radix: 16))")
            } else {
                out.append(binary)
            }
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return out
    }

    nonisolated static func exceptionName(_ type: Int?) -> String? {
        guard let type else { return nil }
        let names = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
                     5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"]
        return names[type] ?? "EXC_\(type)"
    }

    nonisolated static func signalName(_ signal: Int?) -> String? {
        guard let signal else { return nil }
        let names = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS",
                     11: "SIGSEGV", 13: "SIGPIPE"]
        return names[signal] ?? "SIG\(signal)"
    }
}

extension TelemetryRaw {

    /// A crash the system reported. `name` is the signal (what a person
    /// searching for it would type); `message` the Mach exception, the build
    /// that crashed and the system's own termination reason.
    static func crash(native: NativeCrash, _ c: Context) -> [String: JSONValue] {
        var message = [NativeCrash.exceptionName(native.exceptionType)].compactMap { $0 }
        if let build = native.build, !build.isEmpty { message.append("build \(build)") }
        if let why = native.terminationReason, !why.isEmpty { message.append(why) }
        return common(c).merging([
            "type": .string("unknown"),
            "name": .string(NativeCrash.signalName(native.signal) ?? "NativeCrash"),
            "message": .string(message.joined(separator: ", ")),
            "stack": .string(native.frames.joined(separator: "\n")),
            "process": .string("main"),
        ]) { _, new in new }
    }

    /// The report Settings ▸ "Send a Test Report" sends: proof that a crash
    /// report leaves this Mac and reaches the cloud, without a crash. Its
    /// name says what it is, so nobody reading the cloud's report mistakes it.
    static func testCrash(_ c: Context) -> [String: JSONValue] {
        common(c).merging([
            "type": .string("unknown"),
            "name": .string("TestReport"),
            "message": .string("A test report, sent from Settings"),
            "stack": .string(""),
            "process": .string("main"),
        ]) { _, new in new }
    }
}

/// MetricKit's subscriber. MetricKit calls it on a queue of its own; what it
/// needs is copied out there and handed to the main actor as plain values.
final class NativeCrashListener: NSObject, MXMetricManagerSubscriber {
    let deliver: @Sendable ([NativeCrash]) -> Void

    init(deliver: @escaping @Sendable ([NativeCrash]) -> Void) {
        self.deliver = deliver
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var crashes: [NativeCrash] = []
        for payload in payloads {
            for d in payload.crashDiagnostics ?? [] {
                // An Objective-C exception: `LastWords` reports it, with its reason.
                if d.exceptionReason != nil { continue }
                crashes.append(NativeCrash(exceptionType: d.exceptionType?.intValue,
                                           signal: d.signal?.intValue,
                                           build: d.metaData.applicationBuildVersion,
                                           terminationReason: d.terminationReason,
                                           frames: NativeCrash.frames(fromCallStackJSON: d.callStackTree.jsonRepresentation())))
            }
        }
        if !crashes.isEmpty { deliver(crashes) }
    }
}
