import Combine
import CryptoKit
import Foundation
import KhaytCore

@MainActor
final class KhaytAPIClient: ObservableObject {
    private let settings: ConnectionSettings
    private let session: URLSession

    /// When the data currently on screen was last true, if it came from the
    /// cache rather than the desktop. `nil` means what you are looking at is
    /// live. Published so the UI can say so instead of quietly showing old
    /// numbers as though they were current.
    @Published private(set) var servingCachedSince: Date?

    /// True while the screens are reading this phone's own book rather than
    /// asking the desktop. Not a degraded mode — it is the normal one once a
    /// shop has paired with a Mac that can hand the book over.
    @Published private(set) var servingFromBook = false

    /// Edits made on this phone that the Mac has not taken yet.
    ///
    /// Zero is the normal state, including when there is no book at all — a
    /// phone with nothing to send and a phone that cannot send are different
    /// things, but neither has anything waiting.
    @Published private(set) var pendingCount = 0

    /// What this phone holds of the order history, when it holds only part.
    @Published private(set) var historyWindow: HeldWindow?
    /// When to ask the shop for live printers again, after it did not answer.
    private var lanLiveRetryAt: Date?

    /// This phone's own Khayt Cloud sign-in, when it has one — see `CloudSession`.
    @Published private(set) var cloud: CloudSession? = CloudSession.load() {
        didSet { gateEdits() }
    }

    // MARK: - A viewer's sign-in

    /// Whether this phone may edit the shop. Not when its only way to the
    /// shop is a VIEWER's cloud sign-in: the cloud takes no writes from one,
    /// and with no Mac paired an edit kept here would be lost at the next
    /// pull. A paired Mac takes the phone's edits whatever the cloud role.
    var canWrite: Bool {
        #if DEBUG
        if Self.debugReadOnly { return false }
        #endif
        return Self.mayEdit(cloudRole: cloud?.role, macPaired: macPaired, sample: settings.isSampleShop)
    }

    /// A Mac this phone can deliver to: an address, and a PIN or an enrolment.
    private var macPaired: Bool {
        settings.isConfigured && (settings.device != nil || !settings.pin.isEmpty)
    }

    #if DEBUG
    /// `-KhaytReadOnly YES` on the launch line: the read-only state, for a
    /// screenshot. Debug builds only.
    static var debugReadOnly = false
    #endif

    nonisolated static func mayEdit(cloudRole: String?, macPaired: Bool, sample: Bool) -> Bool {
        sample || macPaired || cloudRole.map { $0 != "viewer" } ?? true
    }

    /// Tell the book whether edits are refused, and why. Every edit on the
    /// phone, whichever screen or intent makes it, goes through the book.
    private func gateEdits() {
        CompanionBook.editsRefused = canWrite ? nil : L10n.tr("cloud.read_only.refused")
    }

    private var settingsWatch: AnyCancellable?
    /// Set by `PrintActivities`; its tokens are registered again after a sign-in.
    weak var liveActivityPush: LiveActivityPush?
    /// Which way the book last went home, and when. Said on screen because a
    /// phone that synced through the cloud has reached the Mac only if the Mac
    /// has synced since.
    @Published private(set) var lastSync: SyncMark?
    /// Why the last cloud sync did not finish, in a sentence, or nil.
    @Published private(set) var cloudProblem: String?
    /// Khayt Cloud has refused this phone's token — revoked from the shop's
    /// device list, most often, which the cloud answers with the same plain
    /// 401 as any bad token (khayt-cloud `docs/api-contract.md`). Nothing but
    /// signing in again fixes it, so Settings offers exactly that.
    @Published private(set) var cloudNeedsSignIn = false
    /// When this phone last read the Mac's settings — a settings read
    /// (`refreshMacSettings`) or a whole `/api/store` pull — or nil if it never
    /// has. Kept across launches; Unpair forgets it. A phone that reads its
    /// book from the cloud and has no date here has never seen the Mac's
    /// connectors (`ConnectorLaunch.showsMacHint`).
    @Published private(set) var macSettingsAt: Date? =
        UserDefaults.standard.object(forKey: KhaytAPIClient.macSettingsAtKey) as? Date
    nonisolated static let macSettingsAtKey = "khayt.mac.settingsAt"

    private func noteMacSettings(at date: Date = Date()) {
        macSettingsAt = date
        UserDefaults.standard.set(date, forKey: Self.macSettingsAtKey)
    }

    /// Changes whenever a sync lands — a round home, or the Mac's settings
    /// read after it — for a view that reloads from the book then.
    var syncLanded: [Date] { [lastSync?.at, macSettingsAt].compactMap { $0 } }

    /// The Mac answered a send but did not take some of the changes in it,
    /// in a sentence, or nil. Those changes stay pending (`sendPendingChanges`).
    @Published private(set) var macRefused: String?

    struct SyncMark: Equatable {
        enum Route: Equatable { case mac, cloud }
        let route: Route
        let at: Date
    }

    /// The book, and the reader that turns it into what the screens decode.
    ///
    /// Optional because a build without its App Group container has neither, and
    /// because the companion still has to work against the Electron desktop,
    /// which does not serve `/api/store` and so never fills one.
    // Internal, not private: the WhatsApp extension (WhatsAppUpdates.swift) reads the book too.
    let book: CompanionBook?
    let reader: BookReader?
    /// Guards against a burst of screens each starting their own refresh.
    private var refreshing = false
    private var lastRefresh: Date?

    var isConfigured: Bool { settings.isConfigured }

    /// Whether this phone has any way home at all — a Mac it is paired with, a
    /// Khayt Cloud sign-in, or both. A phone set up from the cloud alone, while
    /// the Mac is out of reach or not yet reachable, is a working phone.
    var canSync: Bool { settings.isConfigured || cloud != nil }

    /// Does this phone hold a book at all? Published, so a screen gated on
    /// it redraws when a book arrives (a pull, a cloud round, the sample shop)
    /// or goes (unpair) without a relaunch. Kept by `refreshHoldsBook()`.
    @Published private(set) var holdsBook: Bool = false

    /// The same question asked of the disk, now: for a gate that must not
    /// trust a value that waits for its next refresh.
    nonisolated var holdsBookOnDisk: Bool { reader?.holdsAnyBook ?? false }

    /// Recompute `holdsBook` from the disk. Called after every path that can
    /// create or delete the book; assigns only on a change, so it never
    /// redraws a screen for nothing.
    func refreshHoldsBook() {
        let now = holdsBookOnDisk
        if holdsBook != now { holdsBook = now }
    }

    /// Whether the book on this phone holds ALL of a collection, so a total
    /// drawn from it is the shop's total and not the phone's.
    func holdsAll(_ collection: String) -> Bool { reader?.holdsAll(collection) ?? false }

    /// The book's scope, when there is a book. See `BookReader.scope()`.
    var bookScope: BookScope.Taken? { holdsBookOnDisk ? reader?.scope() : nil }

    /// How old the book is: the later of its last pull and the last sync.
    var bookAsOf: Date? {
        let pulled = book?.scope().flatMap { ISO8601DateFormatter.withFractions.date(from: $0.takenAt) }
        return [pulled, lastSync?.at].compactMap { $0 }.max()
    }

