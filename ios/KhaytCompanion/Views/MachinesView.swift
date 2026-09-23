import SwiftUI

struct MachinesView: View {
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var live: [MachineLiveStatus] = []
    @State private var typeById: [String: String] = [:]
    @State private var statusById: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Group {
                if live.isEmpty && !didLoad && errorMessage == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if live.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("machines.none"),
                        systemImage: "printer",
                        description: Text(errorMessage ?? L10n.tr("machines.none.sub"))
                    )
                } else {
                    List(live) { m in
                        MachineLiveRow(
                            live: m,
                            type: typeById[m.id],
                            fallbackStatus: statusById[m.id]
                        )
                        .listRowBackground(KhaytDesign.surface)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .refreshable { await load() }
                }
            }
            .khaytScreen(title: L10n.tr("tab.machines"))
            .task {
                await load()
                didLoad = true
            }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            async let liveTask = api.fetchMachinesLive()
            async let machinesTask = api.fetchMachines()
            let (liveData, machineData) = try await (liveTask, machinesTask)
            live = liveData
            typeById = Dictionary(machineData.compactMap { m in m.type.map { (m.id, $0) } },
                                  uniquingKeysWith: { a, _ in a })
            statusById = Dictionary(machineData.compactMap { m in m.status.map { (m.id, $0) } },
                                    uniquingKeysWith: { a, _ in a })
        } catch {
            // Live endpoint may be unavailable on older desktops — fall back to basic list.
            if let basic = try? await api.fetchMachines() {
                live = basic.map {
                    MachineLiveStatus(id: $0.id, name: $0.name, hasPrinterApi: $0.hasPrinterApi ?? false,
                                      state: nil, progress: nil, filename: nil, timeRemaining: nil,
                                      tempNozzle: nil, tempBed: nil, error: nil, lastUpdated: nil, apiType: nil)
                }
                typeById = Dictionary(basic.compactMap { m in m.type.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
                statusById = Dictionary(basic.compactMap { m in m.status.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
                if live.isEmpty { errorMessage = error.localizedDescription }
            } else {
                live = []
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct MachineLiveRow: View {
    let live: MachineLiveStatus
    let type: String?
    let fallbackStatus: String?

    private var isResin: Bool {
        (type ?? "").lowercased().contains("resin")
    }

    private var accent: Color {
        if live.hasError { return KhaytDesign.danger }
        if live.isPrinting { return KhaytDesign.brand }
        if let s = live.state ?? fallbackStatus { return KhaytDesign.statusColor(for: s) }
        return KhaytDesign.textMuted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if live.isPrinting, let progress = live.progress {
                progressSection(progress)
            }
            if live.hasError, let err = live.error {
                errorBanner(err)
            }
            if let temps = live.tempText {
                Label(temps, systemImage: "thermometer.medium")
                    .font(.caption)
                    .foregroundStyle(KhaytDesign.textDim)
            }
            if !live.hasPrinterApi {
                Text(L10n.tr("machines.no_live"))
                    .font(.caption2)
                    .foregroundStyle(KhaytDesign.textMuted)
            }
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isResin ? "cube.transparent" : "printer.fill")
                .font(.system(size: 17))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(live.displayName)
                    .font(.headline)
                    .foregroundStyle(KhaytDesign.text)
                if let type {
                    Text(type.uppercased())
                        .font(.caption)
                        .foregroundStyle(KhaytDesign.textDim)
                }
            }
            Spacer()
            if let state = live.state ?? fallbackStatus {
                CompanionStatusBadge(status: state, compact: true)
            }
        }
    }

    private func progressSection(_ progress: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(min(100, max(0, progress))), total: 100)
                .tint(accent)
            HStack(spacing: 8) {
                if let file = live.filename, !file.isEmpty {
                    Text(file)
                        .font(.caption2)
                        .foregroundStyle(KhaytDesign.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text("\(progress)%")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(accent)
                if let eta = live.etaText {
                    Label(eta, systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(KhaytDesign.textDim)
                }
            }
        }
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(err).lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(KhaytDesign.danger)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.dangerSoft, in: RoundedRectangle(cornerRadius: 8))
    }
}
