import Foundation
import Testing
@testable import KhaytCore

/// A fault in the rules leaves a trace.
///
/// 263 engine calls in this app are asked with `try?`, which is right — a
/// fault in one rule should not take a window down. The cost is that the fault
/// disappears: `lib/invoice-document.js` reached for a function that exists
/// only in the other app's window, `Invoice.document` swallowed the
/// `ReferenceError` as nil, and every shop with loyalty on was told "This
/// job's invoice could not be built" with nothing written down anywhere. It
/// was found by photographing the app.
/// SERIALIZED, and every assertion looks for its own marker.
///
/// The buffer is one global for the whole process and Swift Testing runs
/// suites in parallel — plenty of other tests ask the engine something that
/// throws. A test that counted the faults was reading other suites' work and
/// failed on a machine that was merely busy, which is the flake this file
/// should be the last place to introduce.
@Suite(.serialized)
struct EngineFaultsTests {

    @Test("a throwing call is recorded, and the caller still sees the throw")
    func faultIsRecorded() throws {
        EngineFaults.clear()
        let runtime = try JSRuntime(modules: [])
        #expect(throws: (any Error).self) {
            _ = try runtime.evaluate("thisFunctionDoesNotExistAnywhere_a41()")
        }
        #expect(EngineFaults.recent().contains {
            $0.problem.contains("thisFunctionDoesNotExistAnywhere_a41")
        }, "the fault was not recorded")
    }

    @Test("a call that works records nothing")
    func successIsSilent() throws {
        EngineFaults.clear()
        let runtime = try JSRuntime(modules: [])
        _ = try runtime.evaluate("(function nothingWrongHere_b92() { return 1 + 1; })()")
        #expect(!EngineFaults.recent().contains { $0.call.contains("nothingWrongHere_b92") },
                "a working call left a fault behind")
    }

    /// A process has died inside `JSON.parse` of a 26 MB argument and left
    /// nothing to say which parse it was. A large one is written down before
    /// it starts; see `EngineFaults.LargeParse` for what is known.
    @Test("a large argument is recorded before it is parsed, with its size and where it ran")
    func aLargeParseIsRecordedFirst() throws {
        let runtime = try JSRuntime(modules: [])
        // A length no other suite's argument will have: this buffer is one
        // global for the whole process, so the test looks for its own.
        let text = String(repeating: "x", count: EngineFaults.largeParseBytes + 40_417)
        _ = try runtime.call2("ARG0.length", [.string("warm")], as: Int.self)
        let length = try runtime.call2("ARG1.length", [.string("small"), .string(text)], as: Int.self)
        #expect(length == text.count)

        let mine = EngineFaults.recentLargeParses().filter { $0.bytes == text.utf8.count + 2 }
        let parse = try #require(mine.last, "the large argument was not recorded")
        #expect(mine.count == 1, "the small arguments beside it were recorded too")
        #expect(parse.argument == 1 && parse.of == 2)
        #expect(parse.parsesBefore == 2, "one warm-up argument, then the small one in the same call")
        #expect(parse.stackBytes == pthread_get_stacksize_np(pthread_self()))
    }

    @Test("an engine's large argument is parsed on the engine's 8 MB thread")
    func anEnginesLargeParseIsOnItsThread() async throws {
        let engine = try KhaytEngine()
        let text = String(repeating: "y", count: EngineFaults.largeParseBytes + 51_733)
        let length = try await engine.length(of: text)
        #expect(length == text.count)
        let parse = try #require(EngineFaults.recentLargeParses().last { $0.bytes == text.utf8.count + 2 })
        #expect(parse.thread.hasPrefix("khayt.engine."))
        #expect(parse.stackBytes >= EngineThread.stackBytes)
    }

    /// THE ONE THAT MATTERS. A script carries its arguments inline, so the
    /// text that failed can hold a customer's name or a shop's password. The
    /// record keeps the shape of the call and nothing else.
    @Test("the record keeps the call's shape and none of its data")
    func argumentsAreNotKept() {
        let script = """
            KhaytInvoiceDocument.invoiceHtml({"client":"Najd Architects","vat":"300123456700003"}, \
            {"smtpPassword":"hunter2"})
            """
        let summary = EngineFaults.summary(of: script)
        #expect(summary.contains("KhaytInvoiceDocument.invoiceHtml"), "it no longer says which rule")
        for secret in ["Najd Architects", "300123456700003", "hunter2", "smtpPassword"] {
            #expect(!summary.contains(secret), "the record carries \(secret)")
        }
    }

    @Test("the shape survives the awkward scripts")
    func summaryIsRobust() {
        #expect(EngineFaults.summary(of: "KhaytTax.profileFromSettings({})")
                    .hasPrefix("KhaytTax.profileFromSettings"))
        // A whole function body, as `INVOICE_SCRIPT` is: the first line names it.
        #expect(!EngineFaults.summary(of: "(function () {\n  var order = {\"id\":\"ORD-1\"};\n})()")
                    .contains("ORD-1"))
        // Nothing useful in it at all is still not a crash.
        #expect(!EngineFaults.summary(of: "   ").isEmpty)
        #expect(!EngineFaults.summary(of: "\"\"").isEmpty)
    }

    /// The buffer is bounded: this runs inside an app that stays open for days.
    @Test("only the last few are kept")
    func ringIsBounded() throws {
        EngineFaults.clear()
        let runtime = try JSRuntime(modules: [])
        for i in 0..<(EngineFaults.keep + 5) {
            _ = try? runtime.evaluate("missingFunction\(i)()")
        }
        #expect(EngineFaults.recent().count <= EngineFaults.keep,
                "the buffer is unbounded: \(EngineFaults.recent().count)")
        // Oldest first, so the newest fault is the last one — which is the one
        // a session looking at this actually wants. Twenty is the last of the
        // twenty-one this loop asked for.
        #expect(EngineFaults.recent().last?.problem.contains("missingFunction20") == true,
                "the newest fault is not the last one")
    }
}

extension KhaytEngine {
    /// A call with one argument, bound and parsed as every engine call's are.
    func length(of text: String) throws -> Int {
        try runtime.call2("ARG0.length", [.string(text)], as: Int.self)
    }
}
