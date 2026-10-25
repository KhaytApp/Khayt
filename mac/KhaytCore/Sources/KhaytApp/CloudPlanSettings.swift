import SwiftUI
import KhaytCore

/// Settings › Online › Khayt Cloud plan: what the shop is on, what each plan
/// gives, and — for the owner — the move between them.
///
/// ── FREE DURING THE BETA, AND SAID SO BEFORE THE MOVE ─────────────────────
///
/// Moving up costs nothing while the beta runs, but the real price is shown,
/// and the confirmation says the published rule (khaytapp.com/terms §4 "Plans
/// during the beta") before anything changes: when the beta ends there are
/// the grace days to start paying, or the shop moves back to Free. A move
/// DOWN says what happens to a vault over the new plan (§4 again: read-only,
/// then deleted after 90 days until it fits), and a shop already over is
/// shown it as a status row with the date once the cloud has set one
/// (`VaultLapseNotice`). Tell the website lane before changing that wording.
///
/// While the cloud has upgrades closed (`beta.freeUpgrades` false), the
/// plans are shown and the buttons say "Opens soon". Only the owner gets
/// buttons at all; a manager sees the plan and is told who can change it.
struct CloudPlanSettings: View {
    let shop: Shop

    @State private var state = Shop.CloudPlanState()
    @State private var loaded = false
    @State private var asking: CloudPlans.Plan?
    @State private var busy = false
    private let preloaded: Bool
    /// The section's rows in a plain stack, for a photograph: `ImageRenderer`
    /// cannot draw a `Form`.
    private let flat: Bool

    /// `shown` draws this state without asking the cloud: for a photograph.
    init(shop: Shop, shown: Shop.CloudPlanState? = nil, flat: Bool = false) {
        self.shop = shop
        self.flat = flat
        preloaded = shown != nil
        _state = State(initialValue: shown ?? Shop.CloudPlanState())
        _loaded = State(initialValue: shown != nil)
    }

    private var catalogue: CloudPlans.Catalogue? { state.catalogue }
    private var currentName: String { state.mine?.plan ?? catalogue?.freePlan ?? "free" }
    private var current: CloudPlans.Plan? { catalogue?.plans.first { $0.name == currentName } }
    private var upgradesOpen: Bool { catalogue?.beta?.freeUpgrades == true }
    private var graceDays: Int { catalogue?.beta?.graceDays ?? state.mine?.beta?.graceDays ?? 30 }

    var body: some View {
        Group {
            if flat {
                VStack(alignment: .leading, spacing: 10) {
                    Text(shop.words.callIt("mac.plan_title")).font(.headline)
                    rows
                }
            } else {
                Section(shop.words.callIt("mac.plan_title")) { rows }
            }
        }
        .task { if !preloaded { await load() } }
        .alert(asking.map { shop.words.callIt("mac.plan_move_title", ["plan": .string(Self.planName($0.name, $0.label, shop.words))]) } ?? "",
               isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
               presenting: asking) { plan in
            Button(shop.words.callIt("mac.plan_move_confirm")) { Task { await choose(plan) } }
            Button(shop.words.callIt("common.cancel"), role: .cancel) {}
        } message: { plan in
            Text(confirmText(plan))
        }
    }

