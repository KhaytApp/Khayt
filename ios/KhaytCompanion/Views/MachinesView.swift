import SwiftUI

struct MachinesView: View {
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var live: [MachineLiveStatus] = []
    @State private var statusById: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var didLoad = false

    /// The live endpoint did not answer, so what is shown is what the book
    /// last held — said once, under the list, as the design does.
    @State private var stale = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if live.isEmpty && !didLoad && errorMessage == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 44)
                    } else if live.isEmpty {
                        VStack(spacing: 5) {
                            Text(L10n.tr("machines.none"))
                                .font(.khayt(15, .semibold, relativeTo: .headline))
                                .foregroundStyle(KhaytDesign.ink)
                            Text(errorMessage ?? L10n.tr("machines.none.sub"))
                                .font(.khayt(13, relativeTo: .footnote))
                                .foregroundStyle(KhaytDesign.note)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else {
                        ForEach(live) { m in
                            MachineCard(live: m, fallbackStatus: statusById[m.id])
                        }
                        if stale {
                            Text(L10n.tr("machines.stale"))
                                .font(.khayt(12, relativeTo: .caption))
                                .foregroundStyle(KhaytDesign.note)
                                .padding(.horizontal, 2)
                                .padding(.top, 6)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
            .khaytScreen(title: L10n.tr("tab.machines"))
            .background(KhaytDesign.ground.ignoresSafeArea())
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
            stale = false
            statusById = Dictionary(machineData.compactMap { m in m.status.map { (m.id, $0) } },
                                    uniquingKeysWith: { a, _ in a })
        } catch {
            // Live endpoint may be unavailable on older desktops, or the Mac
            // out of reach — fall back to what the book holds.
            stale = true
            if let basic = try? await api.fetchMachines() {
                live = basic.map {
                    MachineLiveStatus(id: $0.id, name: $0.name, hasPrinterApi: $0.hasPrinterApi ?? false,
                                      state: nil, progress: nil, filename: nil, timeRemaining: nil,
                                      tempNozzle: nil, tempBed: nil, error: nil, lastUpdated: nil, apiType: nil)
                }
                statusById = Dictionary(basic.compactMap { m in m.status.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
                if live.isEmpty { errorMessage = error.localizedDescription }
            } else {
                live = []
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One machine, as `design/ios-v2/` draws it: its name and state, what it is
/// doing, and — while it prints — how far along, with the two temperatures.
/// A running machine earns the orange rail, a faulted one the red; an idle
/// one has none.
private struct MachineCard: View {
    let live: MachineLiveStatus
    let fallbackStatus: String?

    private enum Mode { case printing, idle, error }

    private var mode: Mode {
        if live.hasError { return .error }
        if live.isPrinting { return .printing }
        if let s = fallbackStatus?.lowercased(), s.contains("print") { return .printing }
        return .idle
    }

    private var tone: Color {
        switch mode {
        case .printing: return KhaytDesign.hot
        case .idle: return KhaytDesign.note
        case .error: return KhaytDesign.late
        }
    }

    private var statusLabel: String {
        switch mode {
        case .printing: return L10n.tr("status.printing")
        case .idle: return L10n.tr("machines.idle")
        case .error: return L10n.tr("machines.error")
        }
    }

    private var sub: String? {
        switch mode {
        case .printing: return live.filename.flatMap { $0.isEmpty ? nil : $0 }
        case .idle: return live.hasPrinterApi ? L10n.tr("machines.ready") : L10n.tr("machines.no_live")
        case .error: return live.error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(live.displayName)
                    .font(.khayt(16, .medium, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(statusLabel)
                    .font(.khayt(11.5, .semibold, relativeTo: .caption))
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .foregroundStyle(tone)
                    .background(tone.opacity(0.14), in: Capsule())
            }
            if let sub {
                Text(sub)
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 5)
            }
            if mode == .printing, let progress = live.progress {
                HStack(spacing: 9) {
                    LevelBar(fraction: Double(min(100, max(0, progress))) / 100, color: KhaytDesign.hot, height: 5)
                    Text("\(progress)%")
                        .font(.khayt(13, .medium, relativeTo: .footnote).monospacedDigit())
                        .foregroundStyle(KhaytDesign.hot)
                        .environment(\.layoutDirection, .leftToRight)
                    if let eta = live.etaText {
                        Text(eta)
                            .font(.khayt(12, relativeTo: .caption).monospacedDigit())
                            .foregroundStyle(KhaytDesign.note)
                    }
                }
                .padding(.top, 11)
            }
            if mode == .printing, live.tempNozzle != nil || live.tempBed != nil {
                HStack(spacing: 16) {
                    temp(L10n.tr("machines.nozzle"), live.tempNozzle)
                    temp(L10n.tr("machines.bed"), live.tempBed)
                    Spacer(minLength: 0)
                }
                .padding(.top, 11)
                .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                .padding(.top, 11)
            }
        }
        .padding(.vertical, 14).padding(.leading, 18).padding(.trailing, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface)
        .overlay(alignment: .leading) {
            if mode != .idle { Rectangle().fill(tone).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func temp(_ label: String, _ value: Int?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.khayt(12.5, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
            Text(value.map { "\($0) °C" } ?? "—")
                .font(.khayt(13, .medium, relativeTo: .caption).monospacedDigit())
                .foregroundStyle(KhaytDesign.ink)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}
