import SwiftUI
import KhaytCore

/// What the shop pays every month whether it prints anything or not.
///
/// ── THE SCREEN POINTED AT A DOOR THIS APP DID NOT HAVE ────────────────────
///
/// `BreakEven` already says the right thing when there is nothing here: *"No
/// fixed costs are set, so there is no target to reach. Add rent,
/// subscriptions and anything else that is paid every month in Settings."*
/// Its comment is careful about it — "NOT 'no data'. A shop reaches this by
/// never having told Khayt what it pays every month, which is a thing it can
/// go and do — so the screen says what and where."
///
/// And Settings had nowhere to do it. The sentence was written for the other
/// app's Settings and shipped in this one, so a shop following the instruction
/// arrived at a pane that did not exist.
///
/// It is not only the break-even target: `lib/pnl-report.js` puts a quarter's
/// share of these into the Profit & Loss, so a Mac-only shop's P&L has been
/// computed as though the business had no overhead at all — a wrong figure
/// rather than a missing one, which is the worse kind.
struct FixedCostsSettings: View {
    let shop: Shop

    /// One line a shop can type. `id` is carried so that editing a row is not
    /// deleting it and adding another — the other app keys its list on it.
    struct Line: Identifiable, Equatable {
        var id: String
        var name: String
        var amount: Double
    }

    @State private var lines: [Line] = []
    @State private var original: [Line] = []

    private var total: Double { lines.reduce(0) { $0 + $1.amount } }

    var body: some View {
        Section(shop.words.callIt("mac.fixed_section")) {
            if lines.isEmpty {
                Text(shop.words.callIt("mac.fixed_none"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($lines) { $line in
                HStack {
                    TextField(shop.words.callIt("mac.fixed_name_ph"), text: $line.name)
                        .frame(maxWidth: .infinity)
                    TextField("0", value: $line.amount,
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Button {
                        lines.removeAll { $0.id == line.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(shop.words.callIt("mac.fixed_remove"))
                }
            }

            HStack {
                Button(shop.words.callIt("mac.fixed_add")) {
                    lines.append(Line(id: "fc_" + UUID().uuidString.prefix(8).lowercased(),
                                      name: "", amount: 0))
                }
                Spacer()
                // The total, because it is the number the break-even target is
                // built from and a shop typing six rows should not have to add
                // them up to check.
                //
                // AND IT IS THE ONLY PLACE THE CURRENCY APPEARS. The first
                // draft put "SAR" beside every field — three repetitions of
                // the code, two lines above a total reading "3,510.00 ﷼",
                // which is two notations for one currency on one small pane.
                // `Money.text` is how this app writes money; the fields are
                // bare numbers and the total says what they are in.
                if !lines.isEmpty {
                    Text(shop.words.callIt("mac.fixed_total") + " "
                         + Money.text(total, shop.currency))
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }

            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(lines == original)
                if lines != original {
                    Button(shop.words.callIt("common.cancel")) { lines = original }
                }
                Spacer()
            }
        }
        .task(id: shop.settingsValue) { reload() }
    }

    private func reload() {
        original = Self.read(shop.settingsDict)
        lines = original
    }

    static func read(_ settings: [String: JSONValue]) -> [Line] {
        guard case .array(let rows)? = settings["fixedCosts"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let c) = row else { return nil }
            return Line(id: Shop.plainString(c["id"]) ?? UUID().uuidString,
                        name: Shop.plainString(c["name"]) ?? "",
                        amount: Shop.plainNumber(c["amount"]) ?? 0)
        }
    }

    private func save() async {
        // SENT WHOLE. A row removed on screen has to be a row removed in the
        // book, so this is the list and not a merge into the stored one.
        await shop.saveSettings(["fixedCosts": .array(lines.map { line in
            .object(["id": .string(line.id),
                     "name": .string(line.name),
                     "amount": .number(line.amount)])
        })])
        reload()
    }
}
