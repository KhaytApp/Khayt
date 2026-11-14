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
        for key in ["mac.a_part", "mac.filament", "mac.grams", "mac.hours", "doc.qty"] {
            #expect(sheet.contains("header(\"\(key)\")"), "\(key) has no column header")
            #expect(sheet.contains(".accessibilityLabel(shop.words.callIt(\"\(key)\"))"), "\(key) has no accessibility label")
        }
        // The percentage is a markup on cost, and the sheet calls it that.
        #expect(sheet.contains("label(\"mac.markup\")") && !sheet.contains("label(\"mac.margin\")"))
        // The old sheet stays in the tree for a release.
        #expect(!MenuCoverageTests.source("EditJobSheet.swift").isEmpty)
    }
}
