import Foundation

struct ShopStatus: Codable, Sendable {
    let queued: Int
    let pending: Int
    let printing: Int
    let post: Int
    let qc: Int
    let completedToday: Int

    enum CodingKeys: String, CodingKey {
        case queued, pending, printing, post, qc
        case completedToday = "completed_today"
    }
}

struct QueueOrder: Codable, Identifiable, Sendable {
    let id: String
    let project: String?
    let client: String?
    let status: String
    let machine: String?
    let machineId: String?
    let dueDate: String?
    /// Rush or not.
    ///
    /// ── THIS FIELD BROKE THE QUEUE SCREEN FOR EVERY SHOP ─────────────────
    ///
    /// It was `String?`, and the desktop has never sent a string.
    /// `lib/order-new.js` writes `priority: false` on every order it creates and
    /// `lib/order-edit.js` writes `priority: wanted !== 'normal'` — a BOOLEAN,
    /// always, with the word kept separately in `priorityLevel`. `queueJson`
    /// passes the field straight through, so both servers put a boolean on the
    /// wire.
    ///
    /// A `Codable` mismatch is not a blank field, it throws — and it throws for
    /// the whole array, so ONE order was enough to empty the queue screen. The
    /// screen this app opens on could not load a single real shop's queue.
    ///
    /// The contract check that exists to catch exactly this could not see it:
    /// `scripts/ios-contract-capture.mjs` built its fixture with
    /// `priority: 'high'`, a shape the desktop does not write, so the guard
    /// certified a contract that does not hold anywhere but in the guard. The
    /// fixture is corrected alongside this.
    ///
    /// Read leniently rather than retyped to `Bool?`, because both spellings are
    /// now loose in the world: an older book holds booleans, and nothing stops a
    /// server sending the word later. A field this app does not draw must never
    /// again be the reason a screen is empty.
    let priority: String?

    private enum CodingKeys: String, CodingKey {
        case id, project, client, status, machine, machineId, dueDate, priority
    }

    /// Spelled out because `init(from:)` above suppresses the synthesized one,
    /// and the tests build these directly.
    init(id: String, project: String?, client: String?, status: String,
         machine: String?, machineId: String?, dueDate: String?, priority: String?) {
        self.id = id; self.project = project; self.client = client; self.status = status
        self.machine = machine; self.machineId = machineId
        self.dueDate = dueDate; self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        status = try c.decode(String.self, forKey: .status)
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId)
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        priority = Self.priorityText(c, forKey: .priority)
    }

    /// The word, whichever way it arrived — and nil rather than a throw for
    /// anything else, because no screen draws this and none should fail for it.
    private static func priorityText(_ c: KeyedDecodingContainer<CodingKeys>,
                                     forKey key: CodingKeys) -> String? {
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return text }
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: key) {
            return flag ? "high" : "normal"
        }
        return nil
    }

    var displayTitle: String {
        (project?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? id
    }

    var displayClient: String {
        client?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
    }

    /// The same order with its printer named.
    ///
    /// ── WHY AN ASSIGNED JOB READ AS "UNASSIGNED" ─────────────────────────
    ///
    /// An order carries `machineId`. It does not carry the printer's NAME:
    /// `lib/order-new.js` writes `machineId` and nothing else, and `queueJson`
    /// passes `machine` straight through — so for every job a shop assigned at
    /// the desk, the phone received `machine: null` and drew the row without a
    /// printer, and the detail sheet printed "Unassigned".
    ///
    /// The one exception made it look like a display quirk rather than a gap:
    /// when the PHONE assigns a machine, `lib/lan-server.js` looks the name up
    /// and writes both fields. So the same job read as unassigned until somebody
    /// reassigned it from the phone, and then named itself correctly.
    ///
    /// The id was always there and so was the machine list. This joins them.
    func namingMachine(from machines: [MachineInfo]) -> QueueOrder {
        // A name already on the order wins: it is what the desktop recorded at
        // assignment time, and a machine since renamed should not silently
        // rewrite the history of a job.
        if let machine, !machine.isEmpty { return self }
        guard let machineId, !machineId.isEmpty,
              let named = machines.first(where: { $0.id == machineId })?.name,
              !named.isEmpty else { return self }
        return QueueOrder(id: id, project: project, client: client, status: status,
                          machine: named, machineId: machineId,
                          dueDate: dueDate, priority: priority)
    }
}

