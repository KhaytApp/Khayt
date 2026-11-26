import SwiftUI
import KhaytCore

/// Settings › Internet use (Figma "SIGNED OFF (Turki, Nov 22) · Internet use,
/// success rate, U1 · iPhone": 1A read-only for every role, 1B the owner's
/// phone flipping the shop's switch through the Mac's signed route).
///
/// The page decides nothing: the switch and each line are the gate's answers
/// (`InternetUseModel`), and the change is the Mac's (`NetworkSwitch`). The
/// owner's control shows only when this phone is the owner, the Mac is in
/// reach and the Mac says it serves the route (`can: ["network-switch"]`);
/// otherwise the page is 1A, with no error.
struct SettingsInternetUsePage: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth

    @State private var model = InternetUseModel(switchOn: false, lines: [])
    /// The value the owner asked for, waiting for the confirm.
    @State private var asking: Bool?
    @State private var sending = false
    @State private var result: String?
    /// The Mac's last signed word on the switch (a done or a "changed"
    /// answer), shown until the phone's own gate has caught up: the settings
    /// re-read after a change can fail, and the toggle must not sit stale.
    @State private var macSaid: ShopNetwork?

    private var mayChange: Bool {
        PhoneNetworkSwitch.mayChange(role: settings.effectiveRole, can: api.macCan, macInReach: health.macInReach,
                                sampleShop: settings.isSampleShop)
    }

    var body: some View {
        SettingsPage {
            switchCard
            SettingsPieces.foot(L10n.tr(mayChange ? "internet.foot.owner" : "internet.foot.readonly"))
            if let asking { confirmCard(turnOn: asking) }
            if let result {
                SettingsPieces.foot(result).accessibilityAddTraits(.updatesFrequently)
            }
            SettingsPieces.eyebrow(L10n.tr("internet.uses"))
            VStack(spacing: 0) {
                ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                    lineRow(line, last: index == model.lines.count - 1)
                }
            }
            .card()
        }
        .settingsPageTitle(L10n.tr("internet.title"))
        .task {
            reload()
            await api.refreshMacCan()
        }
        .onReceive(NotificationCenter.default.publisher(for: PhoneOutbound.changedNotification)) { _ in reload() }
        .onChange(of: settings.countInstall) { _, _ in reload() }
    }

    private func reload() {
        let gate = OutboundGate.shared
        if let said = macSaid, said.offline == gate.isShopOffline { macSaid = nil }
        model = InternetUseModel.make(
            shopOffline: macSaid?.offline ?? gate.isShopOffline, rows: gate.rows(), blocked: gate.blockedCounts(),
            countInstall: settings.countInstall, countReady: ActiveCountSender.ready,
            clock: { $0.formatted(.dateTime.hour().minute().locale(L10n.locale)) })
    }

    // MARK: - The switch

    private var switchCard: some View {
        // The toggle never moves by itself: a tap asks (the confirm card), and
        // only the Mac's signed answer moves it.
        let shown = Binding(get: { model.switchOn },
                            set: { wanted in if mayChange, !sending, wanted != model.switchOn { result = nil; asking = wanted } })
        return Toggle(isOn: shown) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("internet.switch"))
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(L10n.tr("internet.switch.hint"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(KhaytDesign.done)
        .disabled(!mayChange || sending)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card()
        .padding(.top, 12)
    }

    // MARK: - Before it changes (1B)

    private func confirmCard(turnOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPieces.eyebrow(L10n.tr("internet.confirm.eyebrow"))
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr(turnOn ? "internet.confirm.on.title" : "internet.confirm.off.title"))
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(L10n.tr(turnOn ? "internet.confirm.on.body" : "internet.confirm.off.body"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(L10n.tr("common.cancel")) { asking = nil }
                        .buttonStyle(.bordered)
                    Button(L10n.tr(turnOn ? "internet.turn_on" : "internet.turn_off")) {
                        guard !sending else { return }
                        Task { await send(turnOn) }
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(KhaytDesign.brand)
                    if sending { ProgressView() }
                }
                .disabled(sending)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .card()
        }
    }

    private func send(_ offline: Bool) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        // What the person confirmed against: the Mac's last signed word when
        // the phone has one the gate has not caught up with, else the gate's.
        let showing = macSaid.map { PhoneNetworkSwitch.Showing($0) } ?? PhoneNetworkSwitch.Showing.current(OutboundGate.shared.currentBook)
        let outcome = await api.setShopOffline(offline, showing: showing)
        asking = nil
        result = PhoneNetworkSwitch.words(outcome)
        switch outcome {
        case .done(let network):
            macSaid = network
            // Saved on the Mac, but this phone could not read it back yet.
            if OutboundGate.shared.isShopOffline != network.offline { result = L10n.tr("internet.result.saved_not_read") }
        case .changed(let network?), .notSaved(let network?):
            macSaid = network
        default: break
        }
        reload()
    }

    // MARK: - What this phone uses

    private func lineRow(_ line: InternetUseModel.Line, last: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.title)
                    .font(.khayt(14.5, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(line.sub)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(L10n.tr("internet.state.\(line.state.rawValue)"))
                .font(.khayt(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(tone(line.state))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }

    private func tone(_ state: InternetUseModel.State) -> Color {
        switch state {
        case .kept, .on: return KhaytDesign.done
        case .blocked: return KhaytDesign.attention
        case .allowed, .off: return KhaytDesign.note
        }
    }
}
