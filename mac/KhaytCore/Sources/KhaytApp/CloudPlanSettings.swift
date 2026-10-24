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
/// the grace days to start paying, or the shop moves back to Free, and
/// nothing is deleted. Tell the website lane before changing that wording.
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

    private var catalogue: CloudPlans.Catalogue? { state.catalogue }
    private var currentName: String { state.mine?.plan ?? catalogue?.freePlan ?? "free" }
    private var current: CloudPlans.Plan? { catalogue?.plans.first { $0.name == currentName } }
    private var upgradesOpen: Bool { catalogue?.beta?.freeUpgrades == true }
    private var graceDays: Int { catalogue?.beta?.graceDays ?? state.mine?.beta?.graceDays ?? 30 }

    var body: some View {
        Section(shop.words.callIt("mac.plan_title")) {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if let catalogue {
                LabeledContent(shop.words.callIt("mac.plan_current")) {
                    Text(current?.label ?? state.mine?.label ?? currentName).fontWeight(.medium)
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
        .task { await load() }
        .alert(asking.map { shop.words.callIt("mac.plan_move_title", ["plan": .string($0.label)]) } ?? "",
               isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
               presenting: asking) { plan in
            Button(shop.words.callIt("mac.plan_move_confirm")) { Task { await choose(plan) } }
            Button(shop.words.callIt("common.cancel"), role: .cancel) {}
        } message: { plan in
            Text(confirmText(plan))
        }
    }

    // MARK: - A plan

    @ViewBuilder
    private func row(_ plan: CloudPlans.Plan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plan.label).fontWeight(plan.name == currentName ? .semibold : .regular)
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
        let money = Money.text(amount, currency)
        return shop.words.callIt(plan.period == "year" ? "mac.plan_per_year" : "mac.plan_per_month",
                                 ["price": .string(money)])
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
            parts.append(n > 0 ? words.callIt("mac.plan_links", ["n": .number(Double(n))])
                               : words.callIt("mac.plan_no_links"))
        }
        if l.publishing == true { parts.append(words.callIt("mac.plan_selling")) }
        if let s = l.maxSeats, s > 1 { parts.append(words.callIt("mac.plan_seats", ["n": .number(Double(s))])) }
        return parts.joined(separator: " · ")
    }

    // MARK: - The terms, before the move

    private var betaNote: String {
        if let end = state.mine?.beta?.graceEndsAt, !end.isEmpty {
            return shop.words.callIt("mac.plan_grace_until", ["day": .string(Calendar.localDay(ofInstant: end))])
        }
        return shop.words.callIt("mac.plan_beta_free", ["days": .number(Double(graceDays))])
    }

    private func confirmText(_ plan: CloudPlans.Plan) -> String {
        if !CloudPlans.isUpgrade(plan, from: current) {
            let note = shop.words.callIt("mac.plan_move_down_note")
            // Only a move that loses selling says what happens to products.
            guard Self.losesSelling(plan, from: current) else { return note }
            return note + "\n\n" + shop.words.callIt("mac.plan_move_down_selling")
        }
        return shop.words.callIt("mac.plan_beta_free", ["days": .number(Double(graceDays))])
    }

    // MARK: - Asking the cloud

    private func load() async {
        state = await shop.cloudPlanState()
        loaded = true
    }

    private func choose(_ plan: CloudPlans.Plan) async {
        busy = true
        state = await shop.chooseCloudPlan(plan.name)
        busy = false
    }
}
