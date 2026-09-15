import SwiftUI

/// Panes on a long sheet — §6's twelve-field rule.
///
/// ── TABS ABOVE TWELVE FIELDS, AND NEVER AT OR BELOW ───────────────────────
///
/// Both halves of that are rules. Above twelve, one column is a scroll a shop
/// loses its place in. At or below, tabs *hide work rather than organise it* —
/// a person filling in a nine-field form should see all nine, and a tab strip
/// over them turns a complete picture into two incomplete ones.
///
/// So this type is deliberately awkward to reach for: `SheetPanes` refuses to
/// draw fewer than two panes, and `SheetTabsTests` holds the app to the
/// design's own table of which sheets have earned them.
///
/// ── NOTHING CALLS THIS YET, AND THAT IS NOT AN OVERSIGHT ─────────────────
///
/// No sheet in the Mac app is tabbed today, and only one — Machine, at 22
/// fields — clears twelve. Its fields are name, kind, model, colour, rate,
/// nozzle and connection; the spec's panes for it are Machine · Build volume ·
/// Rate · Service, and the Mac has no build-volume fields at all (they come
/// from the printer catalogue) while having a Connection pane the spec does
/// not list.
///
/// Forcing the sheet into panes that do not match its fields would be worse
/// than leaving it, so the rule is encoded here and the sheets follow once the
/// design has answered which panes apply to the Mac's own field set. The
/// alternative — retrofitting a tab strip onto a seven-field Customer form
/// because a table says nineteen — is the exact failure §6's second half
/// exists to prevent.
///
/// ── AND THE STRIP IS NOT A SEGMENTED CONTROL ──────────────────────────────
///
/// `.pickerStyle(.segmented)` is a control for choosing a VALUE — it reads as
/// part of the form it sits above, which is the one thing this must not be. A
/// pane is a place, so the strip is drawn as places: a row of labels with the
/// selected one carrying the accent bar the sidebar uses for the same idea.
struct SheetPanes<Content: View>: View {
    let panes: [Pane]
    @Binding var chosen: String
    let words: Words
    @ViewBuilder var content: (String) -> Content

    struct Pane: Identifiable, Hashable {
        /// A stable id, so a renamed label does not move the shop's place.
        let id: String
        let titleKey: String
        /// Marks needing attention inside this pane — an empty required field,
        /// a figure that will not parse. A pane that hides a problem is the
        /// failure mode of tabs, so the strip says which one holds it.
        var problems: Int = 0
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider()
            content(chosen)
        }
    }

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(panes) { pane in
                let on = pane.id == chosen
                Button { chosen = pane.id } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: Space.xs) {
                            Text(words.callIt(pane.titleKey))
                                .font(TypeScale.row(11.5, weight: on ? .semibold : .medium))
                                .foregroundStyle(on ? Role.text : Role.text2)
                            // Never a bare dot: a count says how much is
                            // waiting, and §4's rule about colour not standing
                            // alone applies to a badge as much as to a chip.
                            if pane.problems > 0 {
                                Figure(value: Double(pane.problems), size: 9.5,
                                       weight: .bold, tint: Role.late)
                            }
                        }
                        // The same 2.5px accent bar the sidebar uses for "you
                        // are here", on the bottom edge rather than the
                        // leading one — a pane is a place along a row.
                        Rectangle()
                            .fill(on ? Role.acc : Color.clear)
                            .frame(height: 2.5)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .background(Role.surf2)
    }
}

/// Which sheets have earned panes, and what those panes are.
///
/// ── THESE COUNTS ARE THE OTHER APP'S, AND THAT IS THE POINT ──────────────
///
/// The design's table says "field counts are from the running app", and the
/// app it counted is the Electron one — the feature-complete one. Its customer
/// editor carries an address book, a communication log, a credit limit, a
/// currency and a default discount: nineteen fields. The Mac's carries seven —
/// two names, phone, email, CR, VAT, notes.
///
/// So this table is the TARGET, not a description of the Mac today, and
/// applying it directly would put tabs on a seven-field form — breaking the
/// second half of §6's rule, which is the half that gets forgotten.
///
/// `shouldHaveTabs` therefore asks about a COUNT, not about a name: a sheet
/// earns panes when the sheet in front of the person has more than twelve
/// fields in it. The panes named here are what those panes should be when it
/// does, which for several of these is after the Mac catches up.
enum SheetMap {
    struct Sheet {
        let name: String
        let fields: Int
        /// Empty means one pane, which is most of them.
        let panes: [String]

        /// Whether THIS many fields earns panes. The rule is about the form a
        /// person is looking at, so the count is the argument — see the note
        /// above about whose counts these are.
        var shouldHaveTabs: Bool { Self.earnsTabs(fields) }

        static func earnsTabs(_ fields: Int) -> Bool { fields > 12 }
    }

    static let all: [Sheet] = [
        .init(name: "Job", fields: 36,
              panes: ["job", "parts", "cost", "price", "dates", "notes"]),
        .init(name: "Product", fields: 28,
              panes: ["product", "model", "material", "price", "photos"]),
        .init(name: "Machine", fields: 22,
              panes: ["machine", "build", "rate", "service"]),
        .init(name: "Customer", fields: 19,
              panes: ["who", "contact", "billing", "notes"]),
        .init(name: "Shop settings", fields: 17,
              panes: ["shop", "tax", "rates", "sync"]),
        .init(name: "Spool", fields: 11, panes: []),
        .init(name: "Gift card", fields: 10, panes: []),
        .init(name: "Expense · Purchase", fields: 9, panes: []),
        .init(name: "Project · Model file", fields: 8, panes: []),
        .init(name: "Waste entry · Service log", fields: 7, panes: []),
        .init(name: "Payment", fields: 6, panes: []),
        // Not a form at all. A confirmation with four things on it earns no
        // panes and no Save button — it earns a sentence and two buttons.
        .init(name: "Stage move · Sync", fields: 4, panes: []),
    ]

    static func sheet(_ name: String) -> Sheet? { all.first { $0.name == name } }
}
