import SwiftUI

// ── FLOOR MODE (D-P6 a; frames 255:2, 255:28, 255:55, signed off Nov 22) ─────
//
// An operator or viewer phone keeps no book: it asks the Mac each time, and
// the Mac answers only what its role reaches. These screens are what such a
// phone shows instead of the owner's Today: what is printing, what waits at a
// printer, what is next. No money, no clients. The Mac's 403 is the actual
// check; the phone only avoids offering what would be refused.

extension EnvironmentValues {
    /// A floor phone (operator or viewer): job rows and headers leave the
    /// customer's name out ("no prices, clients or the shop's book on this
    /// phone", frame 254:17). Set once, at the tabs.
    @Entry var hidesClients = false
}

/// The role line at the top of a floor screen (the frames' tinted note).
struct FloorBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.khayt(12.5, relativeTo: .footnote))
            .foregroundStyle(KhaytDesign.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(KhaytDesign.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// A floor card: a title and lines, optionally outlined (waiting at a printer).
struct FloorCard<Content: View>: View {
    let title: String
    var outline: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.khayt(15, .semibold, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.ink)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(outline ?? KhaytDesign.hairline, lineWidth: outline == nil ? 1 : 1.5))
    }
}

struct FloorLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.khayt(12.5, relativeTo: .footnote))
            .foregroundStyle(KhaytDesign.note)
            .lineLimit(2)
    }
}

/// Today on an operator or viewer phone (frame 255:2).
struct FloorTodayView: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var printers: [MachineLiveStatus] = []
    @State private var queue: [QueueOrder] = []
    @State private var problem: String?
    @State private var openOrder: QueueOrder?
    @State private var showSettings = false

    /// How many of the queue's next jobs are listed.
    static let nextShown = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.tr("floor.today.title"))
                            .font(.khayt(30, .semibold, relativeTo: .largeTitle))
                            .foregroundStyle(KhaytDesign.ink)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        // Settings, to see the role and unpair: a compact
                        // iPhone has no Settings tab (Home's gear opens it).
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(KhaytDesign.note)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(L10n.tr("tab.settings"))
                    }
                    .padding(.top, 8)
                    FloorBanner(text: L10n.tr(settings.effectiveRole == "operator" ? "floor.today.banner.operator"
                                                                                   : "floor.today.banner.viewer"))
                    if let problem { V2Note(text: problem, tone: KhaytDesign.late) }
                    printingNow
                    waitingAtPrinters
                    nextInQueue
                    V2Note(text: L10n.tr(settings.effectiveRole == "operator" ? "floor.today.no_money.operator"
                                                                              : "floor.today.no_money.viewer"))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showSettings) { SettingsView(showsClose: true) }
            .navigationDestination(item: $openOrder) { order in
                OrderDetailPage(order: order, facts: nil) { await load() }
            }
        }
    }

    private var busy: [MachineLiveStatus] { printers.filter(\.isPrinting) }

    @ViewBuilder private var printingNow: some View {
        FloorCard(title: L10n.format("floor.today.printing", busy.count)) {
            if busy.isEmpty {
                FloorLine(text: L10n.tr("floor.today.printing.none"))
            } else {
                ForEach(busy) { p in FloorLine(text: Self.printingLine(p, job: job(on: p.id), now: Date())) }
            }
        }
    }

    /// Printers waiting for a person (#2613's `waiting`), when the Mac sends
    /// it. An older Mac sends none, and the card is not shown.
    @ViewBuilder private var waitingAtPrinters: some View {
        let waiting = printers.filter { !$0.waitingReasons.isEmpty }
        if !waiting.isEmpty {
            FloorCard(title: L10n.tr("floor.today.waiting"), outline: KhaytDesign.attention) {
                ForEach(waiting) { p in
                    FloorLine(text: p.displayName + " · " + p.waitingReasons.joined(separator: " · "))
                }
            }
        }
    }

    private var next: [QueueOrder] {
        queue.filter { $0.status == "pending" || $0.status == "queued" }
    }

    @ViewBuilder private var nextInQueue: some View {
        FloorCard(title: L10n.format("floor.today.next", next.count)) {
            if next.isEmpty {
                FloorLine(text: L10n.tr("floor.today.next.none"))
            } else {
                ForEach(next.prefix(Self.nextShown)) { o in
                    Button { openOrder = o } label: {
                        FloorLine(text: Self.queueLine(o))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func job(on machineId: String) -> QueueOrder? {
        let on = queue.filter { $0.status == "printing" && $0.machineId == machineId }
        return on.count == 1 ? on[0] : nil
    }

    /// "Snapmaker U1 · Coffee dallah · 64% · done 16:40".
    static func printingLine(_ p: MachineLiveStatus, job: QueueOrder?, now: Date) -> String {
        var parts = [p.displayName]
        if let project = job?.project, !project.isEmpty { parts.append(project) }
        else if let file = p.filename, !file.isEmpty { parts.append(file) }
        if let progress = p.progress { parts.append("\(progress)%") }
        if let left = p.timeRemaining, left > 0 {
            let done = now.addingTimeInterval(TimeInterval(left))
            parts.append(L10n.format("floor.today.done_at", done.formatted(date: .omitted, time: .shortened)))
        }
        return parts.joined(separator: " · ")
    }

    /// "ORD-01042 Bracket set · due Thu".
    static func queueLine(_ o: QueueOrder) -> String {
        var line = o.reference
        if let project = o.project, !project.isEmpty { line += " " + project }
        if let due = DueDateParser.parse(o.dueDate ?? "") {
            line += " · " + L10n.format("floor.today.due", due.formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale)))
        }
        return line
    }

    private func load() async {
        do {
            async let live = api.fetchMachinesLive()
            async let q = api.fetchQueue()
            printers = (try? await live) ?? printers
            queue = try await q
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

extension MachineLiveStatus {
    /// What the printer waits for, in words. Empty until the Mac sends
    /// `waiting` (#2613/#2621, carried by #2616); kept here so the floor's
    /// Today shows the card the moment it does.
    var waitingReasons: [String] { [] }
}
