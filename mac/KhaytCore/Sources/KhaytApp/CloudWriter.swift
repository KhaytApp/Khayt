import Foundation
import KhaytCore

/// Sending the half of the difference that is only on this Mac.
///
/// **It appends and it never replaces.** That distinction is the whole design,
/// and it is not caution for its own sake:
///
/// `PUT /v1/shops/{id}/store` uploads a whole store and compacts the chain
/// behind it. From the desktop that is safe, because the desktop merges what it
/// pulled into its own book before it pushes, so its "whole store" contains
/// everybody's work. This app does not merge. A whole store from here would be
/// this Mac's book *and nothing else*, and the server would take it — the
/// `baseRev` guard checks that nobody has written since the pull, not that the
/// upload is complete. Every other device would then pull down a shop with
/// their own recent work missing, and the tombstone rules would keep it missing.
///
/// So this file speaks to exactly one route, `POST /deltas`, which appends and
/// can only ever add. The worst a wrong payload from here can do is send a
/// record the cloud already had at a better rev — and `applyDeltas` discards
/// that on arrival, on every device, by the higher-rev rule.
///
/// What it cannot send is a settings change: settings are one object, not
/// revisioned records, so a delta has nowhere to put them. `Outbox` reports
/// that and the screen says so.
@MainActor
enum CloudWriter {

    /// English, like `CloudReader.Failure` beside it. These say what the
    /// service did, and they are the same sentences whichever language the shop
    /// runs in — a gap both of them share and neither should close alone.
    enum Failure: Error, CustomStringConvertible, Equatable {
        /// The cloud moved on between the check and the send. Carries the head
        /// it moved to, purely so the message can be specific.
        case moved(Int)
        /// The shop's delta chain is closed — 404 or 405 on the route. Usually
        /// a device the service has recorded as unable to read a chain.
        case notAccepted
        /// ── THE 409 THAT IS NOT A RACE ────────────────────────────────────
        ///
        /// The chain is FULL — over 1,000 deltas, or four times the base, or
        /// the plan's size — and the way out is a whole `PUT /store`, which is
        /// the only thing that compacts it.
        ///
        /// It has to be its own case because the `rev` in that 409 is the
        /// caller's OWN `baseRev`: nobody has moved, and it reads exactly like
        /// a race to anything that only looks at the number. This app read it
        /// as one, pulled, got the same 409 and retried on a five-minute
        /// backoff forever, while the shop's cloud copy stopped moving. The
        /// server says `compact: true` now precisely so the two can be told
        /// apart.
        case chainFull(Int)
        /// A 401: the token is not accepted at all.
        case unauthorised
        /// A 403: the token is fine and this sign-in may not WRITE. A viewer.
        /// Retrying cannot help, and telling a shop its token was reset sends
        /// it to fix something that is not broken.
        case readOnly
        case http(Int, String)
        case malformed(String)

        var description: String {
            switch self {
            case .moved(let rev):
                return "Khayt Cloud changed while this was on screen — it is now at revision \(rev). "
                     + "Check again, so what goes up is measured against what is actually there."
            case .notAccepted:
                return "Khayt Cloud is not taking changes one at a time for this shop. "
                     + "Open Khayt on this Mac and let it sync instead."
            case .chainFull(let rev):
                return "Khayt Cloud's change history for this shop is full at revision \(rev). "
                     + "The whole book goes up instead, which empties it."
            case .unauthorised:
                return "Khayt Cloud did not accept this shop's token. It may have been reset."
            case .readOnly:
                return "This sign-in can read this shop but not change it. "
                     + "Ask the owner for an account that can make changes."
            case .http(let code, let body):
                return "Khayt Cloud answered \(code)\(body.isEmpty ? "" : ": \(body)")"
            case .malformed(let what):
                return "Khayt Cloud's answer was not the shape this app expects: \(what)"
            }
        }
    }

    struct Sent: Sendable {
        /// The chain head after the append — the cloud's new revision.
        let rev: Int
        let deltas: Int
        let tombstones: Int
        /// True when the shop's chain was closed and the whole book went up
        /// instead. Worth saying on screen: it is a different thing.
        var wholeStore = false
        var count: Int { deltas + tombstones }
    }

