import SwiftUI

struct MachinesView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var printers: LivePrinters

    @State private var machines: [MachineInfo] = []
    @State private var errorMessage: String?
    @State private var didLoad = false

    /// Each machine as the book has it, with the live reading laid over it
    /// when there is one. The book decides WHICH machines there are — a
    /// machine the live endpoint forgot to mention is still the shop's.
    private var rows: [MachineLiveStatus] {
        machines.map { m in
            printers.reading(for: m.id) ?? MachineLiveStatus(
                id: m.id, name: m.name, hasPrinterApi: m.hasPrinterApi ?? false,
                state: nil, progress: nil, filename: nil, timeRemaining: nil,
                tempNozzle: nil, tempBed: nil, error: nil, lastUpdated: nil, apiType: nil)
        }
    }

    private var statusById: [String: String] {
        Dictionary(machines.compactMap { m in m.status.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if machines.isEmpty && !didLoad && errorMessage == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 44)
                    } else if machines.isEmpty {
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
                        LiveStamp()
                        ForEach(rows) { m in
                            MachineCard(live: m, fallbackStatus: statusById[m.id])
                        }
                        if !printers.isLive {
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
                .animation(.easeOut(duration: 0.45), value: printers.updatedAt)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await load()
                await printers.refresh()
            }
            .khaytScreen(title: L10n.tr("tab.machines"))
            .background(KhaytDesign.ground.ignoresSafeArea())
            .task {
                await load()
                didLoad = true
            }
            .onAppear { printers.watch() }
            .onDisappear { printers.unwatch() }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            machines = try await api.fetchMachines()
        } catch {
            machines = []
            errorMessage = error.localizedDescription
        }
    }
}

/// "● Live · 3 s ago" while readings are arriving; nothing when they are not
/// (the stale note under the list says that instead).
struct LiveStamp: View {
    @EnvironmentObject private var printers: LivePrinters

    var body: some View {
        if printers.isLive, let at = printers.updatedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 7) {
                    Circle().fill(KhaytDesign.done).frame(width: 7, height: 7)
                    Text(L10n.tr("machines.live"))
                        .font(.khayt(11, .bold, relativeTo: .caption2))
                        .tracking(0.9)
                        .foregroundStyle(KhaytDesign.done)
                    Text(String(format: L10n.tr("machines.live.ago"),
                                max(0, Int(context.date.timeIntervalSince(at)))))
                        .font(.khayt(11.5, relativeTo: .caption2).monospacedDigit())
                        .foregroundStyle(KhaytDesign.note)
                }
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
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
                }
                .padding(.top, 11)
                // What a shop plans by: how long, and what time on the clock.
                if let eta = live.etaLocalized, let done = live.finishesAt() {
                    Text(String(format: L10n.tr("machines.left_until"), eta,
                                done.formatted(date: .omitted, time: .shortened)))
                        .font(.khayt(12.5, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(KhaytDesign.note)
                        .padding(.top, 7)
                }
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