/// How much of a collection this phone is carrying, when it carries only part.
///
/// A list that simply stops is a shop concluding it has done two hundred jobs.
struct HeldWindow: Equatable, Sendable {
    let sent: Int
    let available: Int
}

struct MachineInfo: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let type: String?
    let status: String?
    /// Whether this machine can be asked what it is doing right now.
    ///
    /// ── IT IS DERIVED, AND THE BOOK DOES NOT CARRY IT ────────────────────
    ///
    /// `lib/lan-server.js` computes this on the way out:
    /// `!!(m.printerApi?.type && m.printerApi.type !== 'none')`. A stored
    /// machine has no such field — it has the `printerApi` object the answer is
    /// derived from.
    ///
    /// That stopped mattering the moment the screens started reading the book
    /// instead of the wire: a raw record decoded to `nil`, `MachinesView` read
    /// that as false, and every machine in a shop — including the ones with a
    /// printer connected — was labelled "No live connection".
    ///
    /// The shop's sample book could not show it: not one of its five machines
    /// has a `printerApi` configured, so both paths agreed on false and the gap
    /// was invisible to a fixture. It takes a shop with a printer plugged in.
    ///
    /// So the rule is applied here, where both paths pass: the wire's boolean
    /// when it is sent, derived from `printerApi` when it is not.
    var hasPrinterApi: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, status, hasPrinterApi, printerApi
    }

    private struct PrinterApi: Decodable { let type: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        if let sent = try c.decodeIfPresent(Bool.self, forKey: .hasPrinterApi) {
            hasPrinterApi = sent
        } else if let api = try? c.decode(PrinterApi.self, forKey: .printerApi) {
            // `lib/lan-server.js`'s rule, and "none" is a configured absence
            // rather than a connection.
            let kind = api.type
            hasPrinterApi = (kind != nil && !kind!.isEmpty && kind != "none")
        } else {
            hasPrinterApi = nil
        }
    }

    init(id: String, name: String?, type: String?, status: String?, hasPrinterApi: Bool?) {
        self.id = id; self.name = name; self.type = type
        self.status = status; self.hasPrinterApi = hasPrinterApi
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(hasPrinterApi, forKey: .hasPrinterApi)
    }
}

