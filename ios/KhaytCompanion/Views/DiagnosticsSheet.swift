import SwiftUI
import KhaytCore

/// Settings ▸ long-press the version line. What this phone's book is and what
/// its syncs last did, so a missing connector can be explained rather than
/// guessed at. Read-only, and counts and states only — no record, no
/// setting's value, no connector id. Behind a long press, so it may say
/// "Connectors" before they launch.
struct DiagnosticsSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var rows: BookDiagnostics?
    @State private var refreshing = false

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    var body: some View {
        NavigationStack {
            Form {
                if let d = rows { sections(d) } else { ProgressView() }
                Section(footer: Text(L10n.tr("diag.footer"))) {
                    Button {
                        Task {
                            refreshing = true
                            await api.refreshNow()
                            rows = await api.diagnostics()
                            refreshing = false
                        }
                    } label: {
                        Text(L10n.tr(refreshing ? "diag.refreshing" : "diag.refresh"))
                    }
                    .disabled(refreshing)
                }
            }
            .navigationTitle(L10n.tr("diag.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.done")) { dismiss() }
                }
            }
            .task { rows = await api.diagnostics() }
        }
    }

    @ViewBuilder
    private func sections(_ d: BookDiagnostics) -> some View {
        Section(header: Text(L10n.tr("diag.section.book"))) {
            row("diag.holds_book", yes(d.holdsBook))
            row("diag.book_file", yes(d.bookExists))
            row("diag.baseline", L10n.tr("diag.baseline." + d.baseline.rawValue))
            row("diag.settings", yes(d.settingsPresent))
            row("diag.plugin_entries", count(d.pluginEntries))
        }
        Section(header: Text(L10n.tr("connectors.title"))) {
            row("diag.connectors_count", count(d.connectorCount))
            ForEach([Connector.Status.active, .paused, .off, .notReviewed, .invalid], id: \.self) { status in
                if let n = d.byStatus[status], n > 0 {
                    row(ConnectorRules.statusName(status), count(n), key: false)
                }
            }
        }
        Section(header: Text(L10n.tr("diag.section.sources"))) {
            row("diag.last_source", d.recorded.last.map { Self.sourceName($0) + " · " + when(d.recorded.lastAt) }
                ?? L10n.tr("diag.never"))
            row("diag.cloud_refused", d.recorded.refused.map {
                Self.refusedValue($0, when: when(d.recorded.refusedAt), shopTail: d.recorded.refusedShopTail)
            } ?? L10n.tr("diag.never"))
            ForEach(SyncDiagnostics.Source.allCases, id: \.self) { source in
                row(Self.sourceName(source), Self.sourceValue(when(d.recorded.sources[source]),
                                                              records: d.recorded.records[source]), key: false)
            }
        }
        Section(header: Text(L10n.tr("diag.section.mac"))) {
            row("diag.mac_settings", d.recorded.macSettings.map { Self.outcomeName($0) + " · " + when(d.recorded.macSettingsAt) }
                ?? L10n.tr("diag.never"))
            row("diag.mac_answered", when(d.recorded.macAnsweredAt))
            row("diag.mac_failed", when(d.recorded.macFailedAt))
        }
        Section(header: Text(L10n.tr("diag.section.phone"))) {
            row("diag.paired", yes(d.isPaired))
            row("diag.configured", yes(d.isConfigured))
            row("diag.cloud", yes(d.cloudSignedIn))
            row("diag.cloud_shop", d.cloudShopTail.map { "…" + $0 } ?? L10n.tr("diag.none"))
            row("diag.mac_shop", d.macShopTail.map { "…" + $0 } ?? L10n.tr("diag.none"))
            row("diag.sample", yes(d.isSampleShop))
            row("diag.app", d.version + " (" + d.build + ")")
        }
    }

    private func row(_ label: String, _ value: String, key: Bool = true) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Text(key ? L10n.tr(label) : label)
        }
    }

    private func yes(_ b: Bool) -> String { L10n.tr(b ? "diag.yes" : "diag.no") }
    private func count(_ n: Int) -> String { n.formatted(.number.locale(L10n.locale)) }

    private func when(_ date: Date?) -> String {
        guard let date else { return L10n.tr("diag.never") }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func sourceValue(_ when: String, records: Int?) -> String {
        guard let records else { return when }
        return when + " · " + L10n.format("diag.records", records)
    }

    /// "refused: wrong shop · 2 min. ago · …1ec56f"
    static func refusedValue(_ r: SyncDiagnostics.Refusal, when: String, shopTail: String?) -> String {
        let name = L10n.tr(r == .wrongShop ? "diag.refused.wrong_shop" : "diag.refused.empty")
        return [name, when, shopTail.map { "…" + $0 }].compactMap { $0 }.joined(separator: " · ")
    }

    static func sourceName(_ s: SyncDiagnostics.Source) -> String {
        switch s {
        case .macStore: return L10n.tr("diag.source.mac_store")
        case .cloudWhole: return L10n.tr("diag.source.cloud_whole")
        case .cloudDelta: return L10n.tr("diag.source.cloud_delta")
        case .macSettings: return L10n.tr("diag.source.mac_settings")
        }
    }

    static func outcomeName(_ o: SyncDiagnostics.SettingsOutcome) -> String {
        switch o {
        case .ok: return L10n.tr("diag.outcome.ok")
        case .http(let code): return L10n.format("diag.outcome.http", code)
        case .transport: return L10n.tr("diag.outcome.transport")
        case .empty: return L10n.tr("diag.outcome.empty")
        case .unwritten: return L10n.tr("diag.outcome.unwritten")
        case .skipped(.pulled): return L10n.tr("diag.outcome.skipped_pulled")
        case .skipped(.notConfigured): return L10n.tr("diag.outcome.skipped_not_configured")
        case .skipped(.sampleShop): return L10n.tr("diag.outcome.skipped_sample")
        case .skipped(.noBook): return L10n.tr("diag.outcome.skipped_no_book")
        }
    }
}
