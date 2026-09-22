import Foundation

/// Khayt's library, answerable by an assistant — the Model Context Protocol.
///
/// ── WHY THIS IS A SEPARATE BINARY AND NOT A WINDOW ────────────────────────
///
/// An MCP host — Claude Desktop, Cursor, Codex — launches a command and speaks
/// JSON-RPC to it down a pipe. It cannot talk to a running app, and a shop
/// should not have to leave Khayt open to ask a question about its models. So
/// this is an executable beside `KhaytThumbnail` and `KhaytPreview`, which are
/// already small programs on `KhaytCore` for the same reason.
///
/// ── AND WHY IT ANSWERS ONLY ABOUT THE LIBRARY ─────────────────────────────
///
/// `Library` says what it can see and what it refuses to. This file is the
/// protocol and nothing else: every question it can be asked is one of the
/// three tools below, and none of them takes a path, a query language or
/// anything else that could be pointed somewhere new.
///
/// ── PURE, SO IT CAN BE TESTED WITHOUT A PIPE ──────────────────────────────
///
/// `answer(to:)` takes a request and returns a response. Nothing here reads
/// stdin or writes stdout — `main.swift` does that — so the protocol is
/// exercised by handing it bytes, which is what `McpServerTests` does.
struct Server {
    let library: Library

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
    ]

    // MARK: - One request in, one response out

    func answer(to request: [String: Any]) -> [String: Any]? {
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
                "serverInfo": ["name": "khayt-library", "version": "1"],
            ])
        case "tools/list":
            return ok(id, ["tools": Self.tools])
        case "tools/call":
            return call(id, request["params"] as? [String: Any] ?? [:])
        case "ping":
            return ok(id, [:])
        default:
            return fail(id, -32601, "no method \(method)")
        }
    }

    private func call(_ id: Any?, _ params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "search_models":  return ok(id, content(search(args)))
        case "get_model":      return ok(id, content(one(args)))
        case "library_summary":return ok(id, content(summary()))
        default:               return fail(id, -32602, "no tool \(name)")
        }
    }

    // MARK: - The three answers

    private func search(_ args: [String: Any]) -> Any {
        var found = library.models
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

    private func one(_ args: [String: Any]) -> Any {
        let id = args["id"] as? String ?? ""
        guard let model = library.models.first(where: { $0.id == id }) else {
            return ["error": "no model with id \(id)"]
        }
        return Self.dictionary(of: model)
    }

    private func summary() -> Any {
        let models = library.models
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