/// Real-time printer telemetry from `/api/machines/live`.
struct MachineLiveStatus: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let hasPrinterApi: Bool
    let state: String?
    let progress: Int?          // 0–100
    let filename: String?
    let timeRemaining: Int?     // seconds remaining
    let tempNozzle: Int?
    let tempBed: Int?
    let error: String?
    /// When the Mac last heard from the printer.
    ///
    /// ── TWO SPELLINGS, ONE FIELD ─────────────────────────────────────────
    ///
    /// The LAN routes send an ISO string; Khayt Cloud's printer snapshot
    /// (`docs/api-contract.md`, "Live channel & live printers") sends epoch
    /// MILLISECONDS. A strict `String?` would throw on the number — and a
    /// Codable mismatch throws for the whole array, so one field would empty
    /// every printer on the screen. It is read leniently and kept as text.
    let lastUpdated: String?
    let apiType: String?

    init(id: String, name: String?, hasPrinterApi: Bool, state: String?, progress: Int?, filename: String?,
         timeRemaining: Int?, tempNozzle: Int?, tempBed: Int?, error: String?, lastUpdated: String?,
         apiType: String?) {
        self.id = id; self.name = name; self.hasPrinterApi = hasPrinterApi; self.state = state
        self.progress = progress; self.filename = filename; self.timeRemaining = timeRemaining
        self.tempNozzle = tempNozzle; self.tempBed = tempBed; self.error = error
        self.lastUpdated = lastUpdated; self.apiType = apiType
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hasPrinterApi, state, progress, filename, timeRemaining, tempNozzle, tempBed, error,
             lastUpdated, apiType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        // "Treat a missing field as null" — the cloud contract's rule, and a
        // harmless one for the LAN routes, which always send it.
        hasPrinterApi = (try? c.decodeIfPresent(Bool.self, forKey: .hasPrinterApi)) ?? false
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        func int(_ key: CodingKeys) -> Int? {
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d.rounded()) }
            return nil
        }
        progress = int(.progress)
        filename = try? c.decodeIfPresent(String.self, forKey: .filename)
        timeRemaining = int(.timeRemaining)
        tempNozzle = int(.tempNozzle)
        tempBed = int(.tempBed)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        if let text = try? c.decodeIfPresent(String.self, forKey: .lastUpdated) {
            lastUpdated = text
        } else if let ms = try? c.decodeIfPresent(Double.self, forKey: .lastUpdated) {
            lastUpdated = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000))
        } else {
            lastUpdated = nil
        }
        apiType = try? c.decodeIfPresent(String.self, forKey: .apiType)
    }

    var displayName: String { name ?? id }

    var isPrinting: Bool { (state ?? "").lowercased().contains("print") }
    var hasError: Bool { !(error ?? "").isEmpty }
    var isOnline: Bool { hasPrinterApi && (state != nil || hasError) }

    /// ETA formatted like the desktop: "2h 14m" / "45m".
    var etaText: String? {
        guard let secs = timeRemaining, secs > 0 else { return nil }
        let mins = Int((Double(secs) / 60).rounded())
        if mins < 1 { return "<1m" }
        return mins > 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    }

    var tempText: String? {
        guard tempNozzle != nil || tempBed != nil else { return nil }
        let n = tempNozzle.map { "\($0)°" } ?? "?"
        let b = tempBed.map { "\($0)°" } ?? "?"
        return "\(n) / \(b)"
    }
}

struct Client: Codable, Identifiable, Sendable {
    let id: String
    /// The name this reader should see, already resolved.
    ///
    /// `/api/clients` sends it — `KhaytContentLanguages.read(c, 'name', …)`
    /// against the shop's own content languages — and this app ignored it,
    /// reading `nameEn`/`nameAr` instead. The server compensated by stuffing
    /// the resolved name into `nameEn` when a shop wrote neither, which is why
    /// nobody noticed.
    ///
    /// Reading the book gets no such help: the record holds whatever the shop
    /// writes in, `nameTr` included, and neither of the two keys this app knew
    /// about. `displayName` then fell through to the customer's id, so a
    /// Turkish shop's client list read CLI-8A5045 down the page.
    var name: String?
    let nameEn: String?
    let nameAr: String?
    let phone: String?
    let email: String?

    var displayName: String {
        // The resolved name first: it is the shop's own answer to "what is this
        // customer called", in whichever language the shop keeps its books.
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let en = nameEn?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ar = nameAr?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let en, !en.isEmpty { return en }
        if let ar, !ar.isEmpty { return ar }
        return id
    }

    var secondaryName: String? {
        let en = nameEn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ar = nameAr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!en.isEmpty && !ar.isEmpty) ? ar : nil
    }

    /// Digits-only phone for tel:/wa.me links (keeps a leading +).
    var dialNumber: String? {
        guard let phone, !phone.isEmpty else { return nil }
        let allowed = phone.filter { $0.isNumber || $0 == "+" }
        return allowed.isEmpty ? nil : allowed
    }

    var whatsappNumber: String? {
        dialNumber.map { $0.hasPrefix("+") ? String($0.dropFirst()) : $0 }
    }
}

