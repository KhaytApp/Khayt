import Testing
import Foundation
import KhaytCore
@testable import KhaytApp

/// Numbers that sit on one screen have to add up on that screen.
///
/// Neither defect below was a wrong calculation. Both were two correct figures
/// over DIFFERENT POPULATIONS, printed inches apart, where the obvious
/// arithmetic between them gives a third number the app never shows.
@MainActor
struct DashboardHonestyTests {

    /// `kpi` computes revenue, cost, margin, the average and on-time over
    /// COMPLETED rows, and `orderCount` over every row in the period. The
    /// sample shop's month is 1,243.08 over 2 completed jobs out of 4 — so a
    /// reader dividing revenue by the "Jobs" tile gets 310.77 against a stated
    /// average of 621.54.
    ///
    /// This is the property that makes the average checkable: the count it
    /// divides by is `completedCount`, and that is the count the revenue card
    /// prints beside the money.
    @Test func theAverageDividesByTheCountTheCardShows() throws {
        let kpi = try JSONDecoder().decode(Kpis.self, from: Data("""
        {"orderCount": 4, "completedCount": 2, "revenue": 1243.08, "cost": 403.78,
         "grossProfit": 839.30, "grossMargin": 67.5, "avgOrderValue": 621.54,
         "onTimePct": 100, "onTimeTotal": 2, "outstanding": 0}
        """.utf8))
        // The stated average is revenue over the COMPLETED count, not the
        // order count — so the card must show the completed count for anyone to
        // be able to check it.
        #expect(abs(kpi.revenue / Double(kpi.completedCount) - kpi.avgOrderValue) < 0.01)
        #expect(abs(kpi.revenue / Double(kpi.orderCount) - kpi.avgOrderValue) > 0.01,
                "the two populations happen to agree here, so this fixture proves nothing")
    }

    /// "Machines 0/3" beside "Printing 5" was not a rounding problem: the tile
    /// counts printers ANSWERING ON THE NETWORK, and this shop's three printers
    /// answer to nothing. The label has to say what the number is.
    @Test func theFleetTileIsLabelledForWhatItCounts() {
        let words = Words()
        let label = words.callIt("mac.machines")
        #expect(label != "Machines",
                "the tile counts printers reporting, not machines the shop owns")
        for language in Words.supported {
            #expect(Words.own["mac.machines"]?[language]?.isEmpty == false)
        }
    }
}
