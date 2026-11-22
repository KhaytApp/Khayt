import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The job that is on a bed right now, on the screen a shop lives in.
///
/// ── THE DEFECT THIS EXISTS FOR ────────────────────────────────────────────
///
/// This app polls every linked printer and knows, to the percent, how far
/// through each running print is. It drew that on the Dashboard and on the
/// floor — and the Jobs table said "Printing" as flat text for as many hours
/// as the print took. The livest fact in the shop was known by the app and
/// absent from the list of the work it is about.
///
/// ── AND WHY THE RULE IS THIS NARROW ───────────────────────────────────────
///
/// Every condition in `Shop.livePrint` is a way of being wrong, and each of
/// these is one of them. The one that matters most is the idle machine: a
/// printer that is not printing answers perfectly happily with `progress: 0`,
/// so a job left marked printing against an idle machine would be drawn as 0%
/// underway — a confident picture of something that is not happening — rather
/// than as a row that needs a look.
@MainActor
struct LiveJobTests {

    static func printing(_ progress: Int, state: String = "printing") -> PrinterWatch.Reading {
        PrinterWatch.Reading(
            status: KhaytEngine.PrinterStatus(
                state: state, progress: progress, progressSource: "layers",
                filename: "part.gcode", timeRemaining: 3600,
                tempNozzle: 240, tempBed: 60, type: "moonraker"),
            problem: nil, at: Date())
    }

    static func book() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    /// The fixture itself, first. Every test below is about the sample book's
    /// printing jobs, and a book that stopped having any would make all of
    /// them pass by drawing nothing.
    @Test("the sample book still has printing jobs on real machines")
    func theFixtureIsStillAFixture() async {
        let shop = await Self.book()
        let live = shop.orders.filter { Stage.of($0) == .printing }
        #expect(live.count >= 3, "the sample book no longer exercises this at all")
        #expect(live.allSatisfy { $0.machineId?.isEmpty == false },
                "a printing job in the sample names no machine")
        // Three of them share one printer on purpose — see below.
        let machines = Set(live.compactMap(\.machineId))
        #expect(machines.count < live.count,
                "no two printing jobs share a machine any more")
    }

    @Test("a printing job on a printing machine shows that machine's progress")
    func theLiveRowIsLive() async throws {
        let shop = await Self.book()
        let job = try #require(shop.orders.first { Stage.of($0) == .printing })
        let machine = try #require(job.machineId)
        shop.printers.setReadingForTesting(machine, Self.printing(63))
        #expect(shop.livePrint(for: job)?.progress == 63)
    }

    /// THE ONE THAT MATTERS. An idle printer answers, and answers zero.
    @Test("an idle machine is not a print at 0%")
    func idleIsNotZeroPercent() async throws {
        let shop = await Self.book()
        let job = try #require(shop.orders.first { Stage.of($0) == .printing })
        let machine = try #require(job.machineId)
        for state in ["idle", "operational", "standby", "complete", "paused", "error"] {
            shop.printers.setReadingForTesting(machine, Self.printing(0, state: state))
            #expect(shop.livePrint(for: job) == nil,
                    "a machine reporting \(state) was drawn as a print underway")
        }
    }

    /// A machine that did not answer carries a `problem` and no status. The
    /// row has to fall back to the word, not to a bar at whatever it last saw.
    @Test("a machine that did not answer shows nothing")
    func aSilentMachineShowsNothing() async throws {
        let shop = await Self.book()
        let job = try #require(shop.orders.first { Stage.of($0) == .printing })
        let machine = try #require(job.machineId)
        shop.printers.setReadingForTesting(
            machine, .init(status: nil, problem: "did not answer", at: Date()))
        #expect(shop.livePrint(for: job) == nil)
    }

    /// A job the shop has already moved on is not the print on the bed, even
    /// though the machine is busy — it is busy with the NEXT one.
    @Test("only a job the book says is printing")
    func aMovedOnJobIsNotTheOneOnTheBed() async throws {
        let shop = await Self.book()
        let job = try #require(shop.orders.first { Stage.of($0) == .printing })
        let machine = try #require(job.machineId)
        shop.printers.setReadingForTesting(machine, Self.printing(63))
        for other in shop.orders where other.machineId == machine
            && Stage.of(other) != .printing {
            #expect(shop.livePrint(for: other) == nil,
                    "\(other.id) is \(other.status) and was drawn as the live print")
        }
    }

    /// A job that names no machine has nothing to ask. Guessing from "the only
    /// machine running" would put one printer's progress on another printer's
    /// job the moment a second one starts.
    @Test("a job with no machine is not guessed at")
    func noMachineIsNotGuessed() async throws {
        let shop = await Self.book()
        for machine in shop.machines {
            shop.printers.setReadingForTesting(machine.id, Self.printing(63))
        }
        // A REAL ROW WITH ITS MACHINE TAKEN OFF, rather than one written here:
        // `Order` decodes a wide record, and a hand-built fixture that fails
        // to decode is a test proving nothing about the app.
        let job = try #require(shop.orders.first { Stage.of($0) == .printing })
        var row = try #require(shop.orderRows.first {
            if case .object(let fields) = $0, case .string(job.id)? = fields["id"] { return true }
            return false
        })
        guard case .object(var fields) = row else { Issue.record("not an object"); return }
        fields["machineId"] = nil
        row = .object(fields)
        let unassigned = try JSONDecoder().decode(Order.self,
                                                  from: JSONEncoder().encode(row))
        #expect(unassigned.machineId == nil || unassigned.machineId?.isEmpty == true)
        #expect(Stage.of(unassigned) == .printing, "the row stopped being a printing job")
        #expect(shop.livePrint(for: unassigned) == nil,
                "a job naming no machine borrowed one that was running")
    }

    /// TWO JOBS, ONE PRINTER, and both drawn live — which is right. The book
    /// says both are printing and this reports what the machine says; the fix
    /// for a book that claims two prints on one bed belongs in the book, not
    /// in a tie-break invented in a table cell.
    @Test("jobs sharing a machine all report it, rather than one winning")
    func sharedMachineIsNotTieBroken() async throws {
        let shop = await Self.book()
        let byMachine = Dictionary(grouping: shop.orders.filter { Stage.of($0) == .printing },
                                   by: { $0.machineId ?? "" })
        let shared = try #require(byMachine.first { $0.value.count > 1 })
        shop.printers.setReadingForTesting(shared.key, Self.printing(41))
        for job in shared.value {
            #expect(shop.livePrint(for: job)?.progress == 41,
                    "\(job.id) shares the printer and was left without its progress")
        }
    }
}
