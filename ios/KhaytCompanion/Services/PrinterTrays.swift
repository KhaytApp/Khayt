import Foundation
import KhaytCore

/// The spool tags a printer's heads read (a Snapmaker U1), each matched
/// against the shop's spools BY THE MAC (`GET /api/printer/{id}/trays`, Mac
/// #2697; signed frame 7a). Only the Mac holds the printer: the phone asks,
/// shows what the Mac found, and sends a tap back. It never matches a tag
/// itself and never changes a spool without a tap.
struct PrinterTray: Decodable, Equatable, Identifiable, Sendable {
    struct Tag: Decodable, Equatable, Sendable {
        var vendor: String?
        var manufacturer: String?
        var material: String?
        var sub: String?
        var colours: [String]?
        var weightG: Double?
        var official: Bool?
    }

    struct Match: Decodable, Equatable, Sendable {
        /// `link` (one spool matches), `ask` (several, or only near ones),
        /// `new` (nothing like it on the shelf) or `none` (no tag).
        var kind: String
        var spoolId: String?
        var candidates: [String]?
    }

    /// Counts from one, in the printer's order.
    let head: Int
    let tag: Tag?
    /// Everything the tag says; sent back as `seen` when linking.
    let key: String
    let match: Match
    /// The spool already recorded in this head, if any.
    let linked: String?

    var id: Int { head }

    private enum CodingKeys: String, CodingKey { case head, tag, key, match, linked }

    init(head: Int, tag: Tag?, key: String, match: Match, linked: String?) {
        self.head = head; self.tag = tag; self.key = key; self.match = match; self.linked = linked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        head = try c.decode(Int.self, forKey: .head)
        tag = try? c.decodeIfPresent(Tag.self, forKey: .tag)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        match = (try? c.decodeIfPresent(Match.self, forKey: .match)) ?? Match(kind: "none")
        // The spool's id; an object with an id reads the same, should the Mac send more.
        if let id = try? c.decodeIfPresent(String.self, forKey: .linked) {
            linked = id.isEmpty ? nil : id
        } else if let o = try? c.decodeIfPresent([String: JSONValue].self, forKey: .linked), case .string(let id)? = o["id"] {
            linked = id
        } else {
            linked = nil
        }
    }

    /// "Polymaker PLA SnapSpeed": who made it and what it is, as the tag says.
    var tagWords: String? {
        guard let tag else { return nil }
        let maker = [tag.manufacturer, tag.vendor].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let parts = [maker, tag.material, tag.sub].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "1 kg" / "500 g", when the tag says a weight.
    var weightWords: String? {
        guard let g = tag?.weightG, g > 0, g.isFinite else { return nil }
        if g >= 1000, g.truncatingRemainder(dividingBy: 1000) == 0 { return L10n.format("tray.kg", Int(g / 1000)) }
        return L10n.format("tray.g", Int(g.rounded()))
    }

    /// The tag's first colour, when it is a plain `#RRGGBB`.
    var colourHex: String? { colourHexes.first }

    /// Every colour the tag names that is a plain `#RRGGBB`, in its order.
    /// Drawn as swatches only, never shown as text.
    var colourHexes: [String] {
        (tag?.colours ?? []).filter(Self.isPlainHex)
    }

    /// `#RRGGBB`, and nothing else.
    static func isPlainHex(_ s: String) -> Bool { s.count == 7 && s.hasPrefix("#") && s.dropFirst().allSatisfy(\.isHexDigit) }
}

enum PrinterTrays {
    /// What `/api/devices/self` lists in `can` when the Mac serves the routes
    /// and this phone's role may read them.
    static let capability = "trays"

    /// THE ROLE GATE for linking or adding a spool, in one line: the Mac's
    /// `inventory:write` (operator and up). Frame 7a says "owner/manager
    /// only"; Dev Hub is asking Turki which it is. To follow the frame, make
    /// this `role == "owner" || role == "manager"`. The Mac checks either way.
    static func mayLink(role: String) -> Bool { DeviceRole.allows(role, "inventory:write") }

    /// The trays are asked for only in reach of the Mac, never on the sample
    /// shop. Whether this phone may read them is the Mac's answer: a role it
    /// refuses, or a computer without the route, comes back with no rows.
    static func asks(macInReach: Bool, sampleShop: Bool) -> Bool { macInReach && !sampleShop }

    /// The rows of a `GET …/trays` answer. `{"ok":true}` with no `trays` is a
    /// printer with no tags to read: nothing to show. A row that does not
    /// decode is dropped, never the list.
    /// `signed`: the Mac signed this answer (it names the shop's spools, and
    /// anything on the Wi-Fi can answer for the Mac). Unsigned: nothing shown.
    static func rows(status: Int, body: Data, signed: Bool = true) -> [PrinterTray] {
        guard signed, status == 200 else { return [] }
        struct Answer: Decodable {
            let trays: [PrinterTray]
            private enum CodingKeys: String, CodingKey { case trays }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                trays = c.lossyList(PrinterTray.self, forKey: .trays)
            }
        }
        return ((try? JSONDecoder().decode(Answer.self, from: body))?.trays ?? []).filter { (1...16).contains($0.head) }
    }

