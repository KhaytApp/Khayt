import Foundation

/// Where a JavaScript fault goes when nobody catches it.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// This app asks the shared rules 263 questions, and almost every one of them
/// is asked with `try?`. That is deliberate and it is right: a fault in one
/// rule should not take a window down, and a screen that can say "not known"
/// is better than a screen that is not there.
///
/// The cost is that the fault itself disappears. `lib/invoice-document.js`
/// called a function that exists only in the other app's window; in
/// JavaScriptCore that is a `ReferenceError`, `Invoice.document` swallowed it
/// as nil, and for every shop with loyalty switched on the Invoice button said
/// "This job's invoice could not be built" and nothing else. Nothing was
/// logged. It was found by photographing the app.
///
/// So the fault is recorded here on its way past. Every engine call in both
/// products goes through `JSRuntime.evaluate`, so one place covers all of
/// them, and nothing about what the caller sees changes: the throw still
/// throws, the `try?` still swallows, the screen still says what it said.
///
/// ── WHAT IT IS NOT ────────────────────────────────────────────────────────
///
/// Not telemetry and not a file. It is a ring buffer in memory, it holds the
/// last handful, and it goes when the app does. A shop's book is full of
/// customers' names and a shop's own secrets, and an engine script carries its
/// arguments inline — which is why what is kept is the error and the SHAPE of
/// the call, never the arguments. See `summary(of:)`.
public enum EngineFaults {

    /// One thing that went wrong inside the rules.
    public struct Fault: Sendable, Equatable {
        /// What JavaScriptCore said.
        public let problem: String
        /// The call it came from, with its data taken out.
        public let call: String
        public let at: Date
    }

    /// Small on purpose. This is for "what just failed", not a history — and
    /// an unbounded list in a process that runs for days is a leak with a
    /// justification attached.
    static let keep = 16

    private static let lock = NSLock()
    nonisolated(unsafe) private static var faults: [Fault] = []

    /// Whether faults are also written to standard error as they happen.
    ///
    /// Off unless `KHAYT_ENGINE_LOG` is set, so a shop's run is silent and a
    /// session looking for one of these gets it without a rebuild.
    nonisolated(unsafe) public static var echoing =
        ProcessInfo.processInfo.environment["KHAYT_ENGINE_LOG"] != nil

    static func record(_ problem: String, script: String) {
        let fault = Fault(problem: problem, call: summary(of: script), at: Date())
        lock.lock()
        faults.append(fault)
        if faults.count > keep { faults.removeFirst(faults.count - keep) }
        let echo = echoing
        lock.unlock()
        if echo {
            FileHandle.standardError.write(
                Data("KhaytEngine fault: \(fault.problem)  [\(fault.call)]\n".utf8))
        }
    }

    /// The last faults, oldest first.
    public static func recent() -> [Fault] {
        lock.lock(); defer { lock.unlock() }
        return faults
    }

    /// Forget them — for a test that wants to watch one call.
    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        faults.removeAll()
    }

    /// The shape of a call, with the data taken out.
    ///
    /// An engine script carries its arguments INLINE — `call2` substitutes the
    /// JSON into the expression before evaluating it — so the script that
    /// failed can hold a customer's name, a printer's password, or a whole
    /// book. None of that belongs in a diagnostic, so this keeps the leading
    /// identifiers and throws the rest away.
    ///
    /// `KhaytInvoiceDocument.invoiceHtml({"client":"Najd Architects",…})`
    /// becomes `KhaytInvoiceDocument.invoiceHtml(…)`.
    static func summary(of script: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first line is enough to say which rule was asked.
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1,
                                      omittingEmptySubsequences: false)[0]
        var out = ""
        for character in firstLine {
            // Identifiers and dots name the call; the first bracket or quote
            // is where the data starts.
            if character.isLetter || character.isNumber || character == "." || character == "_"
                || character == "$" {
                out.append(character)
            } else if character == "(" || character == "[" || character == "{"
                        || character == "\"" || character == "'" {
                out.append("(…)")
                break
            } else if !out.isEmpty {
                out.append(" ")
            }
        }
        let shaped = out.trimmingCharacters(in: .whitespaces)
        return shaped.isEmpty ? "(an expression)" : String(shaped.prefix(120))
    }
}
