import Foundation
import Testing
@testable import KhaytCore

/// Library stage 3a, the pure half: the printer chips a tile shows, the
/// Fits filter's place in the one query, and ⌘J's ranking and keys.
struct LibraryStage3aCoreTests {

    // MARK: Fit chips

    @Test("chips follow the inspector's states: ready first, then a swap, then a plain fit; too big is left off")
    func chipOrder() {
        let row = LibraryFitChips.row([
            ("a", "Bambu X1C", .fits),
            ("b", "Snapmaker U1", .ready),
            ("c", "Prusa CORE One", .needsSwap),
            ("d", "Big One", .tooBig),
            ("e", "Elegoo Neptune 4", .readyTurned),
        ])
        #expect(row.chips.map(\.machineId) == ["b", "e", "c", "a"])
        #expect(row.chips.map(\.tone) == [.ready, .ready, .swap, .fits])
        #expect(row.chips.first { $0.machineId == "e" }?.turned == true)
        #expect(!row.tooBigEverywhere)
    }

    @Test("too big for every machine that said anything is one chip; nothing known is no chip")
    func tooBigAndUnknown() {
        let all = LibraryFitChips.row([("a", "A", .tooBig), ("b", "B", .tooBig)])
        #expect(all.tooBigEverywhere && all.chips.isEmpty && !all.isEmpty)
        let none = LibraryFitChips.row([])
        #expect(none.isEmpty && !none.tooBigEverywhere)
    }

    @Test("Fits <machine> is exactly the chip being on the tile")
    func showsIsTheChip() {
        for state in ModelReadiness.State.allCases {
            let chip = LibraryFitChips.row([("m", "M", state)]).chips.contains { $0.machineId == "m" }
            #expect(LibraryFitChips.shows(state) == chip, "\(state)")
        }
    }

    @Test("the machine a filter names leads the row; one with no chip changes nothing")
    func leading() {
        let row = LibraryFitChips.row([("a", "A", .ready), ("b", "B", .fits), ("c", "C", .tooBig)])
        #expect(LibraryFitChips.leading(row, "b").chips.map(\.machineId) == ["b", "a"])
        #expect(LibraryFitChips.leading(row, "c") == row)
        #expect(LibraryFitChips.leading(row, nil) == row)
    }

    @Test("a chip names a machine by its model when the whole name is long")
    func shortNames() {
        #expect(LibraryFitChips.short("Bambu X1C") == "Bambu X1C")
        #expect(LibraryFitChips.short("Snapmaker U1") == "U1")
        #expect(LibraryFitChips.short("Prusa CORE One") == "CORE One")
        #expect(LibraryFitChips.short("Elegoo Neptune 4 Pro") == "4 Pro")
        #expect(LibraryFitChips.short("Bambu Lab X1 Carbon") == "X1 Carbon")
        let long = LibraryFitChips.short("Supercalifragilistic")
        #expect(long.count == LibraryFitChips.shortLength && long.hasSuffix("\u{2026}"))
    }

    @Test("past the width, as many chips as fit beside one +N")
    func overflow() {
        let widths = [30.0, 30, 30, 30]
        let plus: (Int) -> Double = { _ in 20 }
        #expect(LibraryFitChips.visibleCount(widths: widths, available: 200, spacing: 3, overflow: plus) == 4)
        // 4 chips need 129; at 110: 3 chips + "+1" = 90 + 9 + 20 = 119 > 110; 2 + "+2" = 60 + 6 + 20 = 86.
        #expect(LibraryFitChips.visibleCount(widths: widths, available: 110, spacing: 3, overflow: plus) == 2)
        #expect(LibraryFitChips.visibleCount(widths: widths, available: 40, spacing: 3, overflow: plus) == 0)
        #expect(LibraryFitChips.visibleCount(widths: [], available: 100, spacing: 3, overflow: plus) == 0)
        // Exactly the width: everything.
        #expect(LibraryFitChips.visibleCount(widths: [50, 50], available: 103, spacing: 3, overflow: plus) == 2)
    }

    // MARK: The query

