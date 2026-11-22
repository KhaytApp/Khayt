import Foundation
import KhaytCore

/// Khayt's library and books, answerable by an assistant — the Model Context
/// Protocol.
///
/// ── WHY THIS IS A SEPARATE BINARY AND NOT A WINDOW ────────────────────────
///
/// An MCP host — Claude Desktop, Cursor, Codex — launches a command and speaks
/// JSON-RPC to it down a pipe. It cannot talk to a running app, and a shop
/// should not have to leave Khayt open to ask a question about its models. So
/// this is an executable beside `KhaytThumbnail` and `KhaytPreview`, which are
/// already small programs on `KhaytCore` for the same reason.
///
/// ── WHAT IT ANSWERS ───────────────────────────────────────────────────────
///
/// The library (`Library`), and five READ-ONLY questions about the books
/// (`Books`): open orders, who owes what, what is running out, the P&L, and a
/// quote worked out and never saved. This file is the protocol and nothing
/// else: every question it can be asked is one of the tools below, none of
/// them takes a path, a query language or anything else that could be pointed
/// somewhere new, and none of them writes.
///
/// ── PURE, SO IT CAN BE TESTED WITHOUT A PIPE ──────────────────────────────
///
/// `answer(to:)` takes a request and returns a response. Nothing here reads
/// stdin or writes stdout — `main.swift` does that — so the protocol is
/// exercised by handing it bytes, which is what `McpServerTests` does.
struct Server: Sendable {
    let library: Library
    /// The books, read fresh for each question — nil when the rules could not
    /// start, and the books tools then say so.
    var books: (@Sendable () async throws -> Books)? = nil
    /// Today, for every "how late" and "which quarter". Injected so a test can
    /// hold the sample book at a fixed day.
    var now: @Sendable () -> Date = { Date() }
    /// Whose names the LIBRARY tools may say — read from the book per
    /// question, like the books, so turning the setting on or off in Khayt
    /// holds from the next question without restarting the host. The books
    /// tools carry their own (`Books.names`), from the same book by the same
    /// rule, so a label is the same customer in both.
    var names: @Sendable () -> CustomerNames = { .none }
    /// The shared rules, for taking phones, emails and IBANs out of what the
    /// LIBRARY tools say (`Outgoing`). Nil — the rules could not start — and
    /// every title, project and tag is said as `<redacted>`: fail closed.
    var engine: KhaytEngine? = nil

    /// The protocol version this speaks. MCP negotiates: the host sends the
    /// version it wants and a server that knows a different one says so rather
    /// than guessing.
    static let protocolVersion = "2024-11-05"

    /// How many projects a summary names. The rest are counted, not listed —
    /// `search_models` is how you find a particular one.
    static let projectsShown = 20

