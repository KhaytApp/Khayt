import AppKit
import SwiftUI
import KhaytCore

/// The weekly digest switch and the paid-plan checkout, for Settings › Online
/// (`DigestSettings`, `PlanPaySheet`). The rules are in `CloudCheckout`.
extension Shop {

    /// Opens a payment page. A seam, so a test never launches a browser.
    nonisolated(unsafe) static var openPaymentPage: @Sendable (URL) async -> Bool = { url in
        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    /// The owner's digest choice, or nil when this Mac is not signed in to the
    /// cloud, the sign-in is not the owner's, or the cloud has nothing to say
    /// (an older cloud, an anonymous shop): the switch is then not drawn.
    func cloudDigest() async -> CloudCheckout.Digest? {
        guard cloudIsOwner, let (connection, token) = await vaultSession() else { return nil }
        return try? await CloudCheckout.digest(connection, token: token, fetch: Self.plansFetch)
    }

    /// Saves the choice; answers what the cloud now holds, or nil when it
    /// refused (the switch is put back).
    func setCloudDigest(_ enabled: Bool) async -> CloudCheckout.Digest? {
        guard let (connection, token) = await vaultSession() else { return nil }
        return try? await CloudCheckout.setDigest(enabled, connection, token: token, fetch: Self.plansFetch)
    }

    /// Pays for `plan`: see `CloudCheckout.run`. `opened` fires once the page
    /// is in the browser.
    func payForCloudPlan(_ plan: String, period: CloudCheckout.Period,
                         opened: @Sendable @escaping (CloudCheckout.Started) async -> Void) async -> CloudCheckout.Outcome {
        guard let (connection, token) = await vaultSession() else { return .refused(.init(status: 401, reason: "", error: "")) }
        return await CloudCheckout.run(plan: plan, period: period, connection, token: token,
                                       fetch: Self.plansFetch, open: Self.openPaymentPage, opened: opened)
    }

    /// What the sheet says of how the attempt ended.
    func payOutcomeText(_ outcome: CloudCheckout.Outcome) -> String? {
        switch outcome {
        case .paid(let end, _):
            if let end, !end.isEmpty {
                return words.callIt("mac.pay_paid_until", ["day": .string(Calendar.localDay(ofInstant: end))])
            }
            return words.callIt("mac.pay_paid")
        case .failed: return words.callIt("mac.pay_failed")
        case .mismatch(let id): return words.callIt("mac.pay_mismatch", ["id": .string("\u{2068}" + id + "\u{2069}")])
        case .providerOff: return words.callIt("mac.pay_unavailable")
        case .refused(let r): return planProblem(r)
        case .couldNotOpen: return words.callIt("mac.pay_no_browser")
        case .timedOut: return words.callIt("mac.pay_timeout")
        case .unreachable: return words.callIt("mac.pay_unreachable")
        case .cancelled: return nil
        }
    }
}

/// Settings › Online › the weekly email. Owner only: not drawn for anyone
/// else, nor when the cloud does not answer.
struct DigestSettings: View {
    let shop: Shop
    @State private var digest: CloudCheckout.Digest?
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        Group {
            if shop.cloudIsOwner, let digest {
                Section(shop.words.callIt("mac.digest_title")) {
                    Toggle(shop.words.callIt("mac.digest_toggle"), isOn: Binding(
                        get: { digest.enabled }, set: { value in Task { await save(value) } }))
                        .disabled(busy)
                    Text(shop.words.callIt("mac.digest_hint")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !digest.serverEnabled {
                        Text(shop.words.callIt("mac.digest_not_sent")).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let week = digest.lastSentWeek, !week.isEmpty {
                        Text(shop.words.callIt("mac.digest_last", ["day": .string(Calendar.localDay(ofInstant: week))]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if failed {
                        Text(shop.words.callIt("mac.digest_failed")).font(.callout).foregroundStyle(Khayt.attention)
                    }
                }
            }
        }
        .task { digest = await shop.cloudDigest() }
    }

    private func save(_ value: Bool) async {
        busy = true; failed = false
        if let saved = await shop.setCloudDigest(value) { digest = saved } else { failed = true }
        busy = false
    }
}

/// Pay for a plan: pick a month or a year, go to the browser, wait here.
struct PlanPaySheet: View {
    let shop: Shop
    let plan: CloudPlans.Plan
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var period: CloudCheckout.Period
    @State private var working = false
    @State private var waiting = false
    @State private var result: String?
    @State private var paid = false
    @State private var task: Task<Void, Never>?

    init(shop: Shop, plan: CloudPlans.Plan, onDone: @escaping () -> Void) {
        self.shop = shop; self.plan = plan; self.onDone = onDone
        _period = State(initialValue: plan.period == "year" ? .year : .month)
    }

    /// A plan sold by the year has only the year.
    private var periods: [CloudCheckout.Period] { plan.period == "year" ? [.year] : [.month, .year] }

    /// The catalogue's own figure; the year only when the catalogue states it.
    private func priceLine(_ p: CloudCheckout.Period) -> String? {
        let amount = p == .year ? (plan.annualSar ?? (plan.period == "year" ? plan.priceSar : nil)) : plan.priceSar
        guard let amount else { return nil }
        let money = "\u{2068}" + Money.text(amount, "SAR") + "\u{2069}"
        return shop.words.callIt(p == .year ? "mac.plan_per_year" : "mac.plan_per_month", ["price": .string(money)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.pay_title", ["plan": .string(CloudPlanSettings.planName(plan.name, plan.label, shop.words))]))
                .font(.headline)
            if periods.count > 1 {
                Picker(shop.words.callIt("mac.pay_period"), selection: $period) {
                    ForEach(periods, id: \.self) { p in
                        Text([shop.words.callIt(p == .year ? "mac.pay_year" : "mac.pay_month"), priceLine(p)]
                            .compactMap { $0 }.joined(separator: " · ")).tag(p)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(working)
            } else if let line = priceLine(period) {
                Text(line)
            }
            if waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(shop.words.callIt("mac.pay_waiting"))
                }
            }
            if let result {
                Text(result).font(.callout).foregroundStyle(paid ? Color.primary : Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt(paid ? "common.close" : "common.cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                if !paid && !Shop.payGate.providerOff {
                    Button(shop.words.callIt("mac.pay_continue")) { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .onDisappear { task?.cancel() }
    }

    private func start() {
        working = true; result = nil
        task = Task {
            let outcome = await shop.payForCloudPlan(plan.name, period: period) { _ in
                await MainActor.run { waiting = true }
            }
            waiting = false; working = false
            result = shop.payOutcomeText(outcome)
            if case .paid = outcome { paid = true; onDone() }
        }
    }

    /// Closing stops the asking; a payment already made still lands on the
    /// cloud, and the plan pane reads it the next time it opens.
    private func close() { task?.cancel(); onDone(); dismiss() }
}

extension Shop {
    static var payGate: CloudCheckout.Gate { .shared }
}
