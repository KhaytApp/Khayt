import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Loaded on this printer" and "Link a spool" on the machine sheet (Mac
/// file, page 25, frames 1 and 2). Sample data only: the printer's answer is
/// the recorded `test/fixtures/u1-filament-detect.json`.
@MainActor
@Suite(.serialized)
struct MachineHeadsTests {
    static let engine = OperatorLockTests.sharedEngine

    /// A shelf with head 1's spool (Polymaker PLA, black), a second black PLA, and a PETG.
    static func shop(spools: [JSONValue]? = nil, headSpools: JSONValue? = nil, answer: String? = LanTraysTests.recorded,
                     loaded: [KhaytEngine.LoadedSlot] = []) async -> (Shop, LanTraysTests.Asked) {
        let shelf = spools ?? [LanTraysTests.spool("S1", "PLA", "#080A0D", brand: "Polymaker", weight: 640),
                               LanTraysTests.spool("S9", "PETG", "#FFFFFF", weight: 220)]
        let (shop, asked) = LanTraysTests.shop(LanTraysTests.book(spools: shelf, headSpools: headSpools), answer: answer)
        shop.headsLoadedForTests = loaded
        await shop.words.load("en", engine: engine)
        return (shop, asked)
    }

    @Test("frame 1: each tool's three lines, from its tag, from the printer's own word, or nothing")
    func section() async throws {
        // Head 3 has no tag but the printer says red PLA is loaded there. Head 1 is linked.
        let (shop, asked) = await Self.shop(headSpools: .object(["0": .string("S1")]),
                                            loaded: [.init(slot: 2, hex: "#FF0000", material: "PLA")])
        let rows = try #require(await shop.machineHeads("U1"))
        #expect(rows.count == 4 && rows.map(\.head) == [0, 1, 2, 3])
        let words = shop.words
        func spool(_ row: KhaytEngine.HeadRow) -> [String: JSONValue]? { row.spoolId.flatMap { shop.headSpool($0) } }
        // Tool 1: tagged, linked.
        #expect(HeadWords.title(rows[0], spool: spool(rows[0]), words) == "Tool 1 · PLA SnapSpeed · Polymaker")
        #expect(HeadWords.how(rows[0], words) == "Tag read · 500 g spool")
        #expect(HeadWords.linkLine(rows[0], spool: spool(rows[0]), words) == ("Linked to Polymaker PLA · 640 g left", false))
        #expect(rows[0].hex == "#080A0D")
        // Tool 2: tagged, nothing like it on the shelf (the PETG is not PLA): amber, and a spool can be added from the tag.
        #expect(HeadWords.title(rows[1], spool: nil, words) == "Tool 2 · PLA SnapSpeed · Polymaker")
        #expect(HeadWords.linkLine(rows[1], spool: nil, words) == ("No spool in your inventory matches this tag", true))
        #expect(rows[1].match == "new" && rows[1].prefill?.material == "PLA SnapSpeed" && rows[1].prefill?.weight == 500)
        // Tool 3: no tag, set on the printer.
        #expect(HeadWords.title(rows[2], spool: nil, words) == "Tool 3 · PLA")
        #expect(HeadWords.how(rows[2], words) == "Set on the printer · no tag")
        #expect(HeadWords.linkLine(rows[2], spool: nil, words) == ("Not linked to a spool", false))
        #expect(rows[2].hex == "#FF0000" && rows[2].prefill == nil, "a spool is never made from the printer's word alone")
        // Tool 4: nothing.
        #expect(HeadWords.title(rows[3], spool: nil, words) == "Tool 4 · Nothing loaded" && HeadWords.how(rows[3], words).isEmpty)
        // One read of the printer, and only a read.
        #expect(asked.paths == ["GET /printer/objects/query?filament_detect"])
        // Weights, as the other app says them.
        #expect(HeadWords.weight(1000, words) == "1 kg" && HeadWords.weight(1500, words) == "1.5 kg" && HeadWords.weight(640, words) == "640 g")
        // Not a whole number of hundreds: grams, in the shop's own digits and grouping.
        #expect(HeadWords.weight(1250, words) == words.numeral(1250) + " g")
        #expect(HeadWords.weight(0, words).isEmpty && HeadWords.weight(nil, words).isEmpty)
        // In Arabic, Latin makers and materials keep their order: the line states its direction at its start
        // and at each dot (left to the bidi rule, "PLA · Snapmaker" is one left-to-right run, drawn backwards).
        let ar = Words(); await ar.load("ar", engine: Self.engine)
        let said = HeadWords.title(rows[0], spool: spool(rows[0]), ar)
        let mark = "\u{200F}"
        #expect(said.hasPrefix(mark) && said.contains(" \(mark)· PLA SnapSpeed \(mark)· Polymaker"), Comment(rawValue: said))
        #expect(HeadWords.joined(["PETG", "1 kg"], ar, by: ", ") == "\(mark)PETG\(mark)، 1 kg")
        #expect(HeadWords.joined(["a", "", "b"], words) == "a · b" && HeadWords.joined(["a", "b"], words, by: ", ") == "a, b")
        // A spool with nothing but an id is called by it; a spool used up reads "0 g left".
        #expect(HeadWords.spoolLabel(["id": .string("S7")]) == "S7")
        #expect(HeadWords.left(["id": .string("S7"), "weight": .number(0)], words) == "0 g")
    }

