import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A print that ended while the app was closed (Baby U1, Nov 14): Turki quit
/// the Mac mid-print and reopened it after the end. The memo said printing at
/// a mid-print progress, the U1 said `standby` with no file — and the phones
/// were told "cancelled" for a print its own history calls completed at 13:43.
@MainActor
struct MissedFinishTests {

    static let file = "Silica Box_PETG_15h22m.gcode"
    /// 13:43 in Riyadh.
    static let endedAt = "2026-11-14T10:43:00.000Z"

    /// A FinishCamera as the relaunch leaves it: the memo the last run kept
    /// (a reading at 41%), read back by a new one — the real `keep`/`restore`.
    static func relaunched(_ machineId: String, engine: KhaytEngine) async throws -> FinishCamera {
        let defaults = try #require(UserDefaults(suiteName: "missed-\(UUID().uuidString)"))
        let before = FinishCamera()
        before.keepFor = ("/tmp/book.json", defaults)
        _ = await before.observe(machineId, status: FinishPhotoTests.status("printing", 41, Self.file), engine: engine)
        let after = FinishCamera()
        after.restore(book: "/tmp/book.json", defaults: defaults)
        return after
    }

    @Test("memo printing, now standby with no file: unknown, not cancelled — then the history says finished at 13:43")
    func relaunchAfterTheEnd() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let u1 = try #require(shop.machines.first { $0.id == "MACH-u1" })
        shop.connectMachineForTesting(u1.id, type: "moonraker")
        let machine = try #require(shop.machines.first { $0.id == u1.id })

        let camera = try await Self.relaunched(machine.id, engine: engine)
        #expect(camera.resumed == [machine.id])
        let edge = try #require(await camera.observe(machine.id, status: .object([
            "state": .string("standby"), "progress": .number(0), "filename": .string("")]), engine: engine))
        #expect(edge.outcome == "unknown", "never a guess from the state after the gap")
        #expect(edge.filename == Self.file)
        #expect(camera.resumed.isEmpty, "only the first answer after the relaunch is a missed one")

        // The printer's own history: completed at 13:43.
        shop.historyFetch = { _, _ in [
            .object(["filename": .string(Self.file), "status": .string("cancelled"),
                     "endedAt": .string("2026-11-12T08:00:00.000Z")]),
            .object(["filename": .string(Self.file), "status": .string("completed"),
                     "endedAt": .string(Self.endedAt)]),
        ] }
        let told = try #require(await shop.historyOutcome(machine, filename: Self.file))
        #expect(told.outcome == "finished")
        #expect(Shop.isoDate(told.endedAt) == Shop.isoDate("2026-11-14T13:43:00+03:00"))
    }

    @Test("no history to ask: the end stays unknown, and no phone is told anything")
    func noHistory() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let u1 = try #require(shop.machines.first { $0.id == "MACH-u1" })
        // Not Moonraker: nothing keeps a history to ask.
        shop.connectMachineForTesting(u1.id, type: "prusalink")
        let machine = try #require(shop.machines.first { $0.id == u1.id })
        shop.historyFetch = { _, _ in Issue.record("a PrusaLink was asked for Moonraker history"); return [] }
        #expect(await shop.historyOutcome(machine, filename: Self.file) == nil)
        // The phone alert is skipped for an unknown end (it reads only three outcomes).
        let code = MenuCoverageTests.source("Shop+Photos.swift")
        #expect(code.contains("guard ended.outcome != \"unknown\" else { return }\n        await sendPrintFinishedEvent(ended)"))
    }

    @Test("a live edge (no relaunch) keeps the live rule")
    func liveEdgeUnchanged() async throws {
        let engine = try KhaytEngine()
        let camera = FinishCamera()
        _ = await camera.observe("M1", status: FinishPhotoTests.status("printing", 41, Self.file), engine: engine)
        let edge = try #require(await camera.observe("M1", status: .object([
            "state": .string("complete"), "progress": .number(100), "filename": .string(Self.file)]), engine: engine))
        #expect(edge.outcome == "finished")
    }
}
