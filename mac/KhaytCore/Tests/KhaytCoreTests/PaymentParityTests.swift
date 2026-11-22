import Foundation
import Testing
@testable import KhaytCore

/// Swift and Node must agree about whether a shop has been paid.
///
/// "Is this paid" decides what appears in receivables, who gets chased and what
/// a period earned. It is now one rule rather than three, and this checks that
/// the one rule gives the same answer in both runtimes — including at the
/// boundaries, where a credit note and a gift card land on opposite sides of
/// the division.
struct PaymentParityTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        require('./lib/order-payment.js');
        process.stdout.write(String(JSON.stringify(\(expression))));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.currentDirectoryURL = repoRoot
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KhaytJSError.evaluationFailed("node exited \(process.terminationStatus)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Every shape the rule distinguishes, plus the ones it deliberately does not.
    static let ORDERS = """
    [{price:1000,paidAmount:1000},
     {price:1000,paidAmount:999.99},
     {price:1000,paidAmount:0},
     {price:1000},
     {price:1000,paidAmount:400,giftCardDiscount:600},
     {price:1000,paidAmount:400,giftCardDiscount:599.99},
     {price:1000,paidAmount:400,creditNotes:[{amount:600}]},
     {price:1000,paidAmount:0,creditNotes:[{amount:1000}]},
     {price:1000,paidAmount:0,creditNotes:[{amount:1200}]},
     {price:1000,paidAmount:500,voidedAt:'x'},
     {price:1000,paidAmount:500,creditedAt:'x'},
     {price:0},
     {price:0,paymentStatus:'unpaid'},
     {price:0,paidAmount:50},
     {price:0.03,paidAmount:0.01},
     {price:1000,creditNotes:[{amount:'junk'},{amount:null},{amount:400}],paidAmount:600}]
    """

    static let cases: [String] = [
        "\(ORDERS).map(KhaytOrderPayment.statusOf)",
        "\(ORDERS).map(KhaytOrderPayment.isOutstanding)",
        // Recording one: the clamp, the derived status, the date.
        "\(ORDERS).map(function(o){var c=JSON.parse(JSON.stringify(o));KhaytOrderPayment.recordPayment(c,{amount:750,method:'cash',paidAt:'2026-09-04'},{});return c;})",
        // An overpayment is a credit note, not a bigger paidAmount.
        "(function(){var o={price:100};KhaytOrderPayment.recordPayment(o,{amount:1e9},{});return o;})()",
        "(function(){var o={price:100};KhaytOrderPayment.recordPayment(o,{amount:-5},{});return o;})()",
        // Dated today when nobody says otherwise.
        "(function(){var o={price:100};KhaytOrderPayment.recordPayment(o,{amount:50},{today:'2026-09-04'});return o.paidAt;})()",
        // Cleared: owed again, whatever else is on it.
        "(function(){var o={price:100,paidAmount:100,giftCardDiscount:100,paidAt:'x',paymentMethod:'cash'};var r=KhaytOrderPayment.clearPayment(o);return [o,r.effects];})()",
        // Which effects a payment asks for, at each threshold.
        "[0,1,1000].map(function(a){var o={price:1000};return KhaytOrderPayment.recordPayment(o,{amount:a},{}).effects.map(function(e){return e.type+(e.event?':'+e.event:'');});})",
        // Floating point where two engines are likeliest to part company.
        "(function(){var o={price:0.1+0.2,paidAmount:0.3};return [KhaytOrderPayment.statusOf(o),0.1+0.2===0.3];})()",
    ]

    @Test("Swift and Node agree about what a shop has been paid")
    func parity() async throws {
        let engine = try KhaytEngine()
        for expression in Self.cases {
            let fromNode = try Self.node(expression)
            let fromSwift = try await engine.raw(expression, as: JSONValue.self)
            #expect(fromSwift == fromNode, "diverged for: \(expression)")
        }
    }
}
