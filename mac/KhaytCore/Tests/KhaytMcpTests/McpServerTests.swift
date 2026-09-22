import Foundation
import Testing
@testable import KhaytMcp

/// The protocol, and the one thing it must never answer.
///
/// `Server` is pure — a request in, a response out — so this exercises the real
/// protocol by handing it dictionaries rather than by spawning a process and
/// hoping. `main.swift` is the only part that touches a pipe, and it decides
/// nothing.
struct McpServerTests {

    static func model(id: String, title: String, printed: Int = 0,
                      licence: String? = nil, designer: String? = nil,
                      group: String? = nil, tags: [String] = []) -> Library.Model {
        Library.Model(id: id, title: title, group: group, category: nil, tags: tags,
                      material: nil, designer: designer, licence: licence,
                      sellable: licence.flatMap {
                          ["cc-by-nc-sa": false, "cc-by-nc": false,
                           "cc-by": true, "own": true][$0]
                      },
                      timesPrinted: printed, lastPrinted: nil,
                      sizeBytes: nil, fileKind: "3mf")
    }

    static let shop = Server(library: Library(models: [
        model(id: "PF-1", title: "Flexi Dragon", printed: 4, licence: "cc-by",
              designer: "PinkyWings", group: "Toys", tags: ["flexi"]),
        model(id: "PF-2", title: "Slide Shoes", licence: "cc-by-nc-sa",
              designer: "MakerVerse Designs"),
        model(id: "PF-3", title: "Falcon hood", printed: 12, designer: "The3Dee",
              group: "Saudi Kings"),
        model(id: "PF-4", title: "Turbine bracket", group: "Saudi Kings"),
    ]))

    static func result(_ response: [String: Any]?) -> Any? {
        (response?["result"] as? [String: Any])
    }

    /// Tool output comes back as a content block holding JSON text.
    static func payload(_ response: [String: Any]?) -> [String: Any]? {
        guard let result = response?["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func call(_ tool: String, _ args: [String: Any] = [:]) -> [String: Any]? {
        payload(shop.answer(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                 "params": ["name": tool, "arguments": args]]))
    }

    // MARK: - Protocol

    @Test("it introduces itself with the version it speaks")
    func handshake() {
        let out = Self.shop.answer(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        let result = out?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == Server.protocolVersion)
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "khayt-library")
        #expect(out?["id"] as? Int == 1)
    }

    /// A NOTIFICATION HAS NO ID AND TAKES NO ANSWER. Replying to one is a
    /// protocol error and hosts differ in how loudly they complain, so this is
    /// the kind of bug that works everywhere except the host somebody uses.
    @Test("a notification is not answered")
    func notificationsAreSilent() {
        #expect(Self.shop.answer(to: ["jsonrpc": "2.0", "method": "notifications/initialized"])
                == nil)
        #expect(Self.shop.answer(to: ["jsonrpc": "2.0", "method": "anything/at/all"]) == nil)
    }

    @Test("every tool it advertises is one it can be asked")
    func toolsAreReal() {
        let out = Self.shop.answer(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let listed = (out?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(listed.count == 3)
        for tool in listed {
            let name = tool["name"] as? String ?? ""
            #expect(tool["description"] != nil, "\(name) has no description")
            #expect(tool["inputSchema"] != nil, "\(name) has no schema")
            let out = Self.shop.answer(to: ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                            "params": ["name": name,
                                                       "arguments": ["id": "PF-1"]]])
            #expect(out?["error"] == nil, "\(name) is advertised and cannot be called")
        }
    }

    @Test("an unknown method and an unknown tool are refused, not ignored")
    func refusals() {
        let m = Self.shop.answer(to: ["jsonrpc": "2.0", "id": 4, "method": "does/not/exist"])
        #expect((m?["error"] as? [String: Any])?["code"] as? Int == -32601)
        let t = Self.shop.answer(to: ["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                      "params": ["name": "delete_everything"]])
        #expect((t?["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    // MARK: - The answers

    @Test("search narrows on every word, not on any of them")
    func searchIsAnAnd() {
        let both = Self.call("search_models", ["query": "flexi dragon"])
        #expect(both?["count"] as? Int == 1)
        let neither = Self.call("search_models", ["query": "flexi bracket"])
        #expect(neither?["count"] as? Int == 0, """
            two words matched models holding either one — a shop searching two \
            words means both
            """)
    }

    @Test("it can find what the shop has never made")
    func neverPrinted() {
        let out = Self.call("search_models", ["never_printed": true])
        let titles = (out?["models"] as? [[String: Any]])?.compactMap { $0["title"] as? String }
        #expect(titles?.sorted() == ["Slide Shoes", "Turbine bracket"])
    }

    /// THE ONE THAT MATTERS. A model with no recorded licence is in NEITHER
    /// answer. Unknown is not a no, and a shop asking "what may I sell" must
    /// not be handed models on the strength of silence.
    @Test("a model with no licence is neither sellable nor unsellable")
    func silenceIsNotAnAnswer() {
        let yes = (Self.call("search_models", ["sellable": true])?["models"] as? [[String: Any]])?
            .compactMap { $0["title"] as? String } ?? []
        let no = (Self.call("search_models", ["sellable": false])?["models"] as? [[String: Any]])?
            .compactMap { $0["title"] as? String } ?? []
        #expect(yes == ["Flexi Dragon"])
        #expect(no == ["Slide Shoes"])
        for unknown in ["Falcon hood", "Turbine bracket"] {
            #expect(!yes.contains(unknown), "\(unknown) has no licence and was offered as sellable")
            #expect(!no.contains(unknown), "\(unknown) has no licence and was called unsellable")
        }
    }

    @Test("the summary counts what a shop can act on")
    func summaryIsUseful() {
        let out = Self.call("library_summary")
        #expect(out?["models"] as? Int == 4)
        #expect(out?["never_printed"] as? Int == 2)
        #expect(out?["no_licence_recorded"] as? Int == 2)
        #expect(out?["cannot_be_sold"] as? Int == 1)
        let projects = (out?["projects"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        #expect(projects.contains("Saudi Kings"))
        #expect(projects.contains("(unfiled)"), "models in no project are not counted anywhere")
    }

    @Test("asking for a model that is not there says so rather than inventing one")
    func missingModel() {
        let out = Self.call("get_model", ["id": "PF-nope"])
        #expect(out?["error"] != nil)
        #expect(Self.call("get_model", ["id": "PF-3"])?["title"] as? String == "Falcon hood")
    }

    /// A limit that is absurd must not be honoured. A host that asks for two
    /// million models should get a page, not the process's memory.
    @Test("the page size is bounded at both ends")
    func limitsAreSane() {
        #expect((Self.call("search_models", ["limit": 0])?["models"] as? [Any])?.count == 1)
        #expect((Self.call("search_models", ["limit": 9_999_999])?["models"] as? [Any])?.count == 4)
    }
}
