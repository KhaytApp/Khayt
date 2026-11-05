import Foundation
import Testing
@testable import KhaytCore

/// `ApiTokens` (Swift) is held to `lib/api-tokens.js`: a token minted on either
/// app verifies on the other, and the scope rules are the JavaScript's own.
struct ApiTokensParityTests {

    /// `node -e "console.log(require('./lib/api-tokens.js').hashToken('khayt_parity-vector-0001'))"`
    static let vector = "279ca0ac12575d538a580b015b102823115488007f44bee3d6b660afa06a49ce"

    @Test("the hash is the desktop's SHA-256 hex, byte for byte")
    func hashMatchesTheJavaScript() {
        #expect(ApiTokens.hash("khayt_parity-vector-0001") == Self.vector)
    }

    @Test("a minted token is the desktop's shape, and the record holds only its hash")
    func mintShape() throws {
        let known = ["orders:read", "orders:write", "clients:read"]
        let (token, record) = ApiTokens.mint(label: String(repeating: "x", count: 200),
                                             scopes: ["orders:read", "bogus:scope"], known: known,
                                             now: "2026-11-06T09:00:00.000Z")
        #expect(token.hasPrefix("khayt_"))
        // 32 bytes as unpadded base64url is 43 characters.
        let raw = token.dropFirst(6)
        #expect(raw.count == 43)
        #expect(raw.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(record["hash"] == .string(ApiTokens.hash(token)))
        #expect(record["scopes"] == .array([.string("orders:read")]), "an unknown scope is never written")
        guard case .string(let label)? = record["label"] else { Issue.record("no label"); return }
        #expect(label.count == 60)
        guard case .string(let id)? = record["id"] else { Issue.record("no id"); return }
        #expect(id.hasPrefix("tok_") && id.count == 20)
        let stored = String(decoding: try JSONEncoder().encode(JSONValue.object(record)), as: UTF8.self)
        #expect(!stored.contains(String(raw)), "the plaintext is never in the record")
        let (other, _) = ApiTokens.mint(label: "", scopes: [], known: known, now: "")
        #expect(other != token)
    }

    @Test("verify finds the right record and refuses unknown, revoked, unprefixed and malformed")
    func verify() {
        let a = ApiTokens.mint(label: "A", scopes: ["orders:read"], known: ["orders:read"], now: "")
        let b = ApiTokens.mint(label: "B", scopes: [], known: [], now: "")
        let records: [JSONValue] = [.object(a.record), .object(b.record)]
        #expect(ApiTokens.verify(a.token, against: records)?["label"] == .string("A"))
        #expect(ApiTokens.verify(b.token, against: records)?["label"] == .string("B"))
        #expect(ApiTokens.verify(a.token, against: [.object(b.record)]) == nil, "revoked is refused")
        #expect(ApiTokens.verify("khayt_bogus", against: records) == nil)
        #expect(ApiTokens.verify("no-prefix", against: records) == nil)
        #expect(ApiTokens.verify(nil, against: records) == nil)
        #expect(ApiTokens.verify(a.token, against: [.null, .object([:]), .object(["hash": .number(1)]),
                                                   .object(["hash": .string("__KHAYT_MASKED__")])]) == nil)
        #expect(ApiTokens.hasScope(a.record, "orders:read"))
        #expect(!ApiTokens.hasScope(a.record, "orders:write"), "read never implies write")
    }

    @Test("the bearer is read as the desktop reads it")
    func bearer() {
        #expect(ApiTokens.bearer(from: "Bearer khayt_abc") == "khayt_abc")
        #expect(ApiTokens.bearer(from: "bearer   khayt_abc") == "khayt_abc")
        #expect(ApiTokens.bearer(from: "Bearer someothertoken") == nil)
        #expect(ApiTokens.bearer(from: "Basic khayt_abc") == nil)
        #expect(ApiTokens.bearer(from: "Bearerkhayt_abc") == nil)
        #expect(ApiTokens.bearer(from: "") == nil)
        #expect(ApiTokens.bearer(from: nil) == nil)
    }

    @Test("the scope rules come from the JavaScript, and the phone never sees a hash")
    func scopesAreTheJavaScripts() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.apiTokenScopes() == ["orders:read", "orders:write", "clients:read", "clients:write",
                                                       "inventory:read", "inventory:write", "machines:read"])
        #expect(try await engine.apiTokenScope(path: "/v1/orders", method: "GET") == "orders:read")
        #expect(try await engine.apiTokenScope(path: "/v1/orders/A1", method: "PATCH") == "orders:write")
        #expect(try await engine.apiTokenScope(path: "/v1/queue", method: "GET") == "orders:read")
        #expect(try await engine.apiTokenScope(path: "/v1/waiting-list/w1", method: "PATCH") == "clients:write")
        #expect(try await engine.apiTokenScope(path: "/v1/machines", method: "POST") == "machines:read")
        #expect(try await engine.apiTokenScope(path: "/v1/waste", method: "POST") == nil, "waste takes the PIN")
        #expect(try await engine.apiTokenScope(path: "/v1/store", method: "GET") == nil, "the book takes the PIN")
        let minted = ApiTokens.mint(label: "Z", scopes: ["orders:read"], known: ["orders:read"], now: "x")
        let redacted = try await engine.apiTokensRedacted(.array([.object(minted.record)]))
        guard case .object(let row)? = redacted.first else { Issue.record("no row"); return }
        #expect(row["hash"] == nil, "the owner-facing list never carries the hash")
        let book: [String: JSONValue] = ["settings": .object(["lanApi": .object(["apiTokens": .array([.object(minted.record)])])])]
        let phone = try await engine.storeForPhone(book)
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(phone)), as: UTF8.self)
        #expect(!text.contains(ApiTokens.hash(minted.token)), "a phone is never handed a token's hash")
    }
}
