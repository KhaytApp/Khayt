import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The band crossing into the engine and back.
///
/// The rule is `lib/machine-band.js` and `test/machine-band.test.js` pins it.
/// These are about the CROSSING: that the shape decodes, that the numbers
/// survive it, and that the two honesty rules are still true on this side —
/// an unaskable machine is left out of the totals, and a 42-hour job fits.
@MainActor
struct MachineBandTests {

    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    static func machine(_ id: String, _ name: String) -> JSONValue {
        .object(["id": .string(id), "name": .string(name)])
    }

    static func job(_ id: String, machine: String, hours: Double,
                    status: String = "pending", parts: [JSONValue] = []) -> JSONValue {
        .object([
            "id": .string(id), "machineId": .string(machine), "printTime": .number(hours),
            "status": .string(status), "project": .string(id), "parts": .array(parts),
        ])
    }

    static func band(machines: [JSONValue], orders: [JSONValue],
                     inventory: [JSONValue] = [], live: [String: JSONValue] = [:],
                     hours: Double = 48) async throws -> KhaytEngine.MachineBand {
        try await KhaytEngine().machineBand(machines: machines, orders: orders,
                                            inventory: inventory, live: live,
                                            now: Self.now, hours: hours)
    }

    @Test("the band decodes, and a running job's end comes from the printer")
    func crossing() async throws {
        let b = try await Self.band(
            machines: [Self.machine("M1", "Snapmaker U1")],
            orders: [Self.job("run", machine: "M1", hours: 8, status: "printing")],
            live: ["M1": .object(["progress": .number(50), "timeRemaining": .number(4 * 3600)])])
        #expect(b.rows.count == 1)
        #expect(b.rows[0].name == "Snapmaker U1")
        #expect(b.rows[0].known)
        let block = try #require(b.rows[0].blocks.first)
        #expect(block.kind == "printing")
        #expect(!block.projected)
        // Four hours left, and it started four hours before the window opened.
        #expect(block.minutes == 240)
        #expect(block.clippedStart)
        #expect(block.beforeMinutes == 240)
    }

    /// The reason this window is 48 hours and not a day.
    @Test("a 42-hour print is drawn at 42 hours, not squashed to the edge")
    func theLongJobFits() async throws {
        let b = try await Self.band(
            machines: [Self.machine("M1", "Bambu X1C")],
            orders: [Self.job("kings", machine: "M1", hours: 42, status: "printing")],
            live: ["M1": .object(["timeRemaining": .number(42 * 3600)])])
        let block = try #require(b.rows[0].blocks.first)
        #expect(block.minutes == 42 * 60)
        #expect(!block.clippedEnd)
        #expect(b.rows[0].freeMinutes == 6 * 60)
    }

    @Test("a job that does run past the end says how far past")
    func overrunIsSaid() async throws {
        let b = try await Self.band(
            machines: [Self.machine("M1", "Bambu X1C")],
            orders: [Self.job("kings", machine: "M1", hours: 42, status: "printing")],
            live: ["M1": .object(["timeRemaining": .number(42 * 3600)])],
            hours: 24)
        let block = try #require(b.rows[0].blocks.first)
        #expect(block.clippedEnd)
        #expect(block.afterMinutes == 18 * 60)
    }

