import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Partial delivery and the spool switch on a job's parts — the desktop's
/// `openPartialDeliveryModal` and `openSpoolSwitchModal`, written field for
/// field as they write them.
@MainActor
struct PartTrackingTests {

    static func job(parts: Int, status: String = "printing") -> [String: JSONValue] {
        [
            "id": .string("J1"), "project": .string("Lantern"), "status": .string(status),
            "parts": .array((0..<parts).map { i in
                .object(["name": .string("P\(i)"), "material": .string("PLA"),
                         "filamentId": .string("S1"), "printWeight": .number(100)])
            }),
        ]
    }

    static func spool(weight: Double = 500, lot: String? = " L-7 ", poId: String? = "PO-3",
                      history: Int = 0) -> [String: JSONValue] {
        var s: [String: JSONValue] = ["id": .string("S2"), "material": .string("PLA"), "weight": .number(weight)]
        if let lot { s["lot"] = .string(lot) }
        if let poId { s["poId"] = .string(poId) }
        if history > 0 {
            s["usageHistory"] = .array((0..<history).map { .object(["orderId": .string("OLD\($0)"), "weightUsed": .number(1)]) })
        }
        return s
    }

    static func part(_ record: [String: JSONValue], _ i: Int) -> [String: JSONValue] {
        guard case .array(let parts)? = record["parts"], case .object(let p) = parts[i] else { return [:] }
        return p
    }

    // MARK: - Partial delivery

    @Test("ticked parts read delivered: true and unticked ones lose the key — never false")
    func deliveredIsTrueOrAbsent() {
        var record = Self.job(parts: 3)
        // A part the desktop once wrote `false` on: unticked, the key goes.
        if case .array(var parts)? = record["parts"], case .object(var p) = parts[2] {
            p["delivered"] = .bool(false); parts[2] = .object(p); record["parts"] = .array(parts)
        }
        #expect(Shop.applyPartsDelivered(&record, delivered: [true, false, false]))
        #expect(Self.part(record, 0)["delivered"] == .bool(true))
        #expect(Self.part(record, 1)["delivered"] == nil)
        #expect(Self.part(record, 2)["delivered"] == nil, "false was left in the book")
        // Untick again: back to absent, nothing else on the part touched.
        #expect(Shop.applyPartsDelivered(&record, delivered: [false, false, false]))
        #expect(Self.part(record, 0)["delivered"] == nil)
        #expect(Self.part(record, 0)["printWeight"] == .number(100))
    }

    @Test("a job whose parts changed since the sheet opened is refused, untouched")
    func deliveredRefusesAnotherList() {
        var record = Self.job(parts: 2)
        let before = record
        #expect(!Shop.applyPartsDelivered(&record, delivered: [true, true, true]))
        #expect(record == before)
    }

