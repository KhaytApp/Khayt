import Foundation
import KhaytCore

/// Free text on its way to an assistant — the last thing it passes through.
///
/// ── NAMES, THEN EVERY PERSONAL SHAPE ──────────────────────────────────────
///
/// A project the shop typed as "Nouf 0551234567 – pickup Thu" holds a phone
/// number however the name switch is set, and the privacy page promises that
/// phones, emails and addresses are never handed to an assistant. So every
/// free-text field a tool says goes through two steps, in this order:
///
/// 1. `CustomerNames.scrub` — customer names become labels (unless the shop
///    shares names), and any phone or email the book holds for a customer is
///    taken out as it was typed.
/// 2. `KhaytEngine.scrubPersonalData` — the telemetry scrubber's own
///    `scrubPii` (`lib/telemetry-scrub.js`): emails, phone numbers, IBANs and
///    long digit runs, whoever they belong to. The same rule decides what is
///    personal data here as in a crash report; there is no second list of
///    patterns in Swift to drift from it.
///
/// FAILS CLOSED: with no engine, or a scrubber that throws, every non-empty
/// text is said as `<redacted>` rather than handed on with step 2 skipped.
struct Outgoing: Sendable {
    let names: CustomerNames
    let engine: KhaytEngine?

    /// Every text, cleaned, in the order given — one crossing into the rules.
    func clean(_ texts: [String]) async -> [String] {
        if texts.isEmpty { return [] }
        let named = texts.map { names.scrub($0) }
        if let engine, let out = try? await engine.scrubPersonalData(named) { return out }
        return named.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0 : CustomerNames.redacted
        }
    }

    func clean(_ text: String) async -> String { await clean([text])[0] }

    /// Optional texts, cleaned; a nil stays nil.
    func clean(_ texts: [String?]) async -> [String?] {
        let present = texts.compactMap { $0 }
        var cleaned = await clean(present).makeIterator()
        return texts.map { $0 == nil ? nil : cleaned.next() }
    }
}