    /// The rule the whole module exists for.
    @Test("a machine Khayt cannot ask is left out of the totals, not counted as free")
    func theUnaskableMachine() async throws {
        let b = try await Self.band(
            machines: [Self.machine("M1", "U1"), Self.machine("M2", "X1C")],
            orders: [
                Self.job("dark", machine: "M1", hours: 8, status: "printing"),
                Self.job("lit", machine: "M2", hours: 8, status: "printing"),
            ],
            live: ["M2": .object(["timeRemaining": .number(2 * 3600)])])
        let dark = try #require(b.rows.first { $0.machineId == "M1" })
        #expect(!dark.known)
        #expect(dark.blocks.isEmpty)
        #expect(dark.freeMinutes == 0)
        #expect(b.countedMachines == 1)
        #expect(b.unknownMachines == 1)
        #expect(b.capacityMinutes == 48 * 60,
                "counting it would claim a whole printer's hours the shop has not got")
    }

    @Test("a queued job short of filament is blocked, and names the shortfall")
    func blockedOnStock() async throws {
        let part = JSONValue.object([
            "filamentId": .string("s1"), "printWeight": .number(480),
            "supportWeight": .number(0), "qty": .number(1),
        ])
        let b = try await Self.band(
            machines: [Self.machine("M1", "X1C")],
            orders: [Self.job("kings", machine: "M1", hours: 42, parts: [part])],
            inventory: [.object([
                "id": .string("s1"), "material": .string("PA-CF"), "weight": .number(120),
            ])])
        let block = try #require(b.rows[0].blocks.first)
        #expect(block.kind == "blocked")
        let short = try #require(block.shortfall)
        #expect(short.material == "PA-CF")
        #expect(short.short == 360)
    }

    /// Both figures on the row have to describe the same window, because the
    /// screen prints them side by side and a shop adds them up by eye.
    @Test("booked and free add up to the window on every row")
    func rowsAddUp() async throws {
        let b = try await Self.band(
            machines: [Self.machine("M1", "U1"), Self.machine("M2", "Prusa"),
                       Self.machine("M3", "X1C")],
            orders: [
                Self.job("a", machine: "M1", hours: 4, status: "printing"),
                Self.job("b", machine: "M1", hours: 16),
                Self.job("c", machine: "M2", hours: 5.3, status: "printing"),
            ],
            live: ["M1": .object(["timeRemaining": .number(4 * 3600)]),
                   "M2": .object(["timeRemaining": .number(5.3 * 3600)])])
        for row in b.rows where row.known {
            #expect(abs(row.bookedMinutes + row.freeMinutes - 48 * 60) < 0.001,
                    "\(row.name): \(row.bookedMinutes) + \(row.freeMinutes)")
        }
        #expect(abs(b.bookedMinutes + b.freeMinutes - b.capacityMinutes) < 0.001)
    }

    // MARK: - What the screen writes

    /// The mockup this came from printed a free-hours total that did not match
    /// the rows above it. The summary is written as the sum precisely so that
    /// cannot happen unnoticed.
    @Test("the legend's total is the rows added up, in front of the reader")
    func theSumShowsItsWorking() async throws {
        let b = try await Self.band(
            machines: [Self.machine("M1", "U1"), Self.machine("M2", "Prusa")],
            orders: [
                Self.job("a", machine: "M1", hours: 20, status: "printing"),
                Self.job("c", machine: "M2", hours: 5.3, status: "printing"),
            ],
            live: ["M1": .object(["timeRemaining": .number(20 * 3600)]),
                   "M2": .object(["timeRemaining": .number(5.3 * 3600)])])
        let words = Words()
        let line = MachineBandView.sum(b, words)
        #expect(line.contains("28:00"), "M1 has 28 hours free: \(line)")
        #expect(line.contains("42:42"), "M2 has 42h42m free: \(line)")
        #expect(line.contains("=") && line.contains("70:42"),
                "and the total is those two added up: \(line)")
    }

    @Test("hours and minutes are written the way a shop says them")
    func spelling() {
        #expect(Hours.spell(0) == "0:00")
        #expect(Hours.spell(308) == "5:08")
        #expect(Hours.spell(2520) == "42:00")
        #expect(Hours.spell(-5) == "0:00", "a negative stretch is not a stretch")
    }

    /// The marks land on the CLOCK, not on the band's own start.
    ///
    /// Spaced every six hours from the moment the window opens, the ruler read
    /// 17:47, 23:47, 05:47 — truthful, unreadable, and it hid midnight, which
    /// is the boundary a shop plans an overnight run around. So the first mark
    /// is however far it is to the next round six hours, and they are six apart
    /// after that.
    @Test("the marks fall on the clock, so midnight is one of them")
    func ticks() async throws {
        let b = try await Self.band(machines: [Self.machine("M1", "U1")], orders: [])
        let marks = MachineBandView.tickMinutes(b)
        #expect(!marks.isEmpty)
        #expect(marks.allSatisfy { $0 >= 0 && $0 < b.minutes }, "none of them off the end")
        for pair in zip(marks, marks.dropFirst()) {
            #expect(pair.1 - pair.0 == 360, "six hours apart once they start")
        }
        // Every mark is a round six hours on the wall clock.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        for m in marks {
            let at = Date(timeIntervalSince1970: b.from / 1000 + m * 60)
            let parts = cal.dateComponents([.hour, .minute], from: at)
            #expect(parts.minute == 0, "a mark at \(parts.hour ?? -1):\(parts.minute ?? -1)")
            #expect((parts.hour ?? -1) % 6 == 0)
        }
        // And the whole two days are covered: eight marks, or seven when the
        // band opens exactly on one.
        #expect(marks.count == 8 || marks.count == 7)
    }

    /// Every key this screen asks for has to be a word the app can say, or the
    /// band renders `mac.band_state_printing` at a shop.
    @Test("every word the band asks for is one this app knows")
    func everyKeyIsTranslated() async throws {
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        let keys = [
            "mac.band_title", "mac.band_sub", "mac.band_over", "mac.band_unknown",
            "mac.band_cannot_ask", "mac.band_free_in", "mac.band_printing",
            "mac.band_queued", "mac.band_blocked", "mac.band_free",
            "mac.band_state_printing", "mac.band_state_queued", "mac.band_state_free",
            "mac.band_short", "mac.band_past", "mac.band_before",
        ]
        for key in keys {
            #expect(words.callIt(key) != key, "\(key) would reach the screen as its own key")
        }
        // And in Arabic, which is the language this app is for.
        let ar = Words()
        await ar.load("ar", engine: try KhaytEngine())
        for key in keys {
            #expect(ar.callIt(key) != key, "\(key) has no Arabic")
        }
    }

    /// The placeholders have to survive translation, or a shop reads
    /// "ناقص {grams} غ".
    @Test("no band string keeps an unfilled placeholder")
    func placeholders() {
        let words = Words()
        let short = words.callIt("mac.band_short",
                                 ["grams": .number(360), "material": .string("PA-CF")])
        #expect(short.contains("360") && short.contains("PA-CF"))
        #expect(!short.contains("{"))
        let past = words.callIt("mac.band_past", ["hours": .string("15:00")])
        #expect(past.contains("15:00") && !past.contains("{"))
    }
}

