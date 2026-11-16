import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// New Job's cost breakdown counts each part as many times as the job prints it.
///
/// Found in the beta.38 UI review: a product of four brackets and a lid showed
/// rows of 302.47 (×4) and 74.93 (×1) and a breakdown that summed to 150.55,
/// one bracket and one lid, because each line's breakdown (for one piece) was
/// added once.
@MainActor
struct NewJobBreakdownTests {

    static func parts(_ m: Double, _ k: Double, _ l: Double, _ b: Double) throws -> KhaytEngine.CostParts {
        try JSONDecoder().decode(KhaytEngine.CostParts.self, from: Data(
            #"{"material":\#(m),"machine":\#(k),"labor":\#(l),"buffer":\#(b)}"#.utf8))
    }

    @Test("each line's breakdown counts qty times, and matches the rows")
    func countsQty() throws {
        var bracket = NewJobSheet.Draft()
        bracket.qty = 4
        bracket.parts = try Self.parts(40, 1.5, 30, 4.12)
        bracket.cost = 75.62
        var lid = NewJobSheet.Draft()
        lid.qty = 1
        lid.parts = try Self.parts(20, 0.5, 50, 4.43)
        lid.cost = 74.93
        let sum = NewJobSheet.breakdownSum([bracket, lid])
        #expect(sum.m == 180)
        #expect(sum.k == 6.5)
        #expect(sum.l == 170)
        #expect(abs(sum.b - 20.91) < 1e-9)
        // The four figures add up to what the rows show (cost × qty).
        let rows = bracket.cost * 4 + lid.cost * 1
        #expect(abs((sum.m + sum.k + sum.l + sum.b) - rows) < 1e-9)
    }

    @Test("a line with no breakdown yet adds nothing")
    func noneYet() {
        var typed = NewJobSheet.Draft()
        typed.qty = 3
        let sum = NewJobSheet.breakdownSum([typed])
        #expect(sum.m == 0 && sum.k == 0 && sum.l == 0 && sum.b == 0)
    }
}
