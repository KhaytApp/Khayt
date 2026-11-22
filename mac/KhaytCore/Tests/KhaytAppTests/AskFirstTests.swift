import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Every removal a shop can reach from a screen is ASKED first.
///
/// ── WHY A SOURCE GUARD ────────────────────────────────────────────────────
///
/// A SwiftUI body cannot be instantiated and asked what a button does, and the
/// failure being guarded is exactly one line long: `Task { await
/// shop.deleteWaste(id) }` straight inside a context-menu item. Until Oct 2026
/// a waste entry, a maintenance task, a spool, a consumable, a supplier, a
/// message template, a line of a customer's log, what a customer paid, a
/// payment plan, the shop's logo and a linked library folder all went in one
/// click — several with no undo.
///
/// So the rule is read off the source: every call of a removing `Shop` method
/// in a view must sit inside a confirmation — an `askFirst` or a
/// `confirmationDialog` opened a few lines above it. A new delete button that
/// calls one directly fails here, naming the file and line.
@MainActor
struct AskFirstTests {

    static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/KhaytApp")

    static func source(_ name: String) -> String {
        (try? String(contentsOf: sources.appending(path: name), encoding: .utf8)) ?? ""
    }

    /// The `Shop` methods that take something away from the book.
    static let removing = try! Regex(
        #"shop\.(delete[A-Za-z]*|clearPayment|dropPlan|removeCommunication|unlinkFolder|clearLogo|disbandKit)\(|shop\.recordStockCount\(nil"#)

    /// How far above a call its confirmation may open. The longest today is
    /// the product delete in `Catalogue`, whose dialog has a guard and a
    /// selection reset between the title and the call.
    static let window = 14

    /// Not a view: the removing methods are defined here.
    static let exempt: Set<String> = ["Shop.swift"]

    @Test("no view calls a removing Shop method outside a confirmation")
    func everyRemovalAsks() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path)
            .filter { $0.hasSuffix(".swift") && !Self.exempt.contains($0) }
        #expect(files.count > 100, "read the sources: \(Self.sources.path)")
        var unasked: [String] = []
        for file in files.sorted() {
            let lines = Self.source(file).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///"),
                      line.contains(Self.removing) else { continue }
                let above = lines[max(0, i - Self.window)...i].joined(separator: "\n")
                if !above.contains("askFirst(") && !above.contains("confirmationDialog(") {
                    unasked.append("\(file):\(i + 1): \(code)")
                }
            }
        }
        #expect(unasked.isEmpty, "removed in one click:\n\(unasked.joined(separator: "\n"))")
    }

    /// The fixed sites, by name — so the general rule above cannot pass by a
    /// site quietly losing its button altogether.
    @Test("each fixed site still offers its removal, behind a question",
          arguments: [
            ("Spending.swift", "shop.deleteWaste("),
            ("ShopFloor.swift", "shop.deleteMaintenanceTask("),
            ("ShopFloor.swift", "shop.deleteSpool("),
            ("ShopFloor.swift", "shop.deleteConsumable("),
            ("SpoolSheet.swift", "shop.deleteSpool("),
            ("ConsumableSheet.swift", "shop.deleteConsumable("),
            ("PaymentSheet.swift", "shop.clearPayment("),
            ("PaymentPlanSheet.swift", "shop.dropPlan("),
            ("SupplierSheet.swift", "shop.deleteSupplier("),
            ("TemplateSheet.swift", "shop.deleteTemplate("),
            ("CustomersTable.swift", "shop.removeCommunication("),
            ("SettingsWindow.swift", "shop.clearLogo("),
            ("LibraryLocationSettings.swift", "shop.unlinkFolder("),
            ("Catalogue.swift", "shop.recordStockCount(nil"),
          ])
    func fixedSite(file: String, call: String) {
        let text = Self.source(file)
        #expect(text.contains(call), "\(file) no longer calls \(call)")
        #expect(text.contains("askFirst(") || text.contains("confirmationDialog("))
    }

    /// The button that opens a question says so: "Delete…", not "Delete".
    @Test("a button that asks first ends in an ellipsis")
    func ellipsis() {
        for file in ["Spending.swift", "SpoolSheet.swift", "ConsumableSheet.swift",
                     "TemplateSheet.swift", "PaymentSheet.swift", "PaymentPlanSheet.swift"] {
            #expect(Self.source(file).contains("+ \"\\u{2026}\", role: .destructive"),
                    "\(file)")
        }
    }

    // ── THE PRICE OF ZERO ────────────────────────────────────────────────

    static func pricing(_ price: Double) throws -> KhaytEngine.ProductPricing {
        let json = """
        {"cost":0,"basePrice":\(price),"price":\(price),"priceSource":"base",
         "parts":1,"hours":0,"grams":0}
        """
        return try JSONDecoder().decode(KhaytEngine.ProductPricing.self, from: Data(json.utf8))
    }

    @Test("Save at a price of zero is asked about; any real price is not")
    func zeroPriceAsks() throws {
        #expect(ProductSheet.savesAtZero(try Self.pricing(0)))
        #expect(ProductSheet.savesAtZero(try Self.pricing(0.001)))
        #expect(!ProductSheet.savesAtZero(try Self.pricing(13.74)))
        #expect(!ProductSheet.savesAtZero(try Self.pricing(0.01)))
        // Not priced yet is not zero — the sheet has not heard back.
        #expect(!ProductSheet.savesAtZero(nil))
    }

    @Test("the zero-price question says what price it replaces")
    func storedPrice() {
        func product(_ price: JSONValue?) -> Product {
            var record: [String: JSONValue] = ["id": .string("P1"), "nameEn": .string("Dragon")]
            if let price { record["price"] = price }
            return Product.from(record, keys: [])
        }
        #expect(ProductSheet.storedPrice(product(.number(50))) == 50)
        #expect(ProductSheet.storedPrice(product(.string("104.98"))) == 104.98)
        #expect(ProductSheet.storedPrice(product(nil)) == nil)
    }

    @Test("Save in the product sheet goes through the zero check")
    func saveIsGated() {
        let text = Self.source("ProductSheet.swift")
        #expect(text.contains("if Self.savesAtZero(pricing) { askingZero = true } else { save() }"))
        #expect(text.contains("mac.save_zero_q"))
    }

    // ── THE WORDS ────────────────────────────────────────────────────────

    @Test("every new question has English and Arabic",
          arguments: ["mac.no_undo", "mac.undo_after", "mac.clear_payment_q",
                      "mac.clear_payment_note", "mac.remove_plan_q", "mac.remove_plan_note",
                      "mac.save_zero_q", "mac.save_zero_note", "mac.save_zero_new",
                      "mac.save_zero_do", "mac.not_stocked_q", "mac.not_stocked_note",
                      "mac.remove_logo_q", "mac.remove_logo_note",
                      "mac.unlink_folder_q", "mac.unlink_folder_note"])
    func translated(key: String) {
        let entry = Words.own[key]
        #expect(entry?["en"]?.isEmpty == false, "\(key) en")
        #expect(entry?["ar"]?.isEmpty == false, "\(key) ar")
        #expect(entry?["ar"] != entry?["en"], "\(key) ar is English")
    }

    @Test("a spool and a waste entry are named as their screens name them")
    func names() {
        let words = Words()
        #expect(AskName.waste(Self.waste(), words: words).hasPrefix("2026-09-14 · PETG · "))
    }

    static func waste() -> WasteEntry {
        let json = """
        {"id":"W1","date":"2026-09-14","material":"PETG","failureType":"warping",
         "weight":180,"cost":12,"reason":"","notes":""}
        """
        return try! JSONDecoder().decode(WasteEntry.self, from: Data(json.utf8))
    }
}
