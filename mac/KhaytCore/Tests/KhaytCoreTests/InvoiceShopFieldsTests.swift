import Testing
import Foundation
@testable import KhaytCore

/// What the invoice says about the shop that is sending it.
///
/// The document asks its host for four fields — `biz`, `addr`, `tagline` and
/// `footer`. This app answered two of them and returned the shop's NAME for the
/// other two, so every invoice printed the name twice at the top and again in
/// the footer, and the tagline typed into Settings had never once appeared on a
/// document. Nothing failed and nothing was blank; it looked like a design.
struct InvoiceShopFieldsTests {

    static func settings() -> [String: JSONValue] {
        [
            "bizEn": .string("Tuwaiq Additive"),
            "bizAr": .string("تويق أدتف"),
            "taglineEn": .string("Precision 3D printing in Riyadh"),
            "addrEn": .string("Riyadh"),
            "footerEn": .string("Thank you for your business."),
            "currency": .string("SAR"),
            "vatEnabled": .bool(false),
        ]
    }

    static func order() -> JSONValue {
        .object([
            "id": .string("ORD-01000"),
            "project": .string("Turbine bracket"),
            "price": .number(560.51),
            "date": .string("2026-07-02"),
            "status": .string("completed"),
        ])
    }

    static func fields() -> [String: JSONValue] {
        ["biz": .string("Tuwaiq Additive"), "addr": .string("Riyadh"),
         "tagline": .string("Precision 3D printing in Riyadh"),
         "footer": .string("Thank you for your business.")]
    }

    static func html(_ sellerFields: [String: JSONValue]) async throws -> String {
        let engine = try KhaytEngine()
        let doc = try await engine.invoiceHtml(
            order: order(), settings: settings(), clients: [],
            currencies: ["SAR": .object(["code": .string("SAR"), "symbol": .string("﷼"),
                                         "decimals": .number(2)])],
            language: "en",
            money: ["total": .string("560.51"), "subtotal": .string("560.51"),
                    "subtotalShown": .string("560.51"), "vatAmount": .string("0.00"),
                    "vatRate": .number(0), "shipping": .number(0),
                    "payQrSvg": .string("")],
            sellerFields: sellerFields)
        return doc.html
    }

    @Test func theTaglinePrintsTheTagline() async throws {
        let out = try await Self.html(Self.fields())
        #expect(out.contains("Precision 3D printing in Riyadh"),
                "the shop's tagline is not on its own invoice")
    }

    @Test func theFooterPrintsTheFooter() async throws {
        let out = try await Self.html(Self.fields())
        #expect(out.contains("Thank you for your business."))
    }

    /// THE ONE THAT WOULD HAVE CAUGHT IT. The name belongs at the top, once.
    /// Finding it three times is the old behaviour: name, name-as-tagline, and
    /// name-as-footer.
    @Test func theNameIsNotPrintedWhereOtherFieldsBelong() async throws {
        let out = try await Self.html(Self.fields())
        let times = out.components(separatedBy: "Tuwaiq Additive").count - 1
        #expect(times <= 2, "the shop's name appears \(times) times — it is standing in for another field")
    }

    /// A field the shop has not filled in prints NOTHING. Falling back to the
    /// name is how this started.
    @Test func anEmptyFieldIsEmptyRatherThanTheName() async throws {
        var bare = Self.fields()
        bare["tagline"] = .string("")
        bare["footer"] = .string("")
        let out = try await Self.html(bare)
        #expect(!out.contains("Precision 3D printing"))
        let times = out.components(separatedBy: "Tuwaiq Additive").count - 1
        #expect(times <= 2, "an unfilled field fell back to the shop's name")
    }
}
