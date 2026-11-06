import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The desktop's order-flow settings and tools on the Mac: the
/// post-processing checklist and its ticks, post-process presets, custom
/// order fields, saved job filters and Import CSV.
///
/// What is asserted is the record the desktop reads: its keys, its shapes,
/// and every entry the Mac did not touch left exactly as it was.
@MainActor
struct OrderFlowParityTests {

    static let settings: [String: JSONValue] = [
        "currency": .string("SAR"),
        "postChecklist": .array([
            .object(["id": .string("PCH-1"), "label": .string("Sand")]),
            .object(["id": .string("PCH-2"), "label": .string("Paint"), "fromAFutureVersion": .bool(true)]),
        ]),
        "postProcessPresets": .array([.object(["name": .string("Sanding"), "amount": .number(15)])]),
        "customFields": .array([.object(["id": .string("CF-1"), "label": .string("PO number"), "type": .string("text")])]),
        "savedFilters": .array([
            .object(["id": .string("k1"), "name": .string("Unpaid printing"), "status": .string("printing"),
                     "pay": .string("unpaid"), "tag": .string(""), "range": .string("all"),
                     "search": .string(""), "operator": .string("")]),
            .object(["id": .string("k2"), "name": .string("Lamps"), "status": .string(""),
                     "pay": .string(""), "tag": .string(""), "range": .string("all"),
                     "search": .string("lamp"), "operator": .string("")]),
        ]),
    ]

    // MARK: - Settings lists

