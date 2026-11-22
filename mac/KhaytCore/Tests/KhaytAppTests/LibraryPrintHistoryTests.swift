import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Times printed and last printed come from the jobs (`PrintHistory`), not
/// only from the record's own counter — which nothing on the Mac ever wrote.
///
/// The sample's Gripper is the case: its record says `timesPrinted: 0`, and a
/// delivered job (ORD-01017) made 24 of it. Before, every reader called it
/// never printed.
@MainActor
struct LibraryPrintHistoryTests {

    private static func sample() async -> Shop {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        return shop
    }

    @Test("a model its finished jobs made reads as printed, everywhere the Mac shows it")
    func jobsCount() async throws {
        let shop = await Self.sample()
        let gripper = try #require(shop.files.first { $0.id == "PF-sample-gripper" })
        #expect(gripper.timesPrinted == 0, "the record's own counter is left as it was")
        // One delivered job, quantity 24: one print, not 24.
        #expect(gripper.printCount == 1)
        #expect(gripper.printedLast != nil)
        #expect(gripper.lastPrintedDate != nil)
        #expect(!Shop.jumpDay(gripper).isEmpty)

        // The phone's library payload carries it.
        let page = shop.phoneLibrary(q: "gripper", folder: "", offset: 0, limit: 50)
        guard case .object(let o) = page, case .array(let items)? = o["items"],
              let item = items.first(where: {
                  if case .object(let r) = $0, case .string("PF-sample-gripper")? = r["id"] { true } else { false }
              }), case .object(let row) = item else {
            Issue.record("the gripper is not in the phone's page: \(page)"); return
        }
        #expect(row["timesPrinted"] == .number(1))
        #expect(row["lastPrinted"] != nil)

        // And the Never printed filter leaves it out.
        shop.libraryNeverPrintedOnly = true
        #expect(!shop.shownFiles.contains { $0.id == "PF-sample-gripper" })
    }

    @Test("a record's larger desktop count is kept, not added to")
    func storedCountKept() async throws {
        let shop = await Self.sample()
        // Falcon: logged 12 times on the desktop, two delivered jobs.
        let falcon = try #require(shop.files.first { $0.id == "PF-sample-falcon" })
        #expect(falcon.timesPrinted == 12)
        #expect(falcon.printCount == 12)
        #expect(shop.printHistory["PF-sample-falcon"]?.timesPrinted == 2)
        // A job that is only quoted, pending or printing has not printed.
        #expect(shop.printHistory["PF-sample-king-7"] == nil)
    }

    @Test("a library edit keeps the jobs' answer on the models")
    func editKeepsHistory() async throws {
        let shop = await Self.sample()
        shop.showLibraryFiles(shop.files)
        #expect(shop.files.first { $0.id == "PF-sample-gripper" }?.printCount == 1)
    }
}