    /// One cheap question to the Mac itself — the public `/api/status` — for a
    /// strip that has to say whether the Mac is there, not whether the book is.
    func macAnswers() async -> Bool {
        guard settings.isConfigured,
              let (_, response) = try? await request(path: "/api/status?format=json", method: "GET",
                                                     body: nil, requiresPin: false),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// `protocols` is for tests: URL protocols that answer in place of the Mac.
    /// `withBook: false` is for tests too: a client that holds no book always
    /// asks the Mac, whatever the simulator's shared container holds.
    /// `book` is for tests as well: a book in a folder of the test's own.
    init(settings: ConnectionSettings, protocols: [AnyClass] = [], withBook: Bool = true,
         book injected: CompanionBook? = nil) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        if !protocols.isEmpty { config.protocolClasses = protocols + (config.protocolClasses ?? []) }
        // Every request to the Mac carries the PIN or this phone's signature,
        // so none may follow a redirect to another host — see `NoRedirects`.
        self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        let opened = injected ?? (withBook ? try? CompanionBook.inSharedContainer() : nil)
        self.book = opened
        self.reader = opened.map(BookReader.init(book:))
        _holdsBook = Published(initialValue: opened?.exists ?? false)
        gateEdits()
        // Pairing a Mac (or letting it go) changes whether edits have
        // somewhere to go. `objectWillChange` fires before the change lands.
        settingsWatch = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.gateEdits() }
        }
    }

    /// Read from this phone's own records when it has them, and ask the desktop
    /// when it does not.
    ///
    /// ── WHY THE BOOK COMES FIRST, NOT SECOND ─────────────────────────────
    ///
    /// The obvious arrangement is to ask the desktop and fall back to local data
    /// when it cannot be reached. That is what `CompanionCache` does, and for a
    /// cache it is right. It is wrong here for two reasons.
    ///
    /// The native Mac serves `/api/status`, `/api/queue` and `/api/store` and
    /// nothing else. Orders, inventory, clients, machines and the waiting list
    /// have no endpoint on it at all, so "ask the desktop first" is not a slower
    /// path for those screens, it is a broken one.
    ///
    /// And a screen fed live while its neighbour is fed locally is a phone whose
    /// two screens disagree about the same shop. One source at a time.
    ///
    /// Freshness is kept by refreshing the BOOK in the background rather than by
    /// reading past it — see `refreshBookIfConnected`.
    private func fromBook<T>(_ read: (BookReader) async throws -> T) async -> T? {
        guard let reader, reader.holdsAnyBook else { return nil }
        guard let value = try? await read(reader) else { return nil }
        servingFromBook = true
        servingCachedSince = nil
        historyWindow = reader.orderHistoryWindow()
        refreshBookIfConnected()
        return value
    }

    /// Bring the book up to date, at most once a minute, without blocking a read.
    ///
    /// Deliberately fire-and-forget: a screen must never wait on the network to
    /// draw records this phone already holds. If the Mac is out of reach this
    /// fails silently, which is correct — the screens are still right, they are
    /// just as of the last pull.
    private func refreshBookIfConnected() {
        guard let book, canSync, !refreshing else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        refreshing = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.refreshing = false } }
            // Send first: what the Mac takes now does not need carrying
            // through the pull. `adopt` keeps whatever it did not take.
            await self?.refreshEverywhere(book)
            await MainActor.run { self?.lastRefresh = Date() }
        }
    }

    func fetchStatus() async throws -> ShopStatus {
        if let local = await fromBook({ try await $0.status() }) { return local }
        return try await get("/api/status?format=json", requiresPin: false, as: ShopStatus.self)
    }

    func fetchQueue() async throws -> [QueueOrder] {
        if let local = await fromBook({ try await $0.queue() }) { return local }
        return try await get("/api/queue", requiresPin: true, as: [QueueOrder].self)
    }

    func fetchRecentOrders(limit: Int = 40, status: String? = nil) async throws -> [OrderLogEntry] {
        var path = "/api/orders?limit=\(min(max(limit, 1), 200))"
        if let status, !status.isEmpty {
            let encoded = status.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? status
            path += "&status=\(encoded)"
        }
        if let local = await fromBook({ try await $0.recentOrders(limit: limit, status: status) }) {
            return local
        }
        return try await get(path, requiresPin: true, as: [OrderLogEntry].self)
    }

    /// The shop's currency, when this phone holds its book. A price field
    /// labelled with a currency the app assumed is worse than an unlabelled one.
    func shopCurrency() async -> String? {
        guard let reader, reader.holdsAnyBook else { return nil }
        return try? await reader.shopCurrency()
    }

    /// The currency one order's money is in (its own, its customer's, then
    /// the shop's). A job priced in dollars must not read, or be paid, as riyals.
    func orderCurrency(orderId: String) async -> String? {
        guard let reader, reader.holdsAnyBook else { return nil }
        return try? await reader.orderCurrency(orderId: orderId)
    }

    /// Shop Pulse, from this phone's book. Nil with no book: the figures are
    /// the book's, and a phone that holds none has only the live counts.
    /// Filament and quantity per order, when this phone holds its book; empty
    /// otherwise. See `BookReader.orderFacts()`.
    func fetchOrderFacts() async -> [String: OrderFacts] {
        await fromBook { try await $0.orderFacts() } ?? [:]
    }

    /// What the book just copied holds, for pairing's last step.
    func fetchPairingSummary() async -> PairingSummary? {
        await fromBook { try await $0.pairingSummary() }
    }

    /// Today's End of Day figures; nil with no book.
    func fetchEndOfDay() async -> DayReport? {
        await fromBook { try await $0.endOfDay() }
    }

    /// One customer's page, from this phone's book; nil with no book.
    func fetchCustomer(id: String) async -> CustomerSummary? {
        await fromBook { try await $0.customer(id: id) } ?? nil
    }

    func fetchPulse() async -> ShopPulse? {
        await fromBook { try await $0.pulse() }
    }

    /// Who owes, from this phone's book; nil with no book.
    func fetchOwing() async -> [OwedLine]? {
        await fromBook { try await $0.owing() }
    }

    func fetchInventory() async throws -> [InventorySpool] {
        if let local = await fromBook({ try await $0.inventory() }) { return local }
        return try await get("/api/inventory", requiresPin: true, as: [InventorySpool].self)
    }

    func fetchMachines() async throws -> [MachineInfo] {
        if let local = await fromBook({ try await $0.machines() }) { return local }
        return try await get("/api/machines", requiresPin: true, as: [MachineInfo].self)
    }

    /// Live printer status: from the shop when it is in reach, and relayed by
    /// Khayt Cloud when it is not. Throws when neither answers.
    ///
    /// A LAN request that cannot reach the Mac takes its whole timeout to say
    /// so. Away from the shop that would be fifteen seconds before every cloud
    /// read, so once the shop has not answered, the next half-minute of polls
    /// go straight to the cloud and only then is the shop asked again.
    // MARK: - The sample shop

    /// Open the built-in sample shop: its book written to this phone like a
    /// pulled one, with nothing to pull it from and nowhere to send to.
    func openSampleShop(now: Date = Date()) throws {
        guard let book else { throw KhaytAPIError.notConfigured }
        let store = SampleShop.book(now: now)
        try book.replace(with: store, scope: SampleShop.scope(now: now))
        try book.replaceBaseline(with: store)
        try book.replaceLibrary(SampleShop.library())
        settings.host = ""
        settings.pin = ""
        settings.shopLabel = SampleShop.label
        settings.serviceName = ""
        settings.isSampleShop = true
        settings.isPaired = true
        refreshHoldsBook()
    }

    func fetchLivePrinters(now: Date = Date()) async throws -> LiveSnapshot {
        // The sample shop's printers run on the clock, so live tracking can be
        // seen without a printer.
        if settings.isSampleShop {
            return LiveSnapshot(printers: SampleShop.liveReadings(now: now), source: .shop, reportedAt: nil)
        }
        var lanError: Error?
        if lanLiveRetryAt.map({ now >= $0 }) ?? true {
            do {
                let rows = try await fetchMachinesLive()
                lanLiveRetryAt = nil
                return LiveSnapshot(printers: rows, source: .shop, reportedAt: nil)
            } catch {
                lanError = error
                lanLiveRetryAt = now.addingTimeInterval(30)
            }
        }
        guard let session = cloud, let book, let reader else {
            throw lanError ?? KhaytAPIError.notConfigured
        }
        let sync = CloudSync(book: book, engine: try await reader.sharedEngine())
        guard let snap = try await sync.livePrinters(session) else {
            throw lanError ?? KhaytAPIError.server(L10n.tr("machines.not_published"))
        }
        return snap
    }

    func fetchMachinesLive() async throws -> [MachineLiveStatus] {
        try await get("/api/machines/live", requiresPin: true, as: [MachineLiveStatus].self)
    }

    /// One job by id — open or among the recent finished ones — for a screen
    /// that only knows its id (a tapped alert, a feed line). Nil if gone.
    func findOrder(id: String) async -> QueueOrder? {
        if let open = (try? await fetchQueue())?.first(where: { $0.id == id }) { return open }
        if let done = (try? await fetchRecentOrders(limit: 200))?.first(where: { $0.id == id }) {
            return QueueOrder(entry: done)
        }
        return nil
    }

    func fetchClients() async throws -> [Client] {
        if let local = await fromBook({ try await $0.clients() }) { return local }
        return try await get("/api/clients", requiresPin: true, as: [Client].self)
    }

    func fetchWaitingList() async throws -> [WaitingListItem] {
        if let local = await fromBook({ try await $0.waitingList() }) { return local }
        return try await get("/api/waiting-list", requiresPin: true, as: [WaitingListItem].self)
    }

    /// Fetch the working set of the shop's book and keep it, so this phone can
    /// work without asking again.
    ///
    /// NOT the whole book. `printLog` is half a real shop's store and
    /// `printFiles` another quarter, all of it history no companion screen has
    /// ever shown, so the Mac cuts it down to `BookScope.workingSet` and says in
    /// the same breath what it left out. The phone keeps that description beside
    /// the records, because a partial book that reads as a complete one is worse
    /// than no book at all.
    ///
    /// ── NOT THROUGH `get`, AND THAT IS THE POINT ─────────────────────────
    ///
    /// Every other call here ends in `CompanionCache.store`, which is right for
    /// an answer to a question — a screenful of queue, kept so the screen is not
    /// blank next time. The book is not an answer to a question. Putting it
    /// through the same path would leave a second copy of the shop's whole
    /// client list on the phone, in a different file, with its own lifetime and
    /// its own thing to remember to delete at unpair. One copy, in the book.
    ///
    /// It also does not fall back to the cache on failure, for a harder reason:
    /// the fallback in `get` exists so a screen can show something slightly old
    /// rather than nothing. A pull that quietly "succeeded" with an older book
    /// would be telling this phone it is up to date with a Mac it never reached,
    /// and everything downstream — what to send, what to keep — measures against
    /// that. A pull either happened or it did not.
    ///
    /// Returns how many records arrived, so the screen that asked can say
    /// something true rather than "done".
    @discardableResult
    func pullBook(into book: CompanionBook) async throws -> Int {
        let (data, response) = try await request(path: "/api/store", method: "GET",
                                                 body: nil, requiresPin: true)
        guard let http = response as? HTTPURLResponse else {
            throw KhaytAPIError.transport(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw try decodeAPIError(data, status: http.statusCode)
        }
        // A whole working set, decoded off the main actor (`OffMain`).
        let envelope = try await OffMain.run { try JSONDecoder().decode(BookPull.self, from: data) }
        let store = envelope.store

        // A book with nothing in it is not a shop, it is a route that answered
        // the wrong thing — and replacing a book this phone already has with
        // that would lose everything on it. The Mac answers 500 rather than
        // `{}` for the same reason; this is the other half of that agreement,
        // because the phone must not depend on the Mac being the version that
        // keeps it.
        guard !store.isEmpty else {
            throw KhaytAPIError.server(L10n.tr("error.empty_book"))
        }

        // Adopted, not replaced: edits made here and not sent yet survive the
        // pull and stay pending. See `BookReader.adopt`.
        if let reader {
            try await reader.adopt(store, scope: envelope.scope)
        } else {
            try book.replace(with: store, scope: envelope.scope)
        }
        refreshHoldsBook()
        // The whole book carries the Mac's settings: as good as a settings read.
        noteMacSettings()
        let count = Self.recordCount(in: store)
        SyncDiagnostics.record(.macStore, records: count)
        await refreshPendingCount()
        return count
    }

    /// What `GET /api/store` sends: the records, and what was left behind.
    ///
    /// `whole` is what a caller asking `?scope=whole` gets and the phone never
    /// does. It is decoded anyway so that a build of this app pointed at a Mac
    /// answering that way does not fail to read a perfectly good reply.
    private struct BookPull: Decodable {
        let whole: Bool
        let scope: BookScope.Taken
        let store: [String: JSONValue]
    }

    /// Send what this phone has changed, and say how much arrived.
    ///
    /// `POST /api/store/deltas` — the outbox computed by the shop's own push
    /// rule, folded on the Mac by the shop's own pull rule. Returns nil when
    /// there is nothing to send or no book to send from.
    ///
    /// ── THE BASELINE MOVES ONLY ON SUCCESS ───────────────────────────────
    ///
    /// After the Mac has taken the changes, this phone and that Mac agree, so
    /// the baseline becomes the book THE OUTBOX WAS MEASURED FROM — not the
    /// book as it is after the reply, which may hold an edit made during the
    /// send. Doing it before the reply, or after a failure, would tell the
    /// next outbox that edits already went which never did — and they would
    /// never be sent again. A write that is silently dropped is worse than one
    /// that visibly fails.
    @discardableResult
    func sendPendingChanges() async throws -> Int? {
        guard let book, let reader else { return nil }
        guard let pending = try await reader.pendingSnapshot(), !pending.outbox.isEmpty else { return nil }
        let (outbox, measured, baseRevs) = pending

        let body = try JSONEncoder().encode(JSONValue.object(BookReader.wire(outbox, baseRevs: baseRevs)))
        let (data, response) = try await request(path: "/api/store/deltas", method: "POST",
                                                 body: body, requiresPin: true)
        guard let http = response as? HTTPURLResponse else {
            throw KhaytAPIError.transport(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw try decodeAPIError(data, status: http.statusCode)
        }
        // A 200 is not "all of it landed". The Mac answers 200 for changes it
        // did not take (a collection it does not accept from a phone, counted
        // as skipped), and marking those synced lost them without a word. So
        // nothing is marked delivered unless the Mac says it took everything;
        // otherwise it stays pending for the next send or the cloud.
        let refused = Self.refusedByMac(data)
        guard refused == 0 else {
            macRefused = L10n.format("sync.mac_refused", refused)
            await refreshPendingCount()
            throw KhaytAPIError.server(L10n.format("sync.mac_refused", refused))
        }
        macRefused = nil
        // The Mac has it. Only now do the two agree — up to what was sent.
        try book.markSynced(measured)
        await refreshPendingCount()
        return outbox.count
    }

    /// How many of the changes sent the Mac's delta reply says it did not
    /// take: `dropped` when the Mac names it, else `skipped` — which is
    /// conservative, since a stale edit the Mac's newer copy outranks is
    /// skipped too. Kept pending, that one goes at the next pull, when the
    /// Mac's copy becomes the baseline and the edit is no longer a change.
    /// A reply that cannot be read counts as nothing refused, as before.
    nonisolated static func refusedByMac(_ reply: Data) -> Int {
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: reply) else { return 0 }
        func count(_ key: String) -> Int? {
            if case .number(let n)? = o[key], n.isFinite { return max(0, Int(n)) }
            return nil
        }
        return count("dropped") ?? count("skipped") ?? 0
    }

    // MARK: - Two ways home: the Mac, then the cloud

    /// Bring the book up to date, by whichever way home is open.
    ///
    /// ── WITH A CLOUD SIGN-IN, THE CLOUD IS WHERE THE PHONE READS FROM ────
    ///
    /// Edits go to the Mac directly when it answers — it is the quicker way —
    /// but the book is REFRESHED from the cloud. The two are not the same copy
    /// at every moment: an edit this phone sent through the cloud is in the
    /// cloud before the Mac has pulled it, and adopting the Mac's book then
    /// would show the edit undone until the Mac caught up. The cloud has
    /// everything the Mac has sent and everything the phone has, so it is the
    /// copy that is never behind this phone. The Mac's book is taken only when
    /// the cloud cannot be reached.
    ///
    /// ── SETTINGS COME FROM THE MAC ───────────────────────────────────────
    ///
    /// A cloud change carries records, never `settings` (`changesToSend` has
    /// nowhere to put them), so a phone refreshed from the cloud never learnt
    /// of a connector installed on the Mac. After the round, a phone paired
    /// with a Mac reads the Mac's settings alone (`refreshMacSettings`) —
    /// unless the Mac's whole book came down in this round, which has them.
    /// It runs AFTER the cloud round on purpose: a whole cloud pull (a cold
    /// phone — just re-paired or signed in) adopts the cloud's store, whose
    /// settings hold no `plugins`, and the Mac's read must be the one that wins.
    func refreshEverywhere(_ book: CompanionBook) async {
        if settings.isConfigured, (try? await sendPendingChanges()) != nil {
            lastSync = SyncMark(route: .mac, at: Date())
        }
        var cloudDone = false
        if cloud != nil {
            // A refused round adopted nothing: the Mac's book still comes down.
            let round = await syncThroughCloud()
            if case .refused? = round { cloudDone = false } else { cloudDone = round != nil }
        }
        var pulled = false
        if !cloudDone, settings.isConfigured, (try? await pullBook(into: book)) != nil {
            lastSync = SyncMark(route: .mac, at: Date())
            pulled = true
        }
        if !settings.isConfigured {
            SyncDiagnostics.record(.skipped(.notConfigured))
        } else if pulled {
            SyncDiagnostics.record(.skipped(.pulled))
        } else {
            await refreshMacSettings(into: book)
        }
        refreshHoldsBook()
    }

    /// Settings ▸ Diagnostics' "Refresh now": one round at once, whatever the
    /// once-a-minute throttle says.
    func refreshNow() async {
        guard let book, canSync else { return }
        await refreshEverywhere(book)
        lastRefresh = Date()
    }

    /// The Diagnostics sheet's rows (`BookDiagnostics`): counts and states only.
    func diagnostics() async -> BookDiagnostics {
        BookDiagnostics.make(holdsBook: holdsBookOnDisk, book: book, connectors: await connectors(),
                             recorded: SyncDiagnostics.recorded(), isPaired: settings.isPaired,
                             isConfigured: settings.isConfigured, cloudSignedIn: cloud != nil,
                             isSampleShop: settings.isSampleShop, cloudShopId: cloud?.shopId)
    }

    /// What `GET /api/store/settings` sends: the shop's settings, masked as
    /// `/api/store` masks them, and when the Mac served them.
    private struct MacSettingsReply: Decodable {
        let settings: [String: JSONValue]?
        let servedAt: String?
    }

    /// The Mac's settings, alone: `GET /api/store/settings`, with the same
    /// PIN or signature as `/api/store`. Empty when the reply holds none.
    /// Throws for anything but a 2xx — an older Mac answers 404.
    func fetchMacSettings() async throws -> [String: JSONValue] {
        let (status, data) = try await getMacSettings()
        guard (200...299).contains(status) else { throw try decodeAPIError(data, status: status) }
        return try JSONDecoder().decode(MacSettingsReply.self, from: data).settings ?? [:]
    }

    private func getMacSettings() async throws -> (status: Int, data: Data) {
        let (data, response) = try await request(path: "/api/store/settings", method: "GET",
                                                 body: nil, requiresPin: true)
        guard let http = response as? HTTPURLResponse else {
            throw KhaytAPIError.transport(URLError(.badServerResponse))
        }
        return (http.statusCode, data)
    }

    /// Read the Mac's settings into the book and its baseline
    /// (`CompanionBook.adoptSettings`). Silent: a 404 (an older Mac), a 500, no
    /// answer or an empty reply leaves the book exactly as it was. True when
    /// settings landed.
    @discardableResult
    func refreshMacSettings(into book: CompanionBook) async -> Bool {
        func done(_ outcome: SyncDiagnostics.SettingsOutcome) -> Bool {
            SyncDiagnostics.record(outcome)
            return outcome == .ok
        }
        guard settings.isConfigured else { return done(.skipped(.notConfigured)) }
        guard !settings.isSampleShop else { return done(.skipped(.sampleShop)) }
        guard book.exists else { return done(.skipped(.noBook)) }
        let status: Int, data: Data
        do {
            (status, data) = try await getMacSettings()
        } catch KhaytAPIError.unauthorized {
            return done(.http(401))
        } catch {
            return done(.transport)
        }
        guard (200...299).contains(status) else { return done(.http(status)) }
        guard let fetched = try? JSONDecoder().decode(MacSettingsReply.self, from: data).settings,
              !fetched.isEmpty else { return done(.empty) }
        guard (try? await OffMain.run({ try book.adoptSettings(fetched) })) == true else { return done(.unwritten) }
        noteMacSettings()
        SyncDiagnostics.record(.macSettings)
        return done(.ok)
    }

    /// After an edit: to the Mac if it takes it, otherwise through the cloud.
    /// Never required — the edit is safe on the phone before either is tried.
    func deliverPending() async {
        await refreshPendingCount()
        guard pendingCount > 0 else { return }
        if settings.isConfigured, (try? await sendPendingChanges()) != nil {
            lastSync = SyncMark(route: .mac, at: Date())
        }
        if pendingCount > 0, cloud != nil { await syncThroughCloud() }
    }

    /// One round through Khayt Cloud: pull what changed, send what is pending.
    /// A viewer's sign-in only pulls. See `CloudSync` for what is never done.
    ///
    /// One round at a time. A pull reads the baseline, waits on the network
    /// and the engine, and writes it back; two rounds interleaved (a screen's
    /// refresh, the live channel and an edit's delivery, all at once) each
    /// wrote a baseline the other had not seen, and could fold the same
    /// changes twice or mark a send against a stale `seenRev`. A caller that
    /// arrives while a round is running waits for that round and gets its
    /// answer; an edit made meanwhile stays pending for the next one.
    @discardableResult
    func syncThroughCloud() async -> CloudSync.Pushed? {
        if let running = cloudRound { return await running.value }
        let round = Task { await self.oneCloudRound() }
        cloudRound = round
        let result = await round.value
        if cloudRound == round { cloudRound = nil }
        return result
    }

    /// The round `syncThroughCloud` callers share while it runs.
    private var cloudRound: Task<CloudSync.Pushed?, Never>?

    private func oneCloudRound() async -> CloudSync.Pushed? {
        guard var session = cloud, let book, let reader else { return nil }
        // "Use this shop instead" is for a phone with no Mac: a paired phone
        // takes the Mac's shop or none, whatever was stored.
        if session.adoptOtherShop, settings.isConfigured { session.adoptOtherShop = false }
        SyncDiagnostics.cloudRound(shopId: session.shopId)
        do {
            let sync = CloudSync(book: book, engine: try await reader.sharedEngine())
            var next = session
            var pushed: CloudSync.Pushed?
            if session.canWrite {
                let result = try await sync.push(session)
                next = result.0; pushed = result.1
            } else {
                let result = try await sync.pull(session)
                next = result.0
                if case .refused(let why) = result.1 { pushed = .refused(why) } else { pushed = .readOnly }
            }
            next.save()
            cloud = next
            // A whole pull can be this phone's first book.
            refreshHoldsBook()
            if case .refused(let why) = pushed {
                // Nothing was adopted or sent: not a sync, and said as such.
                cloudProblem = Self.refusalText(why)
                cloudNeedsSignIn = false
                return pushed
            }
            lastSync = SyncMark(route: .cloud, at: Date())
            cloudProblem = pushed == .needsTheMac ? L10n.tr("cloud.needs_mac") : nil
            cloudNeedsSignIn = false
            await refreshPendingCount()
            return pushed
        } catch CloudReader.Failure.unauthorised {
            cloudNeedsSignIn = true
            cloudProblem = L10n.tr("cloud.signed_out")
            return nil
        } catch CloudReader.Failure.http(429, _) {
            // Back off and try again — never "signed out".
            cloudProblem = L10n.tr("cloud.busy")
            return nil
        } catch {
            cloudProblem = Self.say(error)
            return nil
        }
    }

    // MARK: - Push (APNs), relayed by Khayt Cloud

    /// This phone's APNs device token, once iOS has handed it over.
    private var pushToken: Data?

    /// "sandbox" for a build run from Xcode, "production" for TestFlight and
    /// the App Store — the APNs environment the token belongs to.
    nonisolated static var pushEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// iOS gave us a token: tell the shop's cloud where to reach this phone.
    func didReceivePushToken(_ token: Data) async {
        pushToken = token
        await registerForPush()
    }

    /// `POST /v1/shops/{id}/push/apns` (khayt-cloud "Push: APNs"). Owner,
    /// manager and operator; a viewer has nothing to be alerted about and is
    /// not registered. Registering again is harmless — it makes the token the
    /// newest — so it is done on every launch and after every sign-in: a
    /// sign-out drops the registrations made with that sign-in.
    func registerForPush() async {
        guard let session = cloud, session.canWrite, let token = pushToken else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard var request = try? CloudReader.request(
            CloudReader.Connection(url: session.url, shopId: session.shopId, storedToken: ""),
            token: session.token, method: "POST", tail: "/push/apns") else { return }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": hex, "bundleId": Bundle.main.bundleIdentifier ?? "com.khaytapp.companion",
            "env": Self.pushEnvironment])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Stop the shop's alerts reaching this phone — before signing out, while
    /// the credential that registered it still works.
    private func unregisterForPush(_ session: CloudSession) async {
        guard let token = pushToken else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard let request = try? CloudReader.request(
            CloudReader.Connection(url: session.url, shopId: session.shopId, storedToken: ""),
            token: session.token, method: "DELETE", tail: "/push/apns/" + hex) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The live stream was refused as signed out — the same answer a sync
    /// gets, reached from the other side.
    func cloudSaysSignedOut() {
        cloudNeedsSignIn = true
        cloudProblem = L10n.tr("cloud.signed_out")
    }

    /// An error as a sentence. `CloudReader.Failure` explains itself through
    /// `description`, and `localizedDescription` ignores that: the screen said
    /// "The operation couldn't be completed. (KhaytCore.CloudReader.Failure
    /// error 4.)", which named neither the status code nor the reason.
    nonisolated static func say(_ error: Error) -> String {
        if error is LocalizedError { return error.localizedDescription }
        if let told = error as? CustomStringConvertible { return told.description }
        return error.localizedDescription
    }

    /// Sign this phone in to the shop's cloud, and take its first pull.
    ///
    /// Returns why that pull was refused, if it was (`CloudSync.Refusal`), so
    /// the sign-in sheet can say so and offer a way out. A sign-in whose shop
    /// is not the one the book is linked to is caught here, before any pull,
    /// push registration or Live Activity token reaches that other shop.
    @discardableResult
    func signInToCloud(url: String, email: String, password: String, passphrase: String) async throws
        -> CloudSync.Refusal? {
        guard let reader else { throw KhaytAPIError.notConfigured }
        let engine = try await reader.sharedEngine()
        let session = try await CloudSync.signIn(url: url, email: email, password: password,
                                                 passphrase: passphrase, engine: engine)
        session.save()
        cloud = session
        cloudNeedsSignIn = false
        cloudProblem = nil
        if let refusal = signedInToAnotherShop(session) {
            SyncDiagnostics.refused(.wrongShop, cloudShopId: session.shopId)
            cloudProblem = Self.refusalText(refusal)
            return refusal
        }
        await registerForPush()
        await liveActivityPush?.sendAll()
        if case .refused(let why)? = await syncThroughCloud() { return why }
        return nil
    }

    /// `.wrongShop` when the book on this phone is linked to a different
    /// shop than `session` — the check `CloudSync.pull` makes before adopting,
    /// made at sign-in too.
    func signedInToAnotherShop(_ session: CloudSession) -> CloudSync.Refusal? {
        guard let book, book.exists, let store = try? book.read() else { return nil }
        return CloudSync.shopRefusal(book: store, cloudShop: session.shopId)
    }

    /// May "Use this shop instead" be offered? Only with no Mac paired: a
    /// paired phone signs in with the Mac's account or unpairs.
    var mayAdoptOtherShop: Bool { cloud != nil && !settings.isConfigured }

    /// "Use this shop instead", confirmed: the NEXT whole pull adopts the
    /// signed-in shop over the book, once. False, and nothing changed, when a
    /// Mac is paired or no one is signed in. The caller runs the round.
    @discardableResult
    func useThisCloudShop() -> Bool {
        guard mayAdoptOtherShop, var session = cloud else { return false }
        session.adoptOtherShop = true
        session.save()
        cloud = session
        cloudProblem = nil
        return true
    }

    /// A refused pull, as the sentence a person reads.
    static func refusalText(_ refusal: CloudSync.Refusal) -> String {
        switch refusal {
        case .wrongShop(_, let email?): return L10n.format("cloud.wrong_shop.as", email)
        case .wrongShop: return L10n.tr("cloud.wrong_shop")
        case .emptyShop: return L10n.tr("cloud.empty_shop")
        }
    }

    func signOutOfCloud() {
        if let session = cloud { Task { await unregisterForPush(session) } }
        CloudSession.forget()
        cloud = nil
        cloudProblem = nil
        cloudNeedsSignIn = false
        if lastSync?.route == .cloud { lastSync = nil }
    }

    /// Unpair, from Settings or the sample shop's banner: everything
    /// `ConnectionSettings.unpair` deletes, AND the cloud sign-in this client
    /// holds in memory.
    ///
    /// `settings.unpair()` alone forgot the stored sign-in but left `cloud`
    /// set, so the phone kept syncing, kept its push registration, and kept
    /// the shop's prints on its Lock Screen until the app was killed. Now it
    /// goes through the same sign-out a person can choose on its own. The
    /// Live Activity tokens are withdrawn with the session taken beforehand —
    /// the one that registered them — so the phone is unpaired at once and
    /// the network catches up behind it.
    func unpair() {
        let session = cloud
        let push = liveActivityPush
        signOutOfCloud()
        settings.unpair()
        // `settings.unpair()` deleted the book.
        refreshHoldsBook()
        // Spotlight, the feed, the widgets, delivered alerts, shared papers.
        ShopTraces.forget()
        pendingCount = 0
        historyWindow = nil
        lastSync = nil
        macSettingsAt = nil
        Task { await push?.forgetShop(session: session) }
    }

    /// How many edits are waiting to reach the Mac, for a screen that says so.
    func refreshPendingCount() async {
        guard let reader else { return }
        let outbox = try? await reader.pendingChanges()
        pendingCount = outbox?.count ?? 0
    }

    /// Do a write locally when this phone keeps a book, and send it on.
    ///
    /// The send is attempted but never required: the whole point is that the
    /// edit is safe on the phone before the network is involved. A failure here
    /// leaves it in the outbox, counted, and the next successful send carries
    /// it.
    ///
    /// The write itself runs off the main actor (`OffMain`): it decodes,
    /// changes and writes the whole book, which on a shop with a history is
    /// a stall a tap should not wait in. Writes still go one at a time —
    /// every `StoreWriter.update` passes through its serial write chain,
    /// whatever thread it is called from.
    private func writeLocally(_ change: @escaping @Sendable (BookWriter) throws -> Void) async throws -> Bool {
        guard let book, book.exists else { return false }
        do {
            try await OffMain.run { try change(BookWriter(book: book)) }
        } catch is BookWriter.Refusal {
            // The book cannot represent this one. Fall through to the desktop,
            // which either does it properly or fails honestly.
            return false
        }
        await refreshPendingCount()
        await deliverPending()
        return true
    }

    /// How many records a book holds, counting only what is actually a list of
    /// them. `settings` is one object, not a collection, and counting its keys
    /// would inflate the number the screen shows.
    ///
    /// `nonisolated` so it can be tested without a client, a PIN or a network.
    nonisolated static func recordCount(in store: [String: JSONValue]) -> Int {
        store.values.reduce(0) { total, value in
            if case .array(let rows) = value { return total + rows.count }
            return total
        }
    }

    /**
     * Ask the desktop what a part costs and what to charge for it.
     *
     * Deliberately NOT cached, unlike every other read. A quote is a live
     * question about the shop's current material prices and settings, and a
     * stale answer given to a customer standing in front of you is a number the
     * shop then has to honour. Offline, this fails — which is the correct
     * outcome, and why the write-shaped `request` path is used rather than
     * `get`.
     */
    func requestQuote(_ input: QuoteRequest) async throws -> QuoteResult {
        let body = try JSONEncoder().encode(input)
        let (data, response) = try await request(path: "/api/quote", method: "POST",
                                                 body: body, requiresPin: true)
        guard let http = response as? HTTPURLResponse else {
            throw KhaytAPIError.transport(URLError(.badServerResponse))
        }
        // The native Mac serves no /api/quote yet (only the Windows/Linux app
        // does): its 404 is "Not found" in English, which says nothing.
        if http.statusCode == 404 { throw KhaytAPIError.server(L10n.tr("quote.needs_mac")) }
        guard (200...299).contains(http.statusCode) else {
            throw try decodeAPIError(data, status: http.statusCode)
        }
        return try JSONDecoder().decode(QuoteResult.self, from: data)
    }

    func updateSpoolRemaining(id: String, grams: Int) async throws {
        if try await writeLocally({ try $0.setSpoolRemaining(spoolId: id, grams: grams) }) { return }
        let encodedId = try encodeOrderIdForPath(id)
        let body = try JSONEncoder().encode(["remaining": max(0, grams)])
        let (data, response) = try await request(
            path: "/api/inventory/\(encodedId)", method: "PATCH", body: body, requiresPin: true
        )
        try ensureOK(data, response)
    }

    /// File an expense, with an optional photographed receipt.
    ///
    /// Into the book when there is no receipt — see `BookWriter.addExpense`.
    /// A receipt is a file the desk stores and points at, so one with a photo
    /// still needs a desktop that serves `/api/expense`.
    func addExpense(_ draft: ExpenseDraft) async throws {
        // One read off a receipt's QR goes into the book whatever else it has:
        // its VAT and its identity are what the shop's tax return and the
        // duplicate check need, and `/api/expense` carries neither.
        if draft.receiptBase64 == nil || draft.receiptRef != nil,
           try await writeLocally({ try $0.addExpense(draft) }) { return }
        let body = try JSONEncoder().encode(draft)
        let (data, response) = try await request(
            path: "/api/expense", method: "POST", body: body, requiresPin: true
        )
        // The native Mac serves no /api/expense yet: say so, and the sheet
        // keeps the draft (it closes only on success).
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw KhaytAPIError.server(L10n.tr("expense.needs_mac")) }
        try ensureOK(data, response)
    }

    /// Keep a receipt's seller as a supplier, in the book, and send it on like
    /// any other edit (see `BookWriter.addSupplier`). No desktop route takes
    /// this, so a phone that keeps no book cannot do it.
    func addSupplier(name: String, vatNumber: String) async throws {
        guard try await writeLocally({ try $0.addSupplier(name: name, vatNumber: vatNumber) }) else {
            throw BookWriter.Refusal.recordHasNoId
        }
    }

    /**
     * Record a failed print where it happened.
     *
     * Into the book when this phone keeps one, deduction and all, and sent on
     * like any edit — see `BookWriter.logWaste`. Over the wire otherwise, where
     * the desktop stamps the SHOP'S calendar day, so the phone sends none.
     */
    func logWaste(_ entry: WasteEntry) async throws {
        if try await writeLocally({ try $0.logWaste(entry) }) { return }
        let body = try JSONEncoder().encode(entry)
        let (data, response) = try await request(
            path: "/api/waste", method: "POST", body: body, requiresPin: true
        )
        try ensureOK(data, response)
    }

    /// Into the book when this phone keeps one: the removal leaves a tombstone
    /// that carries it home — see `BookWriter.deleteSpool`. The native Mac
    /// serves no `DELETE /api/inventory`, so for a shop on it this is the only
    /// way a spool deleted here is deleted at all.
    func deleteSpool(id: String) async throws {
        if try await writeLocally({ try $0.deleteSpool(id: id) }) { return }
        let encodedId = try encodeOrderIdForPath(id)
        let (data, response) = try await request(
            path: "/api/inventory/\(encodedId)", method: "DELETE", body: nil, requiresPin: true
        )
        try ensureOK(data, response)
    }

    func updateWaitingStatus(id: String, status: String, reminderDate: String? = nil) async throws {
        if try await writeLocally({ try $0.setWaitingStatus(id: id, to: status, reminderDate: reminderDate) }) { return }
        let encodedId = try encodeOrderIdForPath(id)
        var fields = ["status": status]
        if let reminderDate { fields["reminderDate"] = reminderDate }
        let body = try JSONEncoder().encode(fields)
        let (data, response) = try await request(
            path: "/api/waiting-list/\(encodedId)", method: "PATCH", body: body, requiresPin: true
        )
        try ensureOK(data, response)
    }

    /// "Take it": a walk-in becomes a pending job, and the request leaves the
    /// waiting list as `converted` — the desktop's own two writes.
    ///
    /// Only from the book. The LAN endpoint accepts `active`, `reminded` and
    /// `declined`, not `converted`, so without a book the phone could make the
    /// order but not say where the request went; a request left sitting there
    /// would be taken twice.
    func takeWaiting(_ item: WaitingListItem) async throws {
        guard let book, book.exists else { throw KhaytAPIError.server(L10n.tr("intake.take.needs_book")) }
        var draft = NewOrderDraft()
        draft.project = item.displayTitle
        draft.client = item.clientName ?? ""
        draft.material = item.material ?? ""
        if let est = item.estValue, est > 0 { draft.price = String(est) }
        try await createOrder(draft)
        try BookWriter(book: book).setWaitingStatus(id: item.id, to: "converted")
        await refreshPendingCount()
        await deliverPending()
    }

    /// Mark a finished job as sent: `shippedAt`, by the shop's own
    /// `KhaytOrderStatus.markShipped`, which leaves the status `completed` and
    /// refuses a job that is not finished or has already arrived.
    ///
    /// From the book only. No LAN route takes this, and a rule this phone
    /// cannot run is a move it does not make.
    func markShipped(orderId: String, now: Date = Date()) async throws {
        guard let book, book.exists, let reader else {
            throw KhaytAPIError.server(L10n.tr("alert.print.needs_book"))
        }
        guard case .array(let rows)? = try book.read()["printLog"],
              let order = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }) else {
            throw KhaytAPIError.server(L10n.tr("alert.print.no_order"))
        }
        let handover = try await reader.sharedEngine().markShipped(order: order, now: now)
        guard handover.ok, case .object(let shipped)? = handover.order else {
            throw KhaytAPIError.server(L10n.tr("alert.print.not_shippable"))
        }
        try book.updateRecord(collection: "printLog", id: orderId) { record in
            record["shippedAt"] = shipped["shippedAt"]
            if let history = shipped["statusHistory"] { record["statusHistory"] = history }
        }
        await refreshPendingCount()
        await deliverPending()
    }

    /// What the Edit sheet starts from: the job's due day, priority level and
    /// price, as the shared rule reads them. Nil without a book, or for a
    /// cancelled job.
    struct OrderEditState: Equatable {
        var dueDate: String?
        var priorityLevel: String
        var price: Double
    }

    func editState(orderId: String) async -> OrderEditState? {
        guard let book, book.exists, let reader, let store = try? book.read(),
              case .array(let rows)? = store["printLog"],
              let row = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }), case .object(let o) = row, o["status"] != .string("cancelled"),
              let engine = try? await reader.sharedEngine() else { return nil }
        var due: String?
        if case .string(let d)? = o["dueDate"], !d.isEmpty { due = String(d.prefix(10)) }
        var price = 0.0
        if case .number(let n)? = o["price"] { price = n }
        let level = (try? await engine.priority(of: row)) ?? "normal"
        return OrderEditState(dueDate: due, priorityLevel: level, price: price)
    }

    /// An edit to a job — `lib/order-edit.js` `applyEdit` through KhaytCore,
    /// as the Mac's Edit sheet: only the fields named, the edit written down
    /// in the job's history, the money following a typed price. Returns
    /// whether anything changed.
    @discardableResult
    func editOrder(orderId: String, fields: [String: JSONValue], now: Date = Date()) async throws -> Bool {
        guard let book, book.exists, let reader else {
            throw KhaytAPIError.server(L10n.tr("alert.print.needs_book"))
        }
        let store = try book.read()
        guard case .array(let rows)? = store["printLog"],
              let row = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }), case .object(let before) = row else {
            throw KhaytAPIError.server(L10n.tr("alert.print.no_order"))
        }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { settings = s }
        let edited = try await reader.sharedEngine().editJob(order: row, fields: fields, settings: settings,
                                                            now: now, editId: BookWriter.lanId("edit", now: now))
        guard edited.changed, case .object(let after) = edited.order else { return false }
        try book.updateRecord(collection: "printLog", id: orderId) { record in
            for (key, value) in after where before[key] != value { record[key] = value }
            for key in before.keys where after[key] == nil { record[key] = nil }
        }
        await refreshPendingCount()
        await deliverPending()
        return true
    }

    // MARK: - Printer care

    /// Each machine's care tasks and the parts to buy, from this phone's book
    /// (`CareBook`). Nil with no book: care is never asked of the desktop.
    /// Read and worked out off the main actor (`OffMain`): the whole book and
    /// its baseline are decoded for it.
    func printerCare(now: Date = Date()) async -> CareBook? {
        guard let book, book.exists else { return nil }
        return try? await OffMain.run { () -> CareBook? in
            guard let store = try? book.read() else { return nil }
            return CareBook(store: store, baseline: book.baseline(), scope: book.scope(), now: now)
        }
    }

    // MARK: - Shopping list and a print's energy

    /// Every filament at or under its reorder point, by supplier, from this
    /// phone's book (`ShopShoppingList`). Nil with no book: the list needs the
    /// suppliers, which only the book carries.
    func shoppingList(shopName: String) -> ShopShoppingList? {
        guard let book, book.exists, let store = try? book.read() else { return nil }
        return ShopShoppingList(store: store, shopName: shopName)
    }

    /// What a job's print drew from a metering plug, when one measured enough
    /// of it (`JobEnergy`). Nil otherwise, and with no book.
    func jobEnergy(orderId: String) -> JobEnergy? {
        guard let book, book.exists, let store = try? book.read() else { return nil }
        return JobEnergy.of(store: store, orderId: orderId)
    }

    /// A care task done, in the book (`BookWriter.markCareTaskDone`), then sent on.
    func markCareTaskDone(taskId: String, now: Date = Date()) async throws {
        guard let book, book.exists else { throw KhaytAPIError.server(L10n.tr("alert.print.needs_book")) }
        try BookWriter(book: book).markCareTaskDone(taskId: taskId, now: now)
        await refreshPendingCount()
        await deliverPending()
    }

    /// A care task inspected and not needed yet (`BookWriter.deferCareTask`), then sent on.
    func deferCareTask(taskId: String, now: Date = Date()) async throws {
        guard let book, book.exists else { throw KhaytAPIError.server(L10n.tr("alert.print.needs_book")) }
        try BookWriter(book: book).deferCareTask(taskId: taskId, now: now)
        await refreshPendingCount()
        await deliverPending()
    }

    /// The carriers to ship a job with — the Mac's Ship sheet list (Manual
    /// last, always there) — or nil when the job is not one to ship now:
    /// unfinished, already sent or already delivered.
    func shipChoices(orderId: String) async -> [KhaytEngine.CarrierChoice]? {
        guard let book, book.exists, let reader, let store = try? book.read(),
              case .array(let rows)? = store["printLog"],
              case .object(let o)? = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }),
              o["status"] == .string("completed"),
              o["deliveredAt"] == nil || o["deliveredAt"] == .null,
              o["shippedAt"] == nil || o["shippedAt"] == .null else { return nil }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { settings = s }
        return try? await reader.sharedEngine().carriersToShipWith(settings: .object(settings))
    }

    /// Hand a finished job to a carrier, with the number off the courier's
    /// receipt — `lib/shipment.js`'s `create`, as the Mac's `Shop.ship` does —
    /// so the customer's page has something to follow.
    func ship(orderId: String, carrier: String, service: String?, tracking: String, now: Date = Date()) async throws {
        guard let book, book.exists, let reader else {
            throw KhaytAPIError.server(L10n.tr("alert.print.needs_book"))
        }
        guard case .array(let rows)? = try book.read()["printLog"],
              let row = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }), case .object(let before) = row else {
            throw KhaytAPIError.server(L10n.tr("alert.print.no_order"))
        }
        guard before["status"] == .string("completed"),
              before["deliveredAt"] == nil || before["deliveredAt"] == .null else {
            throw KhaytAPIError.server(L10n.tr("alert.print.not_shippable"))
        }
        let shipped = try await reader.sharedEngine().shipmentCreate(order: row, carrier: carrier, service: service,
                                                                      trackingNumber: tracking, at: now)
        guard case .object(let after) = shipped else { throw KhaytAPIError.server(L10n.tr("alert.print.not_shippable")) }
        try book.updateRecord(collection: "printLog", id: orderId) { record in
            for (key, value) in after where before[key] != value { record[key] = value }
        }
        await refreshPendingCount()
        await deliverPending()
    }

    /// Where an order stands for money, by the shop's own `cashDue`. Nil
    /// without a book, for a voided or free job, or one this phone lacks.
    func paymentState(orderId: String) async -> BookWriter.PaymentState? {
        guard let book, book.exists, let reader,
              case .array(let rows)? = try? book.read()["printLog"],
              case .object(let order)? = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }) else { return nil }
        var settings: [String: JSONValue] = [:]
        if case .object(let st)? = try? book.read()["settings"] { settings = st }
        guard let engine = try? await reader.sharedEngine(),
              let due = try? await engine.cashDue(order: .object(order), settings: settings) else { return nil }
        return BookWriter.paymentState(order: order, gross: due.gross, cash: due.cash)
    }

    /// The models behind a job that may not be sold today (`LibraryCopy.saleProblems`).
    /// Empty without a book: unknown is not no.
    func saleProblems(orderId: String, now: Date = Date()) -> [ModelLicence.SaleProblem] {
        guard let book else { return [] }
        return LibraryCopy.saleProblems(orderId: orderId, book: book, now: now)
    }

    /// Record a payment — from the book only. No LAN route takes one, and the
    /// rule it runs is the shop's (`BookWriter.recordPayment`).
    func recordPayment(orderId: String, totalPaid: Double, method: String) async throws {
        guard let book, book.exists, let reader else { throw KhaytAPIError.server(L10n.tr("alert.print.needs_book")) }
        let engine = try await reader.sharedEngine()
        try await BookWriter(book: book).recordPayment(orderId: orderId, totalPaid: totalPaid,
                                                       method: method, engine: engine)
        await refreshPendingCount()
        await deliverPending()
    }

    // MARK: - Printer cameras

    /// A machine's still camera, as the phone can show it.
    struct CameraSource: Equatable {
        let url: URL
        let rotate: Int
        let flipH: Bool
        let flipV: Bool
    }

    enum CameraAnswer: Equatable {
        /// No camera set up for this machine.
        case none
        case available(CameraSource)
        /// Set up, but not something this phone can show; the sentence says why.
        case refused(String)
    }

    /// A machine's camera, decided by `lib/webcam.js` — the same rules the
    /// desktops' snapshot proxy runs: the SNAPSHOT url only (a stream never
    /// ends), and only from the printer's own host or a LAN address
    /// (`assertWebcamHostAllowed`). The phone fetches it itself, on the shop's
    /// Wi-Fi; it is not a proxy, so it adds no reach the shop did not set up.
    ///
    /// A camera that needs the printer's key (OctoPrint, PrusaLink, Bambu) is
    /// refused here: the phone's copy of the book carries credentials MASKED,
    /// and the key stays on the Mac. Moonraker's camera needs none.
    func camera(machineId: String) async -> CameraAnswer {
        guard let book, let reader, case .array(let rows)? = try? book.read()["machines"],
              case .object(let machine)? = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(machineId) { return true }
                  return false
              }), let engine = try? await reader.sharedEngine() else { return .none }
        let json = { (v: JSONValue) -> String in
            (try? String(decoding: JSONEncoder().encode(v), as: UTF8.self)) ?? "null"
        }
        let m = json(.object(machine))
        guard let urlText = try? await engine.raw("KhaytWebcam.snapshotUrlFor(\(m))", as: String.self),
              !urlText.isEmpty else { return .none }
        if urlText.lowercased().hasPrefix("rtsp:") { return .refused(L10n.tr("camera.rtsp")) }
        struct Allowed: Decodable { let ok: Bool; let reason: String? }
        let api = json(machine["printerApi"] ?? .null)
        guard let allowed = try? await engine.raw("KhaytWebcam.assertWebcamHostAllowed(\(json(.string(urlText))), \(api))",
                                                  as: Allowed.self), allowed.ok,
              let url = URL(string: urlText) else { return .refused(L10n.tr("camera.refused")) }
        if case .object(let p)? = machine["printerApi"], case .string(let t)? = p["type"],
           ["octoprint", "prusalink", "bambu"].contains(t.lowercased()) {
            return .refused(L10n.tr("camera.needs_key"))
        }
        var w: [String: JSONValue] = [:]
        if case .object(let o)? = machine["webcam"] { w = o }
        func int(_ k: String) -> Int { if case .number(let n)? = w[k] { return Int(n) }; return 0 }
        func bool(_ k: String) -> Bool { w[k] == .bool(true) }
        return .available(CameraSource(url: url, rotate: int("rotate"), flipH: bool("flipH"), flipV: bool("flipV")))
    }

    /// Is this response a frame worth reading? `checkSnapshotHeaders`, asked
    /// BEFORE the body is kept: a redirect, a non-image or anything over the
    /// rule's size limit is refused, and 204/503 mean "no frame yet", not broken.
    func snapshotHeadersOK(status: Int, contentType: String?, length: Int64) async -> (ok: Bool, reason: String?) {
        guard let reader, let engine = try? await reader.sharedEngine() else { return (false, nil) }
        struct Verdict: Decodable { let ok: Bool; let reason: String? }
        let type = (try? String(decoding: JSONEncoder().encode(contentType ?? ""), as: UTF8.self)) ?? "\"\""
        let v = try? await engine.raw("KhaytWebcam.checkSnapshotHeaders(\(status), \(type), \(length < 0 ? "null" : String(length)))",
                                      as: Verdict.self)
        return (v?.ok ?? false, v?.reason)
    }

    /// What a scanned Khayt label names, found in this phone's book.
    enum LabelTarget {
        case order(QueueOrder)
        case spool(InventorySpool)
        /// Not a Khayt label, or one whose record this phone does not hold.
        case refused(String)
    }

    /// Follow a scanned label to its record. The MEANING of the code is
    /// `lib/scan.js` (`KhaytEngine.scanCode`) — the module that reads what
    /// `lib/labels.js` writes — so the phone reads labels from either desktop.
    /// A tracking link is matched by its token, which is what the parcel
    /// carries: the link names an order without exposing its id.
    func followLabel(_ text: String) async -> LabelTarget {
        guard let reader, let engine = try? await reader.sharedEngine(),
              let read = try? await engine.scanCode(text) else { return .refused(L10n.tr("scan.label.unknown")) }
        switch read.type {
        case "spool":
            let spools = (try? await fetchInventory()) ?? []
            if let id = read.id, let s = spools.first(where: { $0.id == id }) { return .spool(s) }
        case "order", "track":
            var id = read.id
            if read.type == "track", let token = read.token, let book, case .array(let rows)? = try? book.read()["printLog"] {
                id = rows.compactMap { row -> String? in
                    guard case .object(let o) = row, o["trackingToken"] == .string(token),
                          case .string(let oid)? = o["id"] else { return nil }
                    return oid
                }.first
            }
            guard let id else { break }
            if let open = ((try? await fetchQueue()) ?? []).first(where: { $0.id == id }) { return .order(open) }
            if let done = ((try? await fetchRecentOrders(limit: 500)) ?? []).first(where: { $0.id == id }) {
                return .order(QueueOrder(entry: done))
            }
        default:
            return .refused(L10n.tr("scan.label.unknown"))
        }
        return .refused(L10n.tr("scan.label.missing"))
    }

    // MARK: - Quoting a model file

    /// What the Mac's estimate route answers (`POST /api/intake/estimate`).
    struct ModelEstimate: Decodable, Equatable {
        let ok: Bool
        let reason: String?
        let price: Double?
        let currency: String?
        let qty: Int?
        let grams: Double?
        let hours: Double?
        /// True when a slicer measured it; false for an estimate off the geometry.
        let exact: Bool?
        /// False when the geometry estimate is outside the range it is good
        /// for — a figure to check before sending.
        var reliable: Bool? = nil
        /// With `not-configured`: what the shop has not set up yet.
        var missing: String? = nil
        /// Worked out on this phone from the library copy, not by the Mac.
        var onPhone: Bool? = nil
    }

    /// The Mac's 32 MB ceiling (`LanServer.maxUpload`), checked here so a big
    /// file is refused on the phone instead of after the upload.
    nonisolated static let maxModelBytes = 32 * 1024 * 1024
    nonisolated static let modelExtensions: Set<String> = ["stl", "obj", "3mf", "gcode", "gco"]

    /// Ask the Mac what a model would cost — the same estimate its intake form
    /// gives a customer, opened to the owner PIN (Mac #1803). The model is
    /// measured on the Mac and priced by the shop's own settings.
    ///
    /// Only the estimate: the intake SUBMISSION records the customer's own
    /// privacy consent, which a shop filing from its phone cannot give for
    /// them, so the price becomes a quote order instead.
    func estimate(file url: URL, qty: Int) async throws -> ModelEstimate {
        let ext = url.pathExtension.lowercased()
        guard Self.modelExtensions.contains(ext) else {
            return ModelEstimate(ok: false, reason: "unsupported", price: nil, currency: nil, qty: nil,
                                 grams: nil, hours: nil, exact: nil)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxModelBytes else {
            return ModelEstimate(ok: false, reason: "too-large", price: nil, currency: nil, qty: nil,
                                 grams: nil, hours: nil, exact: nil)
        }
        var q = URLComponents()
        q.queryItems = [URLQueryItem(name: "name", value: "model." + ext),
                        URLQueryItem(name: "qty", value: String(max(1, min(1000, qty))))]
        let (body, response) = try await request(path: "/api/intake/estimate?" + (q.percentEncodedQuery ?? ""),
                                                 method: "POST", body: data, requiresPin: true)
        guard let http = response as? HTTPURLResponse else { throw KhaytAPIError.transport(URLError(.badServerResponse)) }
        if http.statusCode == 401 || http.statusCode == 404 { throw KhaytAPIError.server(L10n.tr("quote.file.needs_mac")) }
        // Refusals come back as { ok: false, reason } with a 4xx/5xx; read them.
        if let answer = try? JSONDecoder().decode(ModelEstimate.self, from: body) { return answer }
        throw try decodeAPIError(body, status: http.statusCode)
    }

    // MARK: - The catalogue

    /// What the shop sells, from the book this phone keeps: the Mac's prices,
    /// the small picture each product carries, and counted stock.
    func fetchCatalogue() async throws -> CataloguePage {
        guard let reader, holdsBookOnDisk else { throw KhaytAPIError.server(L10n.tr("catalogue.no_book")) }
        return try await reader.catalogue(language: L10n.contentLanguage)
    }

    // MARK: - Invoices

    /// A job's invoice, built from the book this phone keeps — or why not.
    func invoice(orderId: String, proforma: Bool = false) async -> InvoiceBuild {
        guard let reader, holdsBookOnDisk else { return .refused(.missing) }
        return (try? await reader.invoice(orderId: orderId, language: L10n.contentLanguage,
                                          proforma: proforma))
            ?? .refused(.failed)
    }

    // MARK: - The shop's library

    /// The built-in sample shop is open: nothing here talks to a Mac.
    var isSampleShop: Bool { settings.isSampleShop }

    /// One page of the library (`GET /api/library`). The library stays on the
    /// Mac — ten thousand models in a real shop — so searching and paging
    /// happen there.
    func fetchLibrary(query: String, folder: String, offset: Int = 0, limit: Int = 50,
                      filter: LibraryFilter = LibraryFilter()) async throws -> LibraryPage {
        if settings.isSampleShop {
            return SampleLibrary.page(query: query, folder: folder, offset: offset, limit: limit, filter: filter)
        }
        do {
            return try await libraryFromMac(query: query, folder: folder, offset: offset, limit: limit, filter: filter)
        } catch {
            // Away from the shop: the copy that came with the cloud sync.
            guard Self.isUnreachable(error) || isMissingRoute(error) else { throw error }
            guard let rows = book?.library() else {
                throw Self.isUnreachable(error) ? KhaytAPIError.server(L10n.tr("library.no_copy")) : error
            }
            var page = SampleLibrary.page(LibraryCopy.items(rows), query: query, folder: folder, offset: offset,
                                          limit: limit, filter: filter)
            page.fromCopy = true
            // The pictures the Mac already sent, kept on the phone.
            let kept = await thumbShelf.kept(page.items.map(\.id))
            for i in page.items.indices where kept.contains(page.items[i].id) { page.items[i].thumb = true }
            return page
        }
    }

    /// When the Mac last failed to answer: for a minute after, the library
    /// goes straight to the phone's copy rather than wait on every letter typed.
    private var libraryMacDownSince: Date?

    private func isMissingRoute(_ error: Error) -> Bool {
        if case KhaytAPIError.server(let said) = error { return said == L10n.tr("library.needs_mac") }
        return false
    }

    private func libraryFromMac(query: String, folder: String, offset: Int, limit: Int,
                                filter: LibraryFilter) async throws -> LibraryPage {
        if let down = libraryMacDownSince, Date().timeIntervalSince(down) < 60, book?.hasLibrary == true {
            throw KhaytAPIError.transport(URLError(.cannotConnectToHost))
        }
        do {
            let page = try await libraryPage(query: query, folder: folder, offset: offset, limit: limit, filter: filter)
            libraryMacDownSince = nil
            return page
        } catch {
            if Self.isUnreachable(error) { libraryMacDownSince = Date() }
            throw error
        }
    }

    private func libraryPage(query: String, folder: String, offset: Int, limit: Int,
                             filter: LibraryFilter) async throws -> LibraryPage {
        var q = URLComponents()
        q.queryItems = LibraryFilter.queryItems(query: query, folder: folder, offset: offset, limit: limit, filter: filter)
        let (data, response) = try await request(path: "/api/library?" + (q.percentEncodedQuery ?? ""),
                                                 method: "GET", body: nil, requiresPin: true)
        guard let http = response as? HTTPURLResponse else { throw KhaytAPIError.transport(URLError(.badServerResponse)) }
        if http.statusCode == 404 { throw KhaytAPIError.server(L10n.tr("library.needs_mac")) }
        guard (200...299).contains(http.statusCode) else { throw try decodeAPIError(data, status: http.statusCode) }
        return try JSONDecoder().decode(LibraryPage.self, from: data)
    }

    private let thumbs = NSCache<NSString, NSData>()
    var thumbShelf = LibraryThumbs.shared

    /// A model's thumbnail, or nil when it has none. Kept in memory for the
    /// session, since a list scrolls back over the same ones, and on disk
    /// (`LibraryThumbs`) for away from the shop. One the Mac sent within the
    /// day (its `max-age`) is not asked for again.
    func libraryThumb(id: String) async -> Data? {
        if let hit = thumbs.object(forKey: id as NSString) { return hit as Data }
        let kept = await thumbShelf.get(id)
        func use(_ data: Data) -> Data { thumbs.setObject(data as NSData, forKey: id as NSString); return data }
        if let kept, kept.age < 86_400 { return use(kept.data) }
        // The Mac did not answer a moment ago: do not wait on it once per row.
        if let down = libraryMacDownSince, Date().timeIntervalSince(down) < 60 { return kept.map { use($0.data) } }
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) else { return nil }
        let answer: (Data, URLResponse)
        do {
            answer = try await request(path: "/api/library/\(encoded)/thumb", method: "GET", body: nil, requiresPin: true)
        } catch {
            if Self.isUnreachable(error) { libraryMacDownSince = Date() }
            return kept.map { use($0.data) }
        }
        let (data, response) = answer
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200? where !data.isEmpty && data.count < 4_000_000:
            let small = LibraryThumbs.shrink(data) ?? data
            await thumbShelf.put(id, small)
            return use(small)
        case 404?:
            // The model has no picture any more.
            await thumbShelf.remove(id)
            return nil
        default:
            return kept.map { use($0.data) }
        }
    }

    /// While the Mac answers: every library picture it has, kept small on the
    /// phone, so the library looks the same away from the shop. Once every
    /// twelve hours at most, one picture at a time, only the ones not kept
    /// yet; it stops at the first sign the Mac has gone.
    ///
    /// Folder by folder: `/api/library` with no search lists ONE folder's
    /// models and the folders under it, on the Mac and on the desktop alike,
    /// so asking for folder "" alone kept the top folder's pictures and no
    /// others. A walk that reaches the end also lets go of every picture the
    /// Mac no longer lists — a model archived, deleted or left without one.
    private var keepingPictures = false
    static let picturesKeptAtKey = "khayt.library.picturesKeptAt"

    @discardableResult
    func keepAllLibraryPictures(now: Date = Date(), defaults: UserDefaults = .standard) async -> Int {
        guard !settings.isSampleShop, !keepingPictures else { return 0 }
        if let last = defaults.object(forKey: Self.picturesKeptAtKey) as? Date, now.timeIntervalSince(last) < 12 * 3600 { return 0 }
        keepingPictures = true
        defer { keepingPictures = false }
        var fetched = 0
        var folders = [""], walked: Set<String> = [], pictured: Set<String> = []
        while let folder = folders.popLast() {
            guard walked.insert(folder).inserted else { continue }
            var offset = 0
            while true {
                if Task.isCancelled { return fetched }
                guard let page = try? await libraryPage(query: "", folder: folder, offset: offset, limit: 200) else { return fetched }
                if offset == 0 { folders += page.folders.map(\.path) }
                let want = page.items.filter(\.thumb).map(\.id)
                pictured.formUnion(want)
                let kept = await thumbShelf.kept(want)
                for id in want where !kept.contains(id) {
                    if Task.isCancelled { return fetched }
                    if await libraryThumb(id: id) != nil { fetched += 1 }
                    // The Mac stopped answering: try again on the next visit.
                    if let down = libraryMacDownSince, Date().timeIntervalSince(down) < 60 { return fetched }
                }
                offset += page.items.count
                if page.items.isEmpty || offset >= page.total { break }
            }
        }
        await thumbShelf.keepOnly(pictured)
        defaults.set(now, forKey: Self.picturesKeptAtKey)
        return fetched
    }

    /// What a library model would cost: measured and priced on the Mac, or —
    /// away from the shop — worked out here from the library copy.
    func estimate(libraryId id: String, qty: Int, plate: Int?) async throws -> ModelEstimate {
        // No Mac to measure with: the screen offers the calculator instead.
        if settings.isSampleShop { throw KhaytAPIError.server(L10n.tr("library.needs_mac")) }
        do {
            if let down = libraryMacDownSince, Date().timeIntervalSince(down) < 60, book?.hasLibrary == true {
                throw KhaytAPIError.transport(URLError(.cannotConnectToHost))
            }
            return try await estimateOnMac(libraryId: id, qty: qty, plate: plate)
        } catch {
            guard Self.isUnreachable(error) || isMissingRoute(error),
                  let local = await estimateHere(libraryId: id, qty: qty, plate: plate) else { throw error }
            return local
        }
    }

    /// The same question, answered on this phone from the library copy and the
    /// book's spools, rates and margin. Nil when the copy cannot answer it.
    func estimateHere(libraryId id: String, qty: Int, plate: Int?) async -> ModelEstimate? {
        guard let reader, let rows = book?.library(),
              let row = rows.first(where: { if case .object(let o) = $0, case .string(let i)? = o["id"] { return i == id } else { return false } }),
              let store = try? await reader.wholeBook(), let engine = try? await reader.sharedEngine() else { return nil }
        let settings: [String: JSONValue] = { if case .object(let o)? = store["settings"] { return o } else { return [:] } }()
        let orders: [JSONValue] = { if case .array(let r)? = store["printLog"] { return r } else { return [] } }()
        let refused = { (why: String) in
            ModelEstimate(ok: false, reason: why, price: nil, currency: nil, qty: nil, grams: nil, hours: nil,
                          exact: false, onPhone: true)
        }
        guard let figures = await LibraryCopy.figures(row, plate: plate, engine: engine, settings: settings, orders: orders)
        else { return refused("no-numbers") }
        let shelf = await reader.shelf(store)
        let spool = LibraryCopy.spool(for: figures.material, among: shelf.spools)
        let pieces = max(1, min(1000, qty))
        let question = CalculatorQuestion(
            lines: [CalculatorPart.Line(spool: spool?.costing, grams: figures.grams)],
            purge: 0, hours: figures.hours, qty: pieces, machineId: nil,
            presetId: shelf.presets.count == 1 ? shelf.presets[0].id : nil,
            rates: [:], pieces: [], margin: LibraryCopy.defaultMargin(settings), discount: 0, rush: false)
        guard let answer = try? await reader.calculate(question), answer.quoted.total > 0 else { return refused("no-price") }
        return ModelEstimate(ok: true, reason: nil, price: answer.quoted.total, currency: shelf.currency,
                             qty: pieces, grams: figures.grams, hours: figures.hours, exact: figures.exact,
                             reliable: figures.reliable, onPhone: true)
    }

    private func estimateOnMac(libraryId id: String, qty: Int, plate: Int?) async throws -> ModelEstimate {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) else {
            throw KhaytAPIError.invalidURL
        }
        var q = URLComponents()
        q.queryItems = [URLQueryItem(name: "qty", value: String(max(1, min(1000, qty))))]
            + (plate.map { [URLQueryItem(name: "plate", value: String($0))] } ?? [])
        let (body, response) = try await request(path: "/api/library/\(encoded)/estimate?" + (q.percentEncodedQuery ?? ""),
                                                 method: "POST", body: nil, requiresPin: true)
        guard let http = response as? HTTPURLResponse else { throw KhaytAPIError.transport(URLError(.badServerResponse)) }
        if let answer = try? JSONDecoder().decode(ModelEstimate.self, from: body) { return answer }
        if http.statusCode == 404 { throw KhaytAPIError.server(L10n.tr("library.needs_mac")) }
        throw try decodeAPIError(body, status: http.statusCode)
    }

    /// Move a job — the order page's stage picker, the queue's advance
    /// button, a notification's action, Siri, a quote's Approve or Decline.
    ///
    /// With a book, by the shop's own status rule (`BookWriter.setOrderStatus`):
    /// the filament comes off the shelf and the completion is dated, as on the
    /// Mac. A move the rule refuses throws its sentence and is NOT sent to the
    /// desktop instead. Without a book, the desktop's PATCH, as it always was.
    ///
    /// Returns what the rule has to say about the move — filament taken, a
    /// spool running low, a due date pushed back — as sentences to show. The
    /// desktop's PATCH says nothing, so that route returns none.
    @discardableResult
    func updateOrderStatus(orderId: String, status: String) async throws -> [String] {
        if let book, book.exists, let reader {
            let engine = try await reader.sharedEngine()
            do {
                let notices = try await BookWriter(book: book).setOrderStatus(orderId: orderId, to: status, engine: engine)
                await refreshPendingCount()
                await deliverPending()
                return notices.map(BookWriter.sentence(for:))
            } catch is BookWriter.Refusal {
                // Not in this book. Fall through to the desktop, which either
                // does it properly or fails honestly — as `writeLocally` does.
            }
        }
        let encodedId = try encodeOrderIdForPath(orderId)
        let body = try JSONEncoder().encode(["status": status])
        let (data, response) = try await request(
            path: "/api/orders/\(encodedId)",
            method: "PATCH",
            body: body,
            requiresPin: true
        )
        // A refusal (locked pairing, bad stage) must surface, not look saved.
        // The shop's rule refusing the move says why, in this app's words.
        if let http = response as? HTTPURLResponse,
           let refused = BookWriter.MoveRefused.fromWire(status: http.statusCode, body: data) {
            throw refused
        }
        try ensureOK(data, response)
        return []
    }

    func assignMachine(orderId: String, machineId: String?) async throws {
        if let reader, let book, book.exists {
            let machines = (try? await reader.machines()) ?? []
            if try await writeLocally({
                try $0.assignMachine(orderId: orderId, machineId: machineId, machines: machines)
            }) { return }
        }
        let encodedId = try encodeOrderIdForPath(orderId)
        // [String: String?] encodes a nil value as JSON null (unassign).
        let body = try JSONEncoder().encode(["machineId": machineId])
        let (data, response) = try await request(
            path: "/api/orders/\(encodedId)", method: "PATCH", body: body, requiresPin: true
        )
        try ensureOK(data, response)
    }

    func createOrder(_ draft: NewOrderDraft) async throws {
        let project = draft.project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { throw KhaytAPIError.server(L10n.tr("error.project_required")) }

        // Into the phone's own book when it keeps one, and sent on — see
        // `BookWriter.addOrder`. A machine the shop does not have is refused
        // here exactly as the endpoint's 404 refuses it.
        if let book, book.exists, let reader {
            let machines = (try? await reader.machines()) ?? []
            _ = try BookWriter(book: book).addOrder(draft, machines: machines)
            await refreshPendingCount()
            await deliverPending()
            return
        }

        var payload: [String: Any] = [
            "project": InputLimits.clamp(project, max: InputLimits.maxMaterial),
            "status": draft.isQuote ? "quote" : "pending"
        ]
        let client = draft.client.trimmingCharacters(in: .whitespacesAndNewlines)
        if !client.isEmpty { payload["client"] = InputLimits.clamp(client) }
        let material = draft.material.trimmingCharacters(in: .whitespacesAndNewlines)
        if !material.isEmpty { payload["material"] = InputLimits.clamp(material, max: InputLimits.maxMaterial) }
        // The same reading of the price as the offline path — a comma or an
        // Arabic keypad's digits are a price, not nothing.
        if let price = SpoolDraft.price(draft.price) { payload["price"] = price }
        if !draft.dueDate.isEmpty { payload["dueDate"] = draft.dueDate }
        if let machineId = draft.machineId, !machineId.isEmpty { payload["machineId"] = machineId }
        if let clientId = draft.clientId, !clientId.isEmpty { payload["clientId"] = clientId }

        let data = try JSONSerialization.data(withJSONObject: payload)
        let (responseData, response) = try await request(
            path: "/api/orders", method: "POST", body: data, requiresPin: true
        )
        try ensureOK(responseData, response)
    }

    func addSpool(from tag: NFCFilamentTag) async throws -> InventorySpool {
        try await addSpool(draft: SpoolDraft.from(tag: tag))
    }

    func addSpool(material: String, weight: Int, color: String = "#888888", brand: String? = nil) async throws -> InventorySpool {
        var draft = SpoolDraft()
        draft.material = material
        draft.weightGrams = weight
        draft.colorHex = color
        draft.brand = brand ?? ""
        draft.sourceNote = L10n.tr("spool.source.manual")
        return try await addSpool(draft: draft)
    }

    func addSpool(draft: SpoolDraft) async throws -> InventorySpool {
        var one = draft
        one.quantity = 1
        return try await addSpools(draft: one)[0]
    }

    /// Book in `draft.quantity` identical rolls — each its own spool.
    ///
    /// Into the phone's book it is one write: all of them or none. Against a
    /// desktop with no book on the phone it is one request per roll, because
    /// that is all `POST /api/inventory` takes; a failure part-way says how
    /// many made it rather than leaving the count to be guessed.
    @discardableResult
    func addSpools(draft: SpoolDraft) async throws -> [InventorySpool] {
        let material = draft.material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !material.isEmpty else {
            throw KhaytAPIError.server(L10n.tr("error.material_required"))
        }
        let count = min(SpoolDraft.maxQuantity, max(1, draft.quantity))

        // Booked into this phone's own book when it keeps one, and sent on.
        // The native Mac has no `/api/inventory` at all, so for a shop on it
        // this is the only way a roll booked in here reaches the shelf.
        if let book, book.exists, let reader {
            let records = try await reader.newSpools(from: draft, count: count)
            try BookWriter(book: book).addSpools(records)
            await refreshPendingCount()
            await deliverPending()
            return try records.map { record in
                let data = try JSONEncoder().encode(JSONValue.object(record))
                return try JSONDecoder().decode(InventorySpool.self, from: data)
            }
        }

        var added: [InventorySpool] = []
        for _ in 0..<count {
            do {
                added.append(try await postSpool(draft: draft, material: material))
            } catch where !added.isEmpty {
                throw KhaytAPIError.server(L10n.format("error.partial_add", added.count, count, error.localizedDescription))
            }
        }
        return added
    }

    private func postSpool(draft: SpoolDraft, material: String) async throws -> InventorySpool {
        // `id`, `purchasedAt` and `remaining` are not sent: the server decides
        // the first two (the shop's calendar, not this phone's UTC one) and
        // derives the third, and `pickLanSpoolFields` drops all of them.
        var payload: [String: Any] = [
            "material": InputLimits.clamp(material, max: InputLimits.maxMaterial),
            "brand": InputLimits.clamp(draft.brand.trimmingCharacters(in: .whitespacesAndNewlines)),
            "color": InputLimits.clamp(draft.colorHex.isEmpty ? "#888888" : draft.colorHex, max: 32),
            "weight": draft.weightGrams,
            "weightTotal": draft.weightGrams,
            "weightRemaining": draft.weightGrams,
            "materialType": "fdm"
        ]
        if let cost = draft.costValue { payload["cost"] = cost }

        let sku = InputLimits.clamp(draft.sku.trimmingCharacters(in: .whitespacesAndNewlines))
        if !sku.isEmpty { payload["sku"] = sku }
        if let code = ProductBarcode.normalize(draft.barcode) { payload["barcode"] = code }

        let lot = InputLimits.clamp(draft.lot.trimmingCharacters(in: .whitespacesAndNewlines))
        if !lot.isEmpty { payload["lot"] = lot }

        let printTrim = draft.printTemp.trimmingCharacters(in: .whitespacesAndNewlines)
        if let printTemp = PhoneCalculator.wholeNumber(printTrim), printTemp > 0 { payload["printTemp"] = printTemp }

        let bedTrim = draft.bedTemp.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bedTemp = PhoneCalculator.wholeNumber(bedTrim), bedTemp > 0 { payload["bedTemp"] = bedTemp }

        let data = try JSONSerialization.data(withJSONObject: payload)
        let (responseData, response) = try await request(
            path: "/api/inventory",
            method: "POST",
            body: data,
            requiresPin: true
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw try decodeAPIError(responseData, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct AddResponse: Codable { let spool: InventorySpool? }
        if let decoded = try? JSONDecoder().decode(AddResponse.self, from: responseData), let spool = decoded.spool {
            return spool
        }
        throw KhaytAPIError.server(L10n.tr("error.unexpected_spool"))
    }

    func validatePairing() async throws -> ShopStatus {
        guard settings.isConfigured else { throw KhaytAPIError.notConfigured }
        let status: ShopStatus
        do {
            status = try await fetchStatus()
        } catch let err as KhaytAPIError {
            switch err {
            case .transport, .notConfigured, .invalidURL:
                throw KhaytAPIError.server(
                    L10n.format("connection.error.reach_status", settings.displayURL)
                )
            default:
                throw err
            }
        } catch {
            throw KhaytAPIError.server(
                L10n.format("connection.error.reach_status", settings.displayURL)
            )
        }
        do {
            _ = try await fetchQueue()
        } catch let err as KhaytAPIError {
            if case .unauthorized = err {
                throw KhaytAPIError.unauthorized
            }
            throw err   // `.pinTooShort` included: it says what to do
        }
        return status
    }

    func probeConnection() async throws -> ShopStatus {
        try await validatePairing()
    }

    // MARK: - HTTP

    /**
     * Every read goes through here, so this is where the app stops being blank
     * when the desktop is out of reach: a successful answer is remembered, and a
     * request that cannot reach the desktop falls back to the last one.
     *
     * The fallback is restricted to TRANSPORT failures on purpose. A 401 or a
     * 500 is the desktop answering, and serving cached data over it would hide a
     * real problem behind stale numbers — the shop would read a wrong PIN, or a
     * broken server, as "everything is fine, just a bit old". Only genuine
     * unreachability is papered over, and even then the staleness is published
     * rather than pretended away.
     */
    private func get<T: Codable>(_ path: String, requiresPin: Bool, as type: T.Type) async throws -> T {
        do {
            let (data, response) = try await request(path: path, method: "GET", body: nil, requiresPin: requiresPin)
            guard let http = response as? HTTPURLResponse else { throw KhaytAPIError.transport(URLError(.badServerResponse)) }
            guard (200...299).contains(http.statusCode) else {
                throw try decodeAPIError(data, status: http.statusCode)
            }
            let value = try JSONDecoder().decode(T.self, from: data)
            await CompanionCache.shared.store(value, for: path)
            servingCachedSince = nil
            return value
        } catch {
            guard Self.isUnreachable(error),
                  let cached = await CompanionCache.shared.load(T.self, for: path) else { throw error }
            servingCachedSince = cached.storedAt
            return cached.value
        }
    }

    /// Could not reach the desktop at all — as opposed to reaching it and being
    /// told something. Decoding failures are excluded too: a payload we cannot
    /// read is a contract problem, and hiding it behind cached data is how it
    /// stays unnoticed (see scripts/ios-contract.sh).
    /// `nonisolated` because it inspects nothing but the error — the class is
    /// @MainActor, and inheriting that would make the rule untestable off the
    /// main actor for no reason.
    nonisolated static func isUnreachable(_ error: Error) -> Bool {
        if case KhaytAPIError.transport = error { return true }
        return error is URLError
    }

    private func encodeOrderIdForPath(_ orderId: String) throws -> String {
        let trimmed = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              !trimmed.contains("/"),
              !trimmed.contains("..") else {
            throw KhaytAPIError.server(L10n.tr("error.invalid_order_id"))
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw KhaytAPIError.server(L10n.tr("error.invalid_order_id"))
        }
        return encoded
    }

    // MARK: - The Mac's identity

    private struct IdentityAnswer: Decodable { let alg: String?; let publicKey: String }
    private struct ProofAnswer: Decodable { let alg: String?; let sig: String }

    /// The Mac's public key, asked with the PIN at the address the phone
    /// already uses. Nil when the Mac has none to give (a desktop without the
    /// route, a 503) or sends something that is not a key.
    func fetchIdentityKey() async -> String? {
        guard let (data, response) = try? await request(path: "/api/identity", method: "GET",
                                                         body: nil, requiresPin: true),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(IdentityAnswer.self, from: data),
              answer.alg == MacIdentity.algorithm,
              MacIdentity.publicKey(answer.publicKey) != nil else { return nil }
        return answer.publicKey
    }

    /// Whether whatever answers at `host:port` holds `key`. No PIN is sent:
    /// only a fresh nonce, and the signature is checked here.
    func proves(host: String, port: Int, key: String) async -> Bool {
        guard let base = ConnectionSettings.baseURL(host: host, port: port),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return false }
        let nonce = MacIdentity.nonce()
        parts.path = "/api/proof"
        parts.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
        guard let url = parts.url else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(ProofAnswer.self, from: data) else { return false }
        return MacIdentity.verify(signature: answer.sig, alg: answer.alg, nonce: nonce, key: key)
    }

    private func makeURL(path: String) throws -> URL {
        guard let base = settings.baseURL else { throw KhaytAPIError.notConfigured }
        guard path.hasPrefix("/") else { throw KhaytAPIError.invalidURL }
        var components = URLComponents()
        components.scheme = base.scheme ?? "http"
        components.host = base.host
        components.port = base.port
        // Split path from query — otherwise URLComponents percent-encodes the
        // "?" into the path (%3F), breaking ?format=json and ?status= filters.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.path = String(parts[0])
        if parts.count > 1, !parts[1].isEmpty {
            components.percentEncodedQuery = String(parts[1])
        }
        guard let url = components.url else { throw KhaytAPIError.invalidURL }
        return url
    }

    /// A signed request to the Mac whose answer the caller reads whatever its
    /// status — the printer route says why in its body.
    func lanRequest(path: String, method: String) async throws -> (Data, URLResponse) {
        try await request(path: path, method: method, body: nil, requiresPin: true)
    }

    @discardableResult
    private func request(path: String, method: String, body: Data?, requiresPin: Bool,
                         contentType: String = "application/json") async throws -> (Data, URLResponse) {
        let url = try makeURL(path: path)
        guard requiresPin else { return try await send(url, method: method, body: body, auth: .none, contentType: contentType) }
        guard let device = usableDevice else { return try await send(url, method: method, body: body, auth: .pin, contentType: contentType) }

        let (data, response) = try await send(url, method: method, body: body, auth: .device(device), contentType: contentType)
        let status = (response as? HTTPURLResponse)?.statusCode
        if let status, (200...299).contains(status), settings.needsPairAgain {
            // A signed request went through: whatever said this phone was
            // unknown was not the Mac, or the Mac has taken it back.
            settings.needsPairAgain = false
        }
        guard status == 401 else { return (data, response) }
        switch DeviceKey.refusal(data) {
        case .unknown?:
            // ── NEVER THE PIN IN ANSWER TO A 401 ─────────────────────────
            //
            // Removed on the Mac (its PIN changed, or it was let go) — or so
            // says a reply nobody signed, which anything on the shop's Wi-Fi
            // can send. Answering it with the PIN, as this once did, handed
            // the PIN in the clear to whoever asked.
            //
            // So the answerer first proves it holds the PINNED Mac key
            // (`/api/proof`, a fresh nonce, no PIN). Proven: the Mac really
            // forgot this phone, the request fails and the phone says it needs
            // pairing again — only the person, typing the PIN, sends it. Not
            // proven, or no answer: an impostor or a network fault. Nothing
            // changes, no PIN goes anywhere, and the enrolment is kept.
            let key = settings.macIdentityKey
            if !key.isEmpty, await proves(host: settings.host, port: settings.port, key: key) {
                settings.needsPairAgain = true
                throw KhaytAPIError.unauthorized
            }
            throw KhaytAPIError.transport(URLError(.userAuthenticationRequired))
        case .clock(let now)?:
            clockOffset = TimeInterval(now) - Date().timeIntervalSince1970
            return try await send(url, method: method, body: body, auth: .device(device), contentType: contentType)
        case .replay?:
            return try await send(url, method: method, body: body, auth: .device(device), contentType: contentType)
        case .revoked?:
            // Signed out on the Mac: never back to the PIN, never enrol.
            settings.forgetMac(keepShop: cloud != nil)
            enrolNotBefore = nil
            throw KhaytAPIError.server(L10n.tr("pair.signed_out"))
        case nil:
            return (data, response)
        }
    }

    private enum Auth { case none, pin, device(DeviceKey.Credential) }

    /// The enrolment, while the identity that signed it is still the pinned one.
    private var usableDevice: DeviceKey.Credential? {
        guard let device = settings.device, !device.identityKey.isEmpty,
              device.identityKey == settings.macIdentityKey else { return nil }
        return device
    }

    /// The Mac's clock minus this phone's, once the Mac has said (`device-clock`).
    private var clockOffset: TimeInterval = 0

    private func send(_ url: URL, method: String, body: Data?, auth: Auth,
                      contentType: String = "application/json") async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        switch auth {
        case .none:
            break
        case .pin:
            let pin = settings.pin.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pin.isEmpty { req.setValue(pin, forHTTPHeaderField: "x-khayt-pin") }
        case .device(let device):
            guard let h = DeviceKey.headers(device, method: method, url: url, body: body,
                                            now: Date().addingTimeInterval(clockOffset)) else {
                throw KhaytAPIError.unauthorized
            }
            req.setValue(h.device, forHTTPHeaderField: "x-khayt-device")
            req.setValue(h.time, forHTTPHeaderField: "x-khayt-time")
            req.setValue(h.nonce, forHTTPHeaderField: "x-khayt-nonce")
            req.setValue(h.mac, forHTTPHeaderField: "x-khayt-mac")
        }

        do {
            let answer = try await session.data(for: req)
            SyncDiagnostics.macAnswered()
            return answer
        } catch {
            SyncDiagnostics.macFailed()
            throw KhaytAPIError.transport(error)
        }
    }

    // MARK: - A photo of the print, from this phone

    /// The Mac takes a job photo only from a phone it enrolled (signed), never
    /// on the PIN alone: `POST /api/orders/{id}/photos` (docs/LAN_API.md).
    var canAddJobPhoto: Bool { usableDevice != nil && !settings.isSampleShop }

    /// Send one photo of the finished print to the Mac, which keeps it full
    /// size beside the book, makes the small copy every app shows, and adds it
    /// to the job. Then the book is pulled, so it shows here too.
    func addJobPhoto(orderId: String, jpeg: Data) async -> JobPhotoUpload {
        guard canAddJobPhoto else { return .refused("device-key-required") }
        guard let id = try? encodeOrderIdForPath(orderId),
              let (data, response) = try? await request(path: "/api/orders/\(id)/photos", method: "POST",
                                                         body: jpeg, requiresPin: true, contentType: "image/jpeg"),
              let http = response as? HTTPURLResponse else { return .refused("unreachable") }
        let reply = JobPhotoUpload.read(status: http.statusCode, body: data)
        if case .added = reply, let book { _ = try? await pullBook(into: book) }
        return reply
    }

    // MARK: - Enrolling this phone

    /// `closed`: the Mac takes a new phone only while its owner has clicked
    /// "Pair a phone" (Settings ▸ Online), and that window is shut.
    /// `locked`: this phone gave too many wrong PINs while the window was open
    /// (429 `pairing-locked`); it waits for the next window, like `closed`.
    enum Enrolment: Equatable { case enrolled, unsupported, failed, closed, locked }

    private struct EnrolAnswer: Decodable { let deviceId: String; let publicKey: String; let sig: String }

    /// Not before then: a Mac without the route is asked again a day later,
    /// a failed try an hour later.
    private(set) var enrolNotBefore: Date?

    /// Whether this phone should enrol now: paired, the identity pinned, no
    /// enrolment for it yet, and not asked too recently.
    func wantsEnrolment(now: Date = Date()) -> Bool {
        guard settings.isPaired, !settings.pin.isEmpty, !settings.isSampleShop, !settings.macIdentityKey.isEmpty,
              usableDevice == nil else { return false }
        return enrolNotBefore.map { now >= $0 } ?? true
    }

    /// Enrol with the PIN, once, so later requests are signed instead.
    /// Needs the Mac's identity key pinned first: that is what proves the
    /// answer came from the Mac.
    @discardableResult
    func enrolDevice(name: String, now: Date = Date()) async -> Enrolment {
        let result = await enrol(name: name)
        lastEnrolment = result
        switch result {
        case .enrolled: enrolNotBefore = nil
        case .unsupported: enrolNotBefore = now.addingTimeInterval(86_400)
        // A shut window waits as long as a failure. Every try carries the PIN,
        // in the clear, and a window may stay shut for good: retrying each
        // minute would send it sixty times as often as before. Settings offers
        // "Secure this phone" for when the owner opens the window.
        case .failed, .closed, .locked: enrolNotBefore = now.addingTimeInterval(3600)
        }
        return result
    }

    /// How the last enrolment went, for Settings: `.closed` means the phone
    /// still signs in with the PIN until the owner opens the Mac's window.
    @Published private(set) var lastEnrolment: Enrolment?

    /// Settings' "Secure this phone": enrol now, whatever the wait.
    func secureThisPhone(name: String) async -> Enrolment {
        if settings.macIdentityKey.isEmpty, let key = await fetchIdentityKey() { settings.macIdentityKey = key }
        guard !settings.macIdentityKey.isEmpty else { return .failed }
        return await enrolDevice(name: name)
    }

    private func enrol(name: String) async -> Enrolment {
        let identity = settings.macIdentityKey
        guard !identity.isEmpty, let url = try? makeURL(path: "/api/devices") else { return .failed }
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let ask: [String: String] = [
            "publicKey": phone.publicKey.rawRepresentation.base64EncodedString(),
            "name": String(name.prefix(60)),
        ]
        guard let body = try? JSONEncoder().encode(ask),
              let (data, response) = try? await send(url, method: "POST", body: body, auth: .pin),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        if [404, 405, 503].contains(status) { return .unsupported }
        if status == 403, Self.pairingClosed(data) { return .closed }
        if status == 429, Self.pairingReason(data) == "pairing-locked" { return .locked }
        guard status == 200,
              let answer = try? JSONDecoder().decode(EnrolAnswer.self, from: data),
              // The PIN or the Mac may have changed while this was in flight.
              settings.macIdentityKey == identity,
              let credential = DeviceKey.credential(deviceId: answer.deviceId, macPublic: answer.publicKey,
                                                    sig: answer.sig, phonePrivate: phone,
                                                    identityKey: identity) else { return .failed }
        settings.device = credential
        // Signed from here on: the PIN is not kept for a reply to ask for.
        settings.dropPinAfterEnrolment()
        return .enrolled
    }

    /// After the person typed the PIN (pairing, or "Pair again"): pin the
    /// Mac's key, then enrol. Nil when the Mac has no key to give or no
    /// device route: the phone pairs on the PIN, as an older desktop needs.
    /// A shut or locked pairing window lets the pinned key go again, so the
    /// next try starts clean.
    func enrolWithTypedPin(name: String) async -> Enrolment? {
        if settings.macIdentityKey.isEmpty, let key = await fetchIdentityKey() {
            settings.macIdentityKey = key
        }
        guard !settings.macIdentityKey.isEmpty else { return nil }
        let result = await enrolDevice(name: name)
        if result == .closed || result == .locked { settings.macIdentityKey = "" }
        return result
    }

    /// "Pair again", from the banner: the Mac no longer knows this phone, or
    /// it moved to an address that could not prove itself. The PIN is the
    /// one just typed, sent where the person chose to send it — never one
    /// the phone kept.
    func pairAgain(pin: String, name: String) async throws -> Enrolment? {
        // A new PIN lets the old enrolment and pinned key go (see
        // `ConnectionSettings.pin`), so this asks with the PIN itself — and
        // asks the Mac, not the book, which would say yes to any PIN.
        settings.pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        let (data, response) = try await request(path: "/api/queue", method: "GET", body: nil, requiresPin: true)
        try ensureOK(data, response)
        return await enrolWithTypedPin(name: name)
    }

    private func ensureOK(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw KhaytAPIError.transport(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw try decodeAPIError(data, status: http.statusCode)
        }
    }

    private func decodeAPIError(_ data: Data, status: Int) throws -> KhaytAPIError {
        if status == 401 { return Self.unauthorizedKind(data) }
        // Locked out of the Mac's pairing window, on ANY PIN-checked route
        // while it is open: say what to do, in this app's words.
        if status == 429, Self.pairingReason(data) == "pairing-locked" { return .server(L10n.tr("pair.window_locked")) }
        if let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
           let msg = decoded.error, !msg.isEmpty {
            return .server(msg)
        }
        return .server(L10n.format("api.request_failed", status))
    }
}

extension KhaytAPIClient {
    /// The Mac's "no pairing window is open" answer to `POST /api/devices`.
    nonisolated static func pairingClosed(_ body: Data) -> Bool { pairingReason(body) == "pairing-closed" }

    /// The `reason` of a refusal, when it carries one.
    nonisolated static func pairingReason(_ body: Data) -> String? {
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .string(let reason)? = o["reason"] else { return nil }
        return reason
    }

    /// Which 401 this is. The native Mac refuses an owner PIN shorter than 8
    /// characters with its own reason (#1713); that is not a wrong PIN, and
    /// telling a shop "that PIN was refused" would send it hunting for a typo.
    /// A `reason` code is preferred; the sentence is the fallback for a Mac
    /// that does not send one.
    nonisolated static func unauthorizedKind(_ body: Data) -> KhaytAPIError {
        if case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body) {
            if case .string(let reason)? = o["reason"], reason == "pin-too-short" { return .pinTooShort }
            if case .string(let error)? = o["error"], error.lowercased().contains("too short") { return .pinTooShort }
        }
        return .unauthorized
    }
}

extension ISO8601DateFormatter {
    /// `new Date().toISOString()` — what `StoreWriter.iso` writes.
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
