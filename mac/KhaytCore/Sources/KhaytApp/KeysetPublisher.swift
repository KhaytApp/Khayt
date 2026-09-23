import Foundation
import KhaytCore

/// Putting a shop's keyset on Khayt Cloud when the cloud has none.
///
/// ── THE SHOP THIS WAS FOR ─────────────────────────────────────────────────
///
/// The shop's book held a keyset — made by the other app, version 2, with a
/// passphrase slot and a recovery slot — and the cloud held nothing: the book
/// had never been pushed. The Mac signs in with the book's keyset when the
/// server sends none, so the Mac worked; the phone, which can only take a
/// keyset FROM the server, stopped at "no keyset" and could never sync.
///
/// ── IT NEVER MINTS, AND IT NEVER OVERWRITES ──────────────────────────────
///
/// A NEW keyset would orphan the recovery key that belongs to the book's, and
/// every blob sealed with its key. So this publishes only the keyset the book
/// already has, only after the passphrase has unlocked it in the same sign-in
/// (so it is proven to be this shop's), and only when `GET /keyset` answers
/// 204 — "no keyset yet". A 200 means another device put one there, and it is
/// left alone: replacing it would lock that device out.
@MainActor
enum KeysetPublisher {
    enum Outcome: Equatable { case alreadyThere, published }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case readOnly
        case http(Int, String)
        var description: String {
            switch self {
            case .readOnly: "This sign-in can read the shop but not give the cloud its key."
            case .http(let code, let body): "Khayt Cloud answered \(code) about the key" + (body.isEmpty ? "" : ": \(body)")
            }
        }
    }

    static func publishIfAbsent(_ connection: CloudReader.Connection, token: String,
                                keyset: [String: JSONValue],
                                fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Outcome {
        let ask = try CloudReader.request(connection, token: token, method: "GET", tail: "/keyset")
        let (seen, answer) = try await fetch(ask)
        switch (answer as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return .alreadyThere
        case 204: break
        case let code: throw Failure.http(code, String(decoding: seen.prefix(200), as: UTF8.self))
        }
        var put = try CloudReader.request(connection, token: token, method: "PUT", tail: "/keyset")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.httpBody = try JSONEncoder().encode(JSONValue.object(["keyset": .object(keyset)]))
        let (body, response) = try await fetch(put)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200, 204: return .published
        case 403: throw Failure.readOnly
        case let code: throw Failure.http(code, String(decoding: body.prefix(200), as: UTF8.self))
        }
    }
}
