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
