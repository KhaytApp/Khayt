import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `licenceNote` is written on Windows/Linux; the Mac does not show it yet.
/// A Mac edit to the same model (its licence, its name) patches the raw record,
/// so the note must come through it byte for byte, or a Mac save would wipe
/// the terms a shop wrote down on the PC.
extension LibraryEditPerfTests {

    @Test("a Mac licence change and rename keep the desktop's licence note")
    func licenceNoteSurvivesMacEdits() async throws {
        let note = "  Sell up to 50 prints a year — مع ذكر المصمم.  "
        var root = FiguresBook.synthesize(models: 4, logo: false)
        guard case .array(var rows)? = root["printFiles"], case .object(var first)? = rows.first else {
            Issue.record("the synthetic book has no models"); return
        }
        first["licence"] = .string("custom")
        first["licenceNote"] = .string(note)
        rows[0] = .object(first)
        root["printFiles"] = .array(rows)
        let id = try #require(Shop.recordId(.object(first)))
        try await withPerfBook(root) { shop, url in
            shop.fileSelection = [id]
            await shop.fileSelection(licence: "cc-by")
            await shop.settleLibraryWrites()
            #expect(shop.rename(id, to: "Renamed on the Mac"))
            await shop.settleLibraryWrites()
            let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            guard case .object(let book) = saved, case .array(let files)? = book["printFiles"],
                  case .object(let record)? = files.first(where: { Shop.recordId($0) == id }) else {
                Issue.record("the model is gone from the saved book"); return
            }
            #expect(record["licence"] == .string("cc-by"), "the Mac's own edit did not land")
            #expect(record["licenceNote"] == .string(note), "a Mac save changed or dropped the licence note")
        }
    }
}
