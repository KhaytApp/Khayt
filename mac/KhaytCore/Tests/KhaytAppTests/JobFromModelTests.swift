import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A model, or the calculator's answer for one, as a quote or a job — without
/// typing the grams and the hours a second time.
///
/// The promise these hold: the job opened from the calculator is the part the
/// calculator priced, and it SAVES at the price the calculator showed, through
/// the shared rule rather than a second copy of it. And a line made from a
/// model says whether its figures were sliced or estimated.
@MainActor
struct JobFromModelTests {

    static func shop() async -> Shop {
        let s = Shop()
        await s.load(.sample)
        return s
    }

    static func costed(cost: Double) throws -> KhaytEngine.CostedPart {
        let json = """
        {"cost": \(cost),
         "parts": {"material": 10, "machine": 2, "labor": 5, "buffer": 1},
         "rates": {"wearRate": 0.3, "powerDraw": 150, "elecRate": 0.18, "prepTime": 0.25,
                   "postTime": 0.1, "laborRate": 60, "failureRate": 5}}
        """
        return try JSONDecoder().decode(KhaytEngine.CostedPart.self, from: Data(json.utf8))
    }

    // MARK: - Sliced or estimated

    @Test("figures are sliced, estimated, or partly estimated — by the fields the mesh filled")
    func figureSource() {
        #expect(ModelFigureSource.of(estimated: []) == .sliced)
        #expect(ModelFigureSource.of(estimated: ["printWeight", "printTime"]) == .estimated)
        #expect(ModelFigureSource.of(estimated: ["printTime"]) == .partlyEstimated)
        #expect(ModelFigureSource.of(estimated: ["printWeight"]) == .partlyEstimated)
        #expect(!ModelFigureSource.sliced.wantsAttention)
        #expect(ModelFigureSource.estimated.wantsAttention)
    }

    // MARK: - The mapping

    @Test("the calculator's part becomes one cart line: its figures, its cost, its file")
    func draftMapping() throws {
        let input: JSONValue = .object([
            "printWeight": .number(146.3), "printTime": .number(5.25), "qty": .number(3),
            "filamentId": .string("S2"), "spoolCost": .number(12.4), "spoolWeight": .number(146.3),
            "colours": .array([.object(["filamentId": .string("S2"), "grams": .number(96.4)])]),
            "consumables": .array([.object(["consumableId": .string("C1"), "qty": .number(4)])]),
            "purgeGrams": .number(18),
        ])
        let fill = ModelFill(name: "Dallah", link: ["printFileId": .string("PF-1"), "plate": .number(2)],
                             source: .sliced, note: nil, signature: "x")
        let draft = CalculatorModel.jobDraft(input: input, costed: try Self.costed(cost: 21.5), qty: 3,
                                             name: "Dallah", fill: fill, source: .sliced)
        #expect(draft.name == "Dallah")
        #expect(draft.grams == "146.3")
        #expect(draft.hours == "5.25")
        #expect(draft.qty == 3)
        #expect(draft.spoolId == "S2")
        #expect(draft.cost == 21.5)
        #expect(draft.rates?.laborRate == 60)
        #expect(draft.source == .sliced)

        // And what the saved part carries.
        let rows = Shop.partRows([draft], spools: [], unnamed: "x")
        guard case .object(let row)? = rows.first else { Issue.record("no row"); return }
        let link = row["printFileId"]
        #expect(link == .string("PF-1"), "the job does not join the model it prints")
        #expect(row["plate"] == .number(2))
        #expect(row["colours"] != nil, "a multicolour part lost its colours")
        #expect(row["consumables"] != nil)
        #expect(row["purgeGrams"] == .number(18))
        #expect(row["unitCost"] == .number(21.5))
        let base = row["baseCost"]
        #expect(base == .number(64.5), "baseCost is the unit cost times the quantity")
    }

    @Test("a line the shop typed over stops claiming the file's figures")
    func typedOverIsNotSliced() async throws {
        let shop = await Self.shop()
        let dallah = try #require(shop.files.first { $0.id == "PF-sample-dallah" })
        let m = CalculatorModel()
        let problem = await m.fillFromModel(dallah, plate: nil, shop: shop)
        #expect(problem == nil)
        #expect(m.figureSource == .sliced)
        m.hours = "9"
        #expect(m.figureSource == nil)
    }

    @Test("several titles name the job until they stop reading as a name")
    func projectName() {
        #expect(Shop.projectName(for: ["Dallah"]) == "Dallah")
        #expect(Shop.projectName(for: ["Dallah", " Lid "]) == "Dallah + Lid")
        #expect(Shop.projectName(for: ["a", "b", "c", "d"]).isEmpty)
    }

    // MARK: - One price

