import Foundation
import SwiftUI

/// What the shop's printers are doing right now, for as long as somebody is
/// looking.
///
/// ── IT POLLS ONLY WHILE WATCHED ─────────────────────────────────────────
///
/// Every screen that shows a printer (Machines, Home's printing jobs, an
/// order's page) calls `watch()` when it appears and `unwatch()` when it goes.
/// With nobody watching, or the app in the background, nothing is asked: a
/// phone in an apron pocket polling a Mac every four seconds is a battery and a
/// Wi-Fi channel spent on a screen nobody can see.
///
/// ── AND IT SAYS WHEN IT CANNOT ──────────────────────────────────────────
///
/// `/api/machines/live` is served by the Electron desktop; the native Mac's
/// LAN server is being taught it. Against a Mac that does not answer it, or
/// from outside the shop's Wi-Fi, `isLive` is false and the screens keep
/// showing the book's last status, labelled as such — never a progress bar
/// frozen at whatever it last said, drawn as if it were moving.
/// One answer about the printers, and where it came from.
struct LiveSnapshot: Sendable {
    enum Source: Sendable, Equatable {
        /// Straight from the shop, on its Wi-Fi.
        case shop
        /// Relayed by Khayt Cloud, for a phone that is not in the shop.
        case cloud
    }
    var printers: [MachineLiveStatus]
    var source: Source
    /// When the shop's Mac last reported, when that is known — the cloud's
    /// `receivedAt`. Nil for an answer straight from the shop, which is now.
    var reportedAt: Date?
}

@MainActor
final class LivePrinters: ObservableObject {
    @Published private(set) var byMachine: [String: MachineLiveStatus] = [:]
    /// When the last answer arrived. Nil until one has.
    @Published private(set) var updatedAt: Date?
    /// True while answers are arriving. False when the Mac is out of reach or
    /// does not serve live readings.
    @Published private(set) var isLive = false
    /// Where the readings are coming from.
    @Published private(set) var source: LiveSnapshot.Source?
    /// When the Mac last reported, for a relayed answer.
    @Published private(set) var reportedAt: Date?

    /// A relayed snapshot older than this is not live: the Mac has stopped
    /// publishing (asleep, closed, off the network) and the cloud is holding
    /// its last word. The PWA draws the same line at two minutes.
    static let staleAfter: TimeInterval = 120

    /// How often to ask while it is answering, and how long to wait before
    /// asking again once it has not.
    private let interval: Duration
    private let backoff: Duration
    /// Through the cloud the Mac publishes at most every two seconds and
    /// usually far less, so asking every four would mostly fetch the same
    /// snapshot twice.
    private let cloudInterval: Duration

    private let fetch: () async throws -> LiveSnapshot
    private var watchers = 0
    private var active = true
    private var loop: Task<Void, Never>?

    init(interval: Duration = .seconds(4), cloudInterval: Duration = .seconds(10),
         backoff: Duration = .seconds(30), fetch: @escaping () async throws -> LiveSnapshot) {
        self.interval = interval
        self.cloudInterval = cloudInterval
        self.backoff = backoff
        self.fetch = fetch
    }

    /// The reading for the machine a job is on, when it has one worth drawing.
    func reading(for machineId: String?) -> MachineLiveStatus? {
        guard isLive, let machineId else { return nil }
        return byMachine[machineId]
    }

    func watch() {
        watchers += 1
        startIfNeeded()
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { stop() }
    }

    /// Follows the app in and out of the foreground.
    func setActive(_ isActive: Bool) {
        active = isActive
        if isActive { startIfNeeded() } else { stop() }
    }

    /// One answer, now — for pull-to-refresh, and for tests.
    func refresh() async {
        do {
            let snap = try await fetch()
            byMachine = Dictionary(snap.printers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            updatedAt = Date()
            source = snap.source
            reportedAt = snap.reportedAt
            if let reported = snap.reportedAt {
                isLive = Date().timeIntervalSince(reported) <= Self.staleAfter
            } else {
                isLive = true
            }
        } catch {
            isLive = false
        }
    }

    private func startIfNeeded() {
        guard loop == nil, watchers > 0, active else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let wait = !self.isLive ? self.backoff
                    : (self.source == .cloud ? self.cloudInterval : self.interval)
                try? await Task.sleep(for: wait)
            }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
    }
}

extension MachineLiveStatus {
    /// "2 hr, 14 min" / "45 min", in the reader's language — the desktop's
    /// `2h 14m` was English letters on an Arabic screen.
    var etaLocalized: String? { eta(in: L10n.currentLanguage.locale ?? .current) }

    func eta(in locale: Locale) -> String? {
        guard let secs = timeRemaining, secs > 0 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = secs >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        var calendar = Calendar.current
        calendar.locale = locale
        f.calendar = calendar
        return f.string(from: TimeInterval(max(60, secs)))
    }

    /// When it will finish, as a clock time — what a shop actually plans by.
    func finishesAt(from now: Date = Date()) -> Date? {
        guard let secs = timeRemaining, secs > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(secs))
    }
}

/// Watches the printers while this view is on screen AND `needed` is true —
/// for Home and Orders, which have something to draw only when a job on them
/// is printing on a machine the shop can name.
private struct WatchesPrinters: ViewModifier {
    let needed: Bool
    @EnvironmentObject private var printers: LivePrinters
    @State private var visible = false
    @State private var watching = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; sync() }
            .onDisappear { visible = false; sync() }
            .onChange(of: needed) { _, _ in sync() }
    }

    private func sync() {
        let want = visible && needed
        guard want != watching else { return }
        watching = want
        if want { printers.watch() } else { printers.unwatch() }
    }
}

extension View {
    func watchesPrinters(when needed: Bool) -> some View {
        modifier(WatchesPrinters(needed: needed))
    }
}
