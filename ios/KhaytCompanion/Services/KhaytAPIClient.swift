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

    /// The book, and the reader that turns it into what the screens decode.
    ///
    /// Optional because a build without its App Group container has neither, and
    /// because the companion still has to work against the Electron desktop,
    /// which does not serve `/api/store` and so never fills one.
    private let book: CompanionBook?
    private let reader: BookReader?
    /// Guards against a burst of screens each starting their own refresh.
    private var refreshing = false
    private var lastRefresh: Date?

    var isConfigured: Bool { settings.isConfigured }

    init(settings: ConnectionSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        let opened = try? CompanionBook.inSharedContainer()
        self.book = opened
        self.reader = opened.map(BookReader.init(book:))
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
        guard let book, settings.isConfigured, !refreshing else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        refreshing = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.refreshing = false } }
            // Send first: what the Mac takes now does not need carrying
            // through the pull. `adopt` keeps whatever it did not take.
            _ = try? await self?.sendPendingChanges()
            _ = try? await self?.pullBook(into: book)
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

    func fetchInventory() async throws -> [InventorySpool] {
        if let local = await fromBook({ try await $0.inventory() }) { return local }
        return try await get("/api/inventory", requiresPin: true, as: [InventorySpool].self)
    }

    func fetchMachines() async throws -> [MachineInfo] {
        if let local = await fromBook({ try await $0.machines() }) { return local }
        return try await get("/api/machines", requiresPin: true, as: [MachineInfo].self)
    }

    func fetchMachinesLive() async throws -> [MachineLiveStatus] {
        try await get("/api/machines/live", requiresPin: true, as: [MachineLiveStatus].self)
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
        let envelope = try JSONDecoder().decode(BookPull.self, from: data)
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
        await refreshPendingCount()
        return Self.recordCount(in: store)
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
    /// the baseline becomes the book. Doing it before the reply, or after a
    /// failure, would tell the next outbox that edits already went which never
    /// did — and they would never be sent again. A write that is silently
    /// dropped is worse than one that visibly fails.
    @discardableResult
    func sendPendingChanges() async throws -> Int? {
        guard let book, let reader else { return nil }
        guard let outbox = try await reader.pendingChanges(), !outbox.isEmpty else { return nil }

        let body = try JSONEncoder().encode(JSONValue.object(outbox.wire))
        let (data, response) = try await request(path: "/api/store/deltas", method: "POST",
                                                 body: body, requiresPin: true)
        guard let http = response as? HTTPURLResponse else {
            throw KhaytAPIError.transport(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw try decodeAPIError(data, status: http.statusCode)
        }
        // The Mac has it. Only now do the two agree.
        try book.markSynced()
        pendingCount = 0
        return outbox.count
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
    private func writeLocally(_ change: (BookWriter) throws -> Void) async throws -> Bool {
        guard let book, book.exists else { return false }
        do {
            try change(BookWriter(book: book))
        } catch is BookWriter.Refusal {
            // The book cannot represent this one. Fall through to the desktop,
            // which either does it properly or fails honestly.
            return false
        }
        await refreshPendingCount()
        _ = try? await sendPendingChanges()
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

    /// File an expense, with an optional photographed receipt. A write, so it
    /// needs a live connection — refused rather than queued, like every other.
    func addExpense(_ draft: ExpenseDraft) async throws {
        let body = try JSONEncoder().encode(draft)
        let (data, response) = try await request(
            path: "/api/expense", method: "POST", body: body, requiresPin: true
        )
        try ensureOK(data, response)
    }

    /**
     * Record a failed print where it happened.
     *
     * A write, so it needs a live connection — refused rather than queued, for
     * the same reason every other write is: a queued write is a promise about
     * ordering the phone cannot keep, and the desktop owns the data.
     *
     * The desktop stamps the date with the SHOP'S calendar day, so the phone
     * deliberately sends none. A phone travelling through a timezone would
     * otherwise file a failure under the wrong day's waste.
     */
    func logWaste(_ entry: WasteEntry) async throws {
        let body = try JSONEncoder().encode(entry)
        let (data, response) = try await request(
            path: "/api/waste", method: "POST", body: body, requiresPin: true
        )
        try ensureOK(data, response)
    }

    func deleteSpool(id: String) async throws {
        let encodedId = try encodeOrderIdForPath(id)
        let (data, response) = try await request(
            path: "/api/inventory/\(encodedId)", method: "DELETE", body: nil, requiresPin: true
        )
        try ensureOK(data, response)
    }

    func updateWaitingStatus(id: String, status: String) async throws {
        if try await writeLocally({ try $0.setWaitingStatus(id: id, to: status) }) { return }
        let encodedId = try encodeOrderIdForPath(id)
        let body = try JSONEncoder().encode(["status": status])
        let (data, response) = try await request(
            path: "/api/waiting-list/\(encodedId)", method: "PATCH", body: body, requiresPin: true
        )
        try ensureOK(data, response)
    }

    func updateOrderStatus(orderId: String, status: String) async throws {
        if try await writeLocally({ try $0.setOrderStatus(orderId: orderId, to: status) }) { return }
        let encodedId = try encodeOrderIdForPath(orderId)
        let body = try JSONEncoder().encode(["status": status])
        _ = try await request(
            path: "/api/orders/\(encodedId)",
            method: "PATCH",
            body: body,
            requiresPin: true
        )
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
            _ = try? await sendPendingChanges()
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
            _ = try? await sendPendingChanges()
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
                throw KhaytAPIError.server(String(format: L10n.tr("error.partial_add"), added.count, count, error.localizedDescription))
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
        if let printTemp = Int(printTrim), printTemp > 0 { payload["printTemp"] = printTemp }

        let bedTrim = draft.bedTemp.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bedTemp = Int(bedTrim), bedTemp > 0 { payload["bedTemp"] = bedTemp }

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
                    String(format: L10n.tr("connection.error.reach_status"), settings.displayURL)
                )
            default:
                throw err
            }
        } catch {
            throw KhaytAPIError.server(
                String(format: L10n.tr("connection.error.reach_status"), settings.displayURL)
            )
        }
        do {
            _ = try await fetchQueue()
        } catch let err as KhaytAPIError {
            if case .unauthorized = err {
                throw KhaytAPIError.unauthorized
            }
            throw err
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

    @discardableResult
    private func request(path: String, method: String, body: Data?, requiresPin: Bool) async throws -> (Data, URLResponse) {
        let url = try makeURL(path: path)

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let pin = settings.pin.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresPin, !pin.isEmpty {
            req.setValue(pin, forHTTPHeaderField: "x-khayt-pin")
        }

        do {
            return try await session.data(for: req)
        } catch {
            throw KhaytAPIError.transport(error)
        }
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
        if status == 401 { return .unauthorized }
        if let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
           let msg = decoded.error, !msg.isEmpty {
            return .server(msg)
        }
        return .server("Request failed (HTTP \(status))")
    }
}
