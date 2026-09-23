import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth

    @State private var testResult: String?
    @State private var isTesting = false

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
                    Link("How to add the widget", destination: URL(string: "https://github.com/khaytapp/Khayt/blob/main/ios/XCODE_WIDGET.md")!)
                }

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
