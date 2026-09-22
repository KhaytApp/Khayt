import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Orders a storefront has already sent, read against the shelf.
///
/// ── THE GAP THIS CLOSED ───────────────────────────────────────────────────
///
/// The Integrations screen hands a shop the address to paste into Shopify,
/// Salla, Zid, WooCommerce, Etsy or Medusa, and it works: every order those
/// send is filed in khayt-cloud's intake queue right now. This app never asked
/// for one. So the Mac could tell a storefront where to post its orders and
/// could not show the shop a single order that had arrived.
///
/// `CloudIntake` is pure of the network — `fetch` is a seam, as
/// `CloudReader.pull`'s is — so none of this speaks to the service.
@MainActor
struct CloudIntakeTests {

    static let connection = CloudReader.Connection(
        url: "https://cloud.khaytapp.com", shopId: "shop_a1", storedToken: "")

    static func answer(_ json: String, status: Int = 200) -> CloudIntake.Fetch {
        { request in
            (Data(json.utf8),
             HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!)
        }
    }

    /// THE HEADER, WHICH IS NOT A DETAIL.
    ///
    /// khayt-cloud records the delta capability of every credential it hears
    /// from on EVERY route, and one request without `x-delta-capable` closes
    /// delta sync for the whole shop, on all its devices — from a screen with
    /// nothing to do with syncing. Building on `CloudReader.request` is what
    /// prevents it, and this is the assertion that keeps it there.
    @Test("every request carries the header the whole shop's sync depends on")
    func theHeaderIsAlwaysThere() async throws {
        var seen: [URLRequest] = []
        let spy: CloudIntake.Fetch = { request in
            seen.append(request)
            return (Data(#"{"items":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        _ = try await CloudIntake.list(Self.connection, token: "t", fetch: spy)
        try await CloudIntake.drain(Self.connection, token: "t", id: "9", fetch: spy)
        #expect(seen.count == 2)
        for request in seen {
            #expect(request.value(forHTTPHeaderField: "x-delta-capable") == "1",
                    "a request without this closes delta sync for every device this shop has")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        }
        #expect(seen[0].url?.path == "/v1/shops/shop_a1/intake")
        #expect(seen[1].httpMethod == "DELETE")
        #expect(seen[1].url?.path == "/v1/shops/shop_a1/intake/9")
    }

    /// `created_at` is a MySQL `DATETIME` — `2026-09-22 14:02:11`, no `T` and
    /// no zone. An ISO8601 parser alone returns nil for every row the service
    /// has ever held, and the queue would sort by nothing.
    @Test("the cloud's own timestamp is read, not only an ISO one")
    func mysqlTimestamps() async throws {
        let items = try await CloudIntake.list(Self.connection, token: "t", fetch: Self.answer("""
            {"items":[
              {"id":"3","payload":{"title":"Later"},"createdAt":"2026-09-22 14:02:11"},
              {"id":"2","payload":{"title":"ISO"},"createdAt":"2026-09-20T09:00:00Z"},
              {"id":"1","payload":{"title":"Earlier"},"createdAt":"2026-09-19 08:00:00"}
            ]}
            """))
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.createdAt != nil },
                "a row whose date could not be read sorts as the oldest thing there is")
        // Oldest first — the order a shop works through.
        #expect(items.map(\.title) == ["Earlier", "ISO", "Later"])
    }

    /// khayt-cloud's import route answered `"id":"0"` for every storefront
    /// order for most of its life. The id is how a row is deleted afterwards,
    /// so a row carrying that one would be imported and then offered again on
    /// every look — the shop importing the same order each time it opened the
    /// screen.
    @Test("a row with no usable id is dropped rather than shown")
    func unusableRows() async throws {
        let items = try await CloudIntake.list(Self.connection, token: "t", fetch: Self.answer("""
            {"items":[
              {"id":"0","payload":{"title":"Cannot be deleted"}},
              {"id":"","payload":{"title":"Nor this"}},
              {"id":"7","payload":"not an object"},
              {"id":"8","payload":{"title":"Real"}}
            ]}
            """))
        #expect(items.map(\.title) == ["Real"])
    }

    @Test("a refusal is reported with what the cloud said")
    func refusals() async {
        await #expect(throws: CloudIntake.Failure.self) {
            _ = try await CloudIntake.list(Self.connection, token: "t",
                                           fetch: Self.answer(#"{"error":"Unknown shop"}"#, status: 404))
        }
    }
}

/// What an online order does to the shelf.
///
/// The arithmetic is `lib/shelf-sale.js` and is tested in `test/shelf-sale
/// .test.js`. These are about the reading this app builds from it and the
/// writes it turns into — the parts that are Swift.
@MainActor
struct OnlineOrderReadingTests {

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    static func order(_ description: String, shop: Shop) async throws -> Shop.OnlineOrder {
        let payload = JSONValue.object([
            "title": .string("Salla order — SL-4"),
            "description": .string(description),
            "source": .string("salla"),
            "ref": .string("salla:SL-4"),
            "name": .string("Nora"),
        ])
        let engine = try #require(shop.engine)
        return Shop.OnlineOrder(
            item: CloudIntake.Item(id: "12", payload: payload, createdAt: Date()),
            reading: try await engine.shelfSaleReading(
                payload: payload, products: shop.productRows,
                stock: Shop.stockCounts(shop.settingsDict)))
    }

