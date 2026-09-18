import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A label for a job going out the door.
///
/// The shelf could be labelled from this app and a JOB could not, so a parcel
/// leaving the shop had to be labelled from the other one.
@MainActor
struct OrderLabelTests {

    @Test("a box labelled here scans the same as a box labelled there")
    func codeMatchesTheOtherApp() {
        // `renderer/labels.js` decides it exactly this way: the portal link
        // when the cloud is connected AND the job has a token, else the code
        // the shop's own phone reads.
        #expect(ShelfLabels.orderCode(id: "A-1", trackingToken: "tok",
                                      cloudURL: "https://khayt.example", cloudOn: true)
                == "https://khayt.example/p/tok")
        // EVERY trailing slash, not one — `replace(/\/+$/, '')`.
        #expect(ShelfLabels.orderCode(id: "A-1", trackingToken: "tok",
                                      cloudURL: "https://khayt.example///", cloudOn: true)
                == "https://khayt.example/p/tok")
        // Any missing piece falls back, rather than printing a link to nowhere.
        #expect(ShelfLabels.orderCode(id: "A-1", trackingToken: "tok",
                                      cloudURL: "https://khayt.example", cloudOn: false)
                == "KHAYT-ORDER:A-1")
        #expect(ShelfLabels.orderCode(id: "A-1", trackingToken: nil,
                                      cloudURL: "https://khayt.example", cloudOn: true)
                == "KHAYT-ORDER:A-1")
        #expect(ShelfLabels.orderCode(id: "A-1", trackingToken: "",
                                      cloudURL: "https://khayt.example", cloudOn: true)
                == "KHAYT-ORDER:A-1")
        #expect(ShelfLabels.orderCode(id: "A-1", trackingToken: "tok",
                                      cloudURL: "", cloudOn: true) == "KHAYT-ORDER:A-1")
        #expect(ShelfLabels.orderCode(id: "A-1", trackingToken: "tok",
                                      cloudURL: nil, cloudOn: true) == "KHAYT-ORDER:A-1")
    }

    @Test("the spool code and the order code cannot be confused for each other")
    func twoKindsOfCode() {
        #expect(ShelfLabels.code(for: "S-1") == "KHAYT-SPOOL:S-1")
        #expect(ShelfLabels.orderCode(id: "S-1", trackingToken: nil, cloudURL: nil,
                                      cloudOn: false) == "KHAYT-ORDER:S-1")
    }

    @Test("a label carries who, what and when")
    func entryCarriesTheThreeLines() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let row: JSONValue = .object([
            "id": .string("A-7"), "project": .string("Dragon"),
            "client": .string("Salem"), "material": .string("PLA"),
            "dueDate": .string("2026-09-30"),
        ])
        guard case .object(let entry) = ShelfLabels.entry(forOrder: row, shop: shop) else {
            Issue.record("not a label"); return
        }
        #expect(entry["title"] == .string("Dragon"))
        #expect(entry["sub"] == .string("A-7"))
        guard case .array(let lines)? = entry["lines"] else { Issue.record("no lines"); return }
        let said = lines.map { JSSemantics.text($0) }
        #expect(said.contains("Salem"))
        #expect(said.contains("PLA"))
        #expect(said.contains { $0.contains("2026-09-30") })
        // A QR is drawn, because a label a scanner cannot read is a sticker.
        #expect(entry["qr"] != nil)
    }

    @Test("a job with nothing filled in still gets a label with its own id on it")
    func degenerateRows() async throws {
        let shop = Shop()
        await shop.load(.sample)
        guard case .object(let entry) = ShelfLabels.entry(
            forOrder: .object(["id": .string("A-9")]), shop: shop) else {
            Issue.record("not a label"); return
        }
        // No project: the id is the title rather than a blank sticker.
        #expect(entry["title"] == .string("A-9"))
        guard case .array(let lines)? = entry["lines"] else { Issue.record("no lines"); return }
        #expect(lines.isEmpty, "empty fields became empty lines")
        // And a row that is not a row does not crash the sheet.
        #expect(ShelfLabels.entry(forOrder: .null, shop: shop) == .object([:]))
        #expect(ShelfLabels.entry(forOrder: .string("x"), shop: shop) == .object([:]))
    }

    @Test("the sheet is the same builder the shelf labels use")
    func sameSheetBuilder() async throws {
        // A rack labelled half from one app and half from the other is one
        // rack; the same has to be true of a shelf of parcels.
        let shop = Shop()
        await shop.load(.sample)
        let engine = try KhaytEngine()
        let row: JSONValue = .object(["id": .string("A-1"), "project": .string("Dragon")])
        let html = try await engine.labelSheet(
            [ShelfLabels.entry(forOrder: row, shop: shop)], heading: "Order labels")
        #expect(html.contains("Dragon"))
        #expect(html.contains("Order labels"))
    }

    @Test("the menu that ships can reach it")
    func wiredIn() throws {
        let menus = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Menus.swift"), encoding: .utf8)
        #expect(menus.contains("shop.askForOrderLabels("),
                "nothing can print a label for a job")
    }
}
