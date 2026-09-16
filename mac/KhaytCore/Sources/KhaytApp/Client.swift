import Foundation
import KhaytCore

/// A customer as the shop actually wrote them down.
///
/// The `clients` collection, which this app did not read at all: customers were
/// derived from the names denormalised onto orders, so a customer with no jobs
/// yet did not exist here, and nobody's phone number, email or VAT number was
/// ever shown.
///
/// It matters more than a missing screen. A job's `clientId` points at a row in
/// THIS collection — everything that follows a customer through the app reads
/// it — so a job created with an id invented from a name is a job with no
/// customer at all as far as the rest of Khayt is concerned.
///
/// ── THE THREE THINGS THAT FOLLOW A CUSTOMER ──────────────────────────────
///
/// A customer also carries what they have agreed to pay (`priceList`), a
/// standing order (`recurring`) and the log of calls and messages (`commLog`).
/// Until 2026-09-16 this app carried the three through a save untouched and
/// showed none of them, and its help said so. Each is kept here as the RAW
/// record plus typed accessors, so a field the other app writes and this one
/// has no opinion about — a lead time on the schedule, a `quick` flag on a
/// note — survives an edit made on a Mac.
struct Client: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let nameEn: String
    let nameAr: String
    let phone: String
    let email: String
    /// Commercial registration and VAT number, which a Saudi invoice carries.
    let cr: String
    let vat: String
    let notes: String
    let defaultDiscount: Double
    let createdAt: String?
    /// What this customer pays for particular things. See `PriceAgreement`.
    let priceList: [PriceAgreement]
    /// The standing order, if one was ever set up — enabled or not.
    let recurring: Recurring?
    /// Calls, messages and meetings, as written down. Newest is not first:
    /// the other app appends from one screen and prepends from another, so a
    /// reader sorts by `at`.
    let commLog: [CommEntry]

    private enum CodingKeys: String, CodingKey {
        case id, nameEn, nameAr, phone, email, cr, vat, notes, defaultDiscount, createdAt
        case priceList, recurring, commLog
    }

    /// Is there anything under the heading?
    ///
    /// A client written down in a hurry has a name and nothing else — the very
    /// case the initialiser below exists for — and the customer screen printed
    /// a CLIENT heading with nothing beneath it for exactly those. The name is
    /// not counted: it is the title of the pane, said above.
    var hasContactDetails: Bool {
        !phone.isEmpty || !email.isEmpty || !cr.isEmpty || !vat.isEmpty || !notes.isEmpty
    }

    /// The schedule, when it is actually running.
    var standingOrder: Recurring? { recurring.flatMap { $0.enabled ? $0 : nil } }

    /// Every field but the id is optional, because a client written down in a
    /// hurry has a name and nothing else — and a row this app refuses to read
    /// is a customer who disappears.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        nameEn = try c.decodeIfPresent(String.self, forKey: .nameEn) ?? ""
        nameAr = try c.decodeIfPresent(String.self, forKey: .nameAr) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        cr = try c.decodeIfPresent(String.self, forKey: .cr) ?? ""
        vat = try c.decodeIfPresent(String.self, forKey: .vat) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        defaultDiscount = try c.decodeIfPresent(Double.self, forKey: .defaultDiscount) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        // Lenient on shape, like everything else here: a list that is not a
        // list, or an entry that is not an object, is ignored rather than
        // refusing the customer. `try?` because a `null` where an array is
        // expected is what an older record carries, and is not an error.
        let agreements = (try? c.decodeIfPresent([JSONValue].self, forKey: .priceList)) ?? nil
        priceList = (agreements ?? []).compactMap {
            if case .object(let o) = $0 { return PriceAgreement(raw: o) } else { return nil }
        }
        if case .object(let o)? = (try? c.decodeIfPresent(JSONValue.self, forKey: .recurring)) ?? nil {
            recurring = Recurring(raw: o)
        } else {
            recurring = nil
        }
        let log = (try? c.decodeIfPresent([JSONValue].self, forKey: .commLog)) ?? nil
        commLog = (log ?? []).compactMap {
            if case .object(let o) = $0 { return CommEntry(raw: o) } else { return nil }
        }
    }

    init(id: String, nameEn: String = "", nameAr: String = "", phone: String = "",
         email: String = "", cr: String = "", vat: String = "", notes: String = "",
         defaultDiscount: Double = 0, createdAt: String? = nil,
         priceList: [PriceAgreement] = [], recurring: Recurring? = nil,
         commLog: [CommEntry] = []) {
        self.id = id; self.nameEn = nameEn; self.nameAr = nameAr
        self.phone = phone; self.email = email; self.cr = cr; self.vat = vat
        self.notes = notes; self.defaultDiscount = defaultDiscount; self.createdAt = createdAt
        self.priceList = priceList; self.recurring = recurring; self.commLog = commLog
    }

    /// The record, as `clients` holds it — what the customer sheet saves.
    ///
    /// The price list and the schedule are here because the sheet edits them.
    /// THE LOG IS NOT. A note about a phone call is written the moment it is
    /// made, through `Shop.addCommunication`, not when somebody presses Save on
    /// a sheet that may have been open for an hour; a sheet that also wrote
    /// the log would put its stale copy back over that note. `saveCustomer`
    /// carries every field this record omits through from the row on disk.
    var record: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "id": .string(id),
            "nameEn": .string(nameEn), "nameAr": .string(nameAr),
            "phone": .string(phone), "email": .string(email),
            "cr": .string(cr), "vat": .string(vat), "notes": .string(notes),
            "defaultDiscount": .number(defaultDiscount),
            "createdAt": createdAt.map(JSONValue.string) ?? .null,
            "priceList": .array(priceList.map { .object($0.raw) }),
        ]
        if let recurring { out["recurring"] = .object(recurring.raw) }
        return out
    }

    /// Whichever name is filled in, English first. The SHOP's own language
    /// order is `KhaytContentLanguages`' answer and is resolved by the engine
    /// when the screen asks; this is the fallback for a list that has not.
    var anyName: String {
        if !nameEn.isEmpty { return nameEn }
        if !nameAr.isEmpty { return nameAr }
        return id
    }

    /// The same customer with one field changed.
    ///
    /// A record is a value: editing one produces another rather than mutating
    /// this one, so the shape stays defined in exactly one place.
    func with(_ key: KeyPath<Client, String>, _ value: String) -> Client {
        Client(
            id: id,
            nameEn: key == \Client.nameEn ? value : nameEn,
            nameAr: key == \Client.nameAr ? value : nameAr,
            phone: key == \Client.phone ? value : phone,
            email: key == \Client.email ? value : email,
            cr: key == \Client.cr ? value : cr,
            vat: key == \Client.vat ? value : vat,
            notes: key == \Client.notes ? value : notes,
            defaultDiscount: defaultDiscount,
            createdAt: createdAt,
            priceList: priceList, recurring: recurring, commLog: commLog)
    }

    /// The same customer with a different price list.
    func replacing(priceList next: [PriceAgreement]) -> Client {
        Client(id: id, nameEn: nameEn, nameAr: nameAr, phone: phone, email: email, cr: cr,
               vat: vat, notes: notes, defaultDiscount: defaultDiscount, createdAt: createdAt,
               priceList: next, recurring: recurring, commLog: commLog)
    }

    /// The same customer with a different standing order.
    func replacing(recurring next: Recurring?) -> Client {
        Client(id: id, nameEn: nameEn, nameAr: nameAr, phone: phone, email: email, cr: cr,
               vat: vat, notes: notes, defaultDiscount: defaultDiscount, createdAt: createdAt,
               priceList: priceList, recurring: next, commLog: commLog)
    }
}