    /// Append one payload to the shop's delta chain.
    ///
    /// `baseRev` must be the revision reported by the pull that `payload` was
    /// computed against, and not a remembered one. It is what makes the send
    /// safe: if anything reached the cloud in between, the server answers 409
    /// and this refuses rather than sending a payload measured against a store
    /// that no longer exists.
    ///
    /// `fetch` is a seam, for the same reason it is one in `CloudReader`: the
    /// whole path is exercised in the tests and none of them has a shop's
    /// credentials.
    static func send(_ connection: CloudReader.Connection, token: String,
                     payload: KhaytEngine.Outbox, dek: Data, baseRev: Int,
                     fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Sent {
        var request = try CloudReader.request(connection, token: token,
                                              method: "POST", tail: "/deltas")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `payload.wire`, not `payload`: `settingsDiffer` is a fact about this
        // device, and it has no business inside a blob every other device folds.
        let blob = try SyncCrypto.seal(payload.wire, dek: dek)
        request.httpBody = try JSONEncoder().encode(Body(ciphertext: blob, baseRev: baseRev))

        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw Failure.unauthorised
        case 403: throw Failure.readOnly
        // The service's own documented "this server does not take deltas", and
        // also its answer to a shop whose gate is shut. Both mean: not this way.
        case 404, 405: throw Failure.notAccepted
        case 409:
            let conflict = try? JSONDecoder().decode(Conflict.self, from: data)
            let head = conflict?.rev ?? 0
            // `compact: true` — the chain is full. And `rev: 0`, which the
            // server sends when there is no base blob at all: "the first push
            // of a shop's life is necessarily the whole store". Both end the
            // same way and neither is a race.
            if conflict?.compact == true || head == 0 { throw Failure.chainFull(head) }
            throw Failure.moved(head)
        case let code:
            throw Failure.http(code, Self.said(data))
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let rev = reply.rev else {
            throw Failure.malformed("it carried no revision")
        }
        return Sent(rev: rev, deltas: payload.deltas.count, tombstones: payload.tombstones.count)
    }

    /// Replace the cloud's whole store with this book.
    ///
    /// THE DANGEROUS ONE, and the doc comment at the top of this file says why:
    /// a whole store from a device that has not merged is that device's records
    /// and nobody else's, and the server takes it. So this is deliberately NOT
    /// reachable on its own. `Shop.sendToCloud` calls it in exactly one place —
    /// after `POST /deltas` has been refused for the shop, and after the cloud
    /// has been MERGED INTO THIS BOOK — which is the same order the desktop
    /// uses when the chain is unavailable to it.
    ///
    /// `mergedFrom` is not used; it is there so the call site cannot be written
    /// without naming the merge that makes it safe, and so this comment is read
    /// by whoever tries.
    ///
    /// `baseRev` is the revision the merge was folded from. The server compares
    /// it against the head and answers 409 if anything arrived in between, so a
    /// book that is no longer a superset of the cloud cannot overwrite it.
    static func sendWholeStore(_ connection: CloudReader.Connection, token: String,
                               store: [String: JSONValue], dek: Data, baseRev: Int,
                               mergedFrom: KhaytEngine.Merged,
                               fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Sent {
        _ = mergedFrom
        var request = try CloudReader.request(connection, token: token,
                                              method: "PUT", tail: "/store")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let blob = try SyncCrypto.seal(store, dek: dek)
        request.httpBody = try JSONEncoder().encode(Body(ciphertext: blob, baseRev: baseRev))

        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw Failure.unauthorised
        case 403: throw Failure.readOnly
        case 409:
            let head = (try? JSONDecoder().decode(Conflict.self, from: data))?.rev ?? 0
            throw Failure.moved(head)
        case let code:
            // 413 (over the plan's size) and 412 both answer with a sentence
            // written for a person. Showing them 200 bytes of raw JSON instead
            // was showing the shop the envelope rather than the letter.
            throw Failure.http(code, Self.said(data))
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let rev = reply.rev else {
            throw Failure.malformed("it carried no revision")
        }
        return Sent(rev: rev, deltas: 0, tombstones: 0, wholeStore: true)
    }

    private struct Body: Encodable {
        let ciphertext: SyncCrypto.Blob
        let baseRev: Int
    }

    /// What the service SAID, when it said something written for a person.
    ///
    /// Every refusal this app can meet carries `{"error": "…"}` — a sentence,
    /// in the shop's own terms ("Store exceeds your plan's size limit"). The
    /// first 200 bytes of the JSON around it is not that sentence.
    static func said(_ data: Data) -> String {
        if let body = try? JSONDecoder().decode(ServerError.self, from: data),
           let error = body.error, !error.isEmpty { return error }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    private struct ServerError: Decodable { let error: String? }
    private struct Reply: Decodable { let rev: Int?; let deltaCount: Int? }
    /// A 409's body. `compact` is present only when the chain is full —
    /// the race 409 carries `rev` alone, and a contract test on the server
    /// pins that it does.
    private struct Conflict: Decodable {
        let rev: Int?
        let compact: Bool?
    }
}