    @Test("the book's flag and switches reach the part, and the count reads them")
    func partDecodes() throws {
        let json = #"{"id":"J","status":"printing","parts":[{"name":"A","delivered":true,"additionalSpools":[{"spoolId":"S2","weight":40}]},{"name":"B"},{"name":"C","delivered":"x","additionalSpools":"x"}]}"#
        let order = try JSONDecoder().decode(Order.self, from: Data(json.utf8))
        #expect(order.parts[0].delivered && !order.parts[1].delivered && !order.parts[2].delivered)
        #expect(order.parts[0].additionalSpools.first?.spoolId == "S2")
        #expect(order.parts[0].additionalSpools.first?.weight == 40)
        #expect(order.parts[2].additionalSpools.isEmpty, "a malformed list is no list, and the job still reads")
        #expect(Shop.partsDelivered(order) == 1)
        #expect(Shop.offersPartialDelivery(order) && Shop.offersSpoolSwitch(order))
        let done = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"J","status":"completed","parts":[{"name":"A"},{"name":"B"}]}"#.utf8))
        #expect(!Shop.offersPartialDelivery(done) && !Shop.offersSpoolSwitch(done), "offered on a finished job")
        let single = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"J","status":"printing","parts":[{"name":"A"}]}"#.utf8))
        #expect(!Shop.offersPartialDelivery(single), "one part has nothing to deliver partially")
    }

    // MARK: - Spool switch

    @Test("the switch writes the part's list, the spool's grams and its usage line as the desktop does")
    func spoolSwitchRecord() {
        var job = Self.job(parts: 2)
        var spool = Self.spool(weight: 500)
        let stamp: [String: JSONValue] = ["lot": .string("L-7"), "poId": .string("PO-3")]
        #expect(Shop.applySpoolSwitch(order: &job, spool: &spool, partIndex: 1, partCount: 2,
                                      grams: 42.5, today: "2026-11-07", lotStamp: stamp))
        #expect(Self.part(job, 1)["additionalSpools"]
                == .array([.object(["spoolId": .string("S2"), "weight": .number(42.5)])]))
        #expect(Self.part(job, 0)["additionalSpools"] == nil, "the other part was touched")
        #expect(spool["weight"] == .number(457.5))
        guard case .array(let history)? = spool["usageHistory"] else { Issue.record("no history"); return }
        #expect(history.first == .object([
            "orderId": .string("J1"), "project": .string("Lantern"), "weightUsed": .number(42.5),
            "date": .string("2026-11-07"), "lot": .string("L-7"), "poId": .string("PO-3"),
        ]))
        // A second switch on the same part appends, and the newest line is first.
        #expect(Shop.applySpoolSwitch(order: &job, spool: &spool, partIndex: 1, partCount: 2,
                                      grams: 10, today: "2026-11-08", lotStamp: [:]))
        guard case .array(let extra)? = Self.part(job, 1)["additionalSpools"] else { return }
        #expect(extra.count == 2)
        guard case .array(let again)? = spool["usageHistory"], case .object(let top)? = again.first else { return }
        #expect(top["date"] == .string("2026-11-08") && top["lot"] == nil)
    }

    @Test("the spool is floored at nothing and its history kept to 200 lines")
    func spoolSwitchFloorAndCap() {
        var job = Self.job(parts: 1)
        var spool = Self.spool(weight: 30, history: 200)
        #expect(Shop.applySpoolSwitch(order: &job, spool: &spool, partIndex: 0, partCount: 1,
                                      grams: 80, today: "2026-11-07", lotStamp: [:]))
        #expect(spool["weight"] == .number(0))
        guard case .array(let history)? = spool["usageHistory"] else { return }
        #expect(history.count == 200)
        guard case .object(let top)? = history.first, case .object(let last)? = history.last else { return }
        #expect(top["orderId"] == .string("J1") && last["orderId"] == .string("OLD198"))
    }

    @Test("a part that is not there, a changed list or no grams changes nothing")
    func spoolSwitchRefuses() {
        for (index, count, grams) in [(2, 2, 10.0), (0, 3, 10.0), (0, 2, 0.0), (0, 2, -5.0), (0, 2, .nan)] {
            var job = Self.job(parts: 2)
            var spool = Self.spool()
            let (j0, s0) = (job, spool)
            #expect(!Shop.applySpoolSwitch(order: &job, spool: &spool, partIndex: index, partCount: count,
                                           grams: grams, today: "2026-11-07", lotStamp: [:]))
            #expect(job == j0 && spool == s0)
        }
    }

    @Test("the lot stamp is the shared rule's: trimmed, and left off when blank")
    func lotStampIsTheRules() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.lotStamp(.object(Self.spool())) == ["lot": .string("L-7"), "poId": .string("PO-3")])
        #expect(try await engine.lotStamp(.object(Self.spool(lot: "  ", poId: nil))) == [:])
    }

    @Test("written to a book on disk in one swap, and one undo puts both back")
    func spoolSwitchWriteAndUndo() async throws {
        let engine = try KhaytEngine()
        let book: [String: JSONValue] = ["printLog": .array([.object(Self.job(parts: 2))]),
                                         "inventory": .array([.object(Self.spool(weight: 500))])]
        let url = try MachineLifeTests.tempStore(book)
        var undo: [Shop.ChangedRecord] = []
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            undo = try await Shop.writeSpoolSwitch(into: &root, orderId: "J1", partIndex: 0, partCount: 2,
                                                   spoolId: "S2", grams: 120, today: "2026-11-07",
                                                   engine: engine, gone: "gone")
        }
        var after = try MachineLifeTests.read(url)
        let spool = try #require(MachineLifeTests.row(after, "inventory", "S2"))
        let job = try #require(MachineLifeTests.row(after, "printLog", "J1"))
        #expect(spool["weight"] == .number(380))
        #expect(spool["rev"] != nil && job["rev"] != nil, "an unstamped edit never leaves this Mac")
        #expect(Set(undo.map(\.collection)) == ["printLog", "inventory"])
        guard case .array(let history)? = spool["usageHistory"], case .object(let line)? = history.first else {
            Issue.record("no usage line"); return
        }
        #expect(line["lot"] == .string("L-7"), "the lot stamp did not reach the book")

        _ = Shop.undoing(undo, in: &after)
        let back = try #require(MachineLifeTests.row(after, "inventory", "S2"))
        let backJob = try #require(MachineLifeTests.row(after, "printLog", "J1"))
        #expect(back["weight"] == .number(500))
        #expect(back["usageHistory"] == nil)
        #expect(Self.part(backJob, 0)["additionalSpools"] == nil)
    }

    @Test("a spool or job that is gone is refused in the shop's words")
    func spoolSwitchGone() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["printLog": .array([.object(Self.job(parts: 1))]), "inventory": .array([])]
        await #expect(throws: Shop.MoveRefused.self) {
            _ = try await Shop.writeSpoolSwitch(into: &root, orderId: "J1", partIndex: 0, partCount: 1,
                                                spoolId: "S2", grams: 5, today: "2026-11-07",
                                                engine: engine, gone: "gone")
        }
    }

    // MARK: - The app

    @Test("the sample book refuses both writes")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first { $0.parts.count > 1 } ?? shop.orders.first)
        #expect(await shop.setPartsDelivered(job.id, delivered: job.parts.map { _ in true }) == false)
        #expect(await shop.addSpoolSwitch(job.id, partIndex: 0, partCount: job.parts.count,
                                          spoolId: shop.spools.first?.id ?? "S", grams: 5) == false)
    }

    @Test("the inspector offers both, and the sheets save through the shop")
    func reachable() {
        let inspector = MenuCoverageTests.source("OrderInspector.swift")
        #expect(inspector.contains("PartsDeliveredSheet(shop: shop, job: job)"))
        #expect(inspector.contains("SpoolSwitchSheet(shop: shop, job: job, target: target)"))
        #expect(inspector.contains("if Shop.offersPartialDelivery(job), shop.canMoveJobs {"))
        #expect(inspector.contains("if Shop.offersSpoolSwitch(job), shop.canSwitchSpools {"))
        #expect(inspector.contains("shop.words.callIt(\"ord.parts_delivered\""))
        let sheets = MenuCoverageTests.source("PartTrackingSheets.swift")
        #expect(sheets.contains("await shop.setPartsDelivered(job.id, delivered: asked)"))
        #expect(sheets.contains("await shop.addSpoolSwitch(job.id, partIndex: target.id,"))
        let writes = MenuCoverageTests.source("Shop+PartTracking.swift")
        #expect(writes.contains("guard permitted(\"inventory\", \"edit\"), permitted(\"orders\", \"edit\") else { return false }"))
        #expect(writes.contains("registerMoveUndo(undo, named: words.callIt(\"ord.spool_switch\"))"))
    }
}
