import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Booking a machine out of action, from the Mac.
///
/// Three things read `downtimeBlocks` — the band, the scheduler and the
/// delivery promise a storefront quotes — and until now only Khayt could write
/// one. A shop working here could SEE that a printer was booked out and had to
/// open the other app to say so.
@MainActor
struct DowntimeEditorTests {

    static func source(_ name: String) -> String { EmptyStateTests.source(name) }

    /// ── ONE SHAPE, OR THE TWO APPS MEAN DIFFERENT HOURS ──────────────────
    ///
    /// `YYYY-MM-DDTHH:mm`, no zone and no seconds — what a `datetime-local`
    /// input produces and what Khayt's machine modal writes. "Thursday 2pm" is
    /// what a shop means by a maintenance window; a window set here and read
    /// there has to be the same four hours.
    @Test("a time is written the way Khayt writes one")
    func theStampMatchesKhayt() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 10
        parts.hour = 14; parts.minute = 30
        let when = try! #require(Calendar.current.date(from: parts))
        #expect(DowntimeEditor.stamp(when) == "2026-09-10T14:30")
        // And back, so an existing window opens on the control it was set with.
        #expect(DowntimeEditor.parse("2026-09-10T14:30") == when)
    }

    /// A `datetime-local` string carries no zone, so it must not be read as
    /// one. Parsing "…T14:30" as UTC on a +03:00 Mac would show the shop 17:30
    /// for a window it set at half past two.
    @Test("a naive time is read as the shop's own clock, not as UTC")
    func naiveIsLocal() {
        let read = try! #require(DowntimeEditor.parse("2026-09-10T14:30"))
        let back = Calendar.current.dateComponents([.hour, .minute], from: read)
        #expect(back.hour == 14 && back.minute == 30,
                "read back as \(back.hour ?? -1):\(back.minute ?? -1)")
    }

    /// The shared rule drops a window that runs backwards, and does it
    /// silently. A sheet that cannot say so lets a shop type something and find
    /// nothing saved.
    @Test("a window that ends before it starts is flagged on the sheet")
    func backwardsIsSaidOutLoud() {
        let good = Shop.DowntimeBlock(from: "2026-09-10T09:00", to: "2026-09-10T11:00", reason: "")
        let bad = Shop.DowntimeBlock(from: "2026-09-10T11:00", to: "2026-09-10T09:00", reason: "")
        let empty = Shop.DowntimeBlock(from: "", to: "", reason: "")
        #expect(good.isReadable)
        #expect(!bad.isReadable)
        #expect(!empty.isReadable)
        #expect(Self.source("MachineSheet.swift").contains("mac.downtime_backwards"),
                "the sheet never says why a window will vanish")
    }

    /// Every kind of machine, not only the ones something can poll: a laser is
    /// booked out for a lens change the same way a printer is for a belt.
    @Test("the editor is not inside the polled-printer block")
    func everyMachineCanBeBookedOut() {
        let sheet = Self.source("MachineSheet.swift")
        guard let polled = sheet.range(of: "if polled {"),
              let editor = sheet.range(of: "DowntimeEditor(shop: shop, blocks: $downtime)"),
              let wear = sheet.range(of: "The whole wear block belongs to the nozzle") else {
            Issue.record("the sheet's shape moved"); return
        }
        #expect(editor.lowerBound > polled.lowerBound)
        // After the `polled` block closes, which the wear comment follows.
        #expect(editor.lowerBound < wear.lowerBound)
        #expect(sheet.contains("input[\"downtimeBlocks\"] = DowntimeEditor.payload("),
                "the sheet edits windows and never saves them")
    }

    /// Absent means leave alone, which is the shared rule's own convention — a
    /// screen that does not show maintenance must not wipe what Khayt set.
    @Test("the windows survive the round trip through the shared rule")
    func theRoundTripKeepsThem() async throws {
        let engine = try KhaytEngine()
        let machine = JSONValue.object(["id": .string("M1"), "name": .string("U1")])
        let edited = try await engine.editMachine(machine, input: [
            "name": .string("U1"),
            "downtimeBlocks": .array([
                .object(["from": .string("2026-09-20T09:00"), "to": .string("2026-09-20T11:00"),
                         "reason": .string("Lens")]),
                // Backwards: dropped by the rule, which is why the sheet warns.
                .object(["from": .string("2026-09-10T11:00"), "to": .string("2026-09-10T09:00"),
                         "reason": .string("typo")]),
            ]),
        ], settings: [:])
        guard case .object(let fields)? = edited.machine,
              case .array(let kept)? = fields["downtimeBlocks"] else {
            Issue.record("no windows on the record"); return
        }
        #expect(kept.count == 1, "kept \(kept.count)")
        guard case .object(let one) = kept[0] else { return }
        #expect(one["reason"] == JSONValue.string("Lens"))
    }

    // ── A WINDOW KHAYT WROTE AS AN INSTANT ────────────────────────────────
    //
    // Books hold `2026-07-05T08:00:00.000Z` as well as the local form (the
    // bundled sample does). Reading only the local form opened such a window
    // as now→now, flagged it backwards, and the save DROPPED it (Sep 2026).

    static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    @Test("full ISO stamps parse to the instant they name")
    func isoStampsAreInstants() {
        let eight = Self.utc(2026, 7, 5, 8)
        #expect(DowntimeEditor.parse("2026-07-05T08:00:00.000Z") == eight)
        #expect(DowntimeEditor.parse("2026-07-05T08:00:00Z") == eight)
        #expect(DowntimeEditor.parse("2026-07-05T11:00:00+03:00") == eight)
        #expect(DowntimeEditor.parse("2026-07-05T11:00:00.000+03:00") == eight)
        #expect(DowntimeEditor.parse("2026-07-05T08:00:00.250Z") == eight.addingTimeInterval(0.25))
        // The local form with seconds is still the shop's own clock.
        let local = try! #require(DowntimeEditor.parse("2026-09-10T14:30:15"))
        let back = Calendar.book.dateComponents([.hour, .minute, .second], from: local)
        #expect(back.hour == 14 && back.minute == 30 && back.second == 15)
        #expect(DowntimeEditor.parse("not a date") == nil)
        #expect(DowntimeEditor.parse("") == nil)
    }

    @Test("a window held as ISO instants is readable, not 'ends before it starts'")
    func isoBlockIsReadable() {
        let block = Shop.DowntimeBlock(from: "2026-07-05T08:00:00.000Z",
                                       to: "2026-07-06T18:00:00.000Z", reason: "Lens")
        #expect(block.isReadable)
        // Mixed: one end edited here, the other as Khayt wrote it.
        let mixed = Shop.DowntimeBlock(from: "2026-07-05T08:00:00.000Z",
                                       to: DowntimeEditor.stamp(Self.utc(2026, 7, 6, 18)), reason: "")
        #expect(mixed.isReadable)
    }

    @Test("a picker reporting the time already shown leaves the stamp untouched")
    func untouchedEndKeepsItsBytes() {
        let iso = "2026-07-05T08:00:00.000Z"
        let shown = try! #require(DowntimeEditor.parse(iso))
        #expect(DowntimeEditor.edited(iso, picked: shown) == iso)
        // A real move is written in the shape Khayt's field writes.
        let later = shown.addingTimeInterval(3600)
        #expect(DowntimeEditor.edited(iso, picked: later) == DowntimeEditor.stamp(later))
    }

    /// Open the sheet on a machine whose windows are ISO instants, touch
    /// nothing, save: what the shared rule writes back is what was there.
    @Test("opening and saving a machine keeps its ISO windows byte-identical")
    func openAndSaveKeepsIsoWindows() async throws {
        let blocks: JSONValue = .array([
            .object(["from": .string("2026-07-05T08:00:00.000Z"),
                     "to": .string("2026-07-06T18:00:00.000Z"),
                     "reason": .string("Lens clean, mirror align")]),
            .object(["from": .string("2026-08-01T09:00"),
                     "to": .string("2026-08-01T13:00"),
                     "reason": .string("Belt")]),
        ])
        let row: JSONValue = .object(["id": .string("M1"), "name": .string("Laser"),
                                      "kind": .string("laser"), "downtimeBlocks": blocks])
        let machine = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
        let opened = DowntimeEditor.windows(of: machine)
        #expect(opened.allSatisfy { $0.isReadable })
        let engine = try KhaytEngine()
        let saved = try await engine.editMachine(row, input: [
            "name": .string("Laser"),
            "downtimeBlocks": DowntimeEditor.payload(opened),
        ], settings: [:])
        guard case .object(let fields)? = saved.machine else {
            Issue.record("no machine came back"); return
        }
        #expect(fields["downtimeBlocks"] == blocks)
    }

    /// The sample shop's laser was booked out for a lens clean. It must open
    /// on that window — not on now→now.
    @Test("the sample laser shows its real window")
    func sampleLaserWindow() throws {
        let laser = try #require(try SampleShopTests.rows("machines").first {
            $0["kind"] == .string("laser")
        })
        let machine = try JSONDecoder().decode(Machine.self,
                                               from: JSONEncoder().encode(JSONValue.object(laser)))
        let windows = DowntimeEditor.windows(of: machine)
        #expect(!windows.isEmpty, "the sample laser lost its downtime")
        for w in windows {
            #expect(w.isReadable, "\(w.from) → \(w.to) opens as unreadable")
            let from = try #require(DowntimeEditor.parse(w.from))
            let to = try #require(DowntimeEditor.parse(w.to))
            #expect(from == Calendar.instant(w.from))
            #expect(to.timeIntervalSince(from) == 34 * 3600, "lens clean ran \(to.timeIntervalSince(from) / 3600)h")
            #expect(abs(from.timeIntervalSinceNow) > 3600, "opened on now")
        }
    }
}
