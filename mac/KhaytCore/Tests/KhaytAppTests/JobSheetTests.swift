import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// S1 B3b: the job sheet (Edit mode) — only what changed is saved, the parts
/// it hands the rule are the book's own records, and the pinned total is the
/// rule's answer, not a second sum.
@MainActor
struct JobSheetTests {

    @Test("only what the shop changed is named")
    func onlyWhatChanged() {
        var was = JobSheet.Form()
        was.name = "Bracket"; was.notes = "collects Sunday"; was.discount = "10"; was.priority = "normal"
        #expect(JobSheet.fields(opened: was, now: was).isEmpty, "opened and closed: nothing")
        var now = was
        now.name = " Bracket v2 "; now.notes = "collects Monday"; now.discount = "12.5"; now.priority = "urgent"
        now.hasDueDate = true; now.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let f = JobSheet.fields(opened: was, now: now)
        #expect(f["project"] == .string("Bracket v2"))
        #expect(f["notes"] == .string("collects Monday"))
        #expect(f["discountPct"] == .number(12.5))
        #expect(f["priorityLevel"] == .string("urgent"))
        #expect(f["dueDate"] != nil && f["price"] == nil, "an empty price box leaves the price alone")
        // A typed total; a blank name is "leave it"; a discount is held to 0–100.
        now = was; now.price = "1800"; now.name = "   "; now.discount = "250"
        let g = JobSheet.fields(opened: was, now: now)
        #expect(g["price"] == .number(1800) && g["project"] == nil && g["discountPct"] == .number(100))
        // Arabic digits and a decimal comma are numbers too.
        now = was; now.discount = "١٥"
        #expect(JobSheet.fields(opened: was, now: now)["discountPct"] == .number(15))
        #expect(JobSheet.percent(0) == "" && JobSheet.percent(10) == "10" && JobSheet.percent(12.5) == "12.5")
    }

    @Test("a part's cost has moved only when a figure it is made from did")
    func costMoved() {
        let o = EditPartSheet.Opened(name: "Body", grams: "100", hours: "2", qty: 1, spoolId: "sp-1")
        var p = JobSheet.PartDraft(id: "A", storedId: "A", name: "Body", grams: "100", hours: "2", qty: 1, spoolId: "sp-1", opened: o)
        #expect(!p.costMoved)
        p.name = "Renamed"
        #expect(!p.costMoved, "a name is a label")
        p.grams = "120"
        #expect(p.costMoved)
        #expect(JobSheet.PartDraft(id: "new-1").costMoved, "a new part is a new cost")
    }