// MARK: - Reading a raw record

/// The two readings every raw field here needs. Not `Shop.plainString`: that is
/// on the main actor, and a record is a value that has no business there.
private func str(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}
private func num(_ v: JSONValue?) -> Double? {
    if case .number(let n)? = v { return n }
    if case .string(let s)? = v { return Double(s) }
    return nil
}
private func flag(_ v: JSONValue?) -> Bool {
    if case .bool(let b)? = v { return b }
    return false
}

/// A price this customer pays for a particular thing.
///
/// `product` is matched against a part's NAME when a job is taken for them —
/// "bracket" covers "Wall bracket, steel" — and `price` is what the part then
/// costs. The matching and where the figure lands are `lib/price-agreements.js`,
/// the one rule both apps apply; this is only the row.
struct PriceAgreement: Identifiable, Hashable, Sendable {
    /// The row as written, every field of it.
    var raw: [String: JSONValue]
    /// For the sheet's list. Not stored: the other app gives these rows no id.
    let id: UUID

    init(raw: [String: JSONValue]) { self.raw = raw; id = UUID() }
    init(product: String = "", price: Double = 0, note: String = "") {
        raw = ["product": .string(product), "price": .number(price), "note": .string(note)]
        id = UUID()
    }

    var product: String {
        get { str(raw["product"]) ?? "" }
        set { raw["product"] = .string(newValue) }
    }
    var price: Double {
        get { num(raw["price"]) ?? 0 }
        set { raw["price"] = .number(max(0, newValue)) }
    }
    var note: String {
        get { str(raw["note"]) ?? "" }
        set { raw["note"] = .string(newValue) }
    }