    @Test("the section shows nothing for a printer that reports neither tags nor anything loaded, and still shows what was loaded when the printer is off")
    func nothingToShow() async throws {
        let (plain, _) = await Self.shop(answer: #"{"result":{"status":{}}}"#)
        #expect(await plain.machineHeads("U1") == nil)
        #expect(await plain.machineHeads("plain") == nil)
        #expect(await plain.machineHeads("nobody") == nil)
        let (off, _) = await Self.shop(answer: nil, loaded: [.init(slot: 0, hex: "#112233", material: "PETG")])
        let rows = try #require(await off.machineHeads("U1"))
        #expect(rows[0].tag == nil && rows[0].live?.material == "PETG" && rows.count == 4)
        let (dead, _) = await Self.shop(answer: nil)
        #expect(await dead.machineHeads("U1") == nil)
    }

    @Test("frame 2: the choices in order, what starts chosen, and what each says")
    func sheet() async throws {
        // Two black PLA spools: the rule asks. Polymaker's first (the tag's own maker).
        let shelf = [LanTraysTests.spool("B", "PLA", "#080A0D", weight: 220), LanTraysTests.spool("A", "PLA", "#080A0D", brand: "Polymaker", weight: 1000)]
        let (shop, _) = await Self.shop(spools: shelf)
        let rows = try #require(await shop.machineHeads("U1"))
        let head1 = rows[0]
        #expect(head1.match == "ask" && head1.candidates == ["A", "B"])
        #expect(LinkHeadSheet.options(head1, mayAdd: true) == ["A", "B", LinkHeadSheet.new])
        #expect(LinkHeadSheet.options(head1, mayAdd: false) == ["A", "B"], "adding a spool was offered to someone who may not add stock")
        #expect(LinkHeadSheet.first(head1, adding: false, mayAdd: true) == "A")
        #expect(LinkHeadSheet.first(head1, adding: true, mayAdd: true) == LinkHeadSheet.new)
        #expect(LinkHeadSheet.first(head1, adding: true, mayAdd: false) == "A")
        #expect(LinkHeadSheet.said("A", row: head1, shop: shop) == ("Polymaker PLA · 1 kg left", "Same material and colour"))
        #expect(LinkHeadSheet.said("B", row: head1, shop: shop).title == "PLA · 220 g left")
        #expect(LinkHeadSheet.said(LinkHeadSheet.new, row: head1, shop: shop)
                == ("Add as a new spool", "PLA SnapSpeed, 500 g, filled in from the tag. You set the price."))
        #expect(HeadWords.fromTag(head1, shop.words) == "PLA · Polymaker · 500 g · 1.75 mm")
        // One strong match: it is the best match.
        let (one, _) = await Self.shop()
        let strong = try #require(await one.machineHeads("U1"))[0]
        #expect(strong.match == "link" && LinkHeadSheet.said("S1", row: strong, shop: one).sub == "Best match: same material, colour and size")
        // One strong match AND a near one (another maker's, same colour): frame 2's two lines.
        let (two, _) = await Self.shop(spools: [LanTraysTests.spool("S7", "PLA", "#080A0D", brand: "Polymaker", weight: 1000),
                                                LanTraysTests.spool("S9b", "PLA", "#080A0D", brand: "Other", weight: 220)])
        let both = try #require(await two.machineHeads("U1"))[0]
        #expect(both.match == "link" && both.candidates == ["S7", "S9b"])
        #expect(LinkHeadSheet.said("S7", row: both, shop: two) == ("Polymaker PLA · 1 kg left", "Best match: same material, colour and size"))
        #expect(LinkHeadSheet.said("S9b", row: both, shop: two) == ("Other PLA · 220 g left", "Same material and colour"))
        // Already linked to something else: that spool is first, and stays chosen.
        let (linked, _) = await Self.shop(headSpools: .object(["0": .string("S9")]))
        let now = try #require(await linked.machineHeads("U1"))[0]
        #expect(LinkHeadSheet.options(now, mayAdd: true) == ["S9", "S1", LinkHeadSheet.new] && LinkHeadSheet.first(now, adding: false, mayAdd: true) == "S9")
        // An untagged head with nothing like it: nothing to choose, and nothing can be added.
        let (bare, _) = await Self.shop(spools: [], loaded: [.init(slot: 2, hex: "#FF0000", material: "PLA")])
        let untagged = try #require(await bare.machineHeads("U1"))[2]
        #expect(LinkHeadSheet.options(untagged, mayAdd: true).isEmpty && LinkHeadSheet.first(untagged, adding: true, mayAdd: true).isEmpty)
    }

