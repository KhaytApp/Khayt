import Foundation
import WidgetKit
import KhaytCore
import KhaytWidgetData

/// What the desktop widgets are told: written after every load and every
/// printer sweep, read by `KhaytWidgets.appex`.
///
/// ── WHAT IS NEVER WRITTEN ─────────────────────────────────────────────────
///
/// A widget sits on the desktop, where anybody at the Mac can read it without
/// unlocking anything in Khayt. So:
///
/// * **The sample book writes nothing**, and opening it takes away what the
///   real book wrote — a widget showing invented printers beside a real shop's
///   is worse than one saying "Open Khayt".
/// * **Nothing while the staff lock is on.** The lock exists so the book is
///   not open to whoever is at the Mac; a widget repeating its money on the
///   desktop would be a way round it. Switching the lock on empties the file,
///   exactly as it empties Spotlight (`Spotlight.indexable`).
/// * **No customer names, ever** — machines, counts and one total.
///
/// Like the menu bar's strip, the figures are the app's own: `printingNow`'s
/// rule for what counts as printing, the title bar's late count, the
/// dashboard's owed total. A widget that worked them out again would be a
/// second place for each to mean something different.
@MainActor
final class WidgetFeed {
    static let shared = WidgetFeed()

    /// The group container, or nil for a build that has no group (ad hoc).
    var directory: () -> URL? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: ShopWidgetSnapshot.groupInfoKey) as? String,
              !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    var reloadTimelines: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }

    /// What was last written, so an unchanged sweep costs a comparison.
    private(set) var last: ShopWidgetSnapshot?
    private var lastReload: Date?
    private var trailingReload: Task<Void, Never>?

    /// An unchanged snapshot is written again after this long, so "Updated"
    /// on the widget means "the app was looking" rather than "something moved".
    static let refreshAfter: TimeInterval = 5 * 60
    /// WidgetKit budgets reloads; a printer sweep every ten seconds must not
    /// spend it. A change inside the window is reloaded once at its end.
    static let reloadEvery: TimeInterval = 60

    /// The open stages: a job here is work still owed to somebody.
    static let openStages: Set<Stage> = [.pending, .on_hold, .printing, .post, .qc]

    // MARK: - What is written

    /// Whether this book may be on the desktop at all.
    static func shows(isReal: Bool, lockOn: Bool) -> Bool { isReal && !lockOn }

    /// One machine as the poller last heard it.
    struct Heard {
        var id: String
        var name: String
        var state: String
        var progress: Int
        var timeRemaining: Double?
    }

    /// Open jobs due on `now`'s day in the shop's calendar.
    static func dueToday(_ jobs: [(stage: Stage?, due: String?)], now: Date) -> Int {
        let today = Calendar.book.startOfDay(for: now)
        return jobs.count { job in
            guard let stage = job.stage, openStages.contains(stage), let day = Order.day(job.due) else { return false }
            return day == today
        }
    }

    /// The machines worth a row: printing or paused, the soonest to finish
    /// first, and those that did not say when after the ones that did.
    static func printing(_ heard: [Heard], now: Date) -> [ShopWidgetSnapshot.Printer] {
        heard.compactMap { m -> ShopWidgetSnapshot.Printer? in
            let paused = m.state.lowercased() == "paused"
            guard PrinterWatch.isPrinting(m.state) || paused else { return nil }
            let ends = (m.timeRemaining ?? 0) > 0 && !paused ? now.addingTimeInterval(m.timeRemaining!) : nil
            return .init(id: m.id, name: m.name, progress: m.progress, endsAt: ends, paused: paused)
        }
        .sorted { a, b in
            switch (a.endsAt, b.endsAt) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name < b.name
            }
        }
    }

    /// The spools the inventory calls low (`Shop.lowSpools`, worked out by the
    /// shop's own threshold in `lib/`), the emptiest first.
    static func lowSpools(_ spools: [Spool], low: Set<String>,
                          name: (Spool) -> String) -> [ShopWidgetSnapshot.LowSpool] {
        spools.filter { low.contains($0.id) }
            .map { s in
                let hex = s.color.flatMap { $0.hasPrefix("#") && $0.count == 7 ? $0 : nil }
                return ShopWidgetSnapshot.LowSpool(id: s.id, name: name(s), colour: hex,
                                                   gramsLeft: Int((s.weight ?? 0).rounded()))
            }
            .sorted { $0.gramsLeft != $1.gramsLeft ? $0.gramsLeft < $1.gramsLeft : $0.name < $1.name }
    }

    /// The jobs waiting for a printer — the board's waiting column, in the
    /// board's order (`Shop.boardOrder`). Title only: never the customer.
    static func upNext(_ orders: [Order], now: Date) -> [ShopWidgetSnapshot.QueuedJob] {
        orders.filter { Stage.of($0) == .pending }
            .sorted(by: Shop.boardOrder)
            .map { o in
                ShopWidgetSnapshot.QueuedJob(id: o.id, title: o.project.isEmpty ? o.id : o.project,
                                             due: Order.day(o.dueDate), late: o.isOverdue(now: now),
                                             urgent: o.priority)
            }
    }

    /// The words, in the app's language.
    static func words(_ words: Words) -> [String: String] {
        let keys: [ShopWidgetSnapshot.Word: String] = [
            .printingTitle: "mac.widget_printing", .nothingPrinting: "mac.nothing_printing",
            .idleMachines: "mac.widget_idle", .noMachines: "mac.no_machines",
            .paused: "mac.widget_paused", .todayTitle: "mac.widget_today",
            .dueToday: "mac.widget_due_today", .overdue: "mac.widget_late",
            .owed: "mac.widget_owed", .updated: "mac.widget_updated", .more: "mac.widget_more",
            .filamentTitle: "mac.widget_filament", .allStocked: "mac.widget_all_stocked",
            .grams: "mac.widget_grams", .upNextTitle: "mac.widget_up_next",
            .queueEmpty: "mac.widget_queue_empty", .urgent: "mac.widget_urgent",
            .glanceTitle: "mac.widget_glance",
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, words.callIt($0.value)) })
    }

    /// The snapshot for `shop`, or nil when nothing may be shown.
    static func snapshot(of shop: Shop, now: Date = Date()) -> ShopWidgetSnapshot? {
        guard shows(isReal: shop.source.isReal, lockOn: shop.lockSwitchedOn) else { return nil }
        return compose(shop, now: now)
    }

    /// The snapshot, without asking whether it may be shown — for the tests,
    /// which have only the sample book to compose from.
    static func compose(_ shop: Shop, now: Date) -> ShopWidgetSnapshot {
        let heard = shop.machines.compactMap { machine -> Heard? in
            guard let status = shop.printers.readings[machine.id]?.status else { return nil }
            return Heard(id: machine.id, name: machine.name, state: status.state,
                         progress: status.progress, timeRemaining: status.timeRemaining)
        }
        let low = lowSpools(shop.spools, low: shop.lowSpools, name: shop.spoolName)
        let queued = upNext(shop.orders, now: now)
        return ShopWidgetSnapshot(
            writtenAt: now, shopName: shop.shopName,
            language: shop.words.language, rightToLeft: shop.words.isRTL,
            words: words(shop.words),
            printing: printing(heard, now: now),
            machineCount: shop.machines.count,
            today: .init(dueToday: dueToday(shop.orders.map { (Stage.of($0), $0.dueDate) }, now: now),
                         overdue: shop.overdueCount,
                         owed: Money.short(shop.owed, shop.currency)),
            dayEnds: Calendar.book.date(byAdding: .day, value: 1, to: Calendar.book.startOfDay(for: now)),
            lowSpools: Array(low.prefix(ShopWidgetSnapshot.listLimit)), lowSpoolCount: low.count,
            upNext: Array(queued.prefix(ShopWidgetSnapshot.listLimit)), queuedCount: queued.count)
    }

    // MARK: - Writing it

    /// After a load or a sweep.
    func update(shop: Shop, now: Date = Date()) {
        write(Self.snapshot(of: shop, now: now), now: now)
    }

    /// Write `snapshot`, or take the file away when it is nil.
    func write(_ snapshot: ShopWidgetSnapshot?, now: Date = Date()) {
        // lock: system — the app's own widget file in its group container, never the book; with the lock on it only removes.
        guard let dir = directory() else { return }
        let file = dir.appending(path: ShopWidgetSnapshot.fileName)
        guard let snapshot else {
            last = nil
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
                reload(now: now)
            }
            return
        }
        // The same figures written a moment ago: nothing to do, unless long
        // enough has passed that "Updated" would start to mislead.
        if let last, Self.sameFigures(last, snapshot),
           now.timeIntervalSince(last.writtenAt) < Self.refreshAfter { return }
        guard let data = try? snapshot.encoded() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        last = snapshot
        reload(now: now)
    }

    /// The same, as a widget would draw it. A finish time is `now + remaining`
    /// worked out again at every sweep, so it wanders by a few seconds each
    /// time; a minute and a half either way is the same finish on a widget
    /// that counts in minutes, and counting it as a change wrote the file every
    /// ten seconds.
    static func sameFigures(_ a: ShopWidgetSnapshot, _ b: ShopWidgetSnapshot) -> Bool {
        guard a.printing.count == b.printing.count else { return false }
        for (x, y) in zip(a.printing, b.printing) {
            switch (x.endsAt, y.endsAt) {
            case (nil, nil): break
            case let (p?, q?) where abs(p.timeIntervalSince(q)) < 90: break
            default: return false
            }
        }
        var b = b
        b.writtenAt = a.writtenAt
        b.printing = zip(a.printing, b.printing).map { x, y in
            var y = y
            y.endsAt = x.endsAt
            return y
        }
        return a == b
    }

    private func reload(now: Date) {
        if let lastReload, now.timeIntervalSince(lastReload) < Self.reloadEvery {
            guard trailingReload == nil else { return }
            let wait = Self.reloadEvery - now.timeIntervalSince(lastReload)
            trailingReload = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.trailingReload = nil
                self.lastReload = Date()
                self.reloadTimelines()
            }
            return
        }
        lastReload = now
        reloadTimelines()
    }
}
