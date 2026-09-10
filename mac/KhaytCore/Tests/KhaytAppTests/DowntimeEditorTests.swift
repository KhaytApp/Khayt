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
        #expect(sheet.contains("input[\"downtimeBlocks\"] = .array("),
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
}
