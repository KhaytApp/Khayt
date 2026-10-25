import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The beta.7 UI review: Arabic counts, isolated plan lines, one word for a
/// model, and slicer default names said in the shop's language.
@MainActor
@Suite struct Beta7UIFixTests {

    @Test("the library count is grammatical Arabic for 0, 1, 2, 3–10 and 11 and over")
    func modelCount() async throws {
        let ar = try await ArabicDualTests.words("ar")
        #expect(ar.counting(0, "mac.n_models") == "لا نماذج")
        #expect(ar.counting(1, "mac.n_models") == "نموذج واحد")
        #expect(ar.counting(2, "mac.n_models") == "نموذجان")
        #expect(ar.counting(5, "mac.n_models").hasSuffix(" نماذج"))
        #expect(ar.counting(18, "mac.n_models").hasSuffix(" نموذجًا"), "18 نماذج was the review's finding")
        let en = try await ArabicDualTests.words("en")
        #expect(en.counting(18, "mac.n_models") == "18 models")
        #expect(en.counting(1, "mac.n_models") == "1 model")
    }

    @Test("each part of a plan line is isolated, so a Latin GB cannot take the next figure")
    func planLineIsolated() async throws {
        let ar = try await ArabicDualTests.words("ar")
        let json = #"{"name":"maker","label":"Maker","limits":{"maxVaultBytes":53687091200,"maxActiveLinks":50,"maxSeats":3}}"#
        let plan = try JSONDecoder().decode(CloudPlans.Plan.self, from: Data(json.utf8))
        let line = CloudPlanSettings.gives(plan, ar)
        let parts = line.components(separatedBy: " · ")
        #expect(parts.count == 3)
        for part in parts {
            #expect(part.hasPrefix("\u{2068}") && part.hasSuffix("\u{2069}"), "unisolated: \(part)")
        }
        #expect(ar.counting(5, "mac.plan_links").contains("روابط"))
        #expect(ar.counting(1, "mac.plan_links") == "رابط مشاركة واحد")
    }

    @Test("Free is said in the shop's language; a brand name is kept and isolated")
    func planNames() async throws {
        let ar = try await ArabicDualTests.words("ar")
        #expect(CloudPlanSettings.planName("free", "Free", ar) == "المجانية")
        #expect(CloudPlanSettings.planName("maker", "Maker", ar) == "\u{2068}Maker\u{2069}")
    }

    @Test("a slicer's default filament name is said in the shop's words; a chosen one is kept")
    func slicerDefaults() async throws {
        let ar = try await ArabicDualTests.words("ar")
        #expect(LibraryInspector.slicerDefaultNumber("Filament 3") == 3)
        #expect(LibraryInspector.slicerDefaultNumber("Extruder 2") == 2)
        #expect(LibraryInspector.slicerDefaultNumber("T1") == 1)
        #expect(LibraryInspector.slicerDefaultNumber("Galaxy Black") == nil)
        #expect(LibraryInspector.colourLabel("Filament 1", index: 0, words: ar).hasPrefix("الخيط"))
        #expect(LibraryInspector.colourLabel("Galaxy Black", index: 0, words: ar) == "Galaxy Black")
        #expect(LibraryInspector.colourLabel(nil, index: 1, words: ar).hasPrefix("الخيط"))
    }

    @Test("one Arabic word for a library model: مجسّم only for the mesh and objects on the plate")
    func oneWordForModel() {
        let meshKeys: Set<String> = ["mac.mesh", "risk.looking", "risk.look", "risk.not_looked",
                                     "set.risk_hint", "risk.unreadable", "mac.drop_object", "mac.drop_unsupported"]
        for (key, langs) in Words.own where !meshKeys.contains(key) {
            let ar = langs["ar"] ?? ""
            #expect(!ar.contains("مجسم") && !ar.contains("مجسّم"), "\(key) says مجسّم for a model: \(ar)")
        }
    }

    @Test("Print next is «التالي للطباعة», never «للطباعة لاحقًا» (print later)")
    func printNext() {
        for (key, langs) in Words.own {
            #expect(!(langs["ar"] ?? "").contains("لاحقًا: لأجل") && langs["ar"] != "للطباعة لاحقًا", "\(key)")
        }
        #expect(Words.own["mac.print_next"]?["ar"] == "التالي للطباعة")
    }
}
