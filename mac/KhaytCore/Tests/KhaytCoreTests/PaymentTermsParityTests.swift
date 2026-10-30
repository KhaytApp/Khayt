import Foundation
import Testing
@testable import KhaytCore

/// When a customer's invoice falls due, against the JavaScript it came from.
///
/// `lib/payment-terms.js` is the specification: receivables, the invoice and
/// the payment reminders read it in both apps, and the customer pane reads
/// this port. A disagreement would be one screen calling a debt overdue while
/// the next says it is not yet due.
@MainActor
struct PaymentTermsParityTests {

    private func js() throws -> JSModule { try JSModule(["payment-terms"]) }

    /// Every shape a stored `paymentTermsDays` has been seen in, and the ones
    /// a lenient parser would misread.
    private let terms: [JSONValue?] = [
        nil, .null, .number(0), .number(7), .number(30), .number(30.9), .number(-5),
        .number(365), .number(366), .number(1e12), .string(""), .string("30"),
        .string(" 45 "), .string("60.5"), .string("0x1e"), .string("1e2"), .string("-7"),
        .string("abc"), .string("30 days"), .bool(true), .bool(false),
        .array([.number(30)]), .object(["n": .number(30)]),
    ]

    private let dates: [JSONValue?] = [
        nil, .null, .string(""), .string("2026-09-04"), .string("2026-12-15"),
        .string("2028-02-01"), .string("2026-02-30"), .string("2026-13-01"),
        .string("2026-10-01T22:30:00.000Z"), .string("26-10-01"), .string("garbage"),
        .number(20261001), .number(0), .bool(true),
    ]

    private let todays = ["2026-09-04", "2026-10-04", "2026-10-05", "2027-01-14", "2028-03-01", ""]

    private func order(date: JSONValue?, timestamp: JSONValue? = nil,
                       extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var o = extra
        if let date { o["date"] = date }
        if let timestamp { o["timestamp"] = timestamp }
        return o
    }

    private func customer(_ t: JSONValue?) -> [String: JSONValue] {
        var c: [String: JSONValue] = ["id": .string("C")]
        if let t { c["paymentTermsDays"] = t }
        return c
    }

    @Test("termsDays reads every stored shape the same way")
    func termsMatch() throws {
        let js = try js()
        for t in terms {
            let c = customer(t)
            let theirs = try js.int("KhaytPaymentTerms.termsDays(ARG0)", [.object(c)])
            #expect(PaymentTerms.termsDays(customer: c) == theirs,
                    Comment(rawValue: "terms \(String(describing: t))"))
        }
        #expect(try js.int("KhaytPaymentTerms.termsDays(null)") == PaymentTerms.termsDays(customer: nil))
    }

    @Test("the presets are the same list")
    func presetsMatch() throws {
        let v = try js().value("KhaytPaymentTerms.PRESETS")
        guard case .array(let items) = v else { Issue.record("not a list"); return }
        #expect(items.compactMap { if case .number(let n) = $0 { return Int(n) } else { return nil } }
                == PaymentTerms.presets)
        #expect(try js().int("KhaytPaymentTerms.MAX_DAYS") == PaymentTerms.maxDays)
    }

    @Test("invoice date, due date, days past due and overdue agree on every case")
    func rulesMatch() throws {
        let js = try js()
        for date in dates {
            for ts in [nil, JSONValue.string("2026-03-08T10:00:00Z")] as [JSONValue?] {
                let o = order(date: date, timestamp: ts, extra: ["status": .string("completed")])
                let theirInvoice = try js.value("KhaytPaymentTerms.invoiceDate(ARG0)", [.object(o)])
                #expect(theirInvoice == .string(PaymentTerms.invoiceDate(o)),
                        Comment(rawValue: "invoiceDate \(o)"))
                for t in terms {
                    let c = customer(t)
                    let label = Comment(rawValue: "\(o) terms \(String(describing: t))")
                    let theirDue = try js.value("KhaytPaymentTerms.dueDate(ARG0, ARG1)", [.object(o), .object(c)])
                    #expect(theirDue == .string(PaymentTerms.dueDate(order: o, customer: c)), label)
                    for today in todays {
                        let theirPast = try js.value("KhaytPaymentTerms.daysPastDue(ARG0, ARG1, ARG2)",
                                                     [.object(o), .object(c), .string(today)])
                        let mine = PaymentTerms.daysPastDue(order: o, customer: c, today: today)
                        #expect(theirPast == (mine.map { .number(Double($0)) } ?? .null), label)
                        for settled in [false, true] {
                            let theirs = try js.bool("KhaytPaymentTerms.overdue(ARG0, ARG1, ARG2, ARG3)",
                                                     [.object(o), .object(c), .string(today), .bool(settled)])
                            #expect(theirs == PaymentTerms.overdue(order: o, customer: c, today: today,
                                                                   settled: settled), label)
                        }
                    }
                }
            }
        }
    }

    @Test("work that cannot owe is never overdue, in both")
    func cannotOweMatches() throws {
        let js = try js()
        let c = customer(.number(7))
        let cases: [[String: JSONValue]] = [
            ["status": .string("quote")], ["status": .string("cancelled")],
            ["voidedAt": .string("2026-01-02")], ["creditedAt": .string("2026-01-02")],
            ["voidedAt": .string("")], ["voidedAt": .bool(false)], ["voidedAt": .number(0)],
            ["voidedAt": .null], ["creditedAt": .object([:])], ["status": .string("completed")],
        ]
        for extra in cases {
            let o = order(date: .string("2020-01-01"), extra: extra)
            let theirs = try js.bool("KhaytPaymentTerms.overdue(ARG0, ARG1, ARG2, false)",
                                     [.object(o), .object(c), .string("2026-01-01")])
            #expect(theirs == PaymentTerms.overdue(order: o, customer: c, today: "2026-01-01", settled: false),
                    Comment(rawValue: "\(extra)"))
        }
    }

    @Test("a net-30 customer is not overdue until the day after the due day")
    func net30() {
        let o: [String: JSONValue] = ["date": .string("2026-10-01"), "status": .string("completed")]
        let c = customer(.number(30))
        #expect(PaymentTerms.dueDate(order: o, customer: c) == "2026-10-31")
        #expect(!PaymentTerms.overdue(order: o, customer: c, today: "2026-10-02", settled: false))
        #expect(!PaymentTerms.overdue(order: o, customer: c, today: "2026-10-31", settled: false))
        #expect(PaymentTerms.overdue(order: o, customer: c, today: "2026-11-01", settled: false))
        #expect(PaymentTerms.isPastDue(invoiceDate: "2026-10-01", terms: 30, today: "2026-11-01"))
        #expect(!PaymentTerms.isPastDue(invoiceDate: "2026-10-01", terms: 30, today: "2026-10-31"))
    }
}
