import SwiftUI
import KhaytCore

/// Which spool — and which manufacturer's LOT — a job's filament came from.
///
/// ── THE SAME ANSWER AS `lib/lot-trace.js` ─────────────────────────────────
///
/// `rows(for:spools:)` is `KhaytLotTrace.lotsForJob` (without the waste log),
/// written in Swift because the inspector draws synchronously from decoded
/// records. It is pinned to the JavaScript by `FilamentUsedTests`, which runs
/// both on the sample book and compares them row for row — a rule with tests
/// that is not the rule running is this codebase's recurring bug.
///
///   1. `materialDrawn.spools` — what the completion took. A draw stamped
///      with a lot is RECORDED.
///   2. Each spool's `usageHistory` rows naming this job that (1) does not
///      already account for (same spool, same grams) — every job finished
///      before `materialDrawn` existed, and failed attempts.
///
/// A draw with no lot of its own takes the spool's CURRENT lot and is shown
/// "(inferred)": the lot may have been typed after the job, or edited since —
/// unless it is dated before the receipt that brought that lot in, when it
/// takes the lot then in force (`presumedLot`).
enum FilamentUsed {
    struct Row: Hashable, Identifiable {
        /// Position: one job can draw twice from one spool.
        let index: Int
        let spoolId: String
        /// What the spool is — material and colour name — or the bare id of
        /// a spool since deleted.
        let name: String
        /// The swatch, `#RRGGBB`, when the spool has one.
        let color: String?
        /// Empty when neither the draw nor the spool names a lot.
        let lot: String
        let grams: Double
        let inferred: Bool
        var id: Int { index }
    }

    static func rows(for order: Order, spools: [Spool]) -> [Row] {
        let byId = Dictionary(spools.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Row] = []
        // What the completion's record accounts for, as a TOTAL per spool —
        // `allDraws`' rule: a print that took twice off one spool has one
        // merged draw but two history rows, and a gram-for-gram match covers
        // neither and counts the job twice.
        var covered: [String: Double] = [:]
        func add(_ spoolId: String, _ grams: Double, own: String?, date: String) {
            let spool = byId[spoolId]
            let mine = (own ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Row(index: out.count, spoolId: spoolId, name: name(of: spool, id: spoolId),
                           color: spool?.color.flatMap { $0.isEmpty ? nil : $0 },
                           lot: mine.isEmpty ? presumedLot(spool, date: date) : mine,
                           grams: round2(grams), inferred: mine.isEmpty))
        }

        let finished = day(order.completedAt).isEmpty ? day(order.date) : day(order.completedAt)
        for d in order.materialDrawn?.spools ?? [] where d.grams > 0 {
            add(d.spoolId, d.grams, own: d.lot, date: finished)
            covered[d.spoolId] = round2((covered[d.spoolId] ?? 0) + round2(d.grams))
        }
        for spool in spools {
            for h in spool.usageHistory ?? [] {
                guard h.orderId == order.id, h.type != "received", h.weightUsed > 0 else { continue }
                let left = covered[spool.id] ?? 0
                let grams = round2(h.weightUsed - left)
                covered[spool.id] = max(0, round2(left - h.weightUsed))
                guard grams > 0 else { continue }
                add(spool.id, grams, own: h.lot, date: day(h.date))
            }
        }
        return out
    }

    /// `presumedLot` in lib/lot-trace.js: the lot a draw with none of its own
    /// is presumed to be from. The spool's current lot — except for a draw
    /// dated BEFORE the run of receipts that brought that lot in (an empty
    /// spool refilled with a new lot keeps its id), which takes the lot of the
    /// receipt then in force, or none. Taking the current lot for those named
    /// the wrong lot in a recall (Oct 2026 review).
    static func presumedLot(_ spool: Spool?, date: String) -> String {
        let current = (spool?.lot ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spool, !date.isEmpty, !current.isEmpty else { return current }
        let receipts = (spool.usageHistory ?? []).filter { $0.type == "received" && !day($0.date).isEmpty }
        var since = ""
        for h in receipts {
            guard sameLot(h.lot, current) else { break }
            since = day(h.date)
        }
        if since.isEmpty || date >= since { return current }
        let then = receipts.first { day($0.date) <= date }
        return (then?.lot ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed, case folded; two blanks are NOT the same lot.
    static func sameLot(_ a: String?, _ b: String?) -> Bool {
        let x = (a ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !x.isEmpty && x == (b ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `dayOf`: the `YYYY-MM-DD` a stamp starts with, or empty.
    static func day(_ v: String?) -> String {
        let s = v ?? ""
        guard s.count >= 10, s.prefix(10).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return "" }
        return String(s.prefix(10))
    }

    /// Every job a lot was drawn into — RECORDED on the job's own draws, or
    /// inferred from a spool carrying that lot — for the search box. `q` is
    /// already trimmed and lowercased; it matches anywhere in the lot.
    static func jobIds(drawingFromLotMatching q: String, orders: [Order], spools: [Spool]) -> Set<String> {
        Set(lots(matching: q, orders: orders, spools: spools).keys)
    }

    /// The same jobs, each with the lot that matched, as written — so the row
    /// a search turned up can say WHY it is there. "gb-2406" found two jobs
    /// whose rows mentioned no lot at all (alpha.79 review). A job's own
    /// recorded draw wins over a spool's inferred lot.
    static func lots(matching q: String, orders: [Order], spools: [Spool]) -> [String: String] {
        guard !q.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for o in orders {
            if let lot = o.materialDrawn?.spools.lazy.compactMap(\.lot)
                .first(where: { $0.lowercased().contains(q) }) {
                out[o.id] = lot
            }
        }
        for s in spools {
            for h in s.usageHistory ?? [] where h.type != "received" && !h.orderId.isEmpty
                && out[h.orderId] == nil {
                let own = (h.lot ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let lot = own.isEmpty ? presumedLot(s, date: day(h.date)) : own
                if !lot.isEmpty, lot.lowercased().contains(q) { out[h.orderId] = lot }
            }
        }
        return out
    }

    /// "PLA+ · Galaxy Black" — what tells one roll from another in a list.
    static func name(of spool: Spool?, id: String) -> String {
        guard let spool else { return id }
        let colour = (spool.colourVariant ?? "").trimmingCharacters(in: .whitespaces)
        return colour.isEmpty ? spool.material : spool.material + " · " + colour
    }

    private static func round2(_ n: Double) -> Double { (n * 100).rounded() / 100 }
}

/// The inspector's "Filament used": spool · lot · grams per draw. Hidden when
/// the job drew nothing.
struct FilamentUsedSection: View {
    let shop: Shop
    let rows: [FilamentUsed.Row]

    var body: some View {
        DetailSection(shop.words.callIt("mac.filament_used")) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color(nsColor: row.color.flatMap { NSColor(hex: $0) } ?? .tertiaryLabelColor))
                        .frame(width: 9, height: 9)
                        // A ring, or a black filament's dot vanishes in dark mode.
                        .overlay(Circle().strokeBorder(.separator))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).lineLimit(1)
                        if !row.lot.isEmpty {
                            Text(lotText(row))
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: "\(Money.grams(row.grams)) \(shop.words.callIt("common.grams"))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func lotText(_ row: FilamentUsed.Row) -> String {
        let said = shop.words.callIt("mac.lot_label", ["lot": .string(row.lot)])
        return row.inferred ? said + " " + shop.words.callIt("mac.lot_inferred") : said
    }
}
