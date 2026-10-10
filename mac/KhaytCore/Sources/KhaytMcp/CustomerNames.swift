import Foundation
import KhaytCore

/// Whose name an assistant may read — the shop's choice, OFF unless it says so.
///
/// ── WHY THIS IS A CHOICE AT ALL ───────────────────────────────────────────
///
/// An assistant connected to `khayt-mcp` may be a cloud service, and what a
/// tool answers leaves the Mac with it. Phone numbers, emails and addresses
/// never go (`Books` does not lift them). A customer's NAME is the one personal
/// thing the books tools would carry, and whether it goes is
/// `settings.mcp.shareCustomerNames` — a boolean in the book, set from
/// Settings ▸ Assistant. Missing, or anything but `true`, is OFF.
///
/// ── WHAT AN ASSISTANT SEES WHEN IT IS OFF ─────────────────────────────────
///
/// "Customer 3": the client's position in the book's `clients` list, counted
/// from one. Never anything read off the name, so the label says nothing about
/// who it is — but it is the SAME label for the same client in every tool and
/// every call against the same book, so "the same customer owes on two orders"
/// can still be said.
///
/// A job typed with a name and no client record gets the label of the client
/// whose name it matches; failing that, a number after the last client's,
/// given in the order such names first appear in `printLog`.
///
/// Free text the shop typed — a job's project, a model's title, a library
/// folder — can hold a customer's name too ("Nouf Al-Dossari wedding favours").
/// `scrub` replaces every whole customer name found in it with that customer's
/// label. Whole names, as typed on the client record or the job: a first name
/// alone is not matched, because "Hail" or "Red Sea" would then be read as a
/// customer in every text that mentions the city or the sea.
///
/// ── WRITTEN THE WAY PEOPLE WRITE NAMES, NOT AS THE RECORD SPELLS THEM ────
///
/// A name is matched FOLDED, on both sides: ى and ي are one letter, as are ة
/// and ه, and أ إ آ and ا; tatweel and harakat are dropped; any run of spaces
/// and hyphens is one gap; case is ignored. So "نوف الدوسرى", "Nouf  Al-Dossari"
/// and "Nouf Al Dossari" are all the client "Nouf Al-Dossari"/"نوف الدوسري".
/// Arabic writes و ف ب ل ك onto the front of the next word ("لنوف الدوسري"),
/// so one of those letters may stand before a name; it is kept, in front of
/// the label. Only the matched name is replaced — every other character of the
/// text is handed on exactly as it was typed.
///
/// FAILS CLOSED: if the names cannot be made into a pattern, every non-empty
/// text is said as "Customer" rather than handed on unscrubbed.
///
/// ── AND THE CONTACT DETAILS ON RECORD, WHETHER NAMES ARE SHARED OR NOT ───
///
/// A customer's phone or email typed into free text is replaced as the book
/// holds it, whatever the setting — those are never shared. The SHAPES of
/// phones, emails, IBANs and long numbers are taken out after this by the
/// shared rule (`Outgoing`), for text that names nobody on record.
// `@unchecked`: the one non-Sendable member is the compiled pattern, which is
// built once in `init` and only ever read.
struct CustomerNames: @unchecked Sendable {
    /// `settings.mcp.shareCustomerNames` — true only when the book says so.
    let share: Bool
    /// Order id → the label of whoever it is for.
    private let byOrder: [String: String]
    /// A folded name → its label.
    private let byName: [String: String]
    /// Every known name, folded, as one pattern, longest first, for `scrub`.
    private let pattern: NSRegularExpression?
    /// True when there were names to look for and no pattern could be built
    /// from them: `scrub` then says nothing of the text.
    private let broken: Bool
    /// Phones, emails and registration numbers as the book holds them,
    /// longest first.
    private let contacts: [String]

    static let label = "Customer"
    /// What a contact detail becomes — the shared scrubber's own word.
    static let redacted = "<redacted>"