    @Test("an add appends one entry in the desktop's shape and leaves every other key and entry alone")
    func listAdd() throws {
        let step = try #require(Shop.newPostCheck("  Prime  "))
        #expect(Shop.plainString(step["label"]) == "Prime")
        #expect(Shop.plainString(step["id"])?.hasPrefix("PCH-") == true)
        #expect(Shop.newPostCheck("   ") == nil)
        let out = Shop.changingList(Self.settings, .postChecklist, .add(step))
        guard case .array(let rows)? = out["postChecklist"], case .array(let was)? = Self.settings["postChecklist"] else {
            Issue.record("no list"); return
        }
        #expect(Array(rows.prefix(2)) == was, "the entries already there go back as they were")
        #expect(rows.last == .object(step))
        for key in Self.settings.keys where key != "postChecklist" { #expect(out[key] == Self.settings[key]) }

        let field = try #require(Shop.newCustomField("Colour"))
        #expect(Set(field.keys) == ["id", "label", "type"])
        #expect(Shop.plainString(field["type"]) == "text")
        #expect(Shop.plainString(field["id"])?.hasPrefix("CF-") == true)

        let preset = try #require(Shop.newPostPreset("Paint", amount: -4))
        #expect(preset == ["name": .string("Paint"), "amount": .number(0)])
    }

    @Test("a delete removes the entry pointed at — by place, else by content, else nothing")
    func listRemove() {
        let rows = Shop.listEntries(Self.settings, .postChecklist)
        let gone = Shop.changingList(Self.settings, .postChecklist, .remove(index: 1, record: rows[1]))
        #expect(Shop.listEntries(gone, .postChecklist) == [rows[0]])
        // The book moved: the entry is now first, not second.
        var moved = Self.settings
        moved["postChecklist"] = .array([.object(rows[1]), .object(rows[0])])
        let still = Shop.changingList(moved, .postChecklist, .remove(index: 1, record: rows[1]))
        #expect(Shop.listEntries(still, .postChecklist) == [rows[0]])
        // Already gone elsewhere: nothing changes.
        let none = Shop.changingList(gone, .postChecklist, .remove(index: 1, record: rows[1]))
        #expect(none == gone)
    }

    // MARK: - The checklist on a job

    @Test("ticking a step writes postChecks as the desktop's card does, keeping false and other steps")
    func ticking() {
        let order: JSONValue = .object(["id": .string("O1"), "status": .string("post")])
        let one = Shop.ticking(order, step: "PCH-1", done: true)
        let two = Shop.ticking(one, step: "PCH-2", done: true)
        let back = Shop.ticking(two, step: "PCH-1", done: false)
        guard case .object(let o) = back else { Issue.record("not an object"); return }
        #expect(o["postChecks"] == .object(["PCH-1": .bool(false), "PCH-2": .bool(true)]))
        #expect(Shop.postChecks(o) == ["PCH-1": false, "PCH-2": true])
        #expect(o["id"] == .string("O1"))
    }

    // MARK: - Saved filters

    @Test("a filter saved here has the desktop's eight keys, the other four filters off")
    func filterSaved() throws {
        let f = try #require(Shop.newSavedFilter(name: " Late ", stage: .printing, search: "vase",
                                                 now: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(Set(f.keys) == ["id", "name", "status", "pay", "tag", "range", "search", "operator"])
        #expect(f["name"] == .string("Late"))
        #expect(f["status"] == .string("printing"))
        #expect(f["range"] == .string("all"))
        #expect(f["pay"] == .string("") && f["tag"] == .string("") && f["operator"] == .string(""))
        #expect(f["id"] == .string(String(1_700_000_000_000, radix: 36)), "Date.now().toString(36)")
        #expect(Shop.newSavedFilter(name: "  ", stage: nil, search: "") == nil)
        #expect(Shop.filterStatus(nil) == "")
        #expect(Shop.filterStatus(.delivered) == "completed", "delivered is a stamp, not a status")
        #expect(Shop.filterStatus(.on_hold) == "on_hold")
    }

    @Test("a saved filter maps its stage and search, and says when it narrows by more")
    func filterRead() {
        guard case .array(let rows)? = Self.settings["savedFilters"] else { return }
        let filters = rows.enumerated().compactMap { i, r in Shop.asObject(r).map { Shop.SavedFilter(index: i, raw: $0) } }
        #expect(filters[0].stage == .printing)
        #expect(filters[0].narrowsMore, "pay: unpaid is the desktop's only")
        #expect(filters[1].stage == nil)
        #expect(filters[1].search == "lamp")
        #expect(!filters[1].narrowsMore)
        // Deleting one leaves the other's every field, including the ones the Mac cannot apply.
        let out = Shop.changingList(Self.settings, .savedFilters, .remove(index: 1, record: filters[1].raw))
        #expect(Shop.listEntries(out, .savedFilters) == [filters[0].raw])
    }

    // MARK: - Custom order fields in the order editor

    @Test("the order editor sends only the custom fields typed in, and the rule merges them")
    func customFields() async throws {
        let order: [String: JSONValue] = ["id": .string("O1"), "status": .string("pending"), "price": .number(100),
                                          "customData": .object(["CF-1": .string("PO-7"), "CF-old": .string("keep")])]
        let opened = OrderDetailsSheet.opening(order)
        #expect(opened.custom == ["CF-1": "PO-7", "CF-old": "keep"])
        #expect(OrderDetailsSheet.fields(opened: opened, now: opened).isEmpty, "untouched sends nothing")
        var now = opened
        now.custom["CF-1"] = "PO-8"
        now.custom["CF-2"] = "Blue"
        let fields = OrderDetailsSheet.fields(opened: opened, now: now)
        #expect(fields == ["customData": .object(["CF-1": .string("PO-8"), "CF-2": .string("Blue")])])

        let engine = try KhaytEngine()
        let out = try await engine.editOrderDetails(order: .object(order), fields: fields, now: Date(),
                                                    editId: "e1", priceId: "e2")
        guard case .object(let o) = out.order else { Issue.record("no order"); return }
        #expect(o["customData"] == .object(["CF-1": .string("PO-8"), "CF-2": .string("Blue"),
                                             "CF-old": .string("keep")]))
    }

    // MARK: - Import CSV

    @Test("Import CSV reads, maps and plans by lib/csv-import.js")
    func csvImport() async throws {
        let engine = try KhaytEngine()
        let text = "Material,Brand,Color,weightTotal\r\nPLA,Bambu,Black,750\r\npla,bambu,black,\r\n,X,Y,\r\nPETG,,Red,\r\n"
        let read = try await engine.csvRead(kind: "spools", text: text, labels: [:])
        #expect(read.headers == ["Material", "Brand", "Color", "weightTotal"])
        #expect(read.rows.count == 4)
        #expect(read.mapping["material"] == 0 && read.mapping["weightTotal"] == 3 && read.mapping["lot"] == -1)
        #expect(read.fields.first?.key == "material" && read.fields.first?.isRequired == true)

        let existing: [JSONValue] = [.object(["id": .string("S-old"), "material": .string("PETG"),
                                              "brand": .string(""), "color": .string("red")])]
        let plan = try await engine.csvPlan(kind: "spools", rows: read.rows, mapping: read.mapping,
                                            existing: existing, today: "2026-11-06",
                                            settings: ["lowStockThreshold": .number(80)], ids: ["S-a", "S-b", "S-c"])
        #expect(plan.objects.count == 3, "the row with no material is dropped")
        #expect(plan.rows.map(\.verdict) == ["new", "duplicate", "duplicate"])
        #expect(plan.imported == 1 && plan.skipped == 2)
        guard case .object(let s)? = plan.add.first else { Issue.record("nothing added"); return }
        #expect(s["id"] == .string("S-a"))
        #expect(s["weightTotal"] == .number(750) && s["weight"] == .number(750))
        #expect(s["reorderPoint"] == .number(80))
        #expect(s["diameter"] == .number(1.75))
        #expect(s["addedAt"] == .string("2026-11-06"))
        #expect(s["usageHistory"] == .array([]))
        #expect(s["lot"] == nil, "an empty lot is no key, as the desktop's undefined")

        let clients = try await engine.csvRead(kind: "clients", text: "الاسم,phone\nنورة,0500", labels: ["nameEn": "الاسم"])
        #expect(clients.mapping["nameEn"] == 0 && clients.mapping["phone"] == 1)
    }

    @Test("ids are fresh, the desktop's shape, and one per row")
    func csvIds() {
        let ids = Shop.csvIds(.products, count: 50)
        #expect(ids.count == 50 && Set(ids).count == 50)
        #expect(ids.allSatisfy { $0.hasPrefix("PROD-") })
        #expect(Shop.CsvKind.spools.collection == "inventory")
        #expect(Shop.CsvKind.clients.titleKey == "csv.import_clients")
    }
}
