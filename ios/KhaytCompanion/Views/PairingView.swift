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

                bottomBar
                    .padding()
            }
            .navigationTitle("Set up Khayt")
            .navigationBarTitleDisplayMode(.inline)
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
            Text("Step \(step + 1) of \(totalSteps)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < totalSteps - 1 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
            } else {
                Button("Open Khayt") {
                    settings.isPaired = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!testOK)
            }
        }
    }

    private var canAdvance: Bool {
        switch step {
        case 2: return settings.isConfigured && !settings.pin.isEmpty
        default: return true
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        stepCard(
            icon: "iphone.and.arrow.forward",
            title: "Companion for your shop",
            body: "This app connects to **Khayt on your Mac or PC** over Wi‑Fi. Your data stays on the desktop — the phone is for queue, inventory, and scanning spools on the go."
        )
    }

    private var desktopStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepCard(
                icon: "desktopcomputer",
                title: "Prepare Khayt desktop",
                body: "On the computer running Khayt, open **Settings → LAN API** and turn on:"
            )
            VStack(alignment: .leading, spacing: 10) {
                checklistRow("Enable LAN REST API", icon: "network")
                checklistRow("Listen on all network interfaces", icon: "antenna.radiowaves.left.and.right")
                checklistRow("Set an Owner LAN PIN (remember it)", icon: "key.fill")
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
                    title: "Enter connection",
                    body: "Phone and computer must be on the **same Wi‑Fi**. Default port is **3219**."
                )

                Group {
                    TextField("Shop name (optional label)", text: $settings.shopLabel)
                    TextField("Computer IP address", text: $settings.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Stepper("Port: \(settings.port)", value: $settings.port, in: 1024...65535)
                    SecureField("Owner LAN PIN", text: $settings.pin)
                }
                .textFieldStyle(.roundedBorder)

                DisclosureGroup("How do I find the IP address?", isExpanded: $showIPHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On the Mac running Khayt, open **Terminal** and run:")
                            .font(.caption)
                        Text("ipconfig getifaddr en0")
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        Text("Use the number shown (e.g. 192.168.1.42). If empty, try **en1** or check **System Settings → Wi‑Fi → Details**.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .font(.subheadline)
            }
            .padding(.horizontal)
        }
        .onChange(of: settings.host) { _, _ in invalidatePairingTest() }
        .onChange(of: settings.port) { _, _ in invalidatePairingTest() }
        .onChange(of: settings.pin) { _, _ in invalidatePairingTest() }
    }

    private var verifyStep: some View {
        VStack(spacing: 20) {
            stepCard(
                icon: "checkmark.shield",
                title: "Test connection",
                body: "We’ll reach your desktop and confirm the PIN with a quick queue check."
            )
            .padding(.horizontal)

            Button {
                Task { await runPairingTest() }
            } label: {
                HStack {
                    Label("Test now", systemImage: "bolt.fill")
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

    private func stepCard(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey(body))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
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
            var message = "Connected — \(status.queued) job(s) in queue. PIN accepted."

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
                let records = try await api.pullBook(into: CompanionBook.inSharedContainer())
                message += " The shop's book is on this phone — \(records) record(s) — "
                        + "so it keeps working when this Mac is not in reach."
            } catch {
                message += " This desktop does not hand over its book, so the phone will "
                        + "ask it again for every screen and will empty when it is out of reach."
            }
            testMessage = message
        } catch {
            testMessage = error.localizedDescription
        }
    }
}
