import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A printer put under service or retired mid-print stops being asked — and
/// must stop being REMEMBERED too. Its last reading kept it "printing" on the
/// menu bar, the widget and the dashboard for the rest of the session, its
/// phone's Live Activity never ended, and its first poll back in service was
/// taken for the old print's end.
@MainActor
struct UnwatchedMachineTests {

    static func printing() throws -> KhaytEngine.PrinterStatus {
        try LiveActivityPushTests.status("printing")
    }

    @Test("under service or retired: the last reading, the finish memo and the plug's memory go")
    func forgotten() async throws {
        let (shop, rec) = await LiveActivityPushTests.shop(cloud: LiveActivityPushTests.connected)
        let a = try MachineLifeTests.machine(MachineLifeTests.active)
        let s = try MachineLifeTests.machine(MachineLifeTests.service)
        let r = try MachineLifeTests.machine(MachineLifeTests.retired)
        shop.machines = [a, s, r]
        let watch = shop.printers
        let status = try Self.printing()
        for id in ["M-A", "M-S", "M-R"] {
            watch.setReadingForTesting(id, .init(status: status, problem: nil, at: Date(), lastGood: status))
        }
        let engine = try #require(shop.engine)
        let live = JSONValue.object(["state": .string("printing"), "progress": .number(42),
                                     "filename": .string("bracket.gcode")])
        _ = await watch.finishCamera.observe("M-S", status: live, engine: engine)
        #expect(watch.finishCamera.remembers("M-S"))
        shop.lastPrinterState["M-S"] = "printing"
        // The phone was shown M-S printing before it was taken out.
        shop.liveActivities.shopId = "shop_1"
        shop.liveActivities.running["M-S"] = .init(phase: .printing, job: "bracket.gcode", progress: 42,
                                                   startedAt: Date(), endsAt: nil)
        #expect(shop.printingNow == 3)

        #expect(watch.forgetUnwatched(shop: shop))

        #expect(watch.readings["M-A"] != nil, "a machine still in service lost its reading")
        #expect(watch.readings["M-S"] == nil && watch.readings["M-R"] == nil)
        #expect(shop.printingNow == 1)
        #expect(!watch.finishCamera.remembers("M-S"), "its return would read as the old print ending")
        #expect(shop.lastPrinterState["M-S"] == nil)

        await LiveActivityPushTests.settle(rec, count: 1)
        let sent = try #require(rec.requests.first, "the phone's Live Activity was never ended")
        let body = try LiveActivityPushTests.body(sent)
        #expect(body["event"] as? String == "end")
        #expect(body["machineId"] as? String == "M-S")
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.liveActivities.running["M-S"] == nil)

        // Nothing more to drop: a second sweep says so and posts nothing.
        #expect(!watch.forgetUnwatched(shop: shop))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.requests.count == 1)
    }

    @Test("a printer deleted from the book is forgotten too, and its Live Activity ended")
    func deleted() async throws {
        let (shop, rec) = await LiveActivityPushTests.shop(cloud: LiveActivityPushTests.connected)
        let a = try MachineLifeTests.machine(MachineLifeTests.active)
        let gone = try MachineLifeTests.machine(MachineLifeTests.record("M-GONE"))
        shop.machines = [a, gone]
        let watch = shop.printers
        let status = try Self.printing()
        for id in ["M-A", "M-GONE"] {
            watch.setReadingForTesting(id, .init(status: status, problem: nil, at: Date(), lastGood: status))
        }
        let engine = try #require(shop.engine)
        let live = JSONValue.object(["state": .string("printing"), "progress": .number(42),
                                     "filename": .string("bracket.gcode")])
        _ = await watch.finishCamera.observe("M-GONE", status: live, engine: engine)
        shop.liveActivities.shopId = "shop_1"
        shop.liveActivities.running["M-GONE"] = .init(phase: .printing, job: "bracket.gcode", progress: 42,
                                                      startedAt: Date(), endsAt: nil)
        // Nothing to drop while it is in the book and watched.
        #expect(!watch.forgetUnwatched(shop: shop))

        shop.machines = [a]   // deleted, mid-print
        #expect(watch.forgetUnwatched(shop: shop))
        #expect(watch.readings["M-A"] != nil)
        #expect(watch.readings["M-GONE"] == nil && watch.statusCache["M-GONE"] == nil)
        #expect(!watch.finishCamera.remembers("M-GONE"))

        await LiveActivityPushTests.settle(rec, count: 1)
        let sent = try #require(rec.requests.first, "the deleted printer's Live Activity was never ended")
        let body = try LiveActivityPushTests.body(sent)
        #expect(body["event"] as? String == "end" && body["machineId"] as? String == "M-GONE")
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.liveActivities.running["M-GONE"] == nil)
    }

    @Test("stopping the watch drops its readings")
    func stopClears() throws {
        let watch = PrinterWatch()
        let status = try Self.printing()
        watch.setReadingForTesting("M-A", .init(status: status, problem: nil, at: Date(), lastGood: status))
        watch.stop()
        #expect(watch.readings.isEmpty)
        #expect(watch.heard("M-A") == nil)
    }
}