    /// Nobody's name is known: nothing is replaced, and nothing is shared.
    static let none = CustomerNames(book: [:])

    /// The setting, as both apps and this server read it.
    static func sharing(_ settings: [String: JSONValue]) -> Bool {
        guard case .object(let mcp)? = settings["mcp"],
              case .bool(let on)? = mcp["shareCustomerNames"] else { return false }
        return on
    }

    /// From the book's bytes. A book that will not parse knows no names, and
    /// shares none.
    static func read(data: Data) -> CustomerNames {
        guard let book = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return .none
        }
        return CustomerNames(book: book)
    }

    init(book: [String: JSONValue]) {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = book["settings"] { settings = s }
        share = Self.sharing(settings)

        func rows(_ key: String) -> [[String: JSONValue]] {
            guard case .array(let r)? = book[key] else { return [] }
            return r.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
        }
        func text(_ v: JSONValue?) -> String? {
            if case .string(let s)? = v, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        var contacts: Set<String> = []
        // Every phone, mobile, WhatsApp and email field on a client or a job,
        // and a client's CR and VAT numbers: as typed, and a phone as its
        // digits alone too.
        func lift(_ row: [String: JSONValue], ids: Bool) {
            for (key, value) in row {
                let k = key.lowercased()
                guard k.contains("phone") || k.contains("email") || k.contains("mobile")
                        || k.contains("whatsapp") || (ids && (k == "cr" || k == "vat")),
                      let v = text(value), v.count >= 5 else { continue }
                contacts.insert(v)
                let digits = String(String.UnicodeScalarView(
                    v.unicodeScalars.filter { ("0"..."9").contains($0) }))
                if digits.count >= 7, !v.contains("@") { contacts.insert(digits) }
            }
        }

        var byClient: [String: String] = [:]
        var byName: [String: String] = [:]
        var names: Set<String> = []
        let clients = rows("clients")
        for (i, c) in clients.enumerated() {
            let label = "\(Self.label) \(i + 1)"
            if let id = text(c["id"]) { byClient[id] = label }
            lift(c, ids: true)
            // `name`, `nameEn`, `nameAr`, … — every language the record is
            // named in, because `KhaytContentLanguages.read` may answer any.
            for (key, value) in c where key == "name" || key.hasPrefix("name") {
                guard let n = text(value) else { continue }
                names.insert(n)
                if byName[Self.key(n)] == nil { byName[Self.key(n)] = label }
            }
        }
        var next = clients.count
        var byOrder: [String: String] = [:]
        for o in rows("printLog") {
            lift(o, ids: false)
            guard let id = text(o["id"]) else { continue }
            if let cid = text(o["clientId"]), let label = byClient[cid] {
                byOrder[id] = label
                if let typed = text(o["client"]) {
                    names.insert(typed)
                    if byName[Self.key(typed)] == nil { byName[Self.key(typed)] = label }
                }
                continue
            }
            guard let typed = text(o["client"]) else { continue }
            names.insert(typed)
            if let label = byName[Self.key(typed)] { byOrder[id] = label; continue }
            next += 1
            let label = "\(Self.label) \(next)"
            byName[Self.key(typed)] = label
            byOrder[id] = label
        }
        self.byOrder = byOrder
        self.byName = byName
        self.contacts = contacts.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        // Folded, longest first, so "Nouf Al-Dossari" is replaced whole before
        // any shorter name inside it is tried. Bounded by anything that is not
        // a letter or a digit — one Arabic proclitic letter aside — so a name
        // is never matched inside a longer word.
        let folded = Set(names.map { Self.folded($0).text.trimmingCharacters(in: .whitespaces) })
            .filter { !$0.isEmpty }
        let alternatives = folded.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:))
        if alternatives.isEmpty {
            self.pattern = nil
            self.broken = false
        } else {
            let built = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}])([وفبلك])?(?:" + alternatives.joined(separator: "|")
                    + ")(?![\\p{L}\\p{N}])",
                options: [.caseInsensitive])
            self.pattern = built
            self.broken = built == nil
        }
    }

    /// The name to say for the customer on order `orderId`, which the rule
    /// named `name`. An order with no customer stays blank.
    func client(order orderId: String, named name: String) -> String {
        if share { return name }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if let label = byOrder[orderId] { return label }
        if let label = byName[Self.key(name)] { return label }
        // A name the book does not hold anywhere — never handed on as it is.
        return Self.label
    }

    /// Text the shop typed, with every whole customer name in it replaced by
    /// that customer's label (unless names are shared), and every phone,
    /// email or registration number the book holds for a customer replaced by
    /// `redacted` (always).
    func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = share ? text : names(in: text)
        for c in contacts where out.range(of: c, options: .caseInsensitive) != nil {
            out = out.replacingOccurrences(of: c, with: Self.redacted, options: .caseInsensitive)
        }
        return out
    }

    private func names(in text: String) -> String {
        if broken {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : Self.label
        }
        guard let pattern else { return text }
        let (folded, start, end) = Self.folded(text)
        let original = text as NSString
        let foldedNS = folded as NSString
        var out = ""
        var at = 0
        for m in pattern.matches(in: folded, range: NSRange(location: 0, length: foldedNS.length)) {
            let proclitic = m.range(at: 1)
            let nameFrom = proclitic.location == NSNotFound
                ? m.range.location : proclitic.location + proclitic.length
            let last = m.range.location + m.range.length - 1
            let from = start[m.range.location], nameAt = start[nameFrom], to = end[last]
            out += original.substring(with: NSRange(location: at, length: from - at))
            // The proclitic, exactly as it was typed.
            out += original.substring(with: NSRange(location: from, length: nameAt - from))
            let found = foldedNS.substring(with: NSRange(location: nameFrom, length: last + 1 - nameFrom))
            out += byName[Self.key(found)] ?? Self.label
            at = to
        }
        out += original.substring(from: at)
        return out
    }

    // MARK: - Folding

    /// A name as a dictionary key: folded, trimmed, lower-cased.
    static func key(_ s: String) -> String {
        folded(s).text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// `s` folded for matching, with — for every UTF-16 unit of the result —
    /// where in `s` it starts and ends, so a match in the folded text replaces
    /// exactly the characters it came from and nothing else.
    static func folded(_ s: String) -> (text: String, start: [Int], end: [Int]) {
        var scalars = String.UnicodeScalarView()
        var start: [Int] = [], end: [Int] = []
        var offset = 0
        var lastWasGap = false
        for u in s.unicodeScalars {
            let width = u.utf16.count
            defer { offset += width }
            let v = u.value
            // Tatweel, harakat and the dagger alef: dropped — but the unit
            // before reaches over them, so replacing a name does not leave
            // its vowel marks stranded after the label.
            if v == 0x0640 || (0x064B...0x065F).contains(v) || v == 0x0670 {
                if !end.isEmpty { end[end.count - 1] = offset + width }
                continue
            }
            // Any run of spaces and hyphens is one gap.
            let gap = CharacterSet.whitespacesAndNewlines.contains(u)
                || v == 0x2D || v == 0x2010 || v == 0x2011
            if gap {
                if lastWasGap, !end.isEmpty { end[end.count - 1] = offset + width; continue }
                lastWasGap = true
                scalars.append(" ")
                start.append(offset); end.append(offset + width)
                continue
            }
            lastWasGap = false
            let mapped: Unicode.Scalar
            switch v {
            case 0x0649: mapped = "\u{064A}"                          // ى → ي
            case 0x0629: mapped = "\u{0647}"                          // ة → ه
            case 0x0623, 0x0625, 0x0622, 0x0671: mapped = "\u{0627}"  // أ إ آ ٱ → ا
            default: mapped = u
            }
            scalars.append(mapped)
            for _ in 0..<mapped.utf16.count { start.append(offset); end.append(offset + width) }
        }
        return (String(scalars), start, end)
    }
}
