import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A day in the shop, start to finish, on one book.
///
/// Every other suite here tests one write. This one asks the question the whole
/// project is for: can a shop get through a day without opening Khayt? It takes
/// a job, prices it, moves it along the floor, fails an inspection, prints
/// again, finishes it, hands it over, takes the money, prints the invoice,
/// records what the day cost and puts a spool right — through the same calls
/// the screens make, against one file, reading it back at the end.
///
/// It is deliberately not a unit test. A book where each write is correct on
/// its own and the collections disagree with each other is exactly the failure
/// a shop would find at the end of a month, and no single-write test can see
/// it.
@MainActor
struct DayInTheShopTests {

    /// A shop with what a day needs: a shelf, a machine, a customer.
    static func book() -> [String: JSONValue] {
        [
            "printLog": .array([]),
            "inventory": .array([
                .object(["id": .string("S1"), "material": .string("PLA"), "weight": .number(1000),
                         "cost": .number(90), "rev": .number(1)]),
            ]),
            "consumables": .array([]),
            "machines": .array([.object(["id": .string("M1"), "name": .string("Bench")])]),
            "clients": .array([.object(["id": .string("C1"), "nameEn": .string("Acme"),
                                        "phone": .string("+966 50 000 0000")])]),
            "expenses": .array([]),
            "wasteLog": .array([]),
            "settings": .object([
                "currency": .string("SAR"),
                "bizEn": .string("Tuwaiq Additive"),
                "addrEn": .string("Riyadh"),
                "enableVat": .bool(true), "vatRate": .number(15),
                "vat": .string("310122393500003"),
                "enableZatca": .bool(true),
                "autoDeduct": .bool(true),
                "invNumNext": .number(1),
            ]),
        ]
    }

    static func rows(_ root: [String: JSONValue], _ collection: String) -> [[String: JSONValue]] {
        Shop.rows(root, collection).compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }
    static func row(_ root: [String: JSONValue], _ collection: String, _ id: String) -> [String: JSONValue]? {
        rows(root, collection).first { Shop.plainString($0["id"]) == id }
    }
    static func string(_ v: JSONValue?) -> String? { Shop.plainString(v) }
    static func number(_ v: JSONValue?) -> Double? { Shop.plainNumber(v) }