/// Draft for creating an order or quote via POST /api/orders.
struct NewOrderDraft {
    var project = ""
    var client = ""
    var material = ""
    var price = ""
    var dueDate = ""          // yyyy-MM-dd, empty = none
    var machineId: String?
    var isQuote = false
}

/// Inbound job request from `/api/waiting-list` (the intake funnel).
struct WaitingListItem: Codable, Identifiable, Sendable {
    let id: String
    let project: String?
    let clientName: String?
    let notes: String?
    let email: String?
    let phone: String?
    let material: String?
    let priority: String?
    let status: String?
    let estValue: Double?
    let reminderDate: String?
    let source: String?
    let submittedAt: String?

    var displayTitle: String {
        let p = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (p?.isEmpty == false) ? p! : "Request \(id)"
    }
    var displayClient: String {
        clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
    }
    var dialNumber: String? {
        guard let phone, !phone.isEmpty else { return nil }
        let allowed = phone.filter { $0.isNumber || $0 == "+" }
        return allowed.isEmpty ? nil : allowed
    }
}

struct InventorySpool: Codable, Identifiable, Sendable {
    let id: String
    var material: String?
    var brand: String?
    var color: String?
    var weight: Double?
    var remaining: Double?
    var cost: Double?
    var purchasedAt: String?
    var addedAt: String?
    var materialType: String?
    var lot: String?
    var sku: String?
    /// The product barcode off the box, when the roll was booked in by one.
    var barcode: String?
    var printTemp: Int?
    var bedTemp: Int?
    /// What the spool held when it arrived, which is NOT `weight`.
    ///
    /// The store calls the full spool `spoolWeight` and calls what is left on it
    /// `weight` — `renderer/inventory.js` divides cost by `spoolWeight` for a
    /// price per kilo, and subtracts prints from `weight`. The wire has its own
    /// pair of names for the same two facts, `weightTotal` and
    /// `weightRemaining`, so both spellings are read here.
    var initialWeight: Double?

    enum CodingKeys: String, CodingKey {
        case id, material, brand, color, weight, remaining, cost, purchasedAt, addedAt
        case materialType, lot, sku, barcode, printTemp, bedTemp
        case weightRemaining, weightTotal, spoolWeight
    }