    @ViewBuilder private var rows: some View {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if let catalogue {
                LabeledContent(shop.words.callIt("mac.plan_current")) {
                    Text(Self.planName(currentName, current?.label ?? state.mine?.label ?? currentName, shop.words)).fontWeight(.medium)
                }
                // OVER THE VAULT after a move down: said before the plans, so
                // the way out (Upgrade) is the first thing under it.
                let lapse = state.mine?.lapse?.display(now: Date(), calendar: .book) ?? .notOver
                if lapse.isOver {
                    VaultLapseNotice(shop: shop, display: lapse, upgrade: upgradeAction.map { .action($0) } ?? .none)
                }
                if state.mine?.onFreeUpgrade == true {
                    Text(betaNote).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(catalogue.plans) { plan in row(plan) }
                if catalogue.pricesInclusive == true {
                    Text(shop.words.callIt("mac.plan_vat_included")).font(.caption).foregroundStyle(.secondary)
                }
                if !shop.cloudIsOwner {
                    Text(shop.words.callIt("mac.plan_owner_only")).font(.caption).foregroundStyle(.secondary)
                } else if !upgradesOpen {
                    Text(shop.words.callIt("mac.plan_opens_soon")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem = state.problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }

    // MARK: - A plan

    @ViewBuilder
    private func row(_ plan: CloudPlans.Plan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.planName(plan.name, plan.label, shop.words)).fontWeight(plan.name == currentName ? .semibold : .regular)
                    if plan.name == currentName {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            .accessibilityLabel(shop.words.callIt("mac.plan_current"))
                    }
                }
                Text(Self.gives(plan, shop.words)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(priceText(plan)).monospacedDigit()
            if shop.cloudIsOwner && plan.name != currentName {
                Button(shop.words.callIt(CloudPlans.isUpgrade(plan, from: current) ? "mac.plan_upgrade" : "mac.plan_move")) {
                    asking = plan
                }
                // Moving back to Free is always allowed; moving up needs the beta open.
                .disabled(busy || (CloudPlans.isUpgrade(plan, from: current) && !upgradesOpen))
            }
        }
    }

    private func priceText(_ plan: CloudPlans.Plan) -> String {
        guard let (amount, currency) = CloudPlans.price(plan, currency: shop.currency) else { return "" }
        if amount == 0 { return shop.words.callIt("mac.plan_free_price") }
        // Isolated: an Arabic line that starts with a Latin price reads backwards.
        let money = "\u{2068}" + Money.text(amount, currency) + "\u{2069}"
        return shop.words.callIt(plan.period == "year" ? "mac.plan_per_year" : "mac.plan_per_month",
                                 ["price": .string(money)])
    }

    /// A plan's name as the shop reads it. Free is a word and is said in the
    /// shop's language ("Free" beside «مجاناً» read as untranslated); Maker,
    /// Creator and Studio are names, kept as the catalogue spells them and
    /// isolated so a Latin name cannot turn an Arabic line round.
    static func planName(_ name: String, _ label: String, _ words: Words) -> String {
        if name == "free" { return words.callIt("mac.plan_name_free") }
        return "\u{2068}" + label + "\u{2069}"
    }

    static func losesSelling(_ plan: CloudPlans.Plan, from current: CloudPlans.Plan?) -> Bool {
        current?.limits.publishing == true && plan.limits.publishing != true
    }

    /// What a plan adds, in one line: the vault, its share links, selling, seats.
    static func gives(_ plan: CloudPlans.Plan, _ words: Words) -> String {
        var parts: [String] = []
        let l = plan.limits
        if let v = l.maxVaultBytes, v > 0 {
            parts.append(words.callIt("mac.plan_vault", ["size": .string(Format.fileSize(Int64(v)))]))
        }
        if let n = l.maxActiveLinks {
            parts.append(n > 0 ? words.counting(n, "mac.plan_links")
                               : words.callIt("mac.plan_no_links"))
        }
        if l.publishing == true { parts.append(words.callIt("mac.plan_selling")) }
        if let s = l.maxSeats, s > 1 { parts.append(words.callIt("mac.plan_seats", ["n": .number(Double(s))])) }
        // Each part isolated: an Arabic line joined with " · " let the Latin
        // "GB" of one part swallow the figure of the next ("خزنة 150 50 · GB").
        return parts.map { "\u{2068}" + $0 + "\u{2069}" }.joined(separator: " · ")
    }

    /// The Upgrade a shop over its vault is offered: the cheapest move up
    /// whose vault holds what it has now, else the biggest vault there is.
    /// nil when nothing is bigger, or this sign-in cannot move the plan.
    private var upgradeAction: (() -> Void)? {
        guard shop.cloudIsOwner, upgradesOpen, let catalogue,
              let target = Self.upgradeTarget(over: state.mine?.lapse?.overBytes ?? 0, current: current,
                                              plans: catalogue.plans) else { return nil }
        return { asking = target }
    }

    static func upgradeTarget(over: Int, current: CloudPlans.Plan?, plans: [CloudPlans.Plan]) -> CloudPlans.Plan? {
        let up = plans.filter { CloudPlans.isUpgrade($0, from: current) && $0.name != current?.name }
        guard !up.isEmpty else { return nil }
        let holds = (current?.limits.maxVaultBytes ?? 0) + over
        // A plan with no vault limit holds anything: the largest, not none.
        func room(_ p: CloudPlans.Plan) -> Int { p.limits.maxVaultBytes ?? Int.max }
        let fits = up.filter { room($0) >= holds }
        if let cheapest = fits.min(by: { ($0.priceSar ?? 0) < ($1.priceSar ?? 0) }) { return cheapest }
        return up.max(by: { room($0) < room($1) })
    }

    // MARK: - The terms, before the move

    private var betaNote: String {
        if let end = state.mine?.beta?.graceEndsAt, !end.isEmpty {
            return shop.words.callIt("mac.plan_grace_until", ["day": .string(Calendar.localDay(ofInstant: end)), "lapse": .number(90)])
        }
        return shop.words.callIt("mac.plan_beta_free", ["days": .number(Double(graceDays)), "lapse": .number(90)])
    }

    private func confirmText(_ plan: CloudPlans.Plan) -> String {
        if !CloudPlans.isUpgrade(plan, from: current) {
            let note = shop.words.callIt("mac.plan_move_down_note", ["days": .number(90)])
            // Only a move that loses selling says what happens to products.
            guard Self.losesSelling(plan, from: current) else { return note }
            return note + "\n\n" + shop.words.callIt("mac.plan_move_down_selling")
        }
        return shop.words.callIt("mac.plan_beta_free", ["days": .number(Double(graceDays)), "lapse": .number(90)])
    }

    // MARK: - Asking the cloud

    private func load() async {
        state = await shop.cloudPlanState()
        if let mine = state.mine { shop.noteVaultLapse(mine.lapse) }
        loaded = true
    }

    private func choose(_ plan: CloudPlans.Plan) async {
        busy = true
        state = await shop.chooseCloudPlan(plan.name, from: state)
        if let mine = state.mine { shop.noteVaultLapse(mine.lapse) }
        busy = false
    }
}
