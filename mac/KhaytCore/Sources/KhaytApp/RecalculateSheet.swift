import SwiftUI
import KhaytCore

/// Price a job again from its parts: the markup, then old → new before
/// anything is saved; the customer's seen price and a sent proforma are asked
/// about; a refusal is said and nothing is written. Figma Mac file p.19.
struct RecalculateSheet: View {
    @Bindable var shop: Shop
    let jobId: Order.ID
    let currency: String
    /// Closed; true when the new price was saved.
    var done: (Bool) -> Void

    @State private var markup = ""
    @State private var preview: Shop.RepriceAnswer?
    @State private var asking: String?
    @State private var saving = false
    @State private var cost: Double?
    /// Every question the shop has said yes to while this sheet is open. The
    /// rule asks one at a time (the seen price, then a sent proforma), so the
    /// second save must carry the first yes too, or it is asked again forever.
    @State private var answered: Set<String> = []

    private var typedMarkup: Double? {
        let t = markup.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : TypedNumber.parse(t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("mac.rc_title")).font(.headline)
            HStack(spacing: 6) {
                Text(shop.words.callIt("mac.markup")).foregroundStyle(.secondary)
                TextField("", text: $markup)
                    .textFieldStyle(.roundedBorder).frame(width: 64).monospacedDigit()
                    .accessibilityLabel(shop.words.callIt("mac.markup"))
                Text(shop.words.callIt("mac.rc_markup_note")).font(.caption).foregroundStyle(.secondary)
            }
            switch preview {
            case .ready(_, let was, let now, _)?:
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    // The repriced job's cost (Figma 174:235) by the shared
                    // rule, in the JOB's currency: `Shop.repriceCost`.
                    if let cost {
                        GridRow {
                            Text(shop.words.callIt("mac.rc_cost"))
                            Text(Money.text(cost, currency)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                    GridRow {
                        Text(shop.words.callIt("mac.rc_price_now"))
                        Text(Money.text(was, currency)).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                    GridRow {
                        Text(shop.words.callIt("mac.rc_new_price")).fontWeight(.semibold)
                        Text(Money.text(now, currency)).monospacedDigit().fontWeight(.semibold)
                    }
                }
                Text(shop.words.callIt("mac.rc_terms")).font(.caption).foregroundStyle(.secondary)
                Text(shop.words.callIt("mac.rc_typed_dropped")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .refused(let why)?:
                Label(why, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Khayt.late).fixedSize(horizontal: false, vertical: true)
            default:
                ProgressView().controlSize(.small)
            }
            if let asking, case .ready(_, let was, let now, _)? = preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(asking == "ask_price"
                         ? shop.words.callIt("mac.rc_seen_title", ["price": .string(Money.text(was, currency))])
                         : shop.words.callIt("mac.rc_milestones"))
                        .font(.callout.weight(.semibold)).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                    if asking == "ask_price" {
                        Text(shop.words.callIt("mac.rc_seen_body", ["new": .string(Money.text(now, currency))]))
                            .font(.callout)
                    }
                    HStack {
                        Button(shop.words.callIt("mac.rc_keep", ["price": .string(Money.text(was, currency))])) { done(false) }
                        Button(shop.words.callIt("mac.js_markup_change")) { Task { await save(saidYes: asking) } }
                            .buttonStyle(.borderedProminent)
                            // Held while a save is on its way: a double-click
                            // saved twice (release stability review).
                            .disabled(saving || !shop.permitted("orders", "edit"))
                    }
                }
                .padding(10)
                .background(Khayt.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { done(false) }.keyboardShortcut(.cancelAction)
                if case .ready(_, _, let now, _)? = preview, asking == nil {
                    Button(shop.words.callIt("mac.rc_use", ["price": .string(Money.text(now, currency))])) {
                        Task { await save(saidYes: nil) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || !shop.permitted("orders", "edit"))
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await open() }
        .task(id: markup) { await refresh() }
    }

    private func open() async {
        // The markup the rule would use (the job's, else the shop's default),
        // shown so the shop sees what it is pricing at and may change it.
        if case .ready(_, _, _, let used)? = await shop.previewReprice(jobId, marginPct: nil), let used,
           // Only into an empty field: a markup typed while this was being
           // worked out is the shop's, and is not replaced.
           markup.trimmingCharacters(in: .whitespaces).isEmpty {
            markup = Money.fieldValue(used)
        }
    }

    private func refresh() async {
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        asking = nil
        answered = []
        // A markup that is not a number is said, not previewed at the default
        // as if the field were empty.
        if Self.markupUnreadable(markup) {
            preview = .refused(shop.words.callIt("mac.rc_markup_bad"))
            cost = nil
            return
        }
        preview = await shop.previewReprice(jobId, marginPct: typedMarkup)
        if case .ready(let out, _, _, _)? = preview, let engine = shop.engine {
            cost = await Shop.repriceCost(out, engine: engine)
        } else {
            cost = nil
        }
    }

    /// Save; a question the rule asks is asked here, and answered once.
    private func save(saidYes: String?) async {
        guard !saving, !Self.markupUnreadable(markup) else { return }
        saving = true
        defer { saving = false }
        if let saidYes { answered.insert(saidYes) }
        let yes = Shop.repriceYeses(answered)
        let answer = await shop.reprice(jobId, marginPct: typedMarkup,
                                        priceSeenOk: yes.priceSeen, milestonesOk: yes.milestones)
        switch answer {
        case .ready?: done(true)
        case .ask(let code)?: asking = code
        case .refused(let why)?: preview = .refused(why)
        // No answer at all (no engine, or the write could not run): said, so
        // the sheet never sits there as if it had saved.
        case nil: preview = .refused(shop.words.callIt("mac.rc_not_saved"))
        }
    }

    /// Typed, and not a number the field can read.
    static func markupUnreadable(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && TypedNumber.parse(t) == nil
    }
}
