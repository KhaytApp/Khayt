import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Whose name goes on a row of the accountant's file.
///
/// ── THE DIVERGENCE THIS SUITE EXISTS FOR ──────────────────────────────────
///
/// `invoiceCsv` promises, in its own comment, that "a quarter exported from
/// this Mac is the same set of rows, to the halalah, as the same quarter
/// exported from the other app". It was not, on one column.
///
/// `renderer/analytics.js` hands `lib/accounting-rows.js` a `localName`
/// resolved through `content-languages`. This app handed it nothing, so the
/// rule's fallback read `client.name` — a field Khayt writes on no customer —
/// and then fell back again to the name STAMPED ON THE ORDER, which is written
/// in English when the job is taken. A bilingual shop therefore exported the
/// same invoices under different names from the two apps.
@MainActor
struct AccountingNameTests {

    static let client = JSONValue.object([
        "id": .string("CLI-1"),
        "nameEn": .string("KAUST Prototyping Lab"),
        "nameAr": .string("مختبر النماذج — كاوست"),
    ])

    static func order(_ id: String) -> JSONValue {
        .object([
            "id": .string(id), "clientId": .string("CLI-1"),
            // Stamped in English when the job was taken — the value the export
            // used to fall through to.
            "client": .string("KAUST Prototyping Lab"),
            "date": .string("2026-08-01"), "price": .number(1000),
            "status": .string("completed"), "paymentStatus": .string("paid"),
        ])
    }

    static func settings(_ langs: [String]) -> [String: JSONValue] {
        ["currency": .string("SAR"), "taxMode": .string("none"),
         "contentLangs": .array(langs.map(JSONValue.string))]
    }

    @Test("an Arabic reader gets the customer's Arabic name, not the stamped English one")
    func arabicReaderGetsArabic() async throws {
        let engine = try KhaytEngine()
        let csv = try await engine.invoiceCsv(
            [Self.order("ORD-1")], settings: Self.settings(["ar", "en"]),
            clients: [Self.client], format: "generic", language: "ar")
        #expect(csv.contains("مختبر النماذج — كاوست"),
                "the export still carries the name stamped on the order")
        #expect(!csv.contains("KAUST Prototyping Lab"),
                "both names reached one row")
    }

    @Test("an English reader gets the English one")
    func englishReaderGetsEnglish() async throws {
        let engine = try KhaytEngine()
        let csv = try await engine.invoiceCsv(
            [Self.order("ORD-2")], settings: Self.settings(["en", "ar"]),
            clients: [Self.client], format: "generic", language: "en")
        #expect(csv.contains("KAUST Prototyping Lab"))
    }

    @Test("a shop writing neither still gets its own name on the row")
    func aGermanShop() async throws {
        // The case `nameEn || nameAr` cannot serve, and the reason the name is
        // resolved through the content-language rule rather than picked.
        let engine = try KhaytEngine()
        let german = JSONValue.object([
            "id": .string("CLI-1"), "name_de": .string("Muster Werkstatt"),
        ])
        let csv = try await engine.invoiceCsv(
            [Self.order("ORD-3")], settings: Self.settings(["de"]),
            clients: [german], format: "generic", language: "de")
        #expect(csv.contains("Muster Werkstatt"), "the row went out with a blank customer")
    }

    @Test("an order whose customer is gone keeps the name it was written with")
    func deletedCustomerKeepsTheStampedName() async throws {
        // The fallback the rule already had, and the reason it is worth
        // keeping: an invoice records who was billed, and a customer deleted
        // afterwards does not unbill them.
        let engine = try KhaytEngine()
        let csv = try await engine.invoiceCsv(
            [Self.order("ORD-4")], settings: Self.settings(["en"]),
            clients: [], format: "generic", language: "en")
        #expect(csv.contains("KAUST Prototyping Lab"))
    }

    @Test("the export asks for the reader's language rather than assuming one")
    func theCallSitePassesIt() throws {
        let shop = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        #expect(shop.contains("language: words.language"),
                "the accounting export picks a language of its own")
    }
}
