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
/// "(inferred)": the lot may have been typed after the job, or edited since.
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
        var covered: [String: Int] = [:]
        func key(_ spoolId: String, _ grams: Double) -> String {
            spoolId + "|" + String(round2(grams))
        }
        func add(_ spoolId: String, _ grams: Double, own: String?) {
            let spool = byId[spoolId]
            let mine = (own ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let current = (spool?.lot ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Row(index: out.count, spoolId: spoolId, name: name(of: spool, id: spoolId),
                           color: spool?.color.flatMap { $0.isEmpty ? nil : $0 },
                           lot: mine.isEmpty ? current : mine,
                           grams: round2(grams), inferred: mine.isEmpty))
        }

        for d in order.materialDrawn?.spools ?? [] where d.grams > 0 {
            add(d.spoolId, d.grams, own: d.lot)
            covered[key(d.spoolId, d.grams), default: 0] += 1
        }
        for spool in spools {
            for h in spool.usageHistory ?? [] {
                guard h.orderId == order.id, h.type != "received", h.weightUsed > 0 else { continue }
                let k = key(spool.id, h.weightUsed)
                if let left = covered[k], left > 0 { covered[k] = left - 1; continue }
                add(spool.id, h.weightUsed, own: h.lot)
            }
        }
        return out
    }

    /// Every job a lot was drawn into — RECORDED on the job's own draws, or
    /// inferred from a spool carrying that lot — for the search box. `q` is
    /// already trimmed and lowercased; it matches anywhere in the lot.
    static func jobIds(drawingFromLotMatching q: String, orders: [Order], spools: [Spool]) -> Set<String> {
        guard !q.isEmpty else { return [] }
        var ids = Set<String>()
        for o in orders {
            if o.materialDrawn?.spools.contains(where: { ($0.lot ?? "").lowercased().contains(q) }) == true {
                ids.insert(o.id)
            }
        }
        for s in spools {
            let spoolLot = (s.lot ?? "").lowercased()
            for h in s.usageHistory ?? [] where h.type != "received" && !h.orderId.isEmpty {
                let lot = h.lot?.lowercased() ?? spoolLot
                if !lot.isEmpty, lot.contains(q) { ids.insert(h.orderId) }
            }
        }
        return ids
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).lineLimit(1)
                        if !row.lot.isEmpty {
                            Text(lotText(row))
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("\(Money.grams(row.grams)) \(shop.words.callIt("common.grams"))")
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