    /// What is left on the spool.
    ///
    /// ── THE DESKTOP'S RULE, IN ONE PLACE ─────────────────────────────────
    ///
    /// `renderer/inventory.js` totals a shop's filament with
    /// `(+spool.remaining || +spool.weight || 0)` — so a record with no
    /// `remaining` is not a spool of unknown fullness, it is a spool whose
    /// remaining grams are in `weight`. Every shop's book written by the
    /// desktop's own form is that shape: `weight: 860, spoolWeight: 1000`.
    ///
    /// Two screens had this fallback written out by hand. A third would have
    /// forgotten it, and the symptom is a blank where a number belongs.
    var remainingGrams: Double? { remaining ?? weight }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        material = try c.decodeIfPresent(String.self, forKey: .material)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        purchasedAt = try c.decodeIfPresent(String.self, forKey: .purchasedAt)
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        materialType = try c.decodeIfPresent(String.self, forKey: .materialType)
        lot = try c.decodeIfPresent(String.self, forKey: .lot)
        sku = try c.decodeIfPresent(String.self, forKey: .sku)
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode)
        printTemp = try c.decodeIfPresent(Int.self, forKey: .printTemp)
        bedTemp = try c.decodeIfPresent(Int.self, forKey: .bedTemp)
        remaining = try c.decodeIfPresent(Double.self, forKey: .remaining)
            ?? c.decodeIfPresent(Double.self, forKey: .weightRemaining)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight)
            ?? c.decodeIfPresent(Double.self, forKey: .weightTotal)
        initialWeight = try c.decodeIfPresent(Double.self, forKey: .weightTotal)
            ?? c.decodeIfPresent(Double.self, forKey: .spoolWeight)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(material, forKey: .material)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(weight, forKey: .weight)
        try c.encodeIfPresent(remaining, forKey: .remaining)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encodeIfPresent(purchasedAt, forKey: .purchasedAt)
        try c.encodeIfPresent(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(materialType, forKey: .materialType)
        try c.encodeIfPresent(lot, forKey: .lot)
        try c.encodeIfPresent(sku, forKey: .sku)
        try c.encodeIfPresent(barcode, forKey: .barcode)
        try c.encodeIfPresent(printTemp, forKey: .printTemp)
        try c.encodeIfPresent(bedTemp, forKey: .bedTemp)
    }

    var displayLabel: String {
        // Drop the color when it's a raw hex code (shown as a swatch instead);
        // keep human-readable color names ("Galaxy Black").
        let trimmedColor = color?.trimmingCharacters(in: .whitespacesAndNewlines)
        let colorName = (trimmedColor?.isEmpty == false && trimmedColor?.hasPrefix("#") == false)
            ? trimmedColor : nil
        let parts = [brand, material, colorName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? id : parts.joined(separator: " · ")
    }

    /// Hex (`#rrggbb`) color of the spool, if stored as a hex string.
    var colorHex: String? {
        guard let c = color?.trimmingCharacters(in: .whitespacesAndNewlines),
              c.hasPrefix("#"), c.count == 7 else { return nil }
        return c
    }

    var isLowStock: Bool {
        let grams = remaining ?? weight ?? 0
        return grams > 0 && grams <= 200
    }

    var hasOptionalMeta: Bool {
        !(sku ?? "").isEmpty || !(lot ?? "").isEmpty || printTemp != nil || bedTemp != nil
    }
}

struct OrderLogEntry: Codable, Identifiable, Sendable {
    let id: String
    let project: String?
    let client: String?
    let status: String
    let material: String?
    let price: Double?
    let dueDate: String?
    let date: String?
    let paymentStatus: String?

    var displayTitle: String {
        (project?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? id
    }

    var displayClient: String {
        client?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
    }
}

struct NFCFilamentTag: Sendable {
    let standard: String
    let manufacturer: String?
    let material: String?
    let colorName: String?
    let hex: String?
    let weight: Int?
    let printTemp: Int?
    let bedTemp: Int?
    let sku: String?
    let lot: String?

    var materialLabel: String {
        [manufacturer, material, colorName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
    }
}

enum OrderStatus: String, CaseIterable, Hashable, Sendable {
    // `quote` and `delivered` are written by the desktop (renderer/analytics.js)
    // and arrive here through /api/orders. They were missing, so every use site
    // fell back to `status.capitalized` — which meant an Arabic shop read
    // "Quote" and "Delivered" in English. Nothing crashed; it just quietly
    // stopped being translated.
    //
    // `shipped` joined the desktop's list later and this enum did not follow,
    // so the same thing happened a third time. The contract check that exists
    // to catch exactly this could not: it reads the desktop's list out of
    // `renderer/analytics.js`, but its workflow only ran on changes to `ios/**`,
    // `lib/lan-server.js` and `scripts/ios-contract-*` — never on the file it
    // takes its truth from. The path filter is fixed alongside this.
    case quote, pending, printing, post, qc, completed, delivered, shipped, on_hold

    var label: String {
        switch self {
        case .quote: return "Quote"
        case .pending: return "Pending"
        case .printing: return "Printing"
        case .post: return "Post-processing"
        case .qc: return "QC"
        case .completed: return "Completed"
        case .delivered: return "Delivered"
        case .shipped: return "Shipped"
        case .on_hold: return "On hold"
        }
    }