    @Test("Fits is part of the one query: it narrows, it is saved, and it reads back")
    func queryCarriesFits() throws {
        var q = LibraryQuery()
        #expect(!q.filtersOn)
        q.fitsOn = "MACH-u1"
        #expect(q.filtersOn && !q.isEmpty)
        let back = try #require(LibraryQuery(json: q.json))
        #expect(back.fitsOn == "MACH-u1")
        #expect(back == q)
        // An older book's query has no such field: off.
        #expect(LibraryQuery(json: .object([:]))?.fitsOn == nil)
    }

    // MARK: ⌘J

    static func candidates() -> [LibraryJump.Candidate] {
        [
            .init(kind: .model, id: "old", title: "Dental model upper", fields: ["Dental model upper"],
                  lastActive: "2026-01-02", prints: 9),
            .init(kind: .model, id: "new", title: "Dental model lower", fields: ["Dental model lower"],
                  lastActive: "2026-10-20", prints: 1),
            .init(kind: .model, id: "same-day", title: "Dental model set", fields: ["Dental model set"],
                  lastActive: "2026-10-20", prints: 5),
            .init(kind: .folder, id: "Dental", title: "Dental", fields: ["Dental"],
                  lastActive: "2026-10-20", prints: 15),
            .init(kind: .tag, id: "dental", title: "#dental", fields: ["dental"], lastActive: "2025-12-01"),
            .init(kind: .search, id: "LSS-1", title: "Ready dental", fields: ["Ready dental"]),
            .init(kind: .job, id: "J1", title: "Dental job", fields: ["Dental job"]),
        ]
    }

    @Test("ranked by match quality first, then recency, then times printed")
    func ranking() {
        let index = LibraryJump.index(Self.candidates())
        #expect(!index.entries.contains { $0.kind == .job }, "⌘J lists only the library")
        let (_, hits) = index.ranked("dental", kinds: LibraryJump.kinds, limit: 8)
        let ids = hits.map(\.entry.id)
        // The whole key first (the folder "Dental" and the tag "dental"), the
        // folder before the tag because it was used later; then the models
        // starting with it — the most recent first, and of two on one day
        // the more printed; the saved search matches mid-name, last.
        #expect(ids == ["Dental", "dental", "same-day", "new", "old", "LSS-1"], "\(ids)")
    }

    @Test("a longer query narrows the last one's matches")
    func narrowing() {
        let index = LibraryJump.index(Self.candidates())
        let first = index.ranked("den", kinds: LibraryJump.kinds)
        let second = index.ranked("dent", kinds: LibraryJump.kinds, narrowing: first.result)
        #expect(second.result.touched == first.result.matched.count)
        #expect(second.hits.map(\.entry.id) == index.ranked("dent", kinds: LibraryJump.kinds).hits.map(\.entry.id))
    }

    @Test("nothing typed lists the most recently used models")
    func recent() {
        let index = LibraryJump.index(Self.candidates())
        #expect(LibraryJump.recent(index, limit: 2).map(\.id) == ["same-day", "new"])
    }

    @Test("↩ opens, ⌘↩ quotes, ⌥↩ starts a job — and only a model, only when the menus allow")
    func keys() {
        #expect(LibraryJump.action(command: false, option: false) == .open)
        #expect(LibraryJump.action(command: true, option: false) == .quote)
        #expect(LibraryJump.action(command: false, option: true) == .newJob)
        #expect(LibraryJump.action(command: true, option: true) == .quote)
        for kind in LibraryJump.kinds {
            #expect(LibraryJump.allows(.open, on: kind, canMoveJobs: false))
            #expect(LibraryJump.allows(.quote, on: kind, canMoveJobs: true) == (kind == .model))
            #expect(!LibraryJump.allows(.newJob, on: kind, canMoveJobs: false))
        }
    }

    @Test("a day is ten characters in the shape of a day, or nothing")
    func days() {
        #expect(LibraryJump.day("2026-10-25T09:00:00Z") == "2026-10-25")
        #expect(LibraryJump.day("2026-10-25") == "2026-10-25")
        #expect(LibraryJump.day("yesterday!") == "")
        #expect(LibraryJump.day(nil) == "")
    }
}