    // `nonisolated(unsafe)` because this is a literal that is written once at
    // launch and only ever read. A `[String: Any]` cannot be `Sendable` — the
    // schemas are JSON, which has no Swift type — and wrapping it in an actor
    // to satisfy a checker it cannot satisfy honestly would buy nothing.
    nonisolated(unsafe) static let tools: [[String: Any]] = [
        [
            "name": "search_models",
            "description": """
                Search the 3D print shop's model library by title, project, \
                category, tag, material, designer or licence. Returns the \
                models that match.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string",
                              "description": "Words to look for. Empty matches everything."],
                    "never_printed": ["type": "boolean",
                                      "description": "Only models the shop has never printed."],
                    "sellable": ["type": "boolean",
                                 "description": """
                                     True for models whose licence permits selling a print, \
                                     false for those it forbids. Models with no recorded \
                                     licence are in neither: nobody has said.
                                     """],
                    "limit": ["type": "integer", "description": "At most this many. Default 25."],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "get_model",
            "description": "Everything the library records about one model, by its id.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
            ],
        ],
        [
            "name": "library_summary",
            "description": """
                How big the library is and what is in it: totals, the projects, \
                and how many models carry no licence.
                """,
            "inputSchema": ["type": "object", "properties": [:] as [String: Any],
                            "required": [] as [String]],
        ],
        [
            "name": "open_orders",
            "description": """
                The shop's open jobs — not finished, not voided: status, \
                customer, due date, days late, and what each is worth and still \
                owes, in the job's own currency. Late jobs first. Read-only. \
                Unless the shop shares customer names, a customer is a label \
                such as "Customer 3", the same customer in every answer.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "include_quotes": ["type": "boolean",
                                       "description": "Also list quotes not yet accepted."],
                    "late_only": ["type": "boolean",
                                  "description": "Only jobs past the date promised."],
                    "limit": ["type": "integer",
                              "description": "At most this many. Default 25, at most 100."],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "receivables",
            "description": """
                Who owes the shop money and for how long, aged as the Reports \
                screen ages it: each unpaid job or instalment, days outstanding, \
                the 0-30/31-60/61-90/90+ buckets, and days past the due date \
                where one was set. In the shop's own currency. Read-only. \
                Customers are labelled as in open_orders.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "overdue_only": ["type": "boolean",
                                     "description": "Only amounts past a due date that was set."],
                    "limit": ["type": "integer",
                              "description": "At most this many rows. Default 25, at most 100."],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "stock_runway",
            "description": """
                Filament and consumables that are low, will run out within the \
                window at the recent rate of use, or are promised to open jobs \
                beyond what is on the shelf — with the grams those jobs have \
                reserved and whether a purchase order is still needed. Read-only.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "within_days": ["type": "integer",
                                    "description": "Running out within this many days. Default 14."],
                    "limit": ["type": "integer",
                              "description": "At most this many. Default 25, at most 100."],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "profit_and_loss",
            "description": """
                The shop's P&L by quarter or month, as the Reports screen shows \
                it: revenue net of VAT, cost of goods, expenses, fixed overhead, \
                waste, depreciation, labour, VAT collected and due, net and \
                margin. Newest first. Read-only.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "period": ["type": "string",
                               "description": "One period, \"2026-Q3\" or \"2026-09\". Omit for the latest."],
                    "granularity": ["type": "string", "enum": ["quarter", "month"],
                                    "description": "Default quarter."],
                    "limit": ["type": "integer",
                              "description": "How many periods. Default 4, at most 24."],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "quote_draft",
            "description": """
                Work out what a print would cost the shop and what to charge, \
                with the shop's own calculator rules, rates, margin and tax. A \
                DRAFT: nothing is saved — no job, no quote, no customer.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "grams": ["type": "number", "description": "Filament per piece, in grams."],
                    "hours": ["type": "number", "description": "Print time per piece, in hours."],
                    "qty": ["type": "integer", "description": "Pieces. Default 1, at most 1000."],
                    "spool_id": ["type": "string",
                                 "description": "The spool it prints from, for the material's price."],
                    "machine_id": ["type": "string",
                                   "description": "The machine, for its wear and power."],
                    "preset_id": ["type": "string", "description": "A saved printer preset."],
                    "margin_pct": ["type": "number",
                                   "description": "Markup on cost. Default the shop's own."],
                    "discount_pct": ["type": "number"],
                    "rush": ["type": "boolean"],
                    "shipping_cost": ["type": "number"],
                ],
                "required": ["grams", "hours"],
            ],
        ],
    ]

    /// The tools that read the books rather than the library.
    static let bookTools: Set<String> = ["open_orders", "receivables", "stock_runway",
                                         "profit_and_loss", "quote_draft"]

    // MARK: - One request in, one response out

    func answer(to request: [String: Any]) async -> [String: Any]? {
        let method = request["method"] as? String ?? ""
        let id = request["id"]
        // A NOTIFICATION HAS NO ID AND TAKES NO ANSWER. Replying to one is a
        // protocol error, and hosts differ in how loudly they complain.
        guard id != nil else { return nil }

        switch method {
        case "initialize":
            return ok(id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "khayt", "version": "2"],
            ])
        case "tools/list":
            return ok(id, ["tools": Self.tools])
        case "tools/call":
            return await call(id, request["params"] as? [String: Any] ?? [:])
        case "ping":
            return ok(id, [:])
        default:
            return fail(id, -32601, "no method \(method)")
        }
    }

    private func call(_ id: Any?, _ params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        if Self.bookTools.contains(name) { return ok(id, content(await fromBooks(name, args))) }
        switch name {
        case "search_models":  return ok(id, content(search(args, await models())))
        case "get_model":      return ok(id, content(one(args, await models())))
        case "library_summary":return ok(id, content(summary(await models())))
        default:               return fail(id, -32602, "no tool \(name)")
        }
    }

    // MARK: - The books

    /// A books question, answered — or why it could not be. Said in the
    /// result rather than as a protocol error: the question was a fair one,
    /// and the assistant should be told why there is no answer.
    private func fromBooks(_ name: String, _ args: [String: Any]) async -> Any {
        guard let books else { return ["error": "Khayt's rules could not start, so the books cannot be read."] }
        let at = now()
        do {
            let book = try await books()
            switch name {
            case "open_orders":     return try await book.openOrders(args, now: at)
            case "receivables":     return try await book.receivables(args, now: at)
            case "stock_runway":    return try await book.stockRunway(args, now: at)
            case "profit_and_loss": return try await book.profitAndLoss(args, now: at)
            case "quote_draft":     return try await book.quoteDraft(args)
            default:                return ["error": "no tool \(name)"]
            }
        } catch {
            return ["error": "could not answer from the book: \(error)"]
        }
    }

    // MARK: - The library

    /// The library as an assistant may read it: every customer name in a
    /// title, a project, a category, a tag or a designer replaced by its label
    /// unless the shop shares names, and every phone, email, IBAN and long
    /// number taken out whatever it is set to (`Outgoing`). Searched AFTER
    /// that, so a search for a customer's name or number cannot pick out the
    /// models that carry it.
    private func models() async -> [Library.Model] {
        await Library.Model.cleaned(library.models, Outgoing(names: names(), engine: engine))
    }

    private func search(_ args: [String: Any], _ models: [Library.Model]) -> Any {
        var found = models
        if let q = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !q.isEmpty {
            // Every word has to appear somewhere, so "dragon flexi" narrows
            // rather than widening — a shop searching two words means both.
            let words = q.split(separator: " ").map(String.init)
            found = found.filter { model in words.allSatisfy { model.haystack.contains($0) } }
        }
        if args["never_printed"] as? Bool == true {
            found = found.filter { $0.timesPrinted == 0 }
        }
        if let wants = args["sellable"] as? Bool {
            // NOT `!= wants`: a model nobody has recorded a licence for is in
            // neither answer. Unknown is not a no, and a shop asking "what can
            // I sell" must not be handed models on the strength of silence.
            found = found.filter { $0.sellable == wants }
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 25, 200))
        return ["count": found.count, "models": found.prefix(limit).map(Self.dictionary(of:))]
    }

    private func one(_ args: [String: Any], _ models: [Library.Model]) -> Any {
        let id = args["id"] as? String ?? ""
        guard let model = models.first(where: { $0.id == id }) else {
            return ["error": "no model with id \(id)"]
        }
        return Self.dictionary(of: model)
    }

    private func summary(_ models: [Library.Model]) -> Any {
        var byGroup: [String: Int] = [:]
        for m in models { byGroup[m.group ?? "(unfiled)", default: 0] += 1 }
        return [
            "models": models.count,
            "never_printed": models.count { $0.timesPrinted == 0 },
            // Said as its own figure rather than folded into a yes/no, because
            // "no licence recorded" is the commonest state of a real library
            // and the one a shop can act on.
            "no_licence_recorded": models.count { $0.licence == nil },
            "cannot_be_sold": models.count { $0.sellable == false },
            // BIGGEST FIRST AND CAPPED. This shop's book has 236 models across
            // dozens of projects, and a summary is read by a model with a
            // budget: a hundred project names, most of them holding one model,
            // crowd out the four figures above that are the point of asking.
            "projects": byGroup.sorted { $0.value > $1.value }.prefix(Self.projectsShown)
                .map { ["name": $0.key, "models": $0.value] },
            "projects_total": byGroup.count,
        ]
    }

    // MARK: - Shapes

    static func dictionary(of m: Library.Model) -> [String: Any] {
        var out: [String: Any] = ["id": m.id, "title": m.title,
                                  "times_printed": m.timesPrinted]
        if let v = m.group { out["project"] = v }
        if let v = m.category { out["category"] = v }
        if !m.tags.isEmpty { out["tags"] = m.tags }
        if let v = m.material { out["material"] = v }
        if let v = m.designer { out["designer"] = v }
        if let v = m.licence { out["licence"] = v }
        if let v = m.sellable { out["sellable"] = v }
        if let v = m.lastPrinted { out["last_printed"] = v }
        if let v = m.sizeBytes { out["size_bytes"] = v }
        if let v = m.fileKind { out["file_kind"] = v }
        return out
    }

    /// MCP wants tool output as content blocks. JSON in a text block is what
    /// every host renders and what a model reads most reliably.
    private func content(_ value: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value,
                                                options: [.sortedKeys, .prettyPrinted]))
            ?? Data("{}".utf8)
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }

    private func ok(_ id: Any?, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func fail(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(),
         "error": ["code": code, "message": message]]
    }
}
