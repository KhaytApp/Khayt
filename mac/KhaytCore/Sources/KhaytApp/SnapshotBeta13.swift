import AppKit
import SwiftUI
import KhaytCore

/// ── THE BETA.13 SCREENS, ON THE SAMPLE, IN MEMORY ───────────────────────
///
/// The licence warning (a Standard Digital File License model, a remix of
/// one), the designer credit on a product, the proof sheet with "the whole
/// catalogue", the From-slicer inbox, and the customer sheet with payment
/// terms. The sample has no licences, no slicer uploads and no terms, so none
/// of it is reachable from the sample on its own.
///
/// Everything faked is in memory: a library handed to `pretendLibrary`,
/// uploads set on `slicerUploads`, a client built here. Nothing is written,
/// and the sample is loaded again at the end.
///
/// `KHAYT_SNAPSHOT_B13=1` runs only these, in whichever appearance and
/// language the run was started in.
extension Snapshot {

    static func captureBeta13(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        shop.pretendsWritable = true
        defer { shop.pretendsWritable = false; shop.slicerUploads = [] }
        await settle()

        let rtl = Direction.rtlLanguages.contains(shop.words.language)
        func shot(_ name: String, width: CGFloat, _ view: some View) {
            captureView(named: "beta13-\(name)\(tag)",
                        view.frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }

        // Three models by one designer, one of them CC BY with its page, one
        // a remix of a model sold under the Standard Digital File License.
        func row(_ id: String, _ name: String, _ fields: [String: JSONValue]) -> JSONValue {
            var r: [String: JSONValue] = ["id": .string(id), "name": .string(name),
                                          "fileName": .string(id + ".3mf")]
            for (k, v) in fields { r[k] = v }
            return .object(r)
        }
        let rows: [JSONValue] = [
            row("PF-b13-owl", "Articulated owl", ["source": .string("Hana Prints"), "licence": .string("cc-by"),
                                                  "sourceUrl": .string("https://www.printables.com/model/101-owl")]),
            row("PF-b13-fox", "Sleeping fox", ["source": .string("Hana Prints"), "licence": .string("sdfl")]),
            row("PF-b13-cat", "Cat planter", ["source": .string("Hana Prints")]),
            row("PF-b13-fox-remix", "Sleeping fox, hollow", ["remixOf": .string("Sleeping fox")]),
        ]
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        await settle()

        let problems = [
            ModelLicence.SaleProblem(id: "PF-b13-fox", name: "Sleeping fox", licence: "sdfl",
                                     reason: "not-commercial", until: ""),
            ModelLicence.SaleProblem(id: "PF-b13-fox-remix", name: "Sleeping fox, hollow", licence: "",
                                     reason: "remix", until: "Sleeping fox"),
        ]
        shot("1-licence-warning", width: 560, LicenceWarning(shop: shop, problems: problems).padding(18))
        shot("2-credits", width: 560,
             LicenceCredits(shop: shop, credits: shop.licenceCredits(["PF-b13-owl"]),
                            written: "", add: { _ in }).padding(18))
        if let owl = shop.files.first(where: { $0.id == "PF-b13-owl" }) {
            shot("3-proof-sheet", width: SheetMetrics.outerWidth(480), LicenceProofSheet(shop: shop, file: owl))
        }

        // Two uploads waiting: one with the slicer's figures, one a binary
        // G-code that carries none.
        let now = Date()
        shop.slicerUploads = [
            SlicerUpload(id: "su-1", name: "Benchy_PETG.gcode", arrived: now.addingTimeInterval(-600),
                         bytes: 2_400_000, grams: 37.25, minutes: 125, material: "PETG", slicer: "OrcaSlicer"),
            SlicerUpload(id: "su-2", name: "Lantern_PLA.bgcode", arrived: now.addingTimeInterval(-60),
                         bytes: 9_800_000, grams: nil, minutes: nil, material: nil, slicer: nil),
        ]
        await settle()
        shot("4-slicer-inbox", width: SheetMetrics.outerWidth(520), SlicerInboxSheet(shop: shop))
        shop.slicerUploads = []
        shot("5-slicer-inbox-empty", width: SheetMetrics.outerWidth(520), SlicerInboxSheet(shop: shop))

        let client = Client(id: "CL-b13", nameEn: "Riyadh Dental Lab", nameAr: "مختبر الرياض لطب الأسنان",
                            phone: "+966500000000", paymentTermsDays: 30)
        shot("6-customer-terms", width: SheetMetrics.outerWidth(CustomerSheet.width),
             CustomerSheet(shop: shop, existing: client))

        await shop.load(.sample)
        await settle()
    }
}