    @Test("the parts handed to the rule: untouched ones as the book has them, a new one costed like a new job's")
    func partsForSave() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first { $0.parts.count >= 1 && $0.status == "pending" } ?? shop.orders.first { !$0.parts.isEmpty })
        let drafts: [JobSheet.PartDraft] = job.parts.map { part in
            let o = EditPartSheet.opening(part, raw: shop.rawPart(job.id, partId: part.id), spools: shop.spools)
            return .init(id: part.id, storedId: part.id, name: o.name, grams: o.grams, hours: o.hours,
                         qty: o.qty, spoolId: o.spoolId, opened: o, delivered: part.delivered)
        }
        let same = await shop.partsForSave(job.id, drafts: drafts)
        #expect(same.count == job.parts.count)
        for (row, part) in zip(same, job.parts) {
            #expect(row == shop.rawPart(job.id, partId: part.id).map(JSONValue.object), "byte for byte the stored part")
        }
        // One added: costed by the shared model, with its spool's fields.
        let spool = try #require(shop.spools.first)
        var added = JobSheet.PartDraft(id: "new-1")
        added.name = "Clip"; added.grams = "50"; added.hours = "1.5"; added.qty = 2; added.spoolId = spool.id
        let more = await shop.partsForSave(job.id, drafts: drafts + [added])
        #expect(more.count == job.parts.count + 1)
        let fresh = try #require(Shop.asObject(more[more.count - 1]))
        #expect(fresh["name"] == .string("Clip") && fresh["qty"] == .number(2))
        #expect(fresh["filamentId"] == .string(spool.id))
        #expect((Shop.plainNumber(fresh["unitCost"]) ?? 0) > 0, "costed, not saved at nothing")
        #expect(Shop.plainNumber(fresh["baseCost"]) == (Shop.plainNumber(fresh["unitCost"]) ?? 0) * 2)
        #expect(fresh["id"] == nil, "the rule gives a new part its id")
        // One taken off is simply not there.
        if drafts.count > 1 {
            #expect(await shop.partsForSave(job.id, drafts: Array(drafts.dropFirst())).count == drafts.count - 1)
        }
    }

    @Test("the pinned total and the refusal line are the rule's own answer")
    func preview() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first { $0.status == "pending" && $0.price > 0 })
        // Nothing changed: the job as it is.
        let same = try #require(await shop.previewJobSave(job.id, Shop.JobSave()))
        #expect((try? same.get()) == shop.orderRow(job.id))
        // A typed total far below what a paid job has taken is refused, in words.
        let paid = try #require(shop.orders.first { $0.paidAmount > 1 && $0.status != "quote" && $0.status != "cancelled" })
        var cut = Shop.JobSave()
        cut.fields = ["price": .number(0.5)]
        if case .failure(let refused)? = await shop.previewJobSave(paid.id, cut) {
            #expect(refused.code == "paid_exceeds_price")
            #expect(refused.sentence == shop.words.callIt("mac.parts_paid_exceeds"))
        } else {
            Issue.record("a total below what was paid previewed as fine")
        }
        // Nothing was written by asking.
        #expect(shop.orders.first { $0.id == paid.id }?.price == paid.price)
    }

    @Test("Edit Job opens the job sheet; it saves once and asks where the customer has seen the price")
    func wired() {
        #expect(MenuCoverageTests.source("ShopWindow.swift").contains("shopSheet(item: $shop.pendingEdit) { JobSheet(shop: shop, subject: $0) }"))
        let sheet = MenuCoverageTests.source("JobSheet.swift")
        #expect(sheet.contains("await shop.saveJob(subject.id, pending)"))
        #expect(sheet.contains("if lock?.askPrice == true, partsCostMoved { askingPrice = true } else { commit(keepPrice: false) }"))
        #expect(sheet.contains(".disabled(saving || !changed || refusal != nil || !shop.canMoveJobs)"))
        #expect(sheet.contains("shop.previewJobSave(subject.id, pending)"))
        // Every part column is named once, and each field says what it is.
        for key in ["pe.part", "mac.filament", "mac.grams", "mac.hours", "doc.qty"] {
            #expect(sheet.contains("header(\"\(key)\")"), "\(key) has no column header")
        }
        for key in ["mac.a_part", "mac.filament", "mac.grams", "mac.hours", "doc.qty"] {
            #expect(sheet.contains(".accessibilityLabel(shop.words.callIt(\"\(key)\"))"), "\(key) has no accessibility label")
        }
        // The percentage is a markup on cost, and the sheet calls it that.
        #expect(sheet.contains("label(\"mac.markup\")") && !sheet.contains("label(\"mac.margin\")"))
        // The old sheet stays in the tree for a release.
        #expect(!MenuCoverageTests.source("EditJobSheet.swift").isEmpty)
    }

    // MARK: - A part the book holds with no id (pre-release review, beta.37)

    /// The desktop's calculator writes parts without an id, and the real book
    /// has some. The sheet found stored parts by id alone, so such a part
    /// opened with 0 hours and, on any save that touched the parts, went back
    /// as a NEW part: costed again from nothing, its colour and model gone.
    @Test("a part with no id opens with its own figures and goes back untouched, byte for byte")
    func partWithNoId() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first { $0.parts.count == 1 })
        // Take the id off the stored part, as the calculator would have left it.
        var rows = shop.orderRows
        let at = try #require(rows.firstIndex { Shop.plainString(Shop.asObject($0)?["id"]) == job.id })
        guard case .object(var order) = rows[at], case .array(var parts)? = order["parts"],
              case .object(var part) = parts[0] else { Issue.record("the sample job has a part"); return }
        part.removeValue(forKey: "id")
        parts[0] = .object(part); order["parts"] = .array(parts); rows[at] = .object(order)
        shop.orderRows = rows
        // What `Order.Part.id` is for such a part: made up on each read.
        let madeUp = "made-up-on-this-read"
        let shown = try #require(job.parts.first)

        #expect(shop.rawPart(job.id, partId: madeUp) == nil, "a made-up id finds nothing")
        let raw = try #require(shop.rawPart(job.id, partId: madeUp, at: 0))
        #expect(raw == part)
        let o = EditPartSheet.opening(shown, raw: raw, spools: shop.spools)
        #expect(o.hours != "0" && !o.hours.isEmpty, "it opened with no print time")
        #expect(EditPartSheet.opening(shown, raw: nil, spools: shop.spools).hours != o.hours,
                "found by id alone, the sheet opened it without its print time")

        let draft = JobSheet.PartDraft(id: madeUp, storedId: madeUp, storedIndex: 0, name: o.name,
                                       grams: o.grams, hours: o.hours, qty: o.qty, spoolId: o.spoolId, opened: o)
        let same = await shop.partsForSave(job.id, drafts: [draft])
        #expect(same == [.object(part)], "untouched: exactly the stored part, still with no id")

        var renamed = draft
        renamed.name = "Renamed"
        let out = await shop.partsForSave(job.id, drafts: [renamed])
        guard case .object(let after)? = out.first else { Issue.record("one part back"); return }
        #expect(after["name"] == .string("Renamed"))
        #expect(after["id"] == nil, "the borrowed id is not written into the book")
        #expect(after["baseCost"] == part["baseCost"] && after["colour"] == part["colour"])
        #expect(after["printTime"] == part["printTime"])
    }


    /// Three parts with no id, as the calculator leaves them.
    static func idless(_ name: String, _ cost: Double, colour: String, file: String) -> JSONValue {
        .object(["name": .string(name), "material": .string("PLA"), "colour": .string(colour),
                 "printFileId": .string(file), "printWeight": .number(100), "printTime": .number(2),
                 "qty": .number(1), "unitCost": .number(cost), "baseCost": .number(cost)])
    }

    @Test("removing one of three id-less parts leaves the other two exactly as stored")
    func removalKeepsTheOthers() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try KhaytEngine()
        let stored = [Self.idless("One", 60, colour: "red", file: "PF-1"),
                      Self.idless("Two", 80, colour: "blue", file: "PF-2"),
                      Self.idless("Three", 40, colour: "green", file: "PF-3")]
        // 180 of cost at 50%: 270.
        let order = JobPartsRuleTests.with(JobPartsRuleTests.job(["price": .number(270), "printTime": .number(6)]),
                                           parts: stored)
        shop.orderRows = [order]
        // The sheet's drafts, as it opened: each part's place among the three.
        let drafts: [JobSheet.PartDraft] = try stored.enumerated().map { index, row in
            let raw = try #require(shop.rawPart("J1", partId: "read-\(index)", at: index))
            let o = EditPartSheet.Opened(name: Shop.plainString(raw["name"]) ?? "", grams: "100", hours: "2",
                                         qty: 1, spoolId: nil)
            return JobSheet.PartDraft(id: "read-\(index)", storedId: "read-\(index)", storedIndex: index,
                                      name: o.name, grams: o.grams, hours: o.hours, qty: 1, spoolId: nil, opened: o)
        }
        // Part ONE is removed in the sheet: the places are the ones it opened
        // with, not the places in the shorter list.
        let kept = await shop.partsForSave("J1", drafts: Array(drafts.dropFirst()))
        #expect(kept == [stored[1], stored[2]], "Two and Three, byte for byte: cost, colour, linked model")

        var save = Shop.JobSave()
        save.parts = kept
        let out = try await Shop.jobSaved(order, save, clients: [], settings: [:], engine: engine,
                                          refusals: Shop.jobSaveRefusalWords(shop.words), now: Date())
        guard case .array(let after)? = Shop.asObject(out)?["parts"] else { Issue.record("parts"); return }
        #expect(after == [stored[1], stored[2]])
        #expect(Shop.plainNumber(Shop.asObject(out)?["price"]) == 180, "120 of cost at the job's 50%")
    }

    // MARK: - The single-part editor, on a part with no id

    @Test("one id-less part edited from the page: found by place, the others untouched, no made-up id written")
    func singlePartEditor() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let stored = [Self.idless("One", 60, colour: "red", file: "PF-1"),
                      Self.idless("Two", 80, colour: "blue", file: "PF-2")]
        let order = JobPartsRuleTests.with(JobPartsRuleTests.job(["price": .number(210)]), parts: stored)
        let was = EditPartSheet.Opened(name: "Two", grams: "100", hours: "2", qty: 1, spoolId: nil)
        var now = was
        now.name = "Two, v2"

        let (found, lent) = Shop.lendingPartId(order, partId: "read-1", at: 1, named: was.name)
        #expect(lent)
        var edited = Shop.orderWithPartEdited(found, partId: "read-1", now, opened: was, spool: nil, costed: nil)
        edited = Shop.returningLentId(edited, partId: "read-1")
        let out = try await Shop.jobWithParts(of: edited, on: order, keepPrice: false, settings: [:], engine: engine,
                                              refusals: Shop.partsRefusalWords(shop.words))
        guard case .array(let after)? = Shop.asObject(out.order)?["parts"], after.count == 2,
              case .object(let two) = after[1] else { Issue.record("two parts back"); return }
        #expect(after[0] == stored[0], "the part not edited is exactly as stored")
        #expect(two["name"] == .string("Two, v2"))
        #expect(two["id"] != .string("read-1"), "the made-up id reached the book")
        #expect(two["colour"] == .string("blue") && two["printFileId"] == .string("PF-2") && two["baseCost"] == .number(80))
        #expect(Shop.plainNumber(Shop.asObject(out.order)?["price"]) == 210, "a rename moves no price")
    }

    @Test("nothing is lent when the place holds another part, or one with an id of its own")
    func lendingIsCareful() {
        let order = JobPartsRuleTests.with(JobPartsRuleTests.job(), parts: [
            Self.idless("One", 60, colour: "red", file: "PF-1"), JobPartsRuleTests.part("B", 40)])
        #expect(!Shop.lendingPartId(order, partId: "x", at: 0, named: "Somebody else").lent,
                "the book moved under the sheet: that place is another part now")
        #expect(!Shop.lendingPartId(order, partId: "x", at: 1, named: nil).lent, "it has an id of its own")
        #expect(!Shop.lendingPartId(order, partId: "x", at: 7, named: nil).lent)
        #expect(!Shop.lendingPartId(order, partId: "x", at: nil, named: nil).lent)
        #expect(!Shop.lendingPartId(order, partId: "B", at: 0, named: nil).lent, "a part already carries that id")
        let (found, lent) = Shop.lendingPartId(order, partId: "x", at: 0, named: "One")
        #expect(lent)
        #expect(Shop.returningLentId(found, partId: "x") == order)
    }

    @Test("the single-part save and remove refuse a part they cannot find, and look by place")
    func singlePartIsWired() {
        let money = EmptyStateTests.source("Shop.swift")
        #expect(money.components(separatedBy: "let place = partPlace(orderId, partId: partId)").count - 1 == 2)
        #expect(money.components(separatedBy: "Self.lendingPartId(order, partId: partId, at: place").count - 1 == 2)
        #expect(money.contains("if lent { edited = Self.returningLentId(edited, partId: partId) }"))
    }

}
