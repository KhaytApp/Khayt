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
}
