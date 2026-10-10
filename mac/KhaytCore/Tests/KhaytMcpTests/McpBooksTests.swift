import Foundation
import Testing
import KhaytCore
@testable import KhaytMcp

/// The books tools, against the bundled sample shop — each held to the shared
/// rule's OWN answer on the same book, so a tool cannot report a figure the
/// app's screen would not.
///
/// Every comparison here is tool-versus-rule on identical inputs. None of them
/// restates a sum in Swift: that is the thing these tools must not do, and a
/// test that did it would only prove the test agrees with itself.
struct McpBooksTests {

    /// `SampleBook.anchorDay` — the day the sample book was written to be read
    /// on, so lateness and ageing have real cases in them.
    static let anchor: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 20; c.hour = 12
        return Calendar.book.date(from: c)!
    }()

    static let sampleURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")

    static func sample() throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: sampleURL))
    }

    static func rows(_ book: [String: JSONValue], _ key: String) -> [JSONValue] {
        if case .array(let r)? = book[key] { return r }
        return []
    }

    static func settings(_ book: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let s)? = book["settings"] { return s }
        return [:]
    }

    static func currencyTable(_ engine: KhaytEngine) async throws -> [String: JSONValue] {
        try await engine.currencies().mapValues {
            .object(["symbol": .string($0.symbol), "label": .string($0.label), "pos": .string($0.pos)])
        }
    }

    /// A server over these bytes, read the way `main.swift` reads them.
    static func server(_ data: Data, engine: KhaytEngine, now: Date = anchor) -> Server {
        Server(library: (try? Library.read(data: data)) ?? Library(models: []),
               books: { try await Books.open(data, engine: engine) },
               now: { now },
               names: { CustomerNames.read(data: data) })
    }

    /// The book with `settings.mcp.shareCustomerNames` set — the shop having
    /// chosen to let an assistant read its customers' names.
    static func sharingNames(_ book: [String: JSONValue], _ on: JSONValue = .bool(true)) -> [String: JSONValue] {
        var book = book
        var settings = Self.settings(book)
        settings["mcp"] = .object(["shareCustomerNames": on])
        book["settings"] = .object(settings)
        return book
    }

    static func call(_ server: Server, _ tool: String,
                     _ args: [String: Any] = [:]) async -> [String: Any] {
        McpServerTests.payload(await server.answer(to: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": args]])) ?? [:]
    }

    static func close(_ a: Any?, _ b: Double) -> Bool {
        guard let a = a as? Double ?? (a as? Int).map(Double.init) else { return false }
        return abs(a - b) < 0.006
    }

    // MARK: - Open orders

    @Test("open orders are the dashboard's active jobs, late as attention says, owing as order-money says")
    func openOrdersMatchTheRules() async throws {
        let book = try Self.sample()
        let engine = try KhaytEngine()
        // `dashboardFacts` reads today off the clock, so this one runs at today.
        let now = Date()
        let server = Self.server(try JSONEncoder().encode(book), engine: engine, now: now)
        let out = await Self.call(server, "open_orders", ["limit": 100])
        let rows = out["orders"] as? [[String: Any]] ?? []

        let orders = Self.rows(book, "printLog"), settings = Self.settings(book)
        let facts = try await engine.dashboardFacts(orders: orders, machines: [], settings: settings)
        #expect(out["count"] as? Int == facts.activeCount)
        #expect(rows.count == facts.activeCount)
        #expect(rows.count > 3, "the sample shop has open work; a tool that finds none is broken")

        let late = Dictionary(uniqueKeysWithValues: facts.attn.items
            .filter { $0.kind == "order" }.map { ($0.id, $0.daysLate) })
        #expect(out["late"] as? Int == late.count)
        for row in rows {
            let id = row["id"] as? String ?? ""
            #expect(row["days_late"] as? Int == late[id] ?? nil, "\(id) late by a different count")
            guard let order = orders.first(where: {
                if case .object(let o) = $0 { return o["id"] == .string(id) } else { return false }
            }) else { Issue.record("\(id) is not in the book"); continue }
            let owed = try await engine.owedRaw(order: order, settings: settings)
            #expect(Self.close(row["owed"], owed), "\(id) owes \(owed), tool said \(row["owed"] ?? "nil")")
        }
        // Late first.
        let firstOnTime = rows.firstIndex { $0["days_late"] == nil } ?? rows.count
        #expect(rows[firstOnTime...].allSatisfy { $0["days_late"] == nil })

        let quotes = await Self.call(server, "open_orders", ["include_quotes": true, "limit": 100])
        #expect((quotes["count"] as? Int ?? 0) > (out["count"] as? Int ?? 0),
                "asking for quotes too added none, and the sample shop has seven")
    }

    // MARK: - Receivables

    @Test("receivables are the Reports screen's aged figures, row for row")
    func receivablesMatchTheRule() async throws {
        // Shared, so the names can be held to the rule's own; what is said
        // when they are not is `McpCustomerNamesTests`.
        let book = Self.sharingNames(try Self.sample())
        let engine = try KhaytEngine()
        let server = Self.server(try JSONEncoder().encode(book), engine: engine)
        let out = await Self.call(server, "receivables", ["limit": 100])

        let aged = try await engine.receivables(
            orders: Self.rows(book, "printLog"), settings: Self.settings(book),
            clients: Self.rows(book, "clients"), currencies: try await Self.currencyTable(engine),
            language: "en", now: Self.anchor)
        #expect(aged.rows.count > 0, "the sample shop is owed money")
        #expect(Self.close(out["total_owed"], aged.total))
        #expect(out["count"] as? Int == aged.rows.count)
        let rows = out["rows"] as? [[String: Any]] ?? []
        #expect(rows.count == aged.rows.count)
        for (tool, rule) in zip(rows, aged.rows) {
            #expect(tool["id"] as? String == rule.id)
            #expect(Self.close(tool["owed"], rule.owed))
            #expect(tool["days_outstanding"] as? Int == rule.days)
            #expect(tool["bucket"] as? String == rule.bucket)
            #expect(tool["client"] as? String == rule.client)
        }
        let buckets = out["buckets"] as? [[String: Any]] ?? []
        #expect(buckets.map { $0["label"] as? String ?? "" } == aged.buckets.map(\.label))
        #expect(out["currency"] as? String == "SAR")

        // Days past due are the payment reminder's own count: every invoice it
        // would chase carries exactly the days it chases on.
        let owed = try await engine.owedByOrder(
            Self.rows(book, "printLog"), settings: Self.settings(book),
            clients: Self.rows(book, "clients"), currencies: try await Self.currencyTable(engine))
        let chased = try await engine.invoicesToChase(
            orders: Self.rows(book, "printLog"), settings: Self.settings(book),
            owed: owed, now: Self.anchor)
        #expect(!chased.isEmpty, "the sample shop has invoices past due")
        for chase in chased {
            let row = rows.first { $0["id"] as? String == chase.id && $0["instalment"] as? Bool == false }
            #expect(row?["days_past_due"] as? Int == chase.days, "\(chase.id)")
        }

        let overdue = await Self.call(server, "receivables", ["overdue_only": true, "limit": 100])
        let late = overdue["rows"] as? [[String: Any]] ?? []
        #expect(!late.isEmpty)
        #expect(late.count < rows.count, "overdue_only filtered nothing")
        #expect(late.allSatisfy { ($0["days_past_due"] as? Int ?? 0) > 0 || $0["instalment"] as? Bool == true })
    }

    // MARK: - Stock runway

    @Test("stock runway reserves what the reorder rule reserves and flags what the shelf flags")
    func stockRunwayMatchesTheRules() async throws {
        let book = try Self.sample()
        let engine = try KhaytEngine()
        let server = Self.server(try JSONEncoder().encode(book), engine: engine)
        let out = await Self.call(server, "stock_runway", ["limit": 100])
        let items = out["items"] as? [[String: Any]] ?? []
        #expect(!items.isEmpty, "the sample shelf has something low")

        let spools = Self.rows(book, "inventory"), settings = Self.settings(book)
        let runway = try await engine.runway(spools: spools, orders: Self.rows(book, "printLog"),
                                             now: Self.anchor)
        let low = try await engine.lowStock(spools, settings: settings)
        let toOrder = try await engine.needsOrdering(
            spools: spools, consumables: Self.rows(book, "consumables"),
            orders: Self.rows(book, "printLog"), purchaseOrders: Self.rows(book, "purchaseOrders"),
            settings: settings, now: Self.anchor)

        for item in items where item["kind"] as? String == "filament" {
            let id = item["id"] as? String ?? ""
            guard let r = runway[id] else { Issue.record("\(id) has no runway"); continue }
            // The reorder list rounds to the gram; the shelf's runway does not.
            #expect(Self.close(item["reserved"], r.committedG.rounded()), "\(id) reserved")
            #expect(Self.close(item["available"], r.available.rounded()), "\(id) available")
            #expect(item["low"] as? Bool == low[id], "\(id) low")
        }
        // Every spool the shelf calls low is on the list.
        for (id, isLow) in low where isLow {
            #expect(items.contains { $0["id"] as? String == id }, "\(id) is low and not listed")
        }
        // And what it would order is exactly what the shelf offers to order.
        let flagged = Set(items.filter { $0["needs_ordering"] as? Bool == true }
            .compactMap { $0["id"] as? String })
        #expect(flagged == Set(toOrder.map(\.id)))
    }

    // MARK: - P&L

    @Test("the P&L is the Reports screen's rows, net of VAT")
    func pnlMatchesTheRule() async throws {
        let book = try Self.sample()
        let engine = try KhaytEngine()
        let server = Self.server(try JSONEncoder().encode(book), engine: engine)
        let orders = Self.rows(book, "printLog"), machines = Self.rows(book, "machines")
        let values = try await engine.machineValues(machines: machines, orders: orders,
                                                    today: Calendar.book.dayString(Self.anchor))
        for granularity in ["quarter", "month"] {
            let out = await Self.call(server, "profit_and_loss",
                                      ["granularity": granularity, "limit": 24])
            let rule = try await engine.pnlByPeriod(
                orders: orders, expenses: Self.rows(book, "expenses"),
                settings: Self.settings(book), clients: Self.rows(book, "clients"),
                currencies: try await Self.currencyTable(engine), now: Self.anchor,
                granularity: granularity, wasteLog: Self.rows(book, "wasteLog"),
                inventory: Self.rows(book, "inventory"), machines: machines,
                recentMonthlyHours: values.compactMapValues { $0.recentMonthlyHours },
                timeEntries: Self.rows(book, "timeEntries"))
            let periods = out["periods"] as? [[String: Any]] ?? []
            #expect(periods.count == rule.count)
            #expect(rule.contains { $0.revenue > 0 }, "the sample shop earned nothing")
            for p in rule {
                guard let row = periods.first(where: { $0["period"] as? String == p.period }) else {
                    Issue.record("\(p.period) missing"); continue
                }
                #expect(Self.close(row["revenue_net_of_vat"], p.revenue), "\(p.period) revenue")
                #expect(Self.close(row["vat_collected"], p.vatCollected), "\(p.period) VAT")
                #expect(Self.close(row["net"], p.net), "\(p.period) net")
                #expect(Self.close(row["cost_of_goods"], p.cogs ?? 0), "\(p.period) cogs")
            }
            // Newest first.
            let names = periods.compactMap { $0["period"] as? String }
            #expect(names == names.sorted(by: >))
        }
        // One named period, and its granularity read off its name.
        let one = await Self.call(server, "profit_and_loss", ["period": "2026-08"])
        #expect(one["granularity"] as? String == "month")
        #expect((one["periods"] as? [Any])?.count == 1)
        let none = await Self.call(server, "profit_and_loss", ["period": "1999-Q1"])
        #expect(none["error"] != nil)
    }

    // MARK: - Quote draft

    @Test("a quote draft is the calculator's cost and price, and saves nothing")
    func quoteMatchesTheCalculator() async throws {
        let book = try Self.sample()
        let engine = try KhaytEngine()
        let server = Self.server(try JSONEncoder().encode(book), engine: engine)
        let out = await Self.call(server, "quote_draft",
                                  ["grams": 120, "hours": 5.5, "qty": 3, "spool_id": "sp-1",
                                   "margin_pct": 40, "rush": true])
        #expect(out["draft"] as? Bool == true)
        #expect(out["saved"] as? Bool == false)

        // The same part `Shop.costInput` builds for spool sp-1.
        guard case .object(let spool)? = Self.rows(book, "inventory").first(where: {
            if case .object(let o) = $0 { return o["id"] == .string("sp-1") } else { return false }
        }) else { Issue.record("no sp-1"); return }
        var part: [String: JSONValue] = ["printWeight": .number(120), "printTime": .number(5.5),
                                         "qty": .number(3), "filamentId": .string("sp-1"),
                                         "spoolCost": spool["cost"] ?? .number(0),
                                         "spoolWeight": spool["spoolWeight"] ?? .number(1000)]
        part["material"] = spool["material"]
        let settings = Self.settings(book)
        let costed = try await engine.costPart(.object(part), inventory: Self.rows(book, "inventory"),
                                               settings: settings,
                                               consumables: Self.rows(book, "consumables"))
        #expect(costed.cost > 0)
        let cost = out["cost"] as? [String: Any]
        #expect(Self.close(cost?["per_unit"], costed.cost))

        let quote = try await engine.quoteTotal([
            "baseCost": .number(costed.cost * 3), "qty": .number(1), "margin": .number(40),
            "discountPct": .number(0), "shippingCost": .number(0), "rushEnabled": .bool(true),
            "rushPct": .number(25), "business": .bool(true), "agreedAmount": .number(0),
        ])
        let price = out["price"] as? [String: Any]
        #expect(Self.close(price?["total"], quote.total))
        #expect(Self.close(price?["rush_fee"], quote.rushFee))
        #expect(quote.rushFee > 0)

        // The sample shop is VAT-registered and prices inclusive: the tax is
        // inside the total, and the invoice prints the same total.
        let tax = out["tax"] as? [String: Any]
        #expect(tax?["mode"] as? String == "inclusive")
        #expect(Self.close(tax?["invoice_total"], quote.total))
        #expect((tax?["tax"] as? Double ?? 0) > 0)

        #expect(await Self.call(server, "quote_draft", ["hours": 1])["error"] != nil,
                "a quote with no weight was priced")
        #expect(await Self.call(server, "quote_draft",
                                ["grams": 1, "hours": 1, "spool_id": "nope"])["error"] != nil)
    }

    // MARK: - Bounded

    @Test("every list is capped and says so")
    func listsAreBounded() async throws {
        let engine = try KhaytEngine()
        let server = Self.server(try JSONEncoder().encode(try Self.sample()), engine: engine)
        for tool in ["open_orders", "receivables", "stock_runway"] {
            let full = await Self.call(server, tool, ["limit": 100])
            let one = await Self.call(server, tool, ["limit": 1])
            #expect(full["truncated"] as? Bool == false, "\(tool) cut short at 100")
            let key = ["open_orders": "orders", "receivables": "rows", "stock_runway": "items"][tool]!
            #expect((one[key] as? [Any])?.count == 1, "\(tool)")
            #expect(one["truncated"] as? Bool == ((full["count"] as? Int ?? 0) > 1), "\(tool)")
            let huge = await Self.call(server, tool, ["limit": 9_999_999])
            #expect(((huge[key] as? [Any])?.count ?? 0) <= 100, "\(tool)")
        }
    }

    // MARK: - What it must never say, and never do

    /// A book carrying every kind of thing the tools must not repeat: a PIN
    /// hash, the recovery hash, a sealed value, a credential at a listed path,
    /// and a customer's phone and email.
    static func bookWithSecrets() throws -> [String: JSONValue] {
        var book = try sample()
        let secrets = Self.secrets
        if case .array(var ops)? = book["operators"], case .object(var first)? = ops.first {
            first["pinHash"] = .string(secrets["pin"]!)
            ops[0] = .object(first)
            book["operators"] = .array(ops)
        }
        var settings = Self.settings(book)
        settings["recoveryCodeHash"] = .string(secrets["recovery"]!)
        settings["ai"] = .object(["apiKey": .string(secrets["sealed"]!)])
        settings["cloud"] = .object(["token": .string(secrets["token"]!)])
        book["settings"] = .object(settings)
        if case .array(var clients)? = book["clients"], case .object(var c)? = clients.first {
            c["phone"] = .string(secrets["phone"]!)
            c["email"] = .string(secrets["email"]!)
            clients[0] = .object(c)
            book["clients"] = .array(clients)
        }
        return book
    }

    static let secrets = [
        "pin": "scrypt$PINHASH-must-not-leave",
        "recovery": "scrypt$RECOVERY-must-not-leave",
        "sealed": "__enc__SEALED-must-not-leave",
        "token": "CLOUDTOKEN-must-not-leave",
        "phone": "+966500000999",
        "email": "never-said@example.com",
    ]

    @Test("no tool repeats a secret, a PIN hash, a sealed value or a customer's contact details")
    func nothingPrivateLeaves() async throws {
        let engine = try KhaytEngine()
        let data = try JSONEncoder().encode(try Self.bookWithSecrets())
        let server = Self.server(data, engine: engine)

        // Masked before any tool reads it.
        let books = try await Books.open(data, engine: engine)
        let held = String(decoding: try JSONEncoder().encode(books.book), as: UTF8.self)
        for key in ["pin", "recovery", "sealed", "token"] {
            #expect(!held.contains(Self.secrets[key]!), "\(key) survived the mask")
        }

        var said = ""
        let calls: [(String, [String: Any])] = [
            ("open_orders", ["include_quotes": true, "limit": 100]),
            ("receivables", ["limit": 100]),
            ("stock_runway", ["limit": 100]),
            ("profit_and_loss", ["granularity": "month", "limit": 24]),
            ("quote_draft", ["grams": 50, "hours": 2, "spool_id": "sp-1"]),
            ("library_summary", [:]),
            ("search_models", ["limit": 200]),
        ]
        for (tool, args) in calls {
            let response = await server.answer(to: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool, "arguments": args]])
            said += String(decoding: try JSONSerialization.data(withJSONObject: response ?? [:]),
                           as: UTF8.self)
        }
        #expect(said.count > 1000, "the tools said almost nothing; this check would pass vacuously")
        for (key, value) in Self.secrets {
            #expect(!said.contains(value), "\(key) was repeated to the assistant")
        }
        #expect(!said.contains("__enc__"))
        #expect(!said.contains("pinHash"))
    }

    /// READ-ONLY, proved on a real file: every tool is asked, and the book
    /// and the folder it sits in are byte-for-byte as they were — no write, no
    /// temporary file beside it, no `.prev`.
    @Test("asking every tool leaves the book and its folder untouched")
    func nothingIsWritten() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "khayt-mcp-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appending(path: "khayt-store.json")
        try Data(contentsOf: Self.sampleURL).write(to: store)
        let before = try Data(contentsOf: store)
        let stamp = try FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as? Date

        let engine = try KhaytEngine()
        let server = Server(library: try Library.read(from: store),
                            books: { try await Books.open(Library.bookData(at: store), engine: engine) },
                            now: { Self.anchor })
        for tool in Server.bookTools.sorted() {
            let out = await Self.call(server, tool, ["grams": 80, "hours": 3])
            #expect(out["error"] == nil, "\(tool): \(out["error"] ?? "")")
        }
        #expect(try Data(contentsOf: store) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as? Date
                == stamp)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["khayt-store.json"])
    }
}
