import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What has already been sent, which both apps recorded and neither showed.
///
/// ── THE DEFECT, STATED ────────────────────────────────────────────────────
///
/// `settings.campaignLog` has been written since campaigns existed. Grepping
/// the repository for it finds exactly two hits and both are writes: this app
/// and the other one each keep the record, and no screen in either has ever
/// drawn it.
///
/// That is the same fault as the marketing opt-out, in the other direction —
/// there, a field the app read and could not set; here, one it writes and
/// cannot show. Both are half a feature.
@MainActor
struct CampaignLogTests {

    static func runs(_ log: [JSONValue]) -> [Shop.CampaignRun] {
        Shop.campaignRuns(in: ["campaignLog": .array(log)])
    }

    static func run(_ at: String, reached: Int, sent: Int, failed: Int) -> JSONValue {
        .object(["at": .string(at), "channel": .string("email"),
                 "recipients": .number(Double(reached)),
                 "sent": .number(Double(sent)), "failed": .number(Double(failed))])
    }

    @Test("the newest run is first, whichever order the book holds them in")
    func newestFirst() async {
        // The other app APPENDS, so the book's order is oldest-first. A list
        // that showed the oldest three would answer a question nobody asked.
        let runs = Self.runs([
            Self.run("2026-09-01T09:00:00Z", reached: 10, sent: 10, failed: 0),
            Self.run("2026-09-20T09:00:00Z", reached: 38, sent: 36, failed: 2),
        ])
        #expect(runs.first?.day == "2026-09-20")
        #expect(runs.first?.sent == 36)
        #expect(runs.first?.failed == 2)
        #expect(runs.last?.day == "2026-09-01")
    }

    @Test("a day, not an instant")
    func aDay() {
        let runs = Self.runs([Self.run("2026-09-20T11:14:07.512Z",
                                       reached: 5, sent: 5, failed: 0)])
        #expect(runs.first?.day == "2026-09-20",
                "a list of times to the second is a list nobody reads")
    }

    @Test("a row with no timestamp is dropped rather than drawn as a blank line")
    func junkIsDropped() {
        let runs = Self.runs([
            .string("not a run"),
            .object(["sent": .number(3)]),                       // no `at`
            Self.run("2026-09-20T09:00:00Z", reached: 1, sent: 1, failed: 0),
        ])
        #expect(runs.count == 1)
    }

    @Test("a shop that has sent nothing has no section at all")
    func emptyIsEmpty() async {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.campaignRuns.isEmpty)
    }

    @Test("the sheet draws it, and says nothing about failures when there were none")
    func wired() throws {
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/CampaignSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("shop.campaignRuns"), "the record is kept and still not shown")
        #expect(sheet.contains("run.failed > 0"), Comment(rawValue:
            "\"0 failed\" on every line teaches a shop to stop reading the line, which "
            + "is how the one that says 2 gets missed"))
    }
}