    /// Only heads with a tag are worth a card.
    static func tagged(_ rows: [PrinterTray]) -> [PrinterTray] { rows.filter { $0.tag != nil && $0.match.kind != "none" } }

    /// The cards a printer gets: every tagged head, and every head that has a
    /// spool linked while the printer reads nothing there. That link is KEPT
    /// (a U1 clears a head's tag when the filament comes out, and one empty
    /// read can be a missed tag) and said: "not in the printer now". Whether
    /// it is said is `lib/head-spools.js shown`, the Mac's and the desktop's
    /// rule; `notInPrinter` holds the heads it said it for.
    static func shown(_ rows: [PrinterTray], notInPrinter: Set<Int>) -> [PrinterTray] {
        rows.filter { ($0.tag != nil && $0.match.kind != "none") || ($0.tag == nil && notInPrinter.contains($0.head)) }
    }

    /// Heads with a spool linked and no tag read: the ones to ask `shown` about.
    static func emptyButLinked(_ rows: [PrinterTray]) -> [PrinterTray] { rows.filter { $0.tag == nil && $0.linked != nil } }

    enum Ask: Equatable, Sendable {
        case link(spoolId: String)
        case create
    }

    /// The body: exactly `{"seen":key,"spoolId":…}` or `{"seen":key,"create":true}`.
    static func body(seen: String, _ ask: Ask) -> Data {
        var o: [String: JSONValue] = ["seen": .string(seen)]
        switch ask {
        case .link(let id): o["spoolId"] = .string(id)
        case .create: o["create"] = .bool(true)
        }
        return (try? JSONEncoder().encode(JSONValue.object(o))) ?? Data()
    }

    enum Outcome: Equatable, Sendable {
        case linked(spoolId: String)
        case created(spoolId: String)
        /// The head's tag is not the one shown; these are the rows now.
        case changed([PrinterTray])
        case refused(String)
        /// No answer at all. After a `create` the spool may have been added:
        /// the trays must be read again before anything is asked twice.
        case noAnswer
    }

    /// An answer the Mac did not sign says nothing the phone may believe:
    /// it is "no answer" (the trays are read again, nothing is re-sent). The
    /// exception is a plain 404 from a computer without the route, which
    /// signs nothing and has nothing to forge.
    static func outcome(status: Int, body: Data, signed: Bool = true) -> Outcome {
        if !signed {
            let ours = (try? JSONDecoder().decode(JSONValue.self, from: body)) != nil
            return status == 404 && !ours ? .refused("not-offered") : .noAnswer
        }
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return .refused(status == 404 ? "not-offered" : "unreachable")
        }
        if (status == 200 || status == 201), o["ok"] == .bool(true), case .string(let id)? = o["spoolId"] {
            return o["created"] == .bool(true) ? .created(spoolId: id) : .linked(spoolId: id)
        }
        var reason = "unreachable"
        if case .string(let r)? = o["reason"] { reason = r }
        if status == 409, reason == "changed" { return .changed(rows(status: 200, body: body)) }
        return .refused(reason)
    }

    /// The sentence for a refusal. A reason this build does not know gets the
    /// plain one, never the raw word.
    static func words(_ reason: String) -> String {
        let known: Set<String> = ["no-spool", "tag-unusable", "printer-unreachable", "read-only", "not-saved", "busy",
                                  "role-scope", "device-key-required", "no-head", "no-trays", "not-found", "not-offered"]
        switch reason {
        case "no-head", "no-trays", "not-found": return L10n.tr("tray.why.no-trays")
        case let r where known.contains(r): return L10n.tr("tray.why." + r)
        default: return L10n.tr("tray.why.unreachable")
        }
    }
}

extension KhaytAPIClient {
    /// The printer's tagged heads, or none (no route, no tags, no answer, or
    /// an answer the Mac did not sign).
    func printerTrays(machineId: String) async -> [PrinterTray] {
        let id = machineId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? machineId
        guard let answer = await signedLanAnswer(path: "/api/printer/\(id)/trays", method: "GET") else { return [] }
        return PrinterTrays.rows(status: answer.status, body: answer.body, signed: answer.signed)
    }

    /// Link the spool in a head, or add one from its tag. Signed by the phone;
    /// the answer is believed only when the Mac signed it.
    func setTraySpool(machineId: String, head: Int, seen: String, _ ask: PrinterTrays.Ask) async -> PrinterTrays.Outcome {
        let id = machineId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? machineId
        guard let answer = await signedLanAnswer(path: "/api/printer/\(id)/trays/\(head)/spool", method: "POST",
                                                 body: PrinterTrays.body(seen: seen, ask)) else { return .noAnswer }
        return PrinterTrays.outcome(status: answer.status, body: answer.body, signed: answer.signed)
    }
}