// MARK: - A print farm

/// Built at three machines, this screen was 46-point rows with two lines inside
/// every block. Ten machines is 560 points of band before the cards start —
/// the whole window — and twenty is unusable. A shop with twenty printers is
/// exactly the shop this screen is for, so these pin the behaviour that makes
/// it survive one.
@MainActor
struct MachineBandFarmTests {

    static func farm(_ n: Int, answering: Int) async throws -> KhaytEngine.MachineBand {
        var machines: [JSONValue] = [], orders: [JSONValue] = []
        var live: [String: JSONValue] = [:]
        for i in 0..<n {
            let id = String(format: "P%02d", i + 1)
            machines.append(MachineBandTests.machine(id, id))
            orders.append(MachineBandTests.job("j\(i)", machine: id,
                                               hours: Double(4 + i), status: "printing"))
            if i < answering {
                live[id] = .object(["timeRemaining": .number(Double(4 + i) * 3600)])
            }
        }
        return try await KhaytEngine().machineBand(
            machines: machines, orders: orders, inventory: [], live: live,
            now: MachineBandTests.now, hours: 48)
    }

    @Test("ten printers all come back, each with its own hours")
    func tenRows() async throws {
        let b = try await Self.farm(10, answering: 10)
        #expect(b.rows.count == 10)
        #expect(b.countedMachines == 10)
        #expect(b.capacityMinutes == 10 * 48 * 60)
        for (i, row) in b.rows.enumerated() {
            #expect(row.bookedMinutes == Double(4 + i) * 60, "\(row.name)")
            #expect(abs(row.bookedMinutes + row.freeMinutes - 48 * 60) < 0.001)
        }
    }

    /// Four machines is an arithmetic a reader checks. Ten is a wall of figures
    /// with the total hidden at the end of it.
    @Test("the summary stops spelling out the sum once a farm cannot check it")
    func summaryStaysReadable() async throws {
        let words = Words()
        let small = MachineBandView.sum(try await Self.farm(3, answering: 3), words)
        #expect(small.contains("+") && small.contains("="),
                "three machines still show their working: \(small)")

        let big = MachineBandView.sum(try await Self.farm(10, answering: 10), words)
        #expect(!big.contains("+"), "ten terms is not a sum anybody verifies: \(big)")
        #expect(big.contains("10"), "and it says what the total is over: \(big)")
    }

    /// The one rule the whole module exists for, at farm scale: six printers
    /// down must not be six printers' worth of free hours.
    @Test("a farm with half its printers dark reports capacity over the half that answer")
    func halfTheFarmIsDark() async throws {
        let b = try await Self.farm(10, answering: 4)
        #expect(b.countedMachines == 4)
        #expect(b.unknownMachines == 6)
        #expect(b.capacityMinutes == 4 * 48 * 60,
                "counting the dark six would claim 288 hours the shop cannot see")
        // 4 + 5 + 6 + 7 hours across the four that answered.
        #expect(b.bookedMinutes == (4 + 5 + 6 + 7) * 60)
        #expect(b.utilised > 0 && b.utilised < 1)
        for row in b.rows where !row.known {
            #expect(row.freeMinutes == 0)
            #expect(row.blocks.isEmpty)
        }
    }

    @Test("a farm where nothing answers has a band with nothing to draw")
    func nothingAnswers() async throws {
        let b = try await Self.farm(10, answering: 0)
        #expect(b.countedMachines == 0)
        #expect(b.capacityMinutes == 0)
        #expect(b.utilised == 0, "and not a division by zero")
        #expect(MachineBandView.sum(b, Words()).isEmpty,
                "a summary of nothing is a line of furniture")
    }

    /// The ruler is computed once for the whole band, so it cannot cost more as
    /// the farm grows — and it has to keep landing on the clock.
    @Test("the ruler is the same nine marks whatever the farm's size")
    func rulerDoesNotGrow() async throws {
        let three = MachineBandView.tickMinutes(try await Self.farm(3, answering: 3))
        let twenty = MachineBandView.tickMinutes(try await Self.farm(20, answering: 20))
        #expect(three == twenty)
        #expect(three.allSatisfy { $0 >= 0 && $0 < 2880 })
    }
}
