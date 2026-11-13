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

    // MARK: - The parse that may be the last thing the process does

    /// An argument big enough to be worth a line before it is parsed.
    ///
    /// ── THE CRASH THIS IS FOR, AND WHAT IS KNOWN ABOUT IT ─────────────────
    ///
    /// Ten times between Oct 14 and Nov 12 2026 a process died with SIGSEGV
    /// inside `JSON.parse`, under `JSRuntime.bind`, while a shop was loading:
    /// once in the app, nine times in the test suite. Each was a rule being
    /// handed the sample shop's whole library or whole book, 24–26 MB of
    /// JSON. #2438 stopped sending those and it has not been seen since,
    /// which is not the same as knowing why.
    ///
    /// The nine November reports are the same fault to the instruction:
    /// `LiteralParser::parseRecursively + 648`, three to five objects deep,
    /// always on `khayt.engine.0`. Disassembled, that instruction reads the
    /// property name of the structure an object is about to move to (the
    /// single transition of its present structure), and the name is null
    /// while the structure still says it adds a property. A structure in that
    /// state has been destroyed, or had its table pinned, while another still
    /// pointed at it; and in all nine it is the cell immediately after the
    /// one pointing at it. So the fault is in JavaScriptCore's own
    /// bookkeeping of object shapes during a large parse. It is NOT:
    ///
    /// - the stack: three to five frames of an 8 MB stack, and the parser
    ///   checks its own limit on entry;
    /// - the string handed over: the address that faulted is 0x10, a field
    ///   of a null name, not a character of the input;
    /// - a second thread in the context: every entry takes the VM's lock,
    ///   and every call runs on the engine's one thread;
    /// - reproduced: in a process with nothing but JavaScriptCore in it,
    ///   7,200 parses on four threads at once (2,400 of them a 47 MB book,
    ///   in fresh contexts with these modules loaded), the shapes of the
    ///   crash written out by hand, and 1,200 shop loads in miniature did
    ///   not fault once.
    ///
    /// One thing every one of the nine had in common is not ruled out: the
    /// test process was using more memory than the machine has (see
    /// `Tests/KhaytTestWidth/width.c`), and none of the attempts above was
    /// made on a machine in that state.
    ///
    /// So it is not fixed here, and nothing here pretends to make it less
    /// likely. What was missing each time was any way to tell one crash's
    /// circumstances from another's: how big the argument was, which
    /// argument, and how much the context had parsed before. That is this
    /// record, written BEFORE the parse because afterwards there may be
    /// nobody to write it.
    public struct LargeParse: Sendable, Equatable {
        /// The argument's JSON, in UTF-8 bytes.
        public let bytes: Int
        /// Which argument of the call, and how many the call had.
        public let argument: Int
        public let of: Int
        /// How many arguments this context had parsed before this one.
        public let parsesBefore: Int
        /// The thread it was parsed on and how much stack that thread has.
        public let thread: String
        public let stackBytes: Int
        public let at: Date
    }

    /// 4 MB. The arguments that crashed were six times this; almost every
    /// call passes kilobytes, so this is silent for nearly all of them.
    static let largeParseBytes = 4 << 20

    nonisolated(unsafe) private static var largeParses: [LargeParse] = []

    /// The last few large parses that were started, oldest first.
    public static func recentLargeParses() -> [LargeParse] {
        lock.lock(); defer { lock.unlock() }
        return largeParses
    }

    /// Record a parse that is about to start, and say so on standard error
    /// in a debug build (which is what `swift test` and CI run) or wherever
    /// `KHAYT_ENGINE_LOG` is set. A shop's release build stays silent.
    static func aboutToParse(bytes: Int, argument: Int, of count: Int, parsesBefore: Int) {
        guard bytes >= largeParseBytes else { return }
        let parse = LargeParse(bytes: bytes, argument: argument, of: count,
                               parsesBefore: parsesBefore,
                               thread: Thread.current.name ?? "",
                               stackBytes: pthread_get_stacksize_np(pthread_self()),
                               at: Date())
        lock.lock()
        largeParses.append(parse)
        if largeParses.count > keep { largeParses.removeFirst(largeParses.count - keep) }
        var echo = echoing
        lock.unlock()
        #if DEBUG
        echo = true
        #endif
        if echo {
            FileHandle.standardError.write(Data("""
                KhaytEngine: about to JSON.parse \(bytes) bytes (argument \(argument) of \(count)) \
                on \(parse.thread.isEmpty ? "an unnamed thread" : parse.thread), \
                stack \(parse.stackBytes) bytes, \(parsesBefore) arguments parsed in this context before it. \
                If the process dies in JSON.parse next, this was the parse (see EngineFaults.LargeParse).

                """.utf8))
        }
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
