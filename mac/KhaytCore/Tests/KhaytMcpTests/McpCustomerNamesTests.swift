import Foundation
import Testing
import KhaytCore
@testable import KhaytMcp

/// Customer names leave the Mac only when the shop says so —
/// `settings.mcp.shareCustomerNames`, off unless it is `true`.
///
/// Every check iterates EVERY customer name the sample book holds, in every
/// language it holds them in, against everything every tool says. One name
/// checked would prove one name.
struct McpCustomerNamesTests {

    typealias Book = [String: JSONValue]

    /// The sample book, with a customer's name typed where a shop might type
    /// one: in a job's project, a model's title, a library folder and a tag,
    /// and a job taken for somebody who has no client record.
    static func book(lang: String = "en") throws -> Book {
        var book = try McpBooksTests.sample()
        var settings = McpBooksTests.settings(book)
        settings["lang"] = .string(lang)
        book["settings"] = .object(settings)

        var orders = McpBooksTests.rows(book, "printLog")
        // ORD-01039, KAUST's pending job — open, so open_orders says it.
        if let at = orders.firstIndex(where: { Self.id($0) == "ORD-01039" }),
           case .object(var o) = orders[at] {
            o["project"] = .string("Souq stall sign for Sara Al-Harbi")
            orders[at] = .object(o)
        }
        // A walk-in: a name typed on the job, no client record, still owing.
        if case .object(var o)? = orders.first(where: { Self.id($0) == "ORD-01041" }) {
            o["id"] = .string("ORD-WALKIN")
            o["clientId"] = .string("")
            o["client"] = .string("Abdulrahman Walk-In")
            o["project"] = .string("Keychains")
            orders.append(.object(o))
        }
        book["printLog"] = .array(orders)

        var files = McpBooksTests.rows(book, "printFiles")
        if case .object(var f)? = files.first {
            f["name"] = .string("Nouf Al-Dossari — wedding favour")
            f["folder"] = .string("KAUST Prototyping Lab")
            f["tags"] = .array([.string("hail motors"), .string("relief")])
            files[0] = .object(f)
        }
        book["printFiles"] = .array(files)
        return book
    }

    static func id(_ v: JSONValue) -> String? {
        if case .object(let o) = v, case .string(let s)? = o["id"] { return s }
        return nil
    }

    /// Every customer name in the book: each client's name in every language
    /// it is written in, and every name typed on a job.
    static func everyName(_ book: Book) -> Set<String> {
        var names: Set<String> = []
        for case .object(let c) in McpBooksTests.rows(book, "clients") {
            for (key, value) in c where key.hasPrefix("name") {
                if case .string(let s) = value, !s.isEmpty { names.insert(s) }
            }
        }
        for case .object(let o) in McpBooksTests.rows(book, "printLog") {
            if case .string(let s)? = o["client"], !s.isEmpty { names.insert(s) }
        }
        return names
    }

    nonisolated(unsafe) static let calls: [(String, [String: Any])] = [
        ("open_orders", ["include_quotes": true, "limit": 100]),
        ("receivables", ["limit": 100]),
        ("stock_runway", ["limit": 100]),
        ("profit_and_loss", ["granularity": "month", "limit": 24]),
        ("quote_draft", ["grams": 50, "hours": 2, "spool_id": "sp-1"]),
        ("library_summary", [:]),
        ("search_models", ["limit": 200]),
        ("search_models", ["query": "nouf", "limit": 200]),
        ("search_models", ["query": "kaust", "limit": 200]),
    ]