    @Test("Link writes the machine's record and no spool; Add as a new spool adds one with no price")
    func links() async throws {
        let s1 = LanTraysTests.spool("S1", "PLA", "#080A0D", brand: "Polymaker", weight: 640), s9 = LanTraysTests.spool("S9", "PETG", "#FFFFFF", weight: 220)
        let (shop, _) = await Self.shop(spools: [s1, s9])
        let rows = try #require(await shop.machineHeads("U1"))
        #expect(await shop.linkHead("U1", head: 0, choice: .link("S1"), prefill: rows[0].prefill))
        var book = try #require(shop.trayBookForTests)
        guard case .object(let machine)? = Shop.rows(book, "machines").first else { Issue.record("shape"); return }
        #expect(machine["headSpools"] == .object(["0": .string("S1")]))
        #expect(Shop.rows(book, "inventory") == [s1, s9], "a spool was changed by linking")
        // An untagged head can be linked too: the Mac's own sheet does not need a tag.
        #expect(await shop.linkHead("U1", head: 2, choice: .link("S9"), prefill: nil))
        // From the tag.
        #expect(await shop.linkHead("U1", head: 1, choice: .create, prefill: rows[1].prefill))
        book = try #require(shop.trayBookForTests)
        let shelf = Shop.rows(book, "inventory")
        #expect(shelf.count == 3 && Array(shelf.prefix(2)) == [s1, s9])
        guard case .object(let made) = shelf[2], case .string(let id)? = made["id"] else { Issue.record("shape"); return }
        #expect(made["material"] == .string("PLA SnapSpeed") && made["brand"] == .string("Polymaker") && made["weight"] == .number(500))
        guard case .object(let after)? = Shop.rows(book, "machines").first else { Issue.record("shape"); return }
        #expect(after["headSpools"] == .object(["0": .string("S1"), "1": .string(id), "2": .string("S9")]))
        // A spool that is gone, a machine that is gone: said, nothing written.
        let before = book
        #expect(!(await shop.linkHead("U1", head: 0, choice: .link("nobody"), prefill: nil)) && shop.moveProblem != nil)
        #expect(!(await shop.linkHead("nobody", head: 0, choice: .link("S1"), prefill: nil)))
        #expect(shop.trayBookForTests == before)
    }

    @Test("under the staff lock: a viewer may not link; whoever may edit a printer may; adding a spool needs the right to add stock")
    func lock() async throws {
        let shop = await OperatorLockTests.shop()
        shop.trayBookForTests = LanTraysTests.book(spools: [LanTraysTests.spool("S1", "PLA", "#080A0D")])
        let before = try #require(shop.trayBookForTests)
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)
        #expect(!(await shop.linkHead("U1", head: 0, choice: .link("S1"), prefill: nil)))
        #expect(!shop.mayAddSpoolFromTag && shop.trayBookForTests == before)
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        #expect(shop.mayAddSpoolFromTag)
        #expect(await shop.linkHead("U1", head: 0, choice: .link("S1"), prefill: nil))
    }

    @Test("the section is on the machine sheet for a Moonraker printer, and its buttons go through the shop")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let sheet = try String(contentsOf: app.appending(path: "MachineSheet.swift"), encoding: .utf8)
        #expect(sheet.contains(#"if let existing, existing.printerApi?.type == "moonraker" {"#) && sheet.contains("MachineHeadsSection(shop: shop, machineId: existing.id)"))
        let mine = try String(contentsOf: app.appending(path: "MachineHeads.swift"), encoding: .utf8)
        #expect(mine.contains("await shop.linkHead(machineId, head: row.head") && mine.contains(#"permittedPrinter("connection")"#))
        // The printer is only ever read.
        #expect(mine.components(separatedBy: "PrinterWatch.get(").count == 2)
        for never in ["PrinterControl", "gcode", "PrinterWatch.send", "printers.commanding", "httpMethod"] { #expect(!mine.contains(never), Comment(rawValue: never)) }
    }
}
