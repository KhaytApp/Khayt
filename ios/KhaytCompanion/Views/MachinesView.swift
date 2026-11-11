import SwiftUI

struct MachinesView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var printers: LivePrinters
    @EnvironmentObject private var settings: ConnectionSettings

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

    /// Why nothing is moving. A relayed snapshot that has gone quiet says how
    /// long ago the Mac last spoke — "asleep for an hour" and "just dropped
    /// off" are different things to a shop deciding whether to drive in.
    private var staleNote: String {
        if let reported = printers.reportedAt {
            return L10n.format("machines.reported", reported.formatted(.relative(presentation: .named).locale(L10n.locale)))
        }
        return L10n.tr("machines.stale")
    }

    private var offline: Set<String> {
        Set(machines.filter(\.isUnderService).map(\.id))
    }

    private var statusById: [String: String] {
        Dictionary(machines.compactMap { m in m.status.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Each machine's camera, as `KhaytAPIClient.camera` decided it.
    @State private var cameras: [String: KhaytAPIClient.CameraAnswer] = [:]
    /// The job printing on each machine — only where there is exactly one, as
    /// the print alerts decide it: two would be a guess.
    @State private var jobs: [String: QueueOrder] = [:]
    /// Each machine's care tasks and the parts list, from the book — nil when
    /// this phone keeps no book (care is never asked of the desktop).
    @State private var care: CareBook?
    /// Debug screenshots (`-KhaytOpen care:<machine id>` / `parts`): a
    /// machine id, or "" for Parts to buy.
    @State private var openCare: String?

    @ViewBuilder
    private func jobLink(_ m: MachineLiveStatus) -> some View {
        if let job = jobs[m.id] {
            NavigationLink {
                OrderDetailPage(order: job, facts: nil) { await load() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox").foregroundStyle(KhaytDesign.note)
                    Text(L10n.format("machines.job", job.displayTitle))
                        .lineLimit(1)
                        .foregroundStyle(KhaytDesign.ink)
                    if job.isRush { RushBadge() }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.caption).foregroundStyle(KhaytDesign.note)
                }
                .font(.khayt(14, .medium, relativeTo: .subheadline))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func cameraLink(_ m: MachineLiveStatus) -> some View {
        switch cameras[m.id] {
        case .available(let source)?:
            NavigationLink {
                MachineCameraPage(name: m.displayName, source: source)
            } label: {
                Label(L10n.tr("camera.open"), systemImage: "video")
                    .font(.khayt(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.brand)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        case .refused(let why)?:
            Text(why).font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note).padding(.horizontal, 4)
        default:
            EmptyView()
        }
    }

    /// Regular width — iPhone Duo's inner display — sets the machines two
    /// across rather than stretching each card over the full 7.6 inches, split
    /// at the fold when the device is partly folded (see `FoldGap`).
    @Environment(\.horizontalSizeClass) private var widthClass
    @State private var fold: FoldGap?
    private var columns: [GridItem] {
        FoldGap.columns(fold, regularWidth: widthClass == .regular, spacing: 10)
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
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(rows) { m in
                                VStack(spacing: 10) {
                                    MachineCard(live: m, fallbackStatus: statusById[m.id], offline: offline.contains(m.id))
                                    jobLink(m)
                                    if let care {
                                        MachineCareLink(name: m.displayName, machineId: m.id, care: care) { await load() }
                                    }
                                    // A print on the bed, on a printer the Mac drives.
                                    if m.hasPrinterApi, m.isPrinting || m.isPaused, !settings.isSampleShop {
                                        PrinterControls(machine: m)
                                    }
                                    cameraLink(m)
                                }
                                .frame(maxHeight: .infinity, alignment: .top)
                            }
                        }
                        .readsFold($fold)
                        if !printers.isLive {
                            Text(staleNote)
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
            .toolbar {
                if care != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            PartsToBuyPage()
                        } label: {
                            Label(L10n.tr("care.parts.title"), systemImage: "cart")
                        }
                    }
                }
            }
            .navigationDestination(item: $openCare) { id in
                if id.isEmpty {
                    PartsToBuyPage()
                } else {
                    MachineCarePage(name: machines.first { $0.id == id }?.name ?? id, machineId: id)
                }
            }
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
            // A retired machine stays in the book only so past orders can
            // name it; it is not one of the shop's machines any more.
            machines = try await api.fetchMachines().filter { !$0.isRetired }
            care = await api.printerCare()
            #if DEBUG
            if let id = KhaytCompanionApp.ScreenshotOpen.take("care:") { openCare = id }
            if KhaytCompanionApp.ScreenshotOpen.take("parts") != nil { openCare = "" }
            #endif
            var found: [String: KhaytAPIClient.CameraAnswer] = [:]
            for m in machines { found[m.id] = await api.camera(machineId: m.id) }
            cameras = found
            let printing = ((try? await api.fetchQueue()) ?? []).filter { $0.status == "printing" && $0.machineId != nil }
            jobs = Dictionary(grouping: printing, by: { $0.machineId! }).compactMapValues { $0.count == 1 ? $0[0] : nil }
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
                        .khaytTracking(0.9)
                        .foregroundStyle(KhaytDesign.done)
                    Text(L10n.format("machines.live.ago", max(0, Int(context.date.timeIntervalSince(printers.reportedAt ?? at)))))
                        .font(.khayt(11.5, relativeTo: .caption2).monospacedDigit())
                        .foregroundStyle(KhaytDesign.note)
                    if printers.source == .cloud {
                        Text(L10n.tr("machines.via_cloud"))
                            .font(.khayt(11.5, relativeTo: .caption2))
                            .foregroundStyle(KhaytDesign.note)
                    }
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
    var offline = false

    private enum Mode { case printing, idle, error, offline }

    private var mode: Mode {
        if live.hasError { return .error }
        if offline && !live.isPrinting { return .offline }
        if live.isPrinting { return .printing }
        if let s = fallbackStatus?.lowercased(), s.contains("print") { return .printing }
        return .idle
    }

    private var tone: Color {
        switch mode {
        case .printing: return KhaytDesign.live
        case .idle, .offline: return KhaytDesign.note
        case .error: return KhaytDesign.late
        }
    }

    private var statusLabel: String {
        switch mode {
        case .printing: return L10n.tr("status.printing")
        case .idle: return L10n.tr("machines.idle")
        case .error: return L10n.tr("machines.error")
        case .offline: return L10n.tr("machines.offline")
        }
    }

    private var sub: String? {
        switch mode {
        case .printing: return live.filename.flatMap { $0.isEmpty ? nil : $0 }
        case .idle: return live.hasPrinterApi ? L10n.tr("machines.ready") : L10n.tr("machines.no_live")
        case .error: return live.error
        case .offline: return L10n.tr("machines.offline.sub")
        }
    }

    /// The redesign's printer card (Figma "Printer card"): a printer tile, the
    /// name and what it is on, a pill; while printing, the percentage large
    /// with the time left and the clock time it ends, over the thread bar.
    /// The card is outlined in its state's colour — green printing, red in
    /// trouble — and a printer in trouble sits on that red's wash.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: mode == .error ? "exclamationmark.triangle" : "printer")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(mode == .idle || mode == .offline ? KhaytDesign.ink : tone)
                    .frame(width: 42, height: 42)
                    .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(live.displayName)
                        .font(.khayt(17, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                        .lineLimit(1)
                    if let sub {
                        Text(sub)
                            .font(.khayt(13, relativeTo: .footnote))
                            .foregroundStyle(mode == .error ? KhaytDesign.late : KhaytDesign.note)
                            .lineLimit(mode == .error ? 2 : 1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle().fill(tone).frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.khayt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.ink)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(tone.opacity(0.16), in: Capsule())
            }
            if mode == .printing, let progress = live.progress {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(progress.formatted(.number.locale(L10n.locale)) + "%")
                        .font(.khaytDisplay(42, .bold, relativeTo: .largeTitle).monospacedDigit())
                        .tracking(-1.2)
                        .foregroundStyle(KhaytDesign.ink)
                        .environment(\.layoutDirection, .leftToRight)
                    Spacer(minLength: 0)
                    // What a shop plans by: how long, and what time on the clock.
                    if let eta = live.etaLocalized, let done = live.finishesAt() {
                        Text(L10n.format("machines.left_until", eta,
                                    done.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))))
                            .font(.khaytMono(12, .medium))
                            .foregroundStyle(KhaytDesign.note)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 12)
                LevelBar(fraction: Double(min(100, max(0, progress))) / 100, color: KhaytDesign.thread, height: 8)
                    .padding(.top, 8)
                    .animation(.easeOut(duration: 0.45), value: progress)
            }
            if mode == .printing, live.tempNozzle != nil || live.tempBed != nil {
                HStack(spacing: 16) {
                    temp(L10n.tr("machines.nozzle"), live.tempNozzle)
                    temp(L10n.tr("machines.bed"), live.tempBed)
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mode == .error ? KhaytDesign.late.opacity(0.12) : .clear)
        .background(KhaytDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(mode == .printing || mode == .error ? tone.opacity(0.6) : KhaytDesign.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func temp(_ label: String, _ value: Int?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.khayt(12.5, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
            Text(value.map { "\($0) °C" } ?? "—")
                .font(.khaytMono(12.5, .medium, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.ink)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}