    @Test("a shop gets through a day without opening Khayt")
    func aDay() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)

        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-day-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(Self.book()).write(to: url)

        func write(_ change: @escaping (inout [String: JSONValue]) async throws -> Void) async throws {
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }, mutate: change)
        }
        func book() throws -> [String: JSONValue] {
            try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        }

        // ── Morning: a customer walks in and the shop takes the job ─────────
        var jobId = ""
        try await write { root in
            let out = try await engine.newOrder([
                // NO PRICE IS PASSED. `lib/order-new.js` prices a job from its
                // parts and the shop's margin — the calculator's own
                // arithmetic — and a `price` handed in here would be ignored.
                // Asserted below rather than assumed.
                "project": .string("Turbine bracket"),
                "clientId": .string("C1"),
                "client": .string("Acme"),
                "printTime": .number(8),
                "parts": .array([.object([
                    "name": .string("Bracket"), "qty": .number(1),
                    "material": .string("PLA"), "filamentId": .string("S1"),
                    "printWeight": .number(200), "baseCost": .number(120),
                ])]),
            ], orders: Shop.rows(root, "printLog"), settings: Shop.settings(root), now: Date(),
               tokens: (tracking: Shop.randomBytes(16), quoteApproval: Shop.randomBytes(16)))
            guard case .object(let record) = out.order,
                  case .string(let id)? = record["id"] else { return }
            jobId = id
            root["printLog"] = .array([out.order])
            // The settings come back changed — the invoice counter was spent —
            // and must be written with the order or the next job takes the
            // same number.
            root["settings"] = .object(out.settings)
        }
        #expect(!jobId.isEmpty, "the job was not taken")
        #expect(Self.number(Shop.settings(try book())["invNumNext"]) == 2,
                "the invoice counter moved on with the job")
        let price = try #require(Self.number(Self.row(try book(), "printLog", jobId)?["price"]))
        #expect(price > 0, "the job was priced from its parts, by the calculator's own arithmetic")

        // ── The floor: printing, then a failed inspection ──────────────────
        for stage in [Stage.pending, .printing, .qc] {
            try await write { root in
                _ = try await Shop.applyMove(to: &root, id: jobId, stage: stage,
                                             engine: engine, words: words)
            }
        }
        try await write { root in
            let orders = Shop.rows(root, "printLog")
            guard let target = orders.first(where: { Shop.recordId($0) == jobId }) else { return }
            let out = try await engine.recordQcFailure(
                order: target, failureType: "warping", severity: "major",
                reason: "Lifted at hour six", weight: 60, inspector: nil,
                inventory: Shop.rows(root, "inventory"), now: Date(),
                wasteId: "W-1", defaultReason: "QC fail",
                settings: Shop.settings(root), machines: Shop.rows(root, "machines"),
                today: Shop.today())
            var rows = orders
            if let at = rows.firstIndex(where: { Shop.recordId($0) == jobId }) { rows[at] = out.order }
            root["printLog"] = .array(rows)
            root["wasteLog"] = .array([out.waste])
            // The shelf, in the same swap: a failed print takes its filament
            // off the spools it was printing from.
            root["inventory"] = .array(out.inventory)
        }
        var after = try book()
        #expect(Self.string(Self.row(after, "printLog", jobId)?["qcStatus"]) == "fail")
        #expect(Self.rows(after, "wasteLog").count == 1, "a failed inspection is in the waste log")
        #expect(Self.number(Self.row(after, "inventory", "S1")?["weight"]) == 940,
                "and the 60g it got through came off the spool, not just into the log")

        // ── Printed again, and finished ────────────────────────────────────
        for stage in [Stage.pending, .printing, .qc, .completed] {
            try await write { root in
                _ = try await Shop.applyMove(to: &root, id: jobId, stage: stage,
                                             engine: engine, words: words,
                                             qcNotes: stage == .completed ? "Passed" : nil)
            }
        }
        after = try book()
        let finished = try #require(Self.row(after, "printLog", jobId))
        #expect(Self.string(finished["status"]) == "completed")
        #expect(Self.string(finished["completedAt"]) != nil)
        // THE COLLECTIONS HAVE TO AGREE, and every gram that went through the
        // machine is off the shelf: the 60 the failed attempt burned and the
        // 200 the reprint finished with. A book where a print failed and
        // wasted 200g while the spool still holds them has told the shop it
        // has filament it has already burned.
        #expect(Self.number(Self.row(after, "inventory", "S1")?["weight"]) == 740,
                "1000g less the 60 it wasted and the 200 the reprint took")
        #expect(Self.number(Self.rows(after, "wasteLog").first?["weight"]) == 60,
                "and the 60 is recorded, and costed, in the waste log as well")

        // ── Handed over, and paid ──────────────────────────────────────────
        try await write { root in
            let orders = Shop.rows(root, "printLog")
            guard let target = orders.first(where: { Shop.recordId($0) == jobId }) else { return }
            let out = try await engine.markDelivered(order: target, now: Date())
            guard let handed = out.order else { return }
            var rows = orders
            if let at = rows.firstIndex(where: { Shop.recordId($0) == jobId }) { rows[at] = handed }
            root["printLog"] = .array(rows)
        }
        try await write { root in
            let orders = Shop.rows(root, "printLog")
            guard let target = orders.first(where: { Shop.recordId($0) == jobId }) else { return }
            // Paid in full, whatever the calculator priced it at. An amount
            // over the price is a credit note, not a bigger payment, and the
            // rule caps it — so the figure has to come from the book.
            var due = 0.0
            if case .object(let fields) = target { due = Self.number(fields["price"]) ?? 0 }
            let out = try await engine.recordPayment(order: target, amount: due, method: "mada",
                                                     paidAt: Shop.today(), today: Shop.today())
            var rows = orders
            if let at = rows.firstIndex(where: { Shop.recordId($0) == jobId }) { rows[at] = out.order }
            root["printLog"] = .array(rows)
        }
        after = try book()
        let paid = try #require(Self.row(after, "printLog", jobId))
        #expect(Self.string(paid["deliveredAt"]) != nil, "handed over")
        #expect(Self.number(paid["paidAmount"]) == price, "paid in full")
        #expect(Self.string(paid["paymentStatus"]) == "paid")

        // ── The paper the customer takes away ──────────────────────────────
        let settings = Shop.settings(after)
        let money = try await engine.computeTax(price, profile: try await engine.taxProfile(settings: settings))
        let document = try #require(await Invoice.document(
            Invoice.Ingredients(
                row: .object(paid), settings: settings,
                clients: Shop.rows(after, "clients"),
                currencies: ["SAR": .object(["symbol": .string("SAR"), "label": .string("SAR"), "pos": .string("after")])],
                language: "en", sellerName: "Tuwaiq Additive", sellerAddress: "Riyadh",
                sellerFields: ["biz": .string("Tuwaiq Additive"), "addr": .string("Riyadh"),
                               "tagline": .string("Precision 3D printing in Riyadh"),
                               "footer": .string("")],
                price: price, subtotal: money.subtotal, taxTotal: money.taxTotal,
                vatRate: 15, timestamp: Self.string(paid["date"]) ?? ""),
            engine: engine, words: words))
        #expect(document.html.contains("Turbine bracket"), "the invoice names the job")
        #expect(document.html.contains(Money.figure(price)), "and what was charged")
        #expect(document.html.contains("alt=\"ZATCA\""), "and carries the QR a Saudi tax invoice must")
        #expect(document.html.contains(jobId), "under the number the book gave it")

        // ── What the day cost, and putting the shelf right ─────────────────
        try await write { root in
            let made = try await engine.newExpense([
                "amount": .number(90), "category": .string("filament"), "note": .string("Restock"),
            ], id: "EXP-1", today: Shop.today())
            root["expenses"] = .array([try #require(made.expense)])
        }
        try await write { root in
            var shelf = Shop.rows(root, "inventory")
            let out = try await engine.editSpool(shelf[0], input: ["weight": .string("700")],
                                                 settings: Shop.settings(root), today: Shop.today())
            guard case .object(var record) = out.spool else { return }
            StoreWriter.stamp(&record)
            shelf[0] = .object(record)
            root["inventory"] = .array(shelf)
        }

        // ── The book at the end of the day ─────────────────────────────────
        after = try book()
        #expect(Self.rows(after, "expenses").count == 1)
        #expect(Self.number(Self.row(after, "inventory", "S1")?["weight"]) == 700,
                "the shop counted the spool and said what was really on it")
        #expect((Self.number(Self.row(after, "inventory", "S1")?["rev"]) ?? 0) > 1,
                "and that correction is stamped, so it reaches the shop's other devices")

        // And the day, as the shop's own reports read it.
        let pnl = try await engine.pnlByPeriod(
            orders: Shop.rows(after, "printLog"), expenses: Shop.rows(after, "expenses"),
            settings: Shop.settings(after), clients: Shop.rows(after, "clients"),
            currencies: [:], now: Date())
        let quarter = try #require(pnl.first)
        #expect(quarter.orders == 1)
        #expect(quarter.expenses == 90)
        // 15% INCLUSIVE, AND HELD FOR THE TAX AUTHORITY — which this test said
        // in words before its numbers agreed. The price is what the customer
        // paid; the shop keeps what is left after the tax inside it, and that
        // is what revenue and profit are. ZATCA and IFRS 15 both refuse to call
        // tax collected on a sale income.
        let held = price - price / 1.15
        #expect(abs(quarter.vatCollected - held) < 0.01)
        #expect(abs(quarter.revenue - (price - held)) < 0.01,
                "revenue is the price without the tax the shop is holding")
        #expect(abs(quarter.revenue + quarter.vatCollected - price) < 0.01,
                "and the two together are still what the customer paid")
        #expect(abs(quarter.net - (price - held - 90)) < 0.01)
        // The day recorded no tax on its own purchases, so there is none to
        // reclaim and the whole of what was charged is owed.
        #expect(quarter.vatReclaimable == 0)
        #expect(abs(quarter.vatDue - quarter.vatCollected) < 0.01)

        // Nothing was lost on the way through: every collection the day touched
        // is still a list, and the ones it did not are still there.
        for collection in ["printLog", "inventory", "consumables", "machines", "clients",
                           "expenses", "wasteLog"] {
            #expect(after[collection] != nil, "\(collection) went missing")
        }
    }
}
