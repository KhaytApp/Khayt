import XCTest
import KhaytCore
@testable import KhaytCompanion

/// A spool tag on a head (signed frame 7a; the Mac's routes, #2697): what the
/// phone reads, what it sends, and what it says. Sample data only.
@MainActor
final class PrinterTraysTests: XCTestCase {

    /// The answer in docs/LAN_API.md, with one more row of each kind.
    private let answer = #"""
    {"ok":true,"trays":[
      {"head":1,"tag":{"vendor":"Snapmaker","manufacturer":"Polymaker","material":"PLA","sub":"SnapSpeed",
                       "colours":["#080A0D"],"weightG":500,"diameterMm":1.75,"official":true},
       "key":"k-1","match":{"kind":"link","spoolId":"INV-1"},
       "prefill":{"material":"PLA SnapSpeed","color":"#080A0D","brand":"Polymaker","weight":500},"linked":null},
      {"head":2,"tag":{"vendor":"Sample","material":"PETG","colours":["#F2A541"],"weightG":1000},
       "key":"k-2","match":{"kind":"ask","candidates":["INV-3","INV-2"]},"prefill":null,"linked":null},
      {"head":3,"tag":null,"key":"","match":{"kind":"none"},"prefill":null,"linked":null},
      {"head":4,"tag":{"material":"ABS"},"key":"k-4","match":{"kind":"new"},"prefill":null,"linked":"INV-2"},
      {"head":"five"},
      {"head":99,"tag":{"material":"PLA"},"key":"k","match":{"kind":"new"}}
    ]}
    """#

    private var rows: [PrinterTray] { PrinterTrays.rows(status: 200, body: Data(answer.utf8)) }

    private let shelf: [InventorySpool] = {
        let json = #"[{"id":"INV-1","material":"PLA","brand":"Polymaker","color":"Black"},{"id":"INV-2","material":"PETG","brand":"Sample","color":"Amber"},{"id":"INV-3","material":"PETG","color":"Orange"}]"#
        return (try? JSONDecoder().decode([InventorySpool].self, from: Data(json.utf8))) ?? []
    }()

    func testTheMacsAnswerIsRead() {
        XCTAssertEqual(shelf.count, 3, "the sample shelf decodes")
        XCTAssertEqual(rows.map(\.head), [1, 2, 3, 4], "a bad row and a head no printer has are dropped, never the list")
        XCTAssertEqual(rows[0].key, "k-1")
        XCTAssertEqual(rows[0].match, .init(kind: "link", spoolId: "INV-1"))
        XCTAssertEqual(rows[1].match.candidates, ["INV-3", "INV-2"], "best first, as the Mac sent them")
        XCTAssertNil(rows[2].tag)
        XCTAssertEqual(rows[3].linked, "INV-2")
        XCTAssertEqual(PrinterTrays.tagged(rows).map(\.head), [1, 2, 4], "a head with no tag gets no card")
    }

    func testAPrinterWithNoTagsShowsNothing() {
        XCTAssertEqual(PrinterTrays.rows(status: 200, body: Data(#"{"ok":true}"#.utf8)), [])
        XCTAssertEqual(PrinterTrays.rows(status: 404, body: Data("Not found".utf8)), [], "a computer without the route")
        XCTAssertEqual(PrinterTrays.rows(status: 403, body: Data(#"{"reason":"role-scope","required":"inventory:read"}"#.utf8)), [])
        XCTAssertEqual(PrinterTrays.rows(status: 502, body: Data(answer.utf8)), [], "only a 200 is read")
    }

    func testWhatTheCardSays() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertEqual(rows[0].tagWords, "Polymaker PLA SnapSpeed")
        XCTAssertEqual(rows[0].weightWords, "500 g")
        XCTAssertEqual(rows[1].weightWords, "1 kg")
        XCTAssertNil(rows[3].weightWords)
        XCTAssertEqual(rows[0].colourHex, "#080A0D")
        XCTAssertEqual(L10n.format("tray.title", "Snapmaker U1", 2), "Snapmaker U1 · head 2")
        XCTAssertEqual(SpoolTagCards.matchWords(rows[0], spools: shelf), "Matches your spool “Polymaker PLA Black”")
        XCTAssertEqual(SpoolTagCards.matchWords(rows[1], spools: shelf), "More than one of your spools could be this one")
        XCTAssertEqual(SpoolTagCards.matchWords(rows[3], spools: shelf), "In this head: “Sample PETG Amber”", "already recorded wins")
        let new = PrinterTray(head: 2, tag: .init(material: "PLA"), key: "k", match: .init(kind: "new"), linked: nil)
        XCTAssertEqual(SpoolTagCards.matchWords(new, spools: shelf), "No spool like it on your shelf")
        // A match to a spool the phone's shelf does not have is not named.
        let gone = PrinterTray(head: 1, tag: .init(material: "PLA"), key: "k", match: .init(kind: "link", spoolId: "INV-9"), linked: nil)
        XCTAssertEqual(SpoolTagCards.matchWords(gone, spools: shelf), "More than one of your spools could be this one")
    }

    /// The U1 run (Nov 27): the card showed no colour although the tag
    /// carries one. Turki: "dont want the color code, the actual color
    /// showing, and color name if known".
    func testTheTagsColourIsShownAndNamedNeverAsACode() throws {
        XCTAssertEqual(rows[0].colourHexes, ["#080A0D"])
        let two = PrinterTray(head: 1, tag: .init(material: "PLA", colours: ["#080A0D", "#E2DEDB", "red", "#12345"]),
                              key: "k", match: .init(kind: "new"), linked: nil)
        XCTAssertEqual(two.colourHexes, ["#080A0D", "#E2DEDB"], "one swatch per colour; anything not #RRGGBB is not drawn")
        // The name: the spool in the head first, then the one the Mac matched.
        XCTAssertEqual(SpoolTagCards.colourName(rows[0], spools: shelf), "Black", "matched to INV-1")
        XCTAssertEqual(SpoolTagCards.colourName(rows[3], spools: shelf), "Amber", "recorded in the head: INV-2")
        XCTAssertNil(SpoolTagCards.colourName(rows[1], spools: shelf), "several could be it: no name, the swatch alone")
        // A spool whose colour is stored as a code names nothing, anywhere.
        let coded = try JSONDecoder().decode([InventorySpool].self, from: Data(
            ##"[{"id":"INV-1","material":"PLA","brand":"Polymaker","color":"#080A0D"}]"##.utf8))
        XCTAssertNil(SpoolTagCards.colourName(rows[0], spools: coded))
        XCTAssertEqual(SpoolTagCards.spoolName("INV-1", in: coded), "Polymaker PLA", "no code in the match line either")
        XCTAssertNil(SpoolTagCards.colourWord("  "))
        XCTAssertEqual(SpoolTagCards.colourWord(" Galaxy Black "), "Galaxy Black")
    }

    func testTheCardDrawsTheSwatchAndNeverPrintsTheCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(contentsOf: root.appending(path: "KhaytCompanion/Views/SpoolTagCards.swift"), encoding: .utf8)
        XCTAssertTrue(card.contains("if !tray.colourHexes.isEmpty { colour(tray) }"), "every tagged colour is shown")
        XCTAssertTrue(card.contains("SpoolSwatch(hex: $0.element, size: 22)"), "the shared ringed swatch")
        XCTAssertTrue(card.contains(#".accessibilityLabel(name ?? L10n.tr("spool.form.colour"))"#), "VoiceOver hears a name, never a code")
        XCTAssertFalse(card.contains("Text(tray.colourHex"), "the code is never shown as text")
        XCTAssertFalse(card.contains("Text(hex"))
    }

    /// "Add spool from the tag" sent with no answer: the Mac may still be
    /// adding it, so Add is not offered again for that head and tag until a
    /// read shows the head linked (review of #2699).
    func testAddIsNotOfferedTwiceWithoutAnAnswer() {
        let new = PrinterTray(head: 2, tag: .init(material: "PLA"), key: "k-2", match: .init(kind: "new"), linked: nil)
        XCTAssertTrue(SpoolTagCards.mayOfferAdd(new, unanswered: []))
        XCTAssertFalse(SpoolTagCards.mayOfferAdd(new, unanswered: [SpoolTagCards.slot(new)]), "the first Add was never answered")
        XCTAssertTrue(SpoolTagCards.mayOfferAdd(new, unanswered: ["2|another-tag", "3|k-2"]), "another tag, or another head")
        let done = PrinterTray(head: 2, tag: .init(material: "PLA"), key: "k-2", match: .init(kind: "new"), linked: "INV-7")
        XCTAssertFalse(SpoolTagCards.mayOfferAdd(done, unanswered: []), "already recorded")
        XCTAssertFalse(SpoolTagCards.mayOfferAdd(rows[0], unanswered: []), "a match is linked, not added")
        // A spool the Mac recorded that this phone's shelf does not hold yet.
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertEqual(SpoolTagCards.matchWords(done, spools: shelf), "A spool is recorded in this head")
    }

    func testChooseAnotherOffersOnlyWhatTheMacProposed() {
        XCTAssertEqual(SpoolTagCards.choices(rows[1], spools: shelf).map(\.id), ["INV-3", "INV-2"],
                       "only what the Mac proposed, best first: never the rest of the phone's shelf")
        XCTAssertEqual(SpoolTagCards.choices(rows[0], spools: shelf).map(\.id), [String](), "the Mac proposed no other")
        let both = PrinterTray(head: 1, tag: .init(material: "PLA"), key: "k",
                               match: .init(kind: "link", spoolId: "INV-1", candidates: ["INV-1", "INV-2", "INV-2", "INV-9"]), linked: nil)
        XCTAssertEqual(SpoolTagCards.choices(both, spools: shelf).map(\.id), ["INV-2"],
                       "not the one Link to this spool names, each once, and none the phone cannot name")
    }

    func testTheBodyIsExactlyWhatTheRouteTakes() throws {
        func json(_ d: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: d) }
        XCTAssertEqual(try json(PrinterTrays.body(seen: "k-1", .link(spoolId: "INV-1"))),
                       .object(["seen": .string("k-1"), "spoolId": .string("INV-1")]))
        XCTAssertEqual(try json(PrinterTrays.body(seen: "k-4", .create)), .object(["seen": .string("k-4"), "create": .bool(true)]))
    }

    private func outcome(_ status: Int, _ body: String) -> PrinterTrays.Outcome {
        PrinterTrays.outcome(status: status, body: Data(body.utf8))
    }

    func testEachAnswerToALink() {
        // Two pounds: the colour's `"#` would close a one-pound raw string.
        let spool = ##""spool":{"id":"INV-1","material":"PLA","color":"#080A0D","brand":"Polymaker","weight":500}"##
        XCTAssertEqual(outcome(200, #"{"ok":true,"head":1,"spoolId":"INV-1","created":false,\#(spool)}"#), .linked(spoolId: "INV-1"))
        XCTAssertEqual(outcome(201, #"{"ok":true,"head":4,"spoolId":"INV-7","created":true,\#(spool)}"#), .created(spoolId: "INV-7"))
        XCTAssertEqual(outcome(409, #"{"ok":false,"reason":"changed","trays":[{"head":1,"tag":null,"key":"","match":{"kind":"none"}}]}"#),
                       .changed([PrinterTray(head: 1, tag: nil, key: "", match: .init(kind: "none"), linked: nil)]))
        for reason in ["bad-body", "not-found", "no-head", "no-spool", "no-trays", "tag-unusable", "read-only", "not-saved",
                       "printer-unreachable", "busy", "device-key-required"] {
            XCTAssertEqual(outcome(409, #"{"ok":false,"reason":"\#(reason)"}"#), .refused(reason))
        }
        XCTAssertEqual(outcome(403, #"{"reason":"role-scope","required":"inventory:write"}"#), .refused("role-scope"))
        XCTAssertEqual(outcome(404, "Not found"), .refused("not-offered"))
        XCTAssertEqual(outcome(500, #"{"ok":true,"spoolId":"INV-1"}"#), .refused("unreachable"), "done only on a 200 or a 201")
        XCTAssertEqual(outcome(200, #"{"ok":true}"#), .refused("unreachable"), "done names the spool")
    }

    /// The answers name the shop's spools and record a link, and anything on
    /// the Wi-Fi can answer for the Mac: one the Mac did not sign shows
    /// nothing and is never read as linked, added or refused (Mac #2697 signs both).
    func testAnUnsignedAnswerIsNotBelieved() {
        XCTAssertEqual(PrinterTrays.rows(status: 200, body: Data(answer.utf8), signed: false), [])
        XCTAssertEqual(PrinterTrays.rows(status: 200, body: Data(answer.utf8), signed: true).count, 4)
        func unsigned(_ status: Int, _ body: String) -> PrinterTrays.Outcome {
            PrinterTrays.outcome(status: status, body: Data(body.utf8), signed: false)
        }
        XCTAssertEqual(unsigned(200, ##"{"ok":true,"head":1,"spoolId":"INV-1","created":false}"##), .noAnswer, "never 'linked'")
        XCTAssertEqual(unsigned(201, ##"{"ok":true,"head":1,"spoolId":"INV-7","created":true}"##), .noAnswer, "never 'added'")
        XCTAssertEqual(unsigned(409, ##"{"ok":false,"reason":"changed","trays":[]}"##), .noAnswer)
        XCTAssertEqual(unsigned(404, ##"{"ok":false,"reason":"no-spool"}"##), .noAnswer, "a forged refusal is not believed either")
        XCTAssertEqual(unsigned(404, "Not found"), .refused("not-offered"), "a computer without the route signs nothing")
    }

    /// With one confident match the Mac sends that spool first and then the
    /// near ones (#2697): "Choose another" lists the rest, and may be empty.
    func testALinkWithNearMatchesOffersThem() {
        let link = PrinterTray(head: 1, tag: .init(material: "PLA"), key: "k",
                               match: .init(kind: "link", spoolId: "INV-1", candidates: ["INV-1", "INV-3"]), linked: nil)
        XCTAssertEqual(SpoolTagCards.choices(link, spools: shelf).map(\.id), ["INV-3"])
        let only = PrinterTray(head: 1, tag: .init(material: "PLA"), key: "k",
                               match: .init(kind: "link", spoolId: "INV-1", candidates: ["INV-1"]), linked: nil)
        XCTAssertEqual(SpoolTagCards.choices(only, spools: shelf).map(\.id), [String](), "just the one: no menu")
    }

    func testEveryRefusalHasWordsAndAnUnknownOneNeverShowsRaw() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        for reason in ["no-spool", "tag-unusable", "printer-unreachable", "read-only", "not-saved", "busy", "role-scope",
                       "device-key-required", "no-head", "no-trays", "not-found", "not-offered", "bad-body", "something-new"] {
            let words = PrinterTrays.words(reason)
            XCTAssertFalse(words.isEmpty || words.hasPrefix("tray.") || words.contains(reason), reason)
        }
        XCTAssertEqual(PrinterTrays.words("something-new"), "That did not go through. Nothing was changed.")
    }

    /// The role gate is one line (`PrinterTrays.mayLink`): the Mac's
    /// `inventory:write` today. Frame 7a's "owner/manager only" is with Turki.
    func testWhoMayLink() {
        for (role, may) in [("owner", true), ("manager", true), ("operator", true), ("viewer", false)] {
            XCTAssertEqual(PrinterTrays.mayLink(role: role), may, role)
        }
        XCTAssertTrue(PrinterTrays.asks(macInReach: true, sampleShop: false))
        XCTAssertFalse(PrinterTrays.asks(macInReach: false, sampleShop: false), "only the Mac holds the printer")
        XCTAssertFalse(PrinterTrays.asks(macInReach: true, sampleShop: true))
    }

    func testTheWordsAreInAllNineLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let en = try XCTUnwrap(NSDictionary(contentsOf: root.appending(path: "KhaytCompanion/Resources/en.lproj/Localizable.strings")) as? [String: String])
        let keys = en.keys.filter { $0.hasPrefix("tray.") }
        XCTAssertEqual(keys.count, 30)
        for lang in ["ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let url = root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys { XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang): \(key)") }
        }
    }
}