    @Test("a job made from the calculator saves at the calculator's price")
    func samePrice() async throws {
        let shop = await Self.shop()
        let dallah = try #require(shop.files.first { $0.id == "PF-sample-dallah" })
        let m = CalculatorModel()
        _ = await m.fillFromModel(dallah, plate: nil, shop: shop)
        m.qty = 3
        m.margin = 45
        m.discount = 10
        m.rush = true
        await m.recompute(shop)
        let shown = try #require(m.quoted?.total)
        let seed = try #require(m.jobSeed(shop, asQuote: true))
        #expect(seed.asQuote)
        #expect(seed.parts.count == 1)
        let line = try #require(seed.parts.first)
        #expect(line.source == .sliced)

        // What the sheet previews: the same call, on the cart.
        let preview = await shop.previewQuote(
            baseCost: line.cost * Double(line.qty), margin: seed.margin,
            discountPct: seed.discountPct, shippingCost: 0, rush: seed.rush)
        let previewed = try #require(preview?.total)
        #expect(abs(previewed - shown) < 0.005, "sheet \(previewed) vs calculator \(shown)")

        // What `lib/order-new.js` saves: the job's own price.
        let input = shop.newJobInput(parts: seed.parts, project: seed.project, clientId: nil,
                                     margin: seed.margin, discountPct: seed.discountPct,
                                     shippingCost: 0, deposit: 0, rush: seed.rush, asQuote: true)
        let engine = try KhaytEngine()
        let out = try await engine.newOrder(
            input, orders: [], settings: shop.settingsDict, now: Date(),
            tokens: (tracking: Array(repeating: 7, count: 16),
                     quoteApproval: Array(repeating: 9, count: 16)))
        guard case .object(let order) = out.order else { Issue.record("no order"); return }
        let saved = Shop.plainNumber(order["price"]) ?? -1
        #expect(abs(saved - shown) < 0.005, "saved \(saved) vs calculator \(shown)")
        guard case .array(let parts)? = order["parts"], case .object(let part)? = parts.first else {
            Issue.record("no part on the order"); return
        }
        let link = part["printFileId"]
        #expect(link == .string("PF-sample-dallah"))
    }

    @Test("the library's Quote this model opens on the calculator's figure for the same model")
    func libraryMatchesCalculator() async throws {
        let shop = await Self.shop()
        let dallah = try #require(shop.files.first { $0.id == "PF-sample-dallah" })
        let seed = try #require(await shop.jobFromModels([dallah], asQuote: true))
        let calc = try #require(await shop.calculator(for: dallah, plate: nil))
        let fromLibrary = try #require(seed.parts.first)
        let fromCalculator = try #require(calc.jobDraft(shop))
        #expect(abs(fromLibrary.cost - fromCalculator.cost) < 1e-9)
        #expect(fromLibrary.grams == fromCalculator.grams)
        #expect(seed.margin == shop.defaultMargin)
        #expect(seed.project == dallah.title)
    }

    @Test("several models are one job with a line each")
    func severalModels() async throws {
        let shop = await Self.shop()
        let sliced = shop.files.filter { $0.id == "PF-sample-dallah" || $0.id == "PF-sample-bracket" }
        #expect(sliced.count == 2)
        let seed = try #require(await shop.jobFromModels(sliced, asQuote: false))
        #expect(!seed.asQuote)
        let lines = seed.parts.count
        #expect(lines == sliced.count, "\(shop.productProblem ?? "")")
    }

    @Test("a model nobody sliced is costed on the mesh and SAYS so")
    func estimatedIsSaid() async throws {
        let shop = await Self.shop()
        var picked: (LibraryFile, Shop.ModelPart)?
        for file in shop.files where shop.estimates[file.id] != nil {
            if let made = await shop.modelPart(from: file), !made.estimated.isEmpty {
                picked = (file, made); break
            }
        }
        let (file, made) = try #require(picked, "the sample library has no unsliced model with an estimate")
        let seed = try #require(await shop.jobFromModels([file], asQuote: true))
        let line = try #require(seed.parts.first)
        let expected = ModelFigureSource.of(estimated: made.estimated)
        #expect(line.source == expected)
        #expect(line.source?.wantsAttention == true)
        #expect(line.sourceNote != nil, "the sentence about which figure was estimated is lost")
    }

    // MARK: - Paid in full

    @Test("Paid in full is the cash the order can take: the bill less credit notes and gift cards")
    func paidInFull() throws {
        let json = #"{"gross": 500, "credited": 0, "giftCard": 100, "cash": 400}"#
        let due = try JSONDecoder().decode(KhaytEngine.CashDue.self, from: Data(json.utf8))
        #expect(PaymentSheet.paidInFull(due: due, price: 500) == 400)
        // Before the engine answers, the price.
        #expect(PaymentSheet.paidInFull(due: nil, price: 123.456) == 123.46)
        #expect(PaymentSheet.paidInFull(due: nil, price: -5) == 0)
        #expect(PaymentSheet.paidInFull(due: nil, price: .nan) == 0)
    }

    @Test("Paid in full on a real job reads Owed nothing, by the same rule the sheet shows")
    func paidInFullOnAJob() async throws {
        let shop = await Self.shop()
        let job = try #require(shop.orders.first { $0.price > 0 })
        let due = await shop.cashDue(job.id)
        let full = PaymentSheet.paidInFull(due: due, price: job.price)
        let cash = due?.cash ?? job.price
        #expect(abs(cash - full) < 0.005)
        #expect(full > 0)
    }

    // MARK: - Wiring

    @Test("every door is wired: calculator, inspector, context menu, sheet, payment")
    func wired() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        func read(_ name: String) throws -> String {
            try String(contentsOf: dir.appending(path: name), encoding: .utf8)
        }
        let calculator = try read("Calculator.swift")
        #expect(calculator.contains("model.jobSeed(shop, asQuote: asQuote)"))
        #expect(calculator.contains("shop.takeJob(seed)"))
        let inspector = try read("LibraryInspector.swift")
        #expect(inspector.contains("shop.startJob(fromModels: [file], asQuote: true)"))
        let menu = try read("FileActions.swift")
        #expect(menu.contains("shop.startJob(fromModels: forJob, asQuote: true)"))
        #expect(menu.contains("shop.startJob(fromModels: forJob, asQuote: false)"))
        let sheet = try read("NewJobSheet.swift")
        #expect(sheet.contains("shop.jobFromModel"))
        let fromModel = try read("CalculatorFromModel.swift")
        #expect(fromModel.contains("calc.fillFromModel("))
        let payment = try read("PaymentSheet.swift")
        #expect(payment.contains("Self.paidInFull("))
        #expect(payment.contains(".keyboardShortcut(.defaultAction)"))
    }
}
