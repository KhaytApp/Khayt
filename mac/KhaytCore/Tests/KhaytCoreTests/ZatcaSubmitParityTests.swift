import Foundation
import Testing
@testable import KhaytCore

/// Reporting a tax invoice, against the JavaScript it came from.
///
/// The invoice counter has to be an unbroken sequence and "accepted" decides
/// whether a document already handed to a customer counts as reported, so the
/// odd cases here are the point rather than the edges.
@MainActor
struct ZatcaSubmitParityTests {

    private func js() throws -> JSModule { try JSModule(["zatca-submit"]) }

    // MARK: - Ready

    @Test("the prerequisites are the same prerequisites")
    func readyMatches() throws {
        let js = try js()
        var cases: [JSONValue] = []
        for enable: JSONValue in [.bool(true), .bool(false), .null, .string("yes"), .number(0)] {
            for enabled: JSONValue in [.bool(true), .bool(false), .null] {
                for ids: [String: JSONValue] in [["pcsid": .string("P")], ["csid": .string("C")],
                                                 ["pcsid": .string(""), "csid": .string("C")],
                                                 ["pcsid": .string(""), "csid": .string("")],
                                                 [:]] {
                    var z2 = ids; z2["enabled"] = enabled
                    cases.append(.object(["enableZatca": enable, "zatcaPhase2": .object(z2)]))
                }
            }
        }
        cases.append(.object([:]))
        cases.append(.object(["enableZatca": .bool(true)]))
        cases.append(.object(["enableZatca": .bool(true), "zatcaPhase2": .null]))
        cases.append(.object(["enableZatca": .bool(true), "zatcaPhase2": .string("on")]))
        for settings in cases {
            guard case .object(let s) = settings else { continue }
            let theirs = try js.value("KhaytZatcaSubmit.zatcaPhase2Ready(ARG0)", [settings])
            #expect(.bool(ZatcaSubmit.phase2Ready(settings: s)) == theirs,
                    Comment(rawValue: "\(settings)"))
        }
    }

    // MARK: - The counter

    @Test("a retry reuses its pending number rather than burning one")
    func icvMatches() throws {
        let js = try js()
        let orders: [JSONValue] = [
            .object(["zatcaSubmission": .object(["icv": .number(7)])]),
            .object(["zatcaSubmission": .object(["icv": .number(0)])]),
            .object(["zatcaSubmission": .object([:])]),
            .object(["zatcaSubmission": .null]),
            .object([:]), .null,
        ]
        let counters: [JSONValue] = [
            .object(["invoiceCounter": .number(5)]),
            .object(["invoiceCounter": .number(0)]),
            .object(["invoiceCounter": .null]),
            .object([:]), .null,
        ]
        for z2 in counters {
            for order in orders {
                let theirs = try js.value("KhaytZatcaSubmit.nextZatcaIcv(ARG0, ARG1)", [z2, order])
                #expect(ZatcaSubmit.nextIcv(z2: z2, order: order) == theirs,
                        Comment(rawValue: "\(z2) / \(order)"))
            }
        }
    }

    @Test("a counter stored as text concatenates, in both apps")
    func icvConcatenates() throws {
        // `(z2.invoiceCounter || 0) + 1` on the string "5" is "51", not 6. The
        // book writes a number and no shop has hit this — but the two apps
        // must not disagree about a sequence a tax authority checks, so the
        // fault is carried over rather than fixed on one side.
        let js = try js()
        for counter: JSONValue in [.string("5"), .string(""), .string("0"), .bool(true),
                                   .array([]), .object([:])] {
            let z2: JSONValue = .object(["invoiceCounter": counter])
            let theirs = try js.value("KhaytZatcaSubmit.nextZatcaIcv(ARG0, null)", [z2])
            #expect(ZatcaSubmit.nextIcv(z2: z2, order: nil) == theirs,
                    Comment(rawValue: "a counter of \(counter)"))
        }
    }

    // MARK: - Eligible

    @Test("a job still on the bench is not late to be reported")
    func eligibleMatches() throws {
        let js = try js()
        var orders: [JSONValue] = []
        for status in ["completed", "delivered", "printing", "quote", "cancelled",
                       "on_hold", "", "COMPLETED"] {
            orders.append(.object(["status": .string(status)]))
            orders.append(.object(["status": .string(status), "voidedAt": .string("2026-09-01")]))
            orders.append(.object(["status": .string(status), "voidedAt": .null]))
            orders.append(.object(["status": .string(status), "voidedAt": .string("")]))
        }
        orders += [.object([:]), .null, .bool(false), .number(0), .string("x"),
                   .object(["status": .number(1)])]
        for order in orders {
            let theirs = try js.value("KhaytZatcaSubmit.orderEligibleForZatcaSubmit(ARG0)", [order])
            #expect(.bool(ZatcaSubmit.eligible(order)) == theirs, Comment(rawValue: "\(order)"))
        }
    }

    // MARK: - Accepted

    @Test("only an explicit rejection is a rejection")
    func acceptedMatches() throws {
        let js = try js()
        var bodies: [JSONValue] = [.null, .object([:]), .string("ok"), .number(1), .array([])]
        for status in ["REJECTED", "rejected", "Rejected", "ACCEPTED", "CLEARED",
                       "PENDING", "", "REJECTED "] {
            bodies.append(.object(["validationResults": .object(["status": .string(status)])]))
            bodies.append(.object(["reportingStatus": .string(status)]))
            bodies.append(.object(["clearanceStatus": .string(status)]))
            // The three names are read in order, so an empty first one falls
            // through to the next rather than answering for it.
            bodies.append(.object(["validationResults": .object(["status": .string("")]),
                                   "reportingStatus": .string(status)]))
            bodies.append(.object(["reportingStatus": .string(""),
                                   "clearanceStatus": .string(status)]))
        }
        bodies.append(.object(["validationResults": .null, "reportingStatus": .string("REJECTED")]))
        bodies.append(.object(["validationResults": .string("x")]))
        for httpOk in [true, false] {
            for body in bodies {
                let theirs = try js.value("KhaytZatcaSubmit.zatcaSubmitAccepted(ARG0, ARG1)",
                                          [.bool(httpOk), body])
                #expect(.bool(ZatcaSubmit.accepted(httpOk: httpOk, body: body)) == theirs,
                        Comment(rawValue: "\(httpOk) \(body)"))
            }
        }
    }

    // MARK: - The log

    @Test("a log line carries what the store keeps")
    func logEntryMatches() throws {
        let js = try js()
        let order: JSONValue = .object(["id": .string("A-1")])
        let payload: JSONValue = .object(["invoiceNumber": .string("INV-1"),
                                          "uuid": .string("u-1"), "invoiceCounter": .number(7)])
        let mine = ZatcaSubmit.logEntry(order: order, payload: payload, httpStatus: 200,
                                        manual: true, status: "accepted", message: "",
                                        at: "2026-09-18T00:00:00.000Z")
        let theirs = try js.value("""
            (function (a) {
              var e = KhaytZatcaSubmit.buildZatcaLogEntry({
                order: a.order, payload: a.payload, result: {status: 200},
                manual: 1, status: 'accepted', message: '',
              });
              e.at = a.at;   // the module reads the clock; the port is given one
              return e;
            })(ARG0)
            """, [.object(["order": order, "payload": payload,
                           "at": .string("2026-09-18T00:00:00.000Z")])])
        #expect(mine == theirs)
        // A failed attempt with no HTTP status at all.
        let none = ZatcaSubmit.logEntry(order: .object([:]), payload: .object([:]),
                                        httpStatus: nil, manual: false, status: "error",
                                        message: "no network", at: "x")
        guard case .object(let o) = none else { Issue.record("not an object"); return }
        #expect(o["httpStatus"] == .null)
        #expect(o["manual"] == .bool(false))
        #expect(o["orderId"] == .null)
    }

    @Test("the log is newest first and stops at a hundred")
    func logCaps() throws {
        let js = try js()
        let existing = (0..<150).map { JSONValue.number(Double($0)) }
        let mine = ZatcaSubmit.appendingLog(.array(existing), .string("new"))
        let theirs = try js.value("""
            (function (a) {
              var z2 = {submissions: a.log};
              KhaytZatcaSubmit.appendZatcaSubmissionLog(z2, a.entry);
              return z2.submissions;
            })(ARG0)
            """, [.object(["log": .array(existing), "entry": .string("new")])])
        #expect(.array(mine) == theirs)
        #expect(mine.count == 100)
        #expect(mine.first == .string("new"))
        // A log that is not a list yet starts one.
        for empty: JSONValue in [.null, .object([:]), .string("x")] {
            let started = ZatcaSubmit.appendingLog(empty, .string("first"))
            #expect(started == [.string("first")], Comment(rawValue: "\(empty)"))
        }
    }

    @Test("the payload is base64 of the XML's own bytes")
    func base64Matches() throws {
        let js = try js()
        // NEITHER FALLBACK EXISTS HERE. The module reaches for `Buffer` in a
        // main process and `btoa` in a window, and JavaScriptCore has neither —
        // so the shared module could not have encoded a payload on this Mac at
        // all, which is an argument for the port rather than an obstacle to
        // testing it. The encoder below is the one the module's own contract
        // names: base64 of the string's UTF-8 bytes.
        let encoder = """
            (function () {
              var A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
              return function (text) {
                var bytes = [];
                for (var i = 0; i < text.length; i++) {
                  var c = text.codePointAt(i);
                  if (c > 0xFFFF) i++;
                  if (c < 0x80) bytes.push(c);
                  else if (c < 0x800) bytes.push(0xC0 | (c >> 6), 0x80 | (c & 63));
                  else if (c < 0x10000) bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
                  else bytes.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
                }
                var out = '';
                for (var j = 0; j < bytes.length; j += 3) {
                  var b0 = bytes[j], b1 = bytes[j + 1], b2 = bytes[j + 2];
                  out += A[b0 >> 2] + A[((b0 & 3) << 4) | ((b1 === undefined ? 0 : b1) >> 4)];
                  out += b1 === undefined ? '=' : A[((b1 & 15) << 2) | ((b2 === undefined ? 0 : b2) >> 6)];
                  out += b2 === undefined ? '=' : A[b2 & 63];
                }
                return out;
              };
            })()
            """
        for xml in ["<Invoice/>", "", "<a>زهرة</a>", "<a>🌸</a>", "a", "ab", "abc",
                    "<a>" + String(repeating: "x", count: 1000) + "</a>"] {
            let theirs = try js.value(
                "KhaytZatcaSubmit.xmlToBase64(ARG0, {base64: \(encoder)})", [.string(xml)])
            #expect(.string(ZatcaSubmit.xmlToBase64(xml)) == theirs,
                    Comment(rawValue: xml.prefix(40).debugDescription))
        }
    }
}
