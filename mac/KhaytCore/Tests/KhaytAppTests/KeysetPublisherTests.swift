import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A shop's key goes to Khayt Cloud only when the cloud has none — and only
/// the key the book already holds.
///
/// The shop's book held a v2 keyset the cloud had never received, so a phone —
/// which can only take the key from the server — stopped at "no keyset".
/// Minting a new one would orphan the recovery key that belongs to the book's;
/// overwriting one the server has would lock out the device that put it there.
@MainActor
struct KeysetPublisherTests {

    static let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com", shopId: "shop_1",
                                                   storedToken: "__enc__x")
    static let keyset: [String: JSONValue] = [
        "version": .number(2),
        "kdf": .object(["algo": .string("scrypt"), "N": .number(32768), "r": .number(8), "p": .number(1), "keyLen": .number(32)]),
        "wrappedByPassphrase": .object(["salt": .string("c2FsdA=="), "iv": .string("aXY="), "ct": .string("Y3Q="), "tag": .string("dGFn")]),
        "wrappedByRecovery": .object(["salt": .string("c2FsdDI="), "iv": .string("aXYy"), "ct": .string("Y3Qy"), "tag": .string("dGFnMg==")]),
    ]

    final class Log: @unchecked Sendable { var requests: [URLRequest] = [] }

    static func server(_ log: Log, get: Int, put: Int = 200) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            log.requests.append(request)
            let code = request.httpMethod == "GET" ? get : put
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!)
        }
    }

    @Test("no keyset on the server: the book's is put there, exactly")
    func publishesTheBooksKey() async throws {
        let log = Log()
        let outcome = try await KeysetPublisher.publishIfAbsent(Self.connection, token: "tok", keyset: Self.keyset,
                                                                fetch: Self.server(log, get: 204))
        #expect(outcome == .published)
        #expect(log.requests.map(\.httpMethod) == ["GET", "PUT"])
        let put = try #require(log.requests.last)
        #expect(put.url?.path.hasSuffix("/v1/shops/shop_1/keyset") == true)
        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(put.httpBody))
        #expect(sent == .object(["keyset": .object(Self.keyset)]), "the keyset sent is not the book's, byte for byte")
    }

    @Test("a keyset already on the server is never overwritten")
    func neverOverwrites() async throws {
        let log = Log()
        let outcome = try await KeysetPublisher.publishIfAbsent(Self.connection, token: "tok", keyset: Self.keyset,
                                                                fetch: Self.server(log, get: 200))
        #expect(outcome == .alreadyThere)
        #expect(log.requests.map(\.httpMethod) == ["GET"], "a PUT went out over a keyset another device set")
    }

    @Test("a refusal or an unreadable answer publishes nothing")
    func refusals() async throws {
        let log = Log()
        await #expect(throws: KeysetPublisher.Failure.readOnly) {
            _ = try await KeysetPublisher.publishIfAbsent(Self.connection, token: "tok", keyset: Self.keyset,
                                                          fetch: Self.server(log, get: 204, put: 403))
        }
        let log2 = Log()
        await #expect(throws: (any Error).self) {
            _ = try await KeysetPublisher.publishIfAbsent(Self.connection, token: "tok", keyset: Self.keyset,
                                                          fetch: Self.server(log2, get: 500))
        }
        #expect(log2.requests.map(\.httpMethod) == ["GET"], "a server that could not say published anyway")
    }

    @Test("sign-in publishes only the book's own key, only when the server sent none, and then sends the book")
    func wired() {
        let s = MenuCoverageTests.source("Shop.swift")
        #expect(s.contains("if !fromServer, session.role != \"viewer\" {"))
        #expect(s.contains("KeysetPublisher.publishIfAbsent("))
        #expect(s.contains("if published { await sendToCloud() }"), "a key with nothing behind it restores to empty")
        #expect(!s.contains("createKeyset"), "the Mac must not mint a keyset over a book that has one")
    }
}
