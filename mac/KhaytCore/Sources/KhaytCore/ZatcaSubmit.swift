import Foundation

/// Reporting a Saudi tax invoice to ZATCA, Phase 2.
///
/// What these decide is not cosmetic. The invoice counter numbers a document in
/// a sequence a tax authority requires to be UNBROKEN, and `accepted` decides
/// whether an invoice already handed to a customer counts as reported.
public enum ZatcaSubmit {

    /// Base64-encode UTF-8 XML for the API payload.
    ///
    /// `Buffer` in a main process, `btoa` in a window — and neither exists in
    /// the other, which is why the original takes an encoder. Here there is
    /// one encoder and no split to paper over.
    public static func xmlToBase64(_ xml: String) -> String {
        Data(xml.utf8).base64EncodedString()
    }

    /// Whether Phase 2 submission prerequisites are met.
    public static func phase2Ready(settings: [String: JSONValue]) -> Bool {
        guard JSSemantics.truthy(settings["enableZatca"]),
              case .object(let z2)? = settings["zatcaPhase2"],
              JSSemantics.truthy(z2["enabled"]) else { return false }
        return JSSemantics.truthy(z2["pcsid"]) || JSSemantics.truthy(z2["csid"])
    }

    /// The counter value for a new submission — or the pending one again, so a
    /// retry does not burn a number out of a sequence that must not have gaps.
    ///
    /// ── THE ORIGINAL CONCATENATES, AND THIS REPRODUCES IT ─────────────────
    ///
    /// `(z2?.invoiceCounter || 0) + 1`. A counter stored as the STRING "5"
    /// is truthy, so `+ 1` appends rather than adds and the next invoice is
    /// numbered 51. The book writes a number and no shop has hit this, but a
    /// port that quietly answered 6 would be two apps disagreeing about a
    /// sequence a tax authority checks — so the fault is carried over, in the
    /// open, with a test on it, rather than fixed on one side only.
    public static func nextIcv(z2: JSONValue?, order: JSONValue?) -> JSONValue {
        if case .object(let o)? = order, case .object(let sub)? = o["zatcaSubmission"],
           let icv = sub["icv"], JSSemantics.truthy(icv) {
            return icv
        }
        var counter: JSONValue = .number(0)
        if case .object(let z)? = z2, let c = z["invoiceCounter"], JSSemantics.truthy(c) {
            counter = c
        }
        // `counter + 1` is JavaScript's `+`, which is addition only when both
        // sides are primitives that are not strings. An array or an object is
        // coerced to text first, so `[] + 1` is "1" and `{} + 1` is
        // "[object Object]1" — the harness found both.
        switch counter {
        case .number(let n): return .number(n + 1)
        case .bool(let b): return .number((b ? 1 : 0) + 1)
        default: return .string(JSSemantics.text(counter) + "1")
        }
    }

    /// True when an order is eligible for ZATCA reporting. A job still on the
    /// bench is not late to be reported.
    public static func eligible(_ order: JSONValue?) -> Bool {
        guard case .object(let o)? = order, !JSSemantics.truthy(o["voidedAt"]) else { return false }
        guard case .string(let status)? = o["status"] else { return false }
        return status == "completed" || status == "delivered"
    }

    /// Read a Fatoorah response as accepted or rejected.
    ///
    /// Anything that is not an explicit REJECTED counts as accepted, which is
    /// the original's shape: the authority answers with a status under one of
    /// three names depending on the endpoint, and a response that names none of
    /// them is not a rejection.
    public static func accepted(httpOk: Bool, body: JSONValue?) -> Bool {
        guard httpOk else { return false }
        var fields: [String: JSONValue] = [:]
        if case .object(let o)? = body { fields = o }
        var status: JSONValue?
        if case .object(let results)? = fields["validationResults"],
           let s = results["status"], JSSemantics.truthy(s) {
            status = s
        } else if let s = fields["reportingStatus"], JSSemantics.truthy(s) {
            status = s
        } else if let s = fields["clearanceStatus"], JSSemantics.truthy(s) {
            status = s
        }
        guard let status, JSSemantics.truthy(status) else { return true }
        // `.toUpperCase()`, which is locale-independent on both sides.
        return JSSemantics.text(status).uppercased() != "REJECTED"
    }

    /// One line of the submission log, trimmed for the store.
    ///
    /// `at` is passed in rather than read from a clock: the original calls
    /// `new Date()` inside, which is the one thing in the module that stops it
    /// being testable.
    public static func logEntry(order: JSONValue, payload: JSONValue, httpStatus: Int?,
                                manual: Bool, status: String, message: String,
                                at: String) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if case .object(let fields) = order { o = fields }
        var p: [String: JSONValue] = [:]
        if case .object(let fields) = payload { p = fields }
        return .object([
            "orderId": o["id"] ?? .null,
            "invoiceNumber": p["invoiceNumber"] ?? .null,
            "uuid": p["uuid"] ?? .null,
            "icv": p["invoiceCounter"] ?? .null,
            "at": .string(at),
            "status": .string(status),
            "httpStatus": httpStatus.map { JSONValue.number(Double($0)) } ?? .null,
            "message": .string(message),
            "manual": .bool(manual),
        ])
    }

    /// The submission log with one more line on the front, capped.
    ///
    /// Newest first, and only the last hundred: a log that grows for ever is a
    /// store that grows for ever, and it syncs.
    public static func appendingLog(_ existing: JSONValue?, _ entry: JSONValue) -> [JSONValue] {
        var log: [JSONValue] = []
        if case .array(let rows)? = existing { log = rows }
        log.insert(entry, at: 0)
        return Array(log.prefix(100))
    }
}