    /// The sample book's shelf, so the numbers below are the book's and not a
    /// fixture's. `sample-shop.json` stocks twelve of one product and four of
    /// another.
    static func stocked(_ shop: Shop) -> [(String, String, Int)] {
        shop.shownProducts.compactMap { row in
            shop.stockCount(of: row.id).map { (row.id, row.name, $0) }
        }
    }

    @Test("an order for something on the shelf is a sale, and says so")
    func aSale() async throws {
        let shop = await Self.shop()
        let shelf = Self.stocked(shop).first { $0.2 >= 2 }
        let stocked = try #require(shelf, "the sample book stocks nothing any more")
        let order = try await Self.order("• \(stocked.1) × 2", shop: shop)
        #expect(order.allFromShelf)
        #expect(order.fromShelf == 2)
        #expect(order.toPrint == 0)
        #expect(order.lines.first?.productId == stocked.0)
    }

    @Test("an order for something this shop does not sell is reported, not guessed at")
    func unmatched() async throws {
        let shop = await Self.shop()
        let order = try await Self.order("• A thing nobody here makes × 1", shop: shop)
        #expect(order.unmatched == 1)
        #expect(!order.allFromShelf)
        #expect(order.lines.first?.unmatched == true)
        #expect(order.lines.first?.fromShelf == 0,
                "an unrecognised line took something off a shelf")
    }

