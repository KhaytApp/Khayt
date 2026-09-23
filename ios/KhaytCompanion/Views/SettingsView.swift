import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth

    @State private var testResult: String?
    @State private var isTesting = false
    @State private var showCloudSignIn = false
    @State private var cloudSyncing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(L10n.tr("settings.lan_status"))
                        Spacer()
                        ConnectionBadge()
                    }
                    if let checked = health.lastChecked {
                        Text(checked.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(KhaytDesign.textMuted)
                    }
                }

                Section(
                    header: Text(L10n.tr("settings.connection")),
                    footer: Text(L10n.tr("settings.connection.footer"))
                ) {
                    TextField(L10n.tr("settings.shop_name"), text: $settings.shopLabel)
                    TextField(L10n.tr("settings.host"), text: $settings.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if let err = settings.hostValidationError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(KhaytDesign.danger)
                    } else if settings.isConfigured {
                        Text("\(L10n.tr("settings.endpoint")) \(settings.displayURL)")
                            .font(.caption)
                            .foregroundStyle(KhaytDesign.textMuted)
                    }
                    Stepper(String(format: L10n.tr("settings.port"), settings.port), value: $settings.port, in: 1024...65535)
                    SecureField(L10n.tr("settings.pin"), text: $settings.pin)
                }

                Section(header: Text(L10n.tr("settings.language"))) {
                    Picker(L10n.tr("settings.language"), selection: $settings.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                }

                Section(
                    header: Text(L10n.tr("settings.notifications")),
                    footer: Text(L10n.tr("settings.notify.footer"))
                ) {
                    Toggle(L10n.tr("settings.notify.queue"), isOn: $settings.notifyQueueChanges)
                    Toggle(L10n.tr("settings.notify.connection"), isOn: $settings.notifyConnection)
                    Toggle(L10n.tr("settings.notify.overdue"), isOn: $settings.notifyOverdue)
                    Toggle(L10n.tr("settings.notify.low_stock"), isOn: $settings.notifyLowStock)
                    Button {
                        Task { await CompanionNotifications.shared.requestAuthorizationIfNeeded() }
                    } label: {
                        Text(L10n.tr("settings.notifications.allow"))
                    }
                }

                Section(
                    header: Text(L10n.tr("settings.widget")),
                    footer: Text(L10n.tr("settings.widget.footer"))
                ) {
                    Link(L10n.tr("settings.widget.howto"), destination: URL(string: "https://github.com/khaytapp/Khayt/blob/main/ios/XCODE_WIDGET.md")!)
                }

                cloudSection

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text(L10n.tr("settings.retest"))
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                    }
                }

                Section(footer: Text(L10n.tr("settings.unpair.footer"))) {
                    Button(L10n.tr("settings.unpair"), role: .destructive) {
                        settings.unpair()
                    }
                }

                Section(header: Text(L10n.tr("settings.docs"))) {
                    Link(
                        L10n.tr("settings.docs"),
                        destination: URL(string: "https://github.com/khaytapp/Khayt/blob/main/docs/LAN_API.md")!
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(KhaytDesign.bg)
            .foregroundStyle(KhaytDesign.text)
            .khaytScreen(title: L10n.tr("tab.settings"))
            .sheet(isPresented: $showCloudSignIn) { CloudSignInSheet() }
        }
    }

    /// Khayt Cloud: how this phone keeps in step when the Mac is elsewhere.
    @ViewBuilder
    private var cloudSection: some View {
        Section(header: Text(L10n.tr("cloud.title")),
                footer: Text(L10n.tr(api.cloud == nil ? "cloud.footer.off" : "cloud.footer.on"))) {
            if let session = api.cloud {
                LabeledContent(L10n.tr("cloud.shop"), value: session.shopId)
                LabeledContent(L10n.tr("cloud.role"), value: session.role)
                if let mark = api.lastSync {
                    LabeledContent(L10n.tr("cloud.last_sync"),
                                   value: String(format: L10n.tr(mark.route == .cloud ? "cloud.via_cloud" : "cloud.via_mac"),
                                                 mark.at.formatted(date: .omitted, time: .shortened)))
                }
                if let problem = api.cloudProblem {
                    Text(problem).font(.footnote).foregroundStyle(KhaytDesign.warn)
                }
                Button {
                    Task {
                        cloudSyncing = true
                        await api.syncThroughCloud()
                        cloudSyncing = false
                    }
                } label: {
                    HStack {
                        Text(L10n.tr("cloud.sync_now"))
                        Spacer()
                        if cloudSyncing { ProgressView() }
                    }
                }
                .disabled(cloudSyncing)
                Button(L10n.tr("cloud.sign_out"), role: .destructive) { api.signOutOfCloud() }
            } else {
                Button(L10n.tr("cloud.sign_in")) { showCloudSignIn = true }
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let status = try await api.validatePairing()
            testResult = "OK — \(status.queued) in queue."
            await health.refresh()
        } catch {
            testResult = error.localizedDescription
        }
    }
}
