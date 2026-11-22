import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A model's licence, asked where the SALE is — and the proof behind a bought
/// licence, with the day it runs out.
///
/// `ModelLicence.saleProblems` and `expired` are held to the JavaScript by
/// `ModelLicenceParityTests`. This holds the Mac to asking them: the library
/// inspector knew a model was not for sale, and nothing stopped it being
/// printed, invoiced or put in the catalogue.
@MainActor
struct LicenceAtSaleTests {

    @Test("a proof that could never be clicked or never expire is refused, not written")
    func proofIsValidated() async {
        let shop = Shop()
        await shop.load(.sample)
        shop.setLicenceProof("F1", code: "PT-123", url: "javascript:alert(1)", expires: "")
        #expect(shop.writeProblem == shop.words.callIt("mac.licence_bad_link"))
        shop.writeProblem = nil
        shop.setLicenceProof("F1", code: "", url: "", expires: "2026-02-30")
        #expect(shop.writeProblem == shop.words.callIt("mac.licence_bad_date"), "Feb 30 was accepted")
        shop.writeProblem = nil
        shop.setLicenceProof("F1", code: "", url: "https://whale3dstudio.com/verify/x", expires: "2026-12-31")
        #expect(shop.writeProblem == nil)
    }

    @Test("a free NonCommercial model whose paid licence the shop bought is for sale")
    func boughtOverridesTheFreeLicence() {
        // Turki, Nov 2026: a free version not allowed to sell, and a special
        // commercial licence version. Recording the bought licence overrides.
        for free in ["cc-by-nc", "cc-by-nc-sa", "cc-by-nc-nd", "sdfl"] {
            var record: [String: JSONValue] = ["id": .string("M"), "name": .string("Dragon"), "licence": .string(free)]
            #expect(ModelLicence.saleProblems(["M"], records: [.object(record)], today: "2026-11-07").count == 1)
            Shop.applyLicenceProof(&record, code: "", url: "", expires: "")
            #expect(record["licence"] == .string("commercial"))
            #expect(ModelLicence.saleProblems(["M"], records: [.object(record)], today: "2026-11-07").isEmpty,
                    Comment(rawValue: "\(free) still not for sale after the licence was bought"))
            #expect(record["licenceCode"] == nil, "a blank code is not written")
        }
        // A bought licence with an end date lapses the day after, as before.
        var dated: [String: JSONValue] = ["id": .string("M"), "licence": .string("sdfl")]
        Shop.applyLicenceProof(&dated, code: "PT-1", url: "", expires: "2026-11-06")
        #expect(ModelLicence.saleProblems(["M"], records: [.object(dated)], today: "2026-11-07").first?.reason == "expired")
    }

    @Test("the warning offers the override where the sale is, and the library does too")
    func overrideIsReachable() {
        let warning = MenuCoverageTests.source("LicenceWarning.swift")
        #expect(warning.contains("\"mac.licence_have\""))
        #expect(warning.contains("LicenceProofSheet(shop: shop, file: $0)"))
        #expect(MenuCoverageTests.source("LibraryInspector.swift").contains("shop.words.callIt(\"mac.licence_have\")"))
    }

    @Test("the job and the product ask, and say so where the sale is")
    func askedAtTheSale() {
        #expect(MenuCoverageTests.source("OrderInspector.swift")
            .contains("let problems = shop.saleProblems(job.parts.compactMap(\\.printFileId))"))
        #expect(MenuCoverageTests.source("ProductSheet.swift")
            .contains("let problems = shop.saleProblems(parts.compactMap(\\.printFileId))"))
        for file in ["OrderInspector.swift", "ProductSheet.swift"] {
            #expect(MenuCoverageTests.source(file).contains("LicenceWarning(shop: shop, problems: problems)"),
                    Comment(rawValue: "\(file) computes the problems and never shows them"))
        }
        #expect(MenuCoverageTests.source("LibraryInspector.swift").contains("LicenceProofSheet(shop: shop, file: $0)"))
        #expect(MenuCoverageTests.source("Shop.swift")
            .contains("ModelLicence.saleProblems(printFileIds, records: libraryRows, today: Self.today())"))
    }

    @Test("a bought licence reads its last day as covered, and the next as not")
    func lastDay() {
        let r: JSONValue = .object(["licence": .string("commercial"), "licenceExpires": .string("2026-09-23")])
        #expect(ModelLicence.sellableOn(r, today: "2026-09-23") == true)
        #expect(ModelLicence.sellableOn(r, today: "2026-09-24") == false)
    }

    @Test("a designer's licence reaches their other models, never the shop's own or a stranger's")
    func sameDesigner() throws {
        func model(_ id: String, _ source: String, _ licence: String = "") throws -> LibraryFile {
            let row: JSONValue = .object(["id": .string(id), "name": .string(id), "title": .string(id),
                                          "source": .string(source), "licence": .string(licence)])
            return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(row))
        }
        let files = [try model("a", "Whale3D", "commercial"), try model("b", " whale3d ", "sdfl"),
                     try model("c", "Whale3D"), try model("d", "Whale3D", "own"),
                     try model("e", "Other"), try model("f", "https://makerworld.com/@whale3d")]
        #expect(Shop.sameDesigner(as: files[0], in: files).map(\.id) == ["b", "c"])
        #expect(Shop.sameDesigner(as: files[5], in: files).isEmpty, "an address is not a designer")
        #expect(MenuCoverageTests.source("LicenceProofSheet.swift")
            .contains("alsoFor: wholeCatalogue ? shop.sameDesigner(as: file).map(\\.id) : []"))
        // Widening makes NonCommercial models sellable, so it needs a code or
        // a page: the sheet will not offer it without one, the write refuses.
        #expect(MenuCoverageTests.source("LicenceProofSheet.swift").contains(".disabled(noProof)"))
        #expect(MenuCoverageTests.source("Shop+Library.swift")
            .contains("if !widened.isEmpty, code.isEmpty, url.isEmpty {"))
    }

    @Test("a remix of a model that may not be sold may not be sold either")
    func remixFollowsItsOriginal() throws {
        func model(_ id: String, licence: String = "", url: String = "", remixOf: String = "") throws -> LibraryFile {
            var row: [String: JSONValue] = ["id": .string(id), "name": .string(id), "title": .string(id),
                                            "licence": .string(licence)]
            if !url.isEmpty { row["sourceUrl"] = .string(url) }
            if !remixOf.isEmpty { row["remixOf"] = .string(remixOf) }
            return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(row)))
        }
        let files = [
            try model("nc", licence: "cc-by-nc", url: "https://www.printables.com/model/1"),
            try model("by", licence: "cc-by", url: "https://www.printables.com/model/2"),
            try model("r1", remixOf: "https://www.printables.com/model/1/"),        // of NC, says nothing
            try model("r2", licence: "commercial", remixOf: "https://www.printables.com/model/1"), // bought
            try model("r3", remixOf: "https://www.printables.com/model/2"),          // of BY
            try model("r4", remixOf: "https://example.com/not-in-library"),
            try model("r5", licence: "cc-by-nc", remixOf: "https://www.printables.com/model/1"), // its own problem
        ]
        let out = Shop.remixProblems(files.map(\.id), files: files, today: "2026-10-30")
        #expect(out.map(\.id) == ["r1"])
        #expect(out.first?.reason == "remix")
        #expect(out.first?.until == "nc")
    }
}