    /// ── ONE SETTINGS WRITE, AND IT STARTS FROM `out.settings` ────────────
    ///
    /// `newOrder` advances the shop's invoice counter and hands the settings
    /// back with it advanced. The shelf lives in the same object. Writing the
    /// shelf first and the counter second puts the shelf back as it was — a
    /// bug that costs a number a customer can see and that nothing else in the
    /// app notices, because every other figure is still right.
    ///
    /// `putStockCount` merges rather than rebuilds, which is what makes the
    /// one-write order work. This proves both halves survive it.
    @Test("the shelf and the advanced invoice counter survive one write")
    func oneSettingsWrite() async throws {
        let shop = await Self.shop()
        let engine = try #require(shop.engine)
        let stocked = try #require(Self.stocked(shop).first { $0.2 >= 2 })
        var settings = shop.settingsDict
        let before = Shop.stockCount(of: stocked.0, in: .object(settings))
        #expect(before == stocked.2)

        let out = try await engine.newOrder(
            await shop.onlineJobInput(try await Self.order("• \(stocked.1) × 2", shop: shop)),
            orders: [], settings: settings, now: Date(),
            tokens: (tracking: Shop.randomBytes(16), quoteApproval: Shop.randomBytes(16)))

        settings = out.settings
        Shop.putStockCount(stocked.2 - 2, for: stocked.0, into: &settings, at: Date())

        #expect(Shop.stockCount(of: stocked.0, in: .object(settings)) == stocked.2 - 2)
        // …and every other shelf in the book is where it was.
        for (id, _, count) in Self.stocked(shop) where id != stocked.0 {
            #expect(Shop.stockCount(of: id, in: .object(settings)) == count,
                    "counting one product rebuilt the whole shelf")
        }
        // …and the counter the order consumed is still advanced.
        if case .number(let next)? = settings["invNumNext"],
           case .number(let was)? = shop.settingsDict["invNumNext"] {
            #expect(next > was, "the shelf write put the invoice counter back")
        }
    }

    /// ── THE FIGURE THAT IS APPLIED IS A RELATIVE ONE ────────────────────
    ///
    /// The effects list carries `taken` (how many came off) and `to` (what
    /// would be left). `to` is absolute, and it was worked out from the count
    /// as it stood WHEN THE QUEUE WAS READ — which can be minutes before the
    /// shop presses the button, with a counter sale, a recount or a sync from
    /// another Mac in between. Writing it would put the shelf back to a number
    /// that was true then, silently.
    @Test("the deduction is how many came off, not what was left")
    func deductionsAreRelative() async throws {
        let shop = await Self.shop()
        let engine = try #require(shop.engine)
        let stocked = try #require(Self.stocked(shop).first { $0.2 >= 3 })
        let order = try await Self.order("• \(stocked.1) × 3", shop: shop)
        let effects = try await engine.shelfSaleEffects(order.reading, at: Date())
        let deductions = Shop.deductions(effects)
        #expect(deductions.count == 1)
        #expect(deductions.first?.0 == stocked.0)
        #expect(deductions.first?.1 == 3, """
            the deduction is \(deductions.first?.1 ?? -1) — that is what would be \
            LEFT, and applying it to a shelf that has moved since overwrites the \
            newer count with an older one
            """)

        // Applied against a book whose shelf has moved on since the screen was
        // drawn: one more was sold over the counter in between.
        var settings = shop.settingsDict
        Shop.putStockCount(stocked.2 - 1, for: stocked.0, into: &settings, at: Date())
        for (productId, taken) in deductions {
            let onShelf = try #require(Shop.stockCount(of: productId, in: .object(settings)))
            Shop.putStockCount(max(0, onShelf - taken), for: productId,
                               into: &settings, at: Date())
        }
        #expect(Shop.stockCount(of: stocked.0, in: .object(settings)) == stocked.2 - 4,
                "the counter sale that happened in between was undone")
    }

    /// ── THE ONE THAT WOULD HAVE COST REAL MONEY ─────────────────────────
    ///
    /// The first cut handed `newOrder` parts carrying a name and a quantity
    /// and nothing else. A part with no grams and no hours costs nothing, so
    /// every online order this app recorded would have landed in the book
    /// priced at **zero** — in the column the whole business is measured in,
    /// without throwing anywhere. `lib/storefront-orders.js` exists because
    /// that already happened once, to every Salla order Khayt ever imported.
    @Test("an order for something in the catalogue is priced, not recorded free")
    func aRecordedOrderIsPriced() async throws {
        let shop = await Self.shop()
        let engine = try #require(shop.engine)
        let stocked = try #require(Self.stocked(shop).first { $0.2 >= 2 })
        let order = try await Self.order("• \(stocked.1) × 2", shop: shop)

        let out = try await engine.newOrder(
            await shop.onlineJobInput(order), orders: [], settings: shop.settingsDict,
            now: Date(), tokens: (tracking: Shop.randomBytes(16),
                                  quoteApproval: Shop.randomBytes(16)))
        guard case .object(let record) = out.order else {
            Issue.record("newOrder produced no record"); return
        }
        guard case .number(let price)? = record["price"] else {
            Issue.record("the record carries no price at all"); return
        }
        #expect(price > 0, """
            an online order for a product this shop sells was recorded at \(price) — \
            the storefront's own total is not in the payload, so the catalogue's \
            parts are the only thing that can price it
            """)
        // And it is the catalogue's price for two, not for one.
        let one = try await engine.newOrder(
            await shop.onlineJobInput(try await Self.order("• \(stocked.1) × 1", shop: shop)),
            orders: [], settings: shop.settingsDict, now: Date(),
            tokens: (tracking: Shop.randomBytes(16), quoteApproval: Shop.randomBytes(16)))
        guard case .object(let single) = one.order,
              case .number(let singlePrice)? = single["price"] else {
            Issue.record("no single-quantity record"); return
        }
        #expect(price > singlePrice, "two of a thing cost the same as one")
    }

    /// A basket of three different things is not one of them. Stamping the
    /// record with a `productId` would report the sale against the wrong
    /// catalogue row — and bring that product's packaging and assembly count
    /// with it, which the shared rule prices and deducts.
    @Test("a mixed basket is not filed against one product")
    func mixedBasketHasNoProduct() async throws {
        let shop = await Self.shop()
        let stocked = Self.stocked(shop)
        guard stocked.count >= 2 else { return }
        let mixed = try await Self.order("• \(stocked[0].1) × 1\n• \(stocked[1].1) × 1",
                                         shop: shop)
        let input = await shop.onlineJobInput(mixed)
        #expect(input["productId"] == nil)

        let single = try await Self.order("• \(stocked[0].1) × 1", shop: shop)
        #expect(await shop.onlineJobInput(single)["productId"] == .string(stocked[0].0),
                "an order that IS one product should be filed against it")
    }

    /// A line naming nothing this shop sells is a part with the customer's own
    /// words and no cost — which is what a request is. It must still be IN the
    /// job: dropping it would record an order missing something the customer
    /// asked for and paid for.
    @Test("an unrecognised line is carried into the job, unpriced")
    func unmatchedLinesSurvive() async throws {
        let shop = await Self.shop()
        let order = try await Self.order("• A thing nobody here makes × 3", shop: shop)
        let input = await shop.onlineJobInput(order)
        guard case .array(let parts)? = input["parts"], case .object(let first)? = parts.first
        else { Issue.record("the unrecognised line was dropped"); return }
        #expect(parts.count == 1)
        if case .string(let name)? = first["name"] {
            #expect(name.contains("nobody here makes"))
        }
        if case .number(let qty)? = first["qty"] { #expect(qty == 3) }
    }

    /// A shop with no cloud has no queue, and must not be told about one.
    @Test("a book with no cloud is quiet rather than wrong")
    func noCloudNoNoise() async throws {
        let shop = await Self.shop()
        await shop.readOnlineOrders { _ in
            Issue.record("a book with no cloud asked the network for a queue")
            throw CloudIntake.Failure.notConnected
        }
        #expect(shop.onlineOrders.isEmpty)
        #expect(shop.onlineProblem == nil, "a shop without a storefront was shown an error")
    }
}
