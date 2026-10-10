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
// `@unchecked`: the one non-Sendable member is the compiled pattern, which is
// built once in `init` and only ever read.
struct CustomerNames: @unchecked Sendable {
    /// `settings.mcp.shareCustomerNames` — true only when the book says so.
    let share: Bool
    /// Order id → the label of whoever it is for.
    private let byOrder: [String: String]
    /// A folded name → its label.
    private let byName: [String: String]
    /// Every known name as one pattern, longest first, for `scrub`.
    private let pattern: NSRegularExpression?

    static let label = "Customer"

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
        func fold(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func text(_ v: JSONValue?) -> String? {
            if case .string(let s)? = v, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        var byClient: [String: String] = [:]
        var byName: [String: String] = [:]
        var names: Set<String> = []
        let clients = rows("clients")
        for (i, c) in clients.enumerated() {
            let label = "\(Self.label) \(i + 1)"
            if let id = text(c["id"]) { byClient[id] = label }
            // `name`, `nameEn`, `nameAr`, … — every language the record is
            // named in, because `KhaytContentLanguages.read` may answer any.
            for (key, value) in c where key == "name" || key.hasPrefix("name") {
                guard let n = text(value) else { continue }
                names.insert(n)
                if byName[fold(n)] == nil { byName[fold(n)] = label }
            }
        }
        var next = clients.count
        var byOrder: [String: String] = [:]
        for o in rows("printLog") {
            guard let id = text(o["id"]) else { continue }
            if let cid = text(o["clientId"]), let label = byClient[cid] {
                byOrder[id] = label
                if let typed = text(o["client"]) {
                    names.insert(typed)
                    if byName[fold(typed)] == nil { byName[fold(typed)] = label }
                }
                continue
            }
            guard let typed = text(o["client"]) else { continue }
            names.insert(typed)
            if let label = byName[fold(typed)] { byOrder[id] = label; continue }
            next += 1
            let label = "\(Self.label) \(next)"
            byName[fold(typed)] = label
            byOrder[id] = label
        }
        self.byOrder = byOrder
        self.byName = byName
        // Longest first, so "Nouf Al-Dossari" is replaced whole before any
        // shorter name inside it is tried. Bounded by anything that is not a
        // letter or a digit, so a name is never matched inside a longer word.
        let alternatives = names.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:))
        self.pattern = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive])
    }

    /// The name to say for the customer on order `orderId`, which the rule
    /// named `name`. An order with no customer stays blank.
    func client(order orderId: String, named name: String) -> String {
        if share { return name }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if let label = byOrder[orderId] { return label }
        if let label = byName[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
            return label
        }
        // A name the book does not hold anywhere — never handed on as it is.
        return Self.label
    }

    /// Text the shop typed, with every whole customer name in it replaced by
    /// that customer's label.
    func scrub(_ text: String) -> String {
        guard !share, !text.isEmpty, let pattern else { return text }
        let whole = text as NSString
        var out = ""
        var at = 0
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            out += whole.substring(with: NSRange(location: at, length: m.range.location - at))
            let found = whole.substring(with: m.range)
            out += byName[found.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? Self.label
            at = m.range.location + m.range.length
        }
        out += whole.substring(from: at)
        return out
    }
}