    /// Nothing named and nothing priced — what the other app drops on save.
    var isBlank: Bool {
        product.trimmingCharacters(in: .whitespaces).isEmpty && price <= 0
    }
}

/// A standing order: the same job again, on a schedule.
///
/// The RULE — when a cycle is due, what the job looks like — is
/// `lib/recurring-orders.js`; this is the schedule as the customer record
/// holds it. The fields the sheet edits are the five the other app's editor
/// offers; `leadDays`, `templateOrderId` and `cloneStatus` are read by the
/// rule and carried, not edited, here.
struct Recurring: Hashable, Sendable {
    var raw: [String: JSONValue]

    /// What the editor offers. The rule also understands `daily` and `yearly`.
    static let intervals = ["weekly", "biweekly", "monthly", "quarterly"]

    /// What the other app's editor starts a customer with.
    static var fresh: Recurring {
        Recurring(raw: ["enabled": .bool(false), "interval": .string("monthly"), "nextDue": .null])
    }

    init(raw: [String: JSONValue]) { self.raw = raw }

    var enabled: Bool {
        get { flag(raw["enabled"]) }
        set { raw["enabled"] = .bool(newValue) }
    }
    var interval: String {
        get { str(raw["interval"]).flatMap { $0.isEmpty ? nil : $0 } ?? "monthly" }
        set { raw["interval"] = .string(newValue) }
    }
    /// `YYYY-MM-DD`, a local day. Nil for `null`, missing or empty — the other
    /// app writes `value || null`, so all three mean "not set".
    var nextDue: String? {
        get { str(raw["nextDue"]).flatMap { $0.isEmpty ? nil : $0 } }
        set { raw["nextDue"] = newValue.map(JSONValue.string) ?? .null }
    }
    var paused: Bool {
        get { flag(raw["paused"]) }
        set { raw["paused"] = .bool(newValue) }
    }
    var endDate: String? {
        get { str(raw["endDate"]).flatMap { $0.isEmpty ? nil : $0 } }
        set { raw["endDate"] = newValue.map(JSONValue.string) ?? .null }
    }
    var leadDays: Int { Int(num(raw["leadDays"]) ?? 0) }
    var templateOrderId: String? { str(raw["templateOrderId"]).flatMap { $0.isEmpty ? nil : $0 } }

    /// `YYYY-MM-DD` ⇄ a local day, the way `localDateStr` in renderer/util.js
    /// writes it. A schedule's date is a day in the shop's own calendar, not
    /// an instant, so UTC would put a Riyadh evening on the wrong date.
    static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
    static func string(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// One line in the communications log.
///
/// TWO SHAPES ON DISK, ONE READER. The other app's customer editor writes
/// `{ id, type, note, at }` with `type` one of call/email/whatsapp/meeting/note;
/// its dashboard's quick note writes `{ channel, note, at, quick }` with
/// `channel` one of email/phone/whatsapp/in-person/other and no id. Both are
/// the same log, and a reader that knew only one would show half of it.
struct CommEntry: Identifiable, Hashable, Sendable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    /// A new line in the editor's shape — the fuller one, with an id.
    init(id: String, kind: String, note: String, at: Date) {
        raw = ["id": .string(id), "type": .string(kind), "note": .string(note),
               "at": .string(StoreWriter.iso(at))]
    }

    /// What the sheet offers, in the other app's editor's order.
    static let kinds = ["call", "email", "whatsapp", "meeting", "note"]

    /// Its own id where it has one; the quick note has none, and the moment
    /// plus the words stands in. Two identical notes in the same millisecond
    /// share one — and `ForEach` here walks positions, not ids.
    var id: String { str(raw["id"]) ?? "\(at)|\(note)" }
    var note: String { str(raw["note"]) ?? "" }
    /// ISO instant. Empty when missing, which sorts oldest.
    var at: String { str(raw["at"]) ?? "" }
    /// The day, for the screen.
    var day: String { String(at.prefix(10)) }

    /// `type` or `channel`, whichever this line carries, as one vocabulary.
    var kind: String {
        let said = str(raw["type"]) ?? str(raw["channel"]) ?? "note"
        switch said {
        case "phone": return "call"
        case "in-person": return "meeting"
        case "other": return "note"
        case "wa": return "whatsapp"
        default: return Self.kinds.contains(said) ? said : "note"
        }
    }

    /// Khayt's word for a kind. `ce.comm_wa`, not `ce.comm_whatsapp` — the
    /// catalogue's key is the short one.
    static func wordKey(for kind: String) -> String {
        kind == "whatsapp" ? "ce.comm_wa" : "ce.comm_\(kind)"
    }
    var wordKey: String { Self.wordKey(for: kind) }
}
