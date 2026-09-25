import SwiftUI

/// Pairing, as `design/ios-v2/` draws it: three steps, each one screen.
///
/// 1. **Which shop?** — the Macs announcing themselves on this Wi-Fi, each
///    saying whether it can hand over its book. Typing an address is a quiet
///    link at the bottom, for the shops discovery cannot serve.
/// 2. **The owner PIN** — for the shop just picked.
/// 3. **Copying the shop's book** — what landed, itemised, and what did not.
///    A Mac that does not serve the book skips this step: there is nothing to
///    itemise, and the phone is paired all the same.
struct PairingView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient

    enum Step { case find, manual, pin, pull }

    @State private var step: Step = .find
    @StateObject private var browser = ShopBrowser()
    @State private var resolving: String?
    @State private var showCloudSignIn = false
    @State private var isConnecting = false
    @State private var pinRefused = false
    @State private var failure: String?
    @State private var summary: PairingSummary?
    @FocusState private var pinFocused: Bool

    var body: some View {
        ZStack {
            KhaytDesign.ground.ignoresSafeArea()
            Group {
                switch step {
                case .find: findStep
                case .manual: manualStep
                case .pin: pinStep
                case .pull: pullStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .sheet(isPresented: $showCloudSignIn) { CloudSignInSheet() }
        // Signing in to the cloud IS setting up: the phone takes the shop from
        // there and can pair with the Mac later, from Settings.
        .onChange(of: api.cloud) { _, session in
            if session != nil { settings.isPaired = true }
        }
    }

    // MARK: - 1. Which shop?

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("KhaytMark")
                .resizable().scaledToFit()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 20)
                .accessibilityHidden(true)
            title(L10n.tr("pair.find.title"))
            lead(L10n.tr("pair.find.body"))

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    searchingRow
                    shopList
                }
            }
            .scrollIndicators(.hidden)
            .padding(.top, 22)

            quietLink(L10n.tr("pair.manual")) { step = .manual }
            foot(L10n.tr("pair.manual.why"))
            quietLink(L10n.tr("pair.use_cloud")) { showCloudSignIn = true }
                .padding(.top, 10)
            foot(L10n.tr("pair.use_cloud.footer"))
        }
        // Scoped to this step: browsing holds a network assertion, and there
        // is no reason to hold it while somebody types a PIN.
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private var searchingRow: some View {
        HStack(spacing: 9) {
            if browser.isSearching {
                ProgressView().controlSize(.mini).tint(KhaytDesign.brand)
            }
            eyebrow(L10n.tr("pair.searching"))
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var shopList: some View {
        if let failure = browser.failure {
            // Said as what it usually is. "No shops found" for a refused
            // permission sends somebody to reboot a router that is fine.
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("pair.browse.failed"))
                    .font(.khayt(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(failure).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                Text(L10n.tr("pair.browse.permission")).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            }
        } else if browser.shops.isEmpty {
            Text(L10n.tr(browser.isSearching ? "pair.browse.looking" : "pair.browse.none"))
                .font(.khayt(13, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.note)
        } else {
            ForEach(browser.shops) { shop in
                Button { Task { await choose(shop) } } label: { shopCard(shop) }
                    .buttonStyle(.plain)
                    .disabled(resolving != nil)
            }
        }
    }

    /// A shop that can hand over its book earns the green rail: it is the one
    /// the phone can keep working with away from the desk.
    private func shopCard(_ shop: ShopBrowser.Shop) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.name)
                    .font(.khayt(16, .medium, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                    .lineLimit(1)
                Text(L10n.tr(shop.servesBook ? "pair.shop.offline" : "pair.shop.needs_mac"))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(shop.servesBook ? KhaytDesign.done : KhaytDesign.note)
            }
            Spacer(minLength: 8)
            if resolving == shop.id {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KhaytDesign.note)
            }
        }
        .padding(.vertical, 15).padding(.leading, 18).padding(.trailing, 16)
        .frame(minHeight: 64)
        .background(KhaytDesign.surface)
        .overlay(alignment: .leading) {
            if shop.servesBook { Rectangle().fill(KhaytDesign.done).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13))
    }

    private func choose(_ shop: ShopBrowser.Shop) async {
        resolving = shop.id
        defer { resolving = nil }
        guard let found = await browser.resolve(shop) else {
            // Discovery said it was there and the connection disagreed — a Mac
            // that went to sleep between the two, most likely. The typed
            // address is the way on, rather than a list that does not respond.
            step = .manual
            return
        }
        settings.host = found.host
        settings.port = Int(found.port)
        settings.shopLabel = shop.name
        settings.serviceName = shop.id
        goToPin()
    }

    // MARK: - 1b. The Mac's address

    // ── THE TYPED ADDRESS STAYS ──────────────────────────────────────────
    //
    // Not as a fallback for when discovery is flaky, but because there are
    // shops it cannot serve at all: the Electron desktop does not advertise
    // itself, and a network with Bonjour blocked between its wireless and wired
    // sides is common in buildings wired by somebody else.
    @State private var portText = ""

    private var manualStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L10n.tr("pair.manual.title"))
            lead(L10n.tr("pair.manual.body"))
                .padding(.bottom, 22)
            fieldLabel(L10n.tr("pair.manual.host"))
            TextField("192.168.1.42", text: $settings.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.decimalPad)
                .modifier(BigField())
            fieldLabel(L10n.tr("pair.manual.port")).padding(.top, 14)
            TextField("3219", text: $portText)
                .keyboardType(.numberPad)
                .modifier(BigField())
                .onAppear { portText = String(settings.port) }
                .onChange(of: portText) { _, v in if let p = Int(v), (1...65535).contains(p) { settings.port = p } }
            Spacer(minLength: 18)
            primary(L10n.tr("pair.continue"), disabled: !settings.isConfigured) {
                if settings.shopLabel.trimmingCharacters(in: .whitespaces).isEmpty {
                    settings.shopLabel = settings.host
                }
                settings.serviceName = ""
                goToPin()
            }
            secondary(L10n.tr("pair.back")) { step = .find }
        }
    }

    // MARK: - 2. The owner PIN

    private func goToPin() {
        settings.pin = ""
        pinRefused = false
        failure = nil
        step = .pin
    }

    private var pinStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow(settings.shopLabel.isEmpty ? settings.host : settings.shopLabel)
                .padding(.bottom, 10)
            title(L10n.tr("pair.pin.title"))
            lead(L10n.tr("pair.pin.body"))
                .padding(.bottom, 22)
            SecureField("••••", text: $settings.pin)
                .keyboardType(.numberPad)
                .textContentType(.password)
                .focused($pinFocused)
                .font(.khayt(26, .semibold, relativeTo: .title))
                .tracking(8)
                .padding(.horizontal, 18)
                .frame(minHeight: 64)
                .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(pinRefused ? KhaytDesign.late : KhaytDesign.hairline, lineWidth: 1))
                .onChange(of: settings.pin) { _, _ in pinRefused = false; failure = nil }
                .onAppear { pinFocused = true }
            if pinRefused {
                Text(L10n.tr("pair.pin.wrong"))
                    .font(.khayt(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.late)
                    .padding(.top, 10)
            } else if let failure {
                Text(failure)
                    .font(.khayt(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.late)
                    .padding(.top, 10)
            }
            foot(L10n.tr("pair.pin.foot")).padding(.top, 10)
            Spacer(minLength: 18)
            primary(L10n.tr("pair.connect"), busy: isConnecting,
                    disabled: settings.pin.count < 4 || isConnecting) {
                Task { await connect() }
            }
            secondary(L10n.tr("pair.back")) { step = .find }
        }
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            _ = try await api.validatePairing()
        } catch KhaytAPIError.unauthorized {
            pinRefused = true
            CompanionHaptics.warning()
            return
        } catch {
            failure = error.localizedDescription
            CompanionHaptics.warning()
            return
        }

        // ── AND THEN ASK FOR THE BOOK, BUT DO NOT INSIST ─────────────────
        //
        // Pairing has succeeded by this line. The book is what lets this phone
        // keep working away from the Mac, so it is taken at the one moment the
        // shop is certainly on the same Wi-Fi with the PIN just typed. It must
        // NOT be able to fail the pairing: the Electron desktop does not serve
        // `/api/store`, and a phone that refused to pair with the app the shop
        // actually runs would be worse than one that cannot work offline.
        do {
            let book = try CompanionBook.inSharedContainer()
            _ = try await api.pullBook(into: book)
            summary = await api.fetchPairingSummary()
        } catch {
            summary = nil
        }
        CompanionHaptics.success()
        if summary != nil {
            step = .pull
        } else {
            settings.isPaired = true
        }
    }

    // MARK: - 3. Copying the shop's book

    private var pullStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(L10n.tr("pair.pull.title"))
            lead(L10n.tr("pair.pull.body"))
                .padding(.bottom, 22)
            if let summary {
                VStack(spacing: 0) {
                    pullRow(L10n.tr("pair.pull.settings"), value: summary.settings ? "✓" : "—",
                            tone: summary.settings ? KhaytDesign.done : KhaytDesign.note)
                    pullRow(L10n.tr("pair.pull.open_orders"), value: summary.openOrders.formatted())
                    pullRow(L10n.tr("pair.pull.newest_finished"), value: summary.newestFinished.formatted(),
                            tone: summary.finishedWindowed ? KhaytDesign.attention : KhaytDesign.ink)
                    pullRow(L10n.tr("tab.clients"), value: summary.clients.formatted())
                    pullRow(L10n.tr("tab.inventory"), value: summary.inventory.formatted())
                    pullRow(L10n.tr("tab.machines"), value: summary.machines.formatted(), last: true)
                }
                .background(KhaytDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
                if summary.omittedAnything {
                    foot(L10n.tr("pair.pull.foot")).padding(.top, 12)
                }
            }
            Spacer(minLength: 18)
            primary(L10n.tr("pair.finish")) { settings.isPaired = true }
        }
    }

    private func pullRow(_ label: String, value: String, tone: Color = KhaytDesign.ink, last: Bool = false) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(KhaytDesign.done)
                .frame(width: 22, height: 22)
                .background(KhaytDesign.done.opacity(0.14), in: Circle())
            Text(label)
                .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(.khayt(14.5, .semibold, relativeTo: .subheadline).monospacedDigit())
                .foregroundStyle(tone)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.khayt(28, .semibold, relativeTo: .largeTitle))
            .tracking(-0.5)
            .foregroundStyle(KhaytDesign.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func lead(_ text: String) -> some View {
        Text(text)
            .font(.khayt(14.5, relativeTo: .subheadline))
            .foregroundStyle(KhaytDesign.note)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 9)
    }

    private func foot(_ text: String) -> some View {
        Text(text)
            .font(.khayt(12, relativeTo: .caption))
            .foregroundStyle(KhaytDesign.note)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .padding(.horizontal, 2)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .tracking(1.05)
            .foregroundStyle(KhaytDesign.note)
    }

    private func fieldLabel(_ text: String) -> some View {
        eyebrow(text).padding(.bottom, 7)
    }

    private func quietLink(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).font(.khayt(15, .medium, relativeTo: .body))
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(KhaytDesign.note)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func primary(_ text: String, busy: Bool = false, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(KhaytDesign.onBrand) } else { Text(text) }
            }
            .font(.khayt(17, .semibold, relativeTo: .headline))
            .foregroundStyle(KhaytDesign.onBrand)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(KhaytDesign.brand.opacity(disabled && !busy ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func secondary(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }
}

/// The design's 56pt input: surface fill, hairline border, a large value.
private struct BigField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.khayt(17, .medium, relativeTo: .body))
            .foregroundStyle(KhaytDesign.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }
}