    /// Statuses the phone may assign. Deliberately not `allCases`: the companion
    /// is a shop-floor tool, and knowing how to *display* a quote is not the same
    /// as being allowed to move a live order back into one. Adding `quote`,
    /// `delivered` or `shipped` above must not silently widen what the phone
    /// can write — handing a job over is a desktop action with a date stamp
    /// behind it, not a column the phone drags a card into.
    static let assignable: [OrderStatus] = [.pending, .printing, .post, .qc, .on_hold]

    var nextInQueue: OrderStatus? {
        switch self {
        case .pending: return .printing
        case .printing: return .post
        case .post: return .qc
        case .qc: return .completed
        default: return nil
        }
    }
}

struct APIErrorResponse: Codable, Sendable {
    let error: String?
}

/**
 * What the desktop says a part costs, and what to charge for it.
 *
 * Every number here is computed on the desktop — `lib/calculator-cost.js`
 * for the cost, `lib/pricing.js` for the price — and none of it is recomputed on
 * the phone. That is the whole point: a quote given standing next to a customer
 * has to be the same number as the one on the desk, and the only way to
 * guarantee that is to have one implementation rather than two that agree today.
 */
struct QuoteResult: Codable, Sendable {
    struct Breakdown: Codable, Sendable {
        let material: Double
        let machine: Double
        let labor: Double
        let buffer: Double
    }
    struct Price: Codable, Sendable {
        let beforeDiscount: Double
        let discount: Double
        let subtotal: Double
        let rushFee: Double
        let shipping: Double
        let extras: Double
        let total: Double
    }
    struct Tier: Codable, Sendable {
        let minQty: Int
        let pricePerUnit: Double
    }

    let qty: Int
    let unitCost: Double
    let totalCost: Double
    let breakdown: Breakdown
    let price: Price
    /// Present only when the quantity has reached a configured tier.
    let priceTier: Tier?
    /// The shop's currency, so the phone never has to guess one.
    let currency: String?
}

/// What the phone sends to be costed. Mirrors the fields the calculator screen
/// collects; anything omitted is treated as zero by the desktop.
struct QuoteRequest: Codable, Sendable {
    var printWeight: Double
    var printTime: Double
    var qty: Int
    var margin: Double
    var spoolCost: Double
    var spoolWeight: Double
    var laborRate: Double
    var prepTime: Double
    var postTime: Double
    var rush: Bool
}

/**
 * A failed print, logged at the machine.
 *
 * No `date` field on purpose: the desktop stamps it with the shop's own calendar
 * day. A phone that has travelled, or is simply set to another timezone, would
 * otherwise file a failure under the wrong day's waste — and waste-by-day is the
 * report this record exists to feed.
 */
struct WasteEntry: Codable, Sendable {
    var material: String
    var failureType: String
    var weight: Double
    var cost: Double
    var reason: String
    var notes: String
    var machineId: String?
    /// Opt-in, mirroring the desktop form: the shop may have already deducted
    /// these grams, or be logging stock that is not theirs.
    var deduct: Bool
}

/**
 * An expense captured on the phone, receipt and all.
 *
 * No `date`: the desktop stamps the shop's calendar day, for the same reason
 * WasteEntry carries none. The receipt travels as base64 — the desktop decides
 * what it is from its own first bytes and names the file itself, so nothing
 * here can choose what lands on that disk.
 */
struct ExpenseDraft: Codable, Sendable {
    var amount: Double
    var category: String
    var note: String
    var receiptBase64: String?
}

/// What it says to a person is in `KhaytAPIError+Words.swift`, not here: this
/// file is compiled ON ITS OWN by `scripts/ios-contract-decode.swift` against
/// live server responses, and anything it reaches for outside Foundation —
/// `L10n`, say — breaks that check. `LocalizationCompletenessTests` holds it.
enum KhaytAPIError: Error, Sendable {
    case notConfigured
    case invalidURL
    case unauthorized
    case server(String)
    case transport(Error)
}
