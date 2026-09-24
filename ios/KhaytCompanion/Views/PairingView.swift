import SwiftUI

/// Guided setup: connect the companion to Khayt desktop over Wi‑Fi.
struct PairingView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var step = 0
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var isTesting = false
    @State private var showIPHelp = false
    @StateObject private var browser = ShopBrowser()
    @State private var resolving: String?
    @State private var showManual = false
    @State private var showCloudSignIn = false
    /// The shop the person tapped, once its address is known — shown, so a tap
    /// that worked does not look exactly like one that did not.
    @State private var chosenShopId: String?

    private let totalSteps = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressHeader
                    .padding()

                TabView(selection: $step) {
                    welcomeStep.tag(0)
                    desktopStep.tag(1)
                    connectionStep.tag(2)
                    verifyStep.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: step)

                if let missing {
                    Text(missing)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal)
                }
                bottomBar
                    .padding()
            }
            .navigationTitle(L10n.tr("pair.title"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCloudSignIn) { CloudSignInSheet() }
            // Signing in to the cloud IS setting up: the phone takes the shop
            // from there and can pair with the Mac later, from Settings.
            .onChange(of: api.cloud) { _, session in
                if session != nil { settings.isPaired = true }
            }
        }
    }

    private var progressHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            Text(String(format: L10n.tr("pair.step_of"), step + 1, totalSteps))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack {
            if step > 0 {
                Button(L10n.tr("pair.back")) { step -= 1 }
            }
            Spacer()
            if step < totalSteps - 1 {
                Button(L10n.tr("pair.continue")) { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
            } else {
                Button(L10n.tr("pair.open")) {
                    settings.isPaired = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!testOK)
            }
        }
    }

    /// Why Continue is off, in a sentence. A greyed-out button alone left a
    /// shop tapping the Mac again and again, seen on a real phone.
    private var missing: String? {
        guard step == 2, !canAdvance else { return nil }
        if !settings.isConfigured { return L10n.tr("pair.missing.shop") }
        if settings.pin.isEmpty { return L10n.tr("pair.missing.pin") }
        return nil
    }

    private var canAdvance: Bool {
        switch step {
        case 2: return settings.isConfigured && !settings.pin.isEmpty
        default: return true
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            // The shop's own mark, not a stock symbol: this is the first screen
            // anybody sees, and it should look like Khayt.
            Image("KhaytMark")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .accessibilityLabel("Khayt")
            stepCard(
                icon: nil,
                title: L10n.tr("pair.welcome.title"),
                body: L10n.tr("pair.welcome.body")
            )
            // For a shop whose Mac is not on this Wi-Fi — or cannot be reached
            // yet — but which syncs to Khayt Cloud.
            Button {
                showCloudSignIn = true
            } label: {
                Label(L10n.tr("pair.use_cloud"), systemImage: "icloud")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            Text(L10n.tr("pair.use_cloud.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var desktopStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepCard(
                icon: "desktopcomputer",
                title: L10n.tr("pair.desktop.title"),
                body: L10n.tr("pair.desktop.body")
            )
            VStack(alignment: .leading, spacing: 10) {
                checklistRow(L10n.tr("pair.desktop.enable"), icon: "network")
                checklistRow(L10n.tr("pair.desktop.listen"), icon: "antenna.radiowaves.left.and.right")
                checklistRow(L10n.tr("pair.desktop.pin"), icon: "key.fill")
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }

    private var connectionStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stepCard(
                    icon: "link",
                    title: L10n.tr("pair.shop.title"),
                    body: L10n.tr("pair.shop.body")
                )

                shopsOnThisNetwork

                // ── THE TYPED ADDRESS STAYS ──────────────────────────────
                //
                // Not as a fallback for when discovery is flaky, but because
                // there are shops it cannot serve at all: the Electron desktop
                // does not advertise itself, and a network with Bonjour blocked
                // between its wireless and wired sides is common enough in
                // buildings that were wired by somebody else. Removing this
                // would make those shops unpairable rather than inconvenient.
                DisclosureGroup(L10n.tr("pair.manual"), isExpanded: $showManual) {
                    manualEntry
                        .padding(.top, 8)
                }
                .font(.subheadline)

                // The PIN is asked for whichever way the shop was found: it is
                // not discoverable, deliberately, and the Mac does not advertise
                // whether it needs one — a stale "no PIN needed" would be the
                // phone telling a shop something untrue.
                // Labelled above the field: on a dark screen the field's own
                // placeholder did not show, and the PIN box read as empty space.
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("pair.pin")).font(.subheadline.weight(.semibold))
                    SecureField(L10n.tr("pair.pin.prompt"), text: $settings.pin)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                }

            }
            .padding(.horizontal)
        }
        .onChange(of: settings.host) { _, _ in invalidatePairingTest() }
        .onChange(of: settings.port) { _, _ in invalidatePairingTest() }
        .onChange(of: settings.pin) { _, _ in invalidatePairingTest() }
        // Scoped to this step rather than the whole wizard: browsing holds a
        // network assertion, and there is no reason to hold it while somebody
        // reads the welcome screen.
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    /// The list that replaces typing an address.
    @ViewBuilder
    private var shopsOnThisNetwork: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.tr("pair.shops")).font(.subheadline.weight(.semibold))
                if browser.isSearching && browser.shops.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }

            if let failure = browser.failure {
                // Said as what it usually is. "No shops found" for a refused
                // permission sends somebody to reboot a router that is fine.
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("pair.browse.failed"))
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                        Text(L10n.tr("pair.browse.permission"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.footnote)
            } else if browser.shops.isEmpty {
                Text(browser.isSearching
                     ? L10n.tr("pair.browse.looking")
                     : L10n.tr("pair.browse.none"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(browser.shops) { shop in
                    Button { Task { await choose(shop) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shop.name).font(.body)
                                if chosenShopId == shop.id, settings.isConfigured {
                                    Text(settings.host).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                // The difference between a phone that keeps
                                // working away from the desk and one that
                                // empties when it loses the Mac. Worth knowing
                                // before pairing, not after.
                                Text(shop.servesBook
                                     ? L10n.tr("pair.shop.offline")
                                     : L10n.tr("pair.shop.online_only"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if resolving == shop.id {
                                ProgressView().controlSize(.small)
                            } else if chosenShopId == shop.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(KhaytDesign.ok)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(minHeight: 44)          // the tap target rule
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var manualEntry: some View {
        Group {
            TextField(L10n.tr("pair.manual.name"), text: $settings.shopLabel)
            TextField(L10n.tr("pair.manual.host"), text: $settings.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Stepper(String(format: L10n.tr("settings.port"), settings.port), value: $settings.port, in: 1024...65535)

            DisclosureGroup(L10n.tr("pair.ip_help"), isExpanded: $showIPHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.markdown(L10n.tr("pair.ip_help.terminal")))
                        .font(.caption)
                    Text(verbatim: "ipconfig getifaddr en0")
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text(Self.markdown(L10n.tr("pair.ip_help.result")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.subheadline)
        }
        .textFieldStyle(.roundedBorder)
    }

    /// Fill in the address from a shop the phone found.
    private func choose(_ shop: ShopBrowser.Shop) async {
        resolving = shop.id
        defer { resolving = nil }
        guard let found = await browser.resolve(shop) else {
            // Discovery said it was there and the connection disagreed — a Mac
            // that went to sleep between the two, most likely. Open the manual
            // fields rather than leaving somebody looking at a list that does
            // not respond to being tapped.
            showManual = true
            return
        }
        settings.host = found.host
        settings.port = Int(found.port)
        chosenShopId = shop.id
        if settings.shopLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.shopLabel = shop.name
        }
        invalidatePairingTest()
    }

    private var verifyStep: some View {
        VStack(spacing: 20) {
            stepCard(
                icon: "checkmark.shield",
                title: L10n.tr("pair.verify.title"),
                body: L10n.tr("pair.verify.body")
            )
            .padding(.horizontal)

            Button {
                Task { await runPairingTest() }
            } label: {
                HStack {
                    Label(L10n.tr("pair.verify.test"), systemImage: "bolt.fill")
                    Spacer()
                    if isTesting { ProgressView() }
                }
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!settings.isConfigured || settings.pin.isEmpty || isTesting)
            .padding(.horizontal)

            if let testMessage {
                HStack(spacing: 8) {
                    Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testOK ? .green : .red)
                    Text(testMessage)
                        .font(.subheadline)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private func stepCard(icon: String?, title: String, body: String) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(Self.markdown(body))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    /// A translated sentence with its **bold** kept. `Text(LocalizedStringKey:)`
    /// would look the already-translated words up a second time.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func checklistRow(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
    }

    private func invalidatePairingTest() {
        testOK = false
        testMessage = nil
    }

    private func runPairingTest() async {
        isTesting = true
        testOK = false
        testMessage = nil
        defer { isTesting = false }
        do {
            let status = try await api.validatePairing()
            testOK = true
            var message = String(format: L10n.tr("pair.verify.ok"), status.queued)

            // ── AND THEN ASK FOR THE BOOK, BUT DO NOT INSIST ─────────────
            //
            // Pairing has succeeded by this line. Taking a copy of the shop's
            // book is what lets this phone keep working when the Mac is not in
            // reach, so it is worth doing at the one moment the shop is
            // definitely on the same Wi-Fi and has just typed the PIN.
            //
            // It must NOT be able to fail the pairing, because `/api/store` is
            // served by the native Mac app and not by the Electron desktop most
            // shops are still running. A phone that refused to pair with the app
            // the shop actually has would be a worse phone than the one that
            // could not work offline. So: if the book arrives, say so; if it
            // does not, say what that means rather than showing an error for
            // something that is not broken.
            do {
                let book = try CompanionBook.inSharedContainer()
                let records = try await api.pullBook(into: book)
                message += " " + String(format: L10n.tr("pair.verify.book"), records)
                // Said plainly, because the alternative is a phone that looks
                // like it has the shop on it and quietly does not. The history
                // stays on the Mac by design; what is worth saying is that it is
                // still there rather than gone.
                if let scope = book.scope(), !scope.omitted.isEmpty {
                    message += " " + L10n.tr("pair.verify.history")
                }
            } catch {
                message += " " + L10n.tr("pair.verify.no_book")
            }
            testMessage = message
        } catch {
            testMessage = error.localizedDescription
        }
    }
}
