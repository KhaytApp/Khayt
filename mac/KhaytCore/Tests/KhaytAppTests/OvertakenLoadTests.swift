import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Two loads in flight, the older one finishing last.
///
/// The library already survived this (`LibraryEditPerfTests`'s
/// `olderReloadFinishingLast`); everything else did not. The older load went
/// on through every await after the newer one had put its book up, and set
/// what it found in ITS book — the print log, the customers, every model's
/// fit and licence — over the newer one's.
///
/// In `LibraryEditPerfTests` — declared `@Suite(.serialized)` — the one suite
/// that may set the test support folder and the load hooks (both globals).
extension LibraryEditPerfTests {

    @Test("an overtaken reload puts none of the older book's jobs, customers or figures back")
    func overtakenLoadPutsNothingBack() async throws {
        try await withPerfBook(FiguresBook.synthesize(models: 40, logo: false)) { shop, url in
            let model = try #require(shop.files.first { file in
                guard let mesh = file.mesh else { return false }
                let small = mesh.x < 190 && mesh.y < 190 && mesh.z < 260
                return mesh.volumeMm3 > 0 && small && file.licence == nil && file.source == nil
            })
            #expect(shop.fits[model.id]?.verdict == "fits")
            #expect(shop.licences[model.id] == nil)
            let jobsBefore = shop.orderRows.count
            Shop.whileLoadingForTests = {
                Shop.whileLoadingForTests = nil
                // The book moves on — a job, a customer, and the model now
                // licensed NonCommercial and too big for every bed — and a
                // newer load reads it and puts it all up.
                try? StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                    var jobs = Shop.rows(root, "printLog")
                    if case .object(var job)? = jobs.first {
                        job["id"] = .string("ORD-newer")
                        job["project"] = .string("Newer job")
                        jobs.append(.object(job))
                    }
                    root["printLog"] = .array(jobs)
                    var people = Shop.rows(root, "clients")
                    people.append(.object(["id": .string("CL-newer"), "name": .string("Newer customer")]))
                    root["clients"] = .array(people)
                    var rows = Shop.rows(root, "printFiles")
                    for i in rows.indices {
                        guard case .object(var record) = rows[i], Shop.recordId(rows[i]) == model.id else { continue }
                        record["licence"] = .string("cc-by-nc")
                        record["geometryKey"] = .string("4000:9000000:600x500x400")
                        rows[i] = .object(record)
                    }
                    root["printFiles"] = .array(rows)
                }
                await shop.load(shop.source)
            }
            // The older load: overtaken at its hook, it must stop there.
            await shop.load(shop.source)
            Shop.whileLoadingForTests = nil
            #expect(shop.orderRows.count == jobsBefore + 1, "the older print log was put back")
            let hasNewer = shop.clients.contains { $0.id == "CL-newer" }
            #expect(hasNewer, "the older customers were put back")
            #expect(shop.licences[model.id]?.sellable == false, "the older licence was put back")
            #expect(shop.fits[model.id]?.verdict == "none", "the older fit was put back")
            #expect(shop.estimates[model.id]?.grams != nil)
        }
    }
}
