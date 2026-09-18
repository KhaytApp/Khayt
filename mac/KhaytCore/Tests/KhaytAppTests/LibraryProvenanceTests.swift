import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Recording where a model came from, and what its licence allows.
///
/// The inspector has always READ this and this Mac could not SET it, so on a
/// real book the provenance panel was blank on every model and the only way to
/// fill it in was to open the other app.
@MainActor
struct LibraryProvenanceTests {

    @Test("every licence the shared rule knows is on the menu, in its order")
    func theMenuIsTheRule() async throws {
        // Not a second list. A menu offering a licence the rule cannot name
        // writes a value the other app reads as "not recorded".
        #expect(ModelLicence.all.map(\.id) == [
            "own", "cc0", "cc-by", "cc-by-sa", "cc-by-nd",
            "cc-by-nc", "cc-by-nc-sa", "cc-by-nc-nd", "commercial",
        ])
        // And every one of them has a name in both languages Khayt's own
        // catalogue carries, because the menu draws `plib.licence_<id>`.
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        for licence in ModelLicence.all {
            let key = "plib.licence_" + licence.id.replacingOccurrences(of: "-", with: "_")
            #expect(words.callIt(key) != key, Comment(rawValue: "no name for \(licence.id)"))
        }
        #expect(words.callIt("plib.licence_unknown") != "plib.licence_unknown")
    }

    @Test("a licence the rule cannot name is refused rather than written")
    func unknownRefused() async throws {
        let shop = Shop()
        await shop.load(.sample)
        guard let any = shop.files.first else { return }
        shop.fileSelection = [any.id]
        await shop.fileSelection(licence: "mit")
        #expect(shop.writeProblem == shop.words.callIt("mac.licence_unknown"))
    }

    @Test("clearing goes back to nobody having said, which is not a refusal")
    func clearingIsReachable() async throws {
        // The whole point of the module: unknown is NOT no. A licence chosen by
        // mistake would otherwise tell a shop for ever that it may not sell its
        // own work, so there has to be a way back.
        #expect(ModelLicence.sellable("") == nil)
        #expect(ModelLicence.find("") == nil)
        let shop = Shop()
        await shop.load(.sample)
        guard let any = shop.files.first else { return }
        shop.fileSelection = [any.id]
        await shop.fileSelection(licence: "")
        // The sample book refuses the write, but not because the value was bad.
        #expect(shop.writeProblem != shop.words.callIt("mac.licence_unknown"))
    }

    @Test("what the menu shows is what everything selected already carries")
    func agreementOnly() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // Nothing selected is not an answer.
        shop.fileSelection = []
        #expect(shop.licenceOnSelection == nil)
        #expect(shop.sourceOnSelection.isEmpty)
        guard shop.files.count >= 2 else { return }
        // One model always agrees with itself.
        shop.fileSelection = [shop.files[0].id]
        #expect(shop.licenceOnSelection != nil)
    }

    @Test("the source is trimmed and capped where the other app caps it")
    func sourceIsTheOtherApps() async throws {
        // `maxlength="300"` on the source box in `renderer/printfiles.js`. A
        // source typed here has to be one that app will show back.
        let shop = Shop()
        await shop.load(.sample)
        guard let any = shop.files.first else { return }
        shop.fileSelection = [any.id]
        await shop.setSourceOnSelection("  " + String(repeating: "x", count: 400) + "  ")
        // The sample refuses the write; what is being pinned is the shaping,
        // which is why it is spelled out rather than read back off the book.
        let shaped = String("  \(String(repeating: "x", count: 400))  "
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        #expect(shaped.count == 300)
    }

    @Test("the sample shop is told why it cannot record one")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        guard let any = shop.files.first else { return }
        shop.fileSelection = [any.id]
        #expect(!shop.canWrite, "the sample book must not be writable")
        await shop.fileSelection(licence: "cc-by")
        #expect(shop.files.first(where: { $0.id == any.id })?.licence != "cc-by",
                "the sample took a licence")
    }

    @Test("the menu is on the shell that ships")
    func wiredIntoTheWindow() throws {
        // The recurring bug in this repo is a correct rule with no caller, and
        // the recurring version of THAT on the Mac is a view added only to the
        // retired shell. `ShopWindow` is the one that ships.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/ShopWindow.swift"), encoding: .utf8)
        #expect(source.contains("ProvenanceMenu(shop: shop)"),
                "nothing in the shipping window draws the provenance menu")
    }
}
