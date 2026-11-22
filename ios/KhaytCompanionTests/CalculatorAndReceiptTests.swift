import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The phone's calculator and receipt scanner (Oct 2026): both work out their
/// answers from the book through the shop's own rules, so these hold the
/// phone to the same figures the rules give — and to moving when an input does.
@MainActor
final class CalculatorAndReceiptTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!
    private var writer: BookWriter!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "calc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
        writer = BookWriter(book: book)
        try book.replace(with: SampleShop.book(), scope: SampleShop.scope())
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Calculator

    func testTheShelfReadsTheBooksSpellings() throws {
        let shelf = CalculatorShelf.from(SampleShop.book(), reclaimsTax: false)
        let pla = try XCTUnwrap(shelf.spools.first { $0.id == "SP-203" })
        XCTAssertEqual(pla.costing.cost, 29.99)
        XCTAssertEqual(pla.costing.spoolWeight, 1000, "weightTotal is the wire's name for spoolWeight")
        XCTAssertEqual(pla.costing.material, "PLA")
        XCTAssertEqual(shelf.presets.map(\.id), ["PR-1"])
        XCTAssertEqual(shelf.consumables.count, 2)
        XCTAssertEqual(shelf.currency, "USD")
    }

    func testAShopThatReclaimsTaxCostsSpoolsWithoutIt() async throws {
        var store = SampleShop.book()
        let roll: JSONValue = .object(["id": .string("SP-VAT"), "material": .string("PLA"), "cost": .number(115),
                                       "vatAmount": .number(15), "spoolWeight": .number(1000)])
        if case .array(var inventory)? = store["inventory"] { inventory.append(roll); store["inventory"] = .array(inventory) }
        func cost(_ shelf: CalculatorShelf) -> Double? { shelf.spools.first { $0.id == "SP-VAT" }?.costing.cost }

        XCTAssertEqual(cost(CalculatorShelf.from(store, reclaimsTax: true)), 100, "200 g of it is 20.00, not 23.00")
        XCTAssertEqual(cost(CalculatorShelf.from(store, reclaimsTax: false)), 115, "a shop that reclaims nothing pays it all")

        // Read from the book: the shop's own VAT setting decides.
        guard case .object(var settings)? = store["settings"] else { return XCTFail("sample shape") }
        settings["enableVat"] = .bool(true); settings["vatRate"] = .number(15)
        store["settings"] = .object(settings)
        try book.replace(with: store, scope: SampleShop.scope())
        let registered = try await reader.calculatorShelf()
        XCTAssertEqual(cost(registered), 100)
        settings["enableVat"] = .bool(false)
        store["settings"] = .object(settings)
        try book.replace(with: store, scope: SampleShop.scope())
        let unregistered = try await reader.calculatorShelf()
        XCTAssertEqual(cost(unregistered), 115)
    }

    func testThePriceIsTheSharedRulesAnswer() async throws {
        let calc = PhoneCalculator()
        await calc.load(reader)
        calc.lines[0].spoolId = "SP-203"
        calc.lines[0].grams = "120"
        calc.hours = "4"
        await calc.recompute(reader)
        let answer = try XCTUnwrap(calc.answer)

        // The same part, priced by calling the engine directly.
        let engine = try KhaytEngine()
        let store = SampleShop.book()
        guard case .object(let settings)? = store["settings"], case .array(let inventory)? = store["inventory"],
              case .array(let presets)? = store["printers"] else { return XCTFail("sample shape") }
        let part = CalculatorPart.input(lines: [.init(spool: CalculatorShelf.from(store, reclaimsTax: false).spools.first { $0.id == "SP-203" }?.costing,
                                                      grams: 120)], purge: 0, hours: 4, qty: 1)
        let costed = try await engine.costPart(part, inventory: inventory, settings: settings, preset: presets.first)
        XCTAssertEqual(answer.costed.cost, costed.cost, accuracy: 0.0001)
        let quoted = try await engine.quoteTotal(CalculatorPart.quoteInput(baseCost: costed.cost, margin: 30,
                                                                          discountPct: 0, rush: false, settings: settings))
        XCTAssertEqual(answer.quoted.total, quoted.total, accuracy: 0.0001)
        XCTAssertGreaterThan(answer.costed.parts.material, 0, "the spool's price reached the cost")
    }

    func testEveryInputMovesTheTotal() async throws {
        let calc = PhoneCalculator()
        await calc.load(reader)
        calc.lines[0].grams = "100"
        calc.hours = "3"
        await calc.recompute(reader)
        var last = try XCTUnwrap(calc.answer?.quoted.total)
        func moved(_ what: String, _ change: () -> Void) async throws {
            change()
            await calc.recompute(reader)
            let now = try XCTUnwrap(calc.answer?.quoted.total)
            XCTAssertNotEqual(now, last, "\(what) did not move the total")
            last = now
        }
        try await moved("grams") { calc.lines[0].grams = "150" }
        try await moved("hours") { calc.hours = "5" }
        try await moved("labour rate typed over the preset") { calc.rates["laborRate"] = "60" }
        try await moved("margin") { calc.margin = 80 }
        try await moved("discount") { calc.discount = 10 }
        try await moved("rush") { calc.rush = true }
        try await moved("quantity") { calc.qty = 4 }
        try await moved("a magnet") { calc.addPiece() }
        XCTAssertTrue(calc.ratesEdited)
        calc.resetRates()
        XCTAssertFalse(calc.ratesEdited)
    }

    /// The shop's fixed costs by the print hour (#1875): off, the price is
    /// what it always was; on, the phone charges what the Mac's calculator
    /// charges — `lib/overhead-rate.js` through the engine, on every piece's
    /// hours — and "You keep" leaves the rent out.
    func testOverheadPerPrintHourIsTheMacsWhenOnAndNothingWhenOff() async throws {
        func price() async throws -> CalculatorAnswer {
            let calc = PhoneCalculator()
            await calc.load(reader)
            calc.lines[0].spoolId = "SP-203"
            calc.lines[0].grams = "120"
            calc.hours = "4"
            calc.qty = 3
            await calc.recompute(reader)
            return try XCTUnwrap(calc.answer)
        }
        func shop(enabled: Bool) throws {
            var store = SampleShop.book()
            guard case .object(var settings)? = store["settings"] else { return XCTFail("sample shape") }
            settings["fixedCosts"] = .array([
                .object(["id": .string("fc1"), "name": .string("Rent"), "amount": .number(2000)]),
                .object(["id": .string("fc2"), "name": .string("Internet"), "amount": .number(400)]),
                .object(["id": .string("fc3"), "name": .string("Salaries"), "amount": .number(9000)]),
            ])
            settings["overheadPerHour"] = .object(["enabled": .bool(enabled), "monthlyHours": .number(200)])
            store["settings"] = .object(settings)
            try book.replace(with: store, scope: SampleShop.scope())
        }

        let plain = try await price()
        try shop(enabled: false)
        let off = try await price()
        XCTAssertEqual(off.overhead, 0)
        XCTAssertEqual(off.quoted.total, plain.quoted.total, "off changes nothing, to the digit")

        try shop(enabled: true)
        let on = try await price()
        // Rent + internet over 200 h (pay is labour's line, left out) = 12/h,
        // on 4 h × 3 pieces.
        XCTAssertEqual(on.overhead, 144, accuracy: 0.0001)
        XCTAssertEqual(on.cost, off.cost, accuracy: 0.0001, "the part's own cost is untouched")
        XCTAssertGreaterThan(on.quoted.total, off.quoted.total)
        XCTAssertEqual(on.keeps, on.quoted.subtotal - on.cost - 144, accuracy: 0.0001)

        // What the Mac's preview sends for the same cart.
        guard case .object(let settings)? = try book.read()["settings"] else { return XCTFail("settings") }
        let engine = try KhaytEngine()
        var input = CalculatorPart.quoteInput(baseCost: on.cost, margin: 30, discountPct: 0,
                                              rush: false, settings: settings)
        input["overheadPerHour"] = .number(12)
        input["printHours"] = .number(12)
        let mac = try await engine.quoteTotal(input)
        XCTAssertEqual(on.quoted.total, mac.total, accuracy: 0.0001)
    }

    func testASecondColourSplitsTheWeightRatherThanAddingToIt() async throws {
        let calc = PhoneCalculator()
        await calc.load(reader)
        calc.lines[0].grams = "80"
        calc.addColour()
        XCTAssertEqual(calc.lines.count, 2)
        XCTAssertEqual(calc.gramsValue, 80, accuracy: 0.001)
        XCTAssertNotEqual(calc.lines[0].spoolId, calc.lines[1].spoolId)
    }

    func testDigitsTypedInArabicOrWithACommaAreRead() {
        XCTAssertEqual(PhoneCalculator.number("١٢٫٥"), 12.5)
        XCTAssertEqual(PhoneCalculator.number("12,5"), 12.5)
        XCTAssertEqual(PhoneCalculator.number("abc"), 0)
        XCTAssertEqual(PhoneCalculator.number("-4"), 0)
    }

    // MARK: - Receipt QR

    /// A ZATCA TLV, as a seller's till prints it.
    private func zatca(seller: String, vat: String, time: String, total: String, tax: String) -> String {
        var bytes: [UInt8] = []
        for (tag, value) in [(1, seller), (2, vat), (3, time), (4, total), (5, tax)] {
            let v = Array(value.utf8)
            bytes += [UInt8(tag), UInt8(v.count)] + v
        }
        return Data(bytes).base64EncodedString()
    }

    func testAReceiptBecomesAnExpenseToCheck() async throws {
        let code = zatca(seller: "Filament House", vat: "300000000000003",
                         time: "2026-09-21T10:15:00Z", total: "115.00", tax: "15.00")
        guard case .draft(let d) = try await reader.readReceipt(code) else { return XCTFail("not read") }
        XCTAssertEqual(d.draft.amount, 115)
        XCTAssertEqual(d.vatNumber, "300000000000003")
        XCTAssertNil(d.duplicateOf)
        XCTAssertNotNil(d.newSupplier, "the sample shop has no such supplier")

        // Filed from the phone, the record carries what the duplicate check needs.
        let made = try writer.addExpense(ExpenseDraft(amount: d.draft.amount, category: "filament",
                                                      note: "x", receiptBase64: nil, vatAmount: 15,
                                                      date: d.draft.date, receiptRef: d.draft.receiptRef))
        XCTAssertEqual(made["receiptRef"], .string(d.draft.receiptRef))
        XCTAssertEqual(made["vatAmount"], .number(15))
        XCTAssertEqual(made["date"], .string(d.draft.date))

        // And the same receipt scanned again is caught.
        guard case .draft(let again) = try await reader.readReceipt(code) else { return XCTFail("not read") }
        XCTAssertEqual(again.duplicateOf, made["id"].flatMap { if case .string(let s) = $0 { s } else { nil } })
    }

    /// "Add as supplier" writes the row the Mac and the other app write, the
    /// next read names it, and a second tap adds nothing.
    func testASellerKeptAsASupplierMatchesTheNextReceipt() async throws {
        let code = zatca(seller: "مؤسسة الخيوط", vat: "311111111111113",
                         time: "2026-09-21T10:15:00Z", total: "57.50", tax: "7.50")
        guard case .draft(let d) = try await reader.readReceipt(code),
              let seller = d.newSupplier else { return XCTFail("not read as a new seller") }

        let row = try XCTUnwrap(try writer.addSupplier(name: seller.name, vatNumber: "٣١١١١١١١١١١١١١٣"))
        XCTAssertEqual(row["vat"], .string("311111111111113"), "Arabic digits are kept as Western ones")
        XCTAssertEqual(row["name"], .string("مؤسسة الخيوط"))
        XCTAssertEqual(row["purchases"], .array([]), "every reader walks this unchecked")
        XCTAssertEqual(row["leadDays"], .null)
        XCTAssertEqual(row["category"], .string("other"))
        let stored = try book.read()
        guard case .array(let suppliers)? = stored["suppliers"],
              case .object(let saved)? = suppliers.last else { return XCTFail("no suppliers") }
        XCTAssertNotNil(saved["updatedAt"], "stamped, so the change is sent on")

        guard case .draft(let again) = try await reader.readReceipt(code) else { return XCTFail("not read") }
        XCTAssertNil(again.newSupplier)
        XCTAssertEqual(again.supplier?.name, "مؤسسة الخيوط")

        XCTAssertNil(try writer.addSupplier(name: "Again", vatNumber: "311111111111113"), "one row per number")
        guard case .array(let after)? = try book.read()["suppliers"] else { return XCTFail("no suppliers") }
        XCTAssertEqual(after.count, suppliers.count)
    }

    func testACodeThatIsNotAReceiptSaysWhy() async throws {
        let reading = try await reader.readReceipt("https://example.com/pay")
        guard case .refused(let why) = reading else { return XCTFail("read a link as a receipt") }
        XCTAssertFalse(L10n.tr("exp.qr.reason.\(why)").hasPrefix("exp.qr."), "\(why) has no words")
    }

    func testEveryReasonTheRuleGivesHasWordsInBothLanguages() throws {
        let reasons = ["empty", "too_long", "not_base64", "truncated", "bad_tag", "not_utf8", "missing_tag",
                       "bad_vat_number", "bad_amount", "vat_over_total", "bad_timestamp"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for lang in ["en", "ar"] {
            let url = root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for r in reasons { XCTAssertNotNil(table["exp.qr.reason.\(r)"], "\(lang): \(r)") }
        }
        // And the rule gives no reason this list does not know.
        let js = try String(contentsOf: root.deletingLastPathComponent().appending(path: "lib/zatca-qr.js"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"reason: '([a-z_0-9]+)'"#)
        let found = Set(regex.matches(in: js, range: NSRange(js.startIndex..., in: js)).compactMap {
            Range($0.range(at: 1), in: js).map { String(js[$0]) }
        })
        XCTAssertEqual(found.subtracting(reasons), [])
    }

    func testAReceiptDatedInTheFutureIsFiledToday() throws {
        let now = Date()
        let made = try writer.addExpense(ExpenseDraft(amount: 10, category: "other", note: "", receiptBase64: nil,
                                                      vatAmount: 50, date: "2999-01-01", receiptRef: "zatca:x"),
                                         now: now)
        XCTAssertEqual(made["date"], .string(BookWriter.localDay(now)))
        XCTAssertEqual(made["vatAmount"], .number(10), "never more VAT than was paid")
    }
}