    /// Everything every tool says about this book, as the assistant reads it.
    static func everything(_ book: Book, engine: KhaytEngine) async throws -> String {
        let server = McpBooksTests.server(try JSONEncoder().encode(book), engine: engine)
        var said = ""
        for (tool, args) in calls {
            let response = await server.answer(to: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool, "arguments": args]])
            // The text the assistant reads, as it reads it — not escaped twice.
            let text = (((response?["result"] as? [String: Any])?["content"] as? [[String: Any]])?
                .first?["text"] as? String) ?? ""
            said += text + "\n"
        }
        return said
    }

    // MARK: - Off

    @Test("off, missing or not a true boolean: no tool says any customer's name",
          arguments: ["missing", "false", "string"])
    func offSaysNoName(_ how: String) async throws {
        let engine = try KhaytEngine()
        for lang in ["en", "ar"] {
            var book = try Self.book(lang: lang)
            switch how {
            case "false":  book = McpBooksTests.sharingNames(book, .bool(false))
            case "string": book = McpBooksTests.sharingNames(book, .string("true"))
            default: break
            }
            let said = try await Self.everything(book, engine: engine)
            #expect(said.count > 5000, "the tools said almost nothing; this would pass vacuously")
            #expect(said.contains("Customer "), "no label was said: nothing was checked")
            let names = Self.everyName(book)
            #expect(names.count >= 31, "the sample book's customers were not all found")
            for name in names {
                #expect(!said.localizedCaseInsensitiveContains(name),
                        "\(lang)/\(how): \(name) was said to the assistant")
            }
        }
    }

    // MARK: - The labels

    @Test("a label is the client's place in the book, and the same in every tool and every call")
    func labelsAreStable() async throws {
        let engine = try KhaytEngine()
        let book = try Self.book()
        let server = McpBooksTests.server(try JSONEncoder().encode(book), engine: engine)

        var position: [String: Int] = [:]
        for (i, c) in McpBooksTests.rows(book, "clients").enumerated() {
            if let id = Self.id(c) { position[id] = i + 1 }
        }
        var clientOf: [String: String] = [:]
        for case .object(let o) in McpBooksTests.rows(book, "printLog") {
            if case .string(let id)? = o["id"], case .string(let c)? = o["clientId"] { clientOf[id] = c }
        }
        func labels(_ tool: String, _ key: String) async -> [String: String] {
            let out = await McpBooksTests.call(server, tool, ["include_quotes": true, "limit": 100])
            var byOrder: [String: String] = [:]
            for row in out[key] as? [[String: Any]] ?? [] {
                if let id = row["id"] as? String, let c = row["client"] as? String { byOrder[id] = c }
            }
            return byOrder
        }

        let open = await labels("open_orders", "orders")
        let owed = await labels("receivables", "rows")
        #expect(open.count > 5 && owed.count > 5)
        // The client's position, counted from one.
        for (order, label) in open.merging(owed, uniquingKeysWith: { a, _ in a }) {
            if let cid = clientOf[order], let at = position[cid] {
                #expect(label == "Customer \(at)", "\(order): \(label)")
            }
        }
        // Across tools: an order in both is the same customer in both.
        let both = Set(open.keys).intersection(owed.keys)
        #expect(!both.isEmpty, "no order is both open and owing; the comparison is empty")
        for id in both { #expect(open[id] == owed[id], "\(id): \(open[id]!) vs \(owed[id]!)") }
        // Across calls.
        #expect(await labels("open_orders", "orders") == open)
        // Two orders for one client carry one label.
        let jood = open.filter { clientOf[$0.key] == "CLI-DEDCB9" }
        #expect(jood.count == 2 && Set(jood.values).count == 1, "\(jood)")
        // A walk-in with no record gets a number after the last client's.
        let clients = McpBooksTests.rows(book, "clients").count
        #expect(open["ORD-WALKIN"] == "Customer \(clients + 1)")

        // The library says the same label for the same customer.
        let models = await McpBooksTests.call(server, "search_models", ["limit": 200])
        let first = (models["models"] as? [[String: Any]])?.first { ($0["id"] as? String) != nil }
        let kaust = "Customer \(position["CLI-8A5045"]!)"
        #expect(open["ORD-01039"] == kaust)
        #expect(first?["project"] as? String == kaust)
        #expect(first?["title"] as? String == "Customer \(position["CLI-F633FC"]!) — wedding favour")
        #expect((first?["tags"] as? [String])?.contains("Customer \(position["CLI-B84866"]!)") == true)
        // A name typed inside a job's project is the same label again.
        let row = (await McpBooksTests.call(server, "open_orders", ["limit": 100])["orders"]
                   as? [[String: Any]])?.first { $0["id"] as? String == "ORD-01039" }
        #expect(row?["project"] as? String == "Souq stall sign for Customer \(position["CLI-1EF91E"]!)")
    }

    @Test("a name is replaced whole, never inside a longer word")
    func scrubIsBounded() {
        let names = CustomerNames(book: [
            "clients": .array([.object(["id": .string("c1"), "nameEn": .string("Al")]),
                               .object(["id": .string("c2"), "nameEn": .string("Sara"),
                                        "nameAr": .string("سارة")])]),
        ])
        #expect(names.scrub("Aluminium bracket") == "Aluminium bracket")
        #expect(names.scrub("Gift for AL, and sara's mum") == "Gift for Customer 1, and Customer 2's mum")
        #expect(names.scrub("هدية سارة") == "هدية Customer 2")
        #expect(names.client(order: "x", named: "") == "")
        #expect(names.client(order: "x", named: "Nobody We Know") == "Customer")
    }

    // MARK: - On

    @Test("on: the tools say the names, as before")
    func onSaysTheNames() async throws {
        let engine = try KhaytEngine()
        let book = McpBooksTests.sharingNames(try Self.book())
        let said = try await Self.everything(book, engine: engine)
        #expect(!said.contains("Customer "), "a label was said while names are shared")
        for name in ["KAUST Prototyping Lab", "Jood Al-Dossari", "Abdulrahman Walk-In",
                     "Souq stall sign for Sara Al-Harbi", "Nouf Al-Dossari — wedding favour"] {
            #expect(said.contains(name), "\(name) is missing")
        }
        // Every name a books tool lists is the rule's own.
        let server = McpBooksTests.server(try JSONEncoder().encode(book), engine: engine)
        let out = await McpBooksTests.call(server, "open_orders", ["include_quotes": true, "limit": 100])
        let rule = try await engine.openOrders(
            orders: McpBooksTests.rows(book, "printLog"), clients: McpBooksTests.rows(book, "clients"),
            settings: McpBooksTests.settings(book),
            currencies: try await McpBooksTests.currencyTable(engine), language: "en",
            now: McpBooksTests.anchor, includeQuotes: true)
        let named = Dictionary(rule.map { ($0.id, $0.client) }, uniquingKeysWith: { a, _ in a })
        let rows = out["orders"] as? [[String: Any]] ?? []
        #expect(!rows.isEmpty)
        for row in rows {
            let id = row["id"] as? String ?? ""
            #expect(row["client"] as? String == named[id], "\(id)")
        }
    }
}
