import Foundation
import KhaytCore

/// Asking Khayt Cloud what it holds.
///
/// **It reads. There is no push here, and that is the whole design of this
/// stage.** `cloud-backend.js` §7 spells out what a blob the server accepts
/// does to the shop's other devices: a full push with a baseRev the server
/// takes replaces its newer copy outright, and every device pulls the older
/// store down, with nothing said on either side. A reader can be wrong and
/// merely fail.
///
/// What it does is one cold pull — `GET /v1/shops/{id}/store` with the shop's
/// bearer token — and then the same fold the Electron app does: decrypt the
/// base with the data key, apply the delta chain with `KhaytSync.applyDeltas`.
/// The server includes the base exactly when the caller is behind it, and a
/// caller with no `?since=` is behind everything, so a cold reply always
/// carries one. Confirmed against the server's own handler, not only the
/// client's.
@MainActor
public enum CloudReader {

    public enum Failure: Error, CustomStringConvertible {
        case notConnected
        case badAddress(String)
        case unauthorised
        case noStoreYet
        case http(Int, String)
        case malformed(String)
        case noBase
        /// The cloud answered with a head BELOW one this device has already
        /// seen for the same shop. See `RevisionMemory`.
        case wentBackwards(seen: Int, got: Int)

        public var description: String {
            switch self {
            case .notConnected:
                return "This book is not connected to Khayt Cloud."
            case .badAddress(let url):
                return "\(url) is not an address this app will connect to."
            case .unauthorised:
                return "Khayt Cloud did not accept this shop's token. It may have been reset."
            case .noStoreYet:
                return "Khayt Cloud has nothing for this shop yet — nothing has been sent to it."
            case .http(let code, let body):
                return "Khayt Cloud answered \(code)\(body.isEmpty ? "" : ": \(body)")"
            case .malformed(let what):
                return "Khayt Cloud's answer was not the shape this app expects: \(what)"
            case .noBase:
                return "Khayt Cloud sent changes but no store to apply them to. "
                     + "Refusing beats guessing: a store built on the wrong base is missing "
                     + "exactly the edits worth having."
            case .wentBackwards(let seen, let got):
                return "Khayt Cloud answered with revision \(got), but this Mac has already seen "
                     + "revision \(seen) for this shop. A cloud does not go backwards on its own, so "
                     + "nothing from it was applied. If you reset or restored the cloud yourself, "
                     + "choose \"Trust the cloud's older copy\" to carry on from it."
            }
        }
    }

    /// What one pull came back with.
    public struct Reply: Sendable {
        /// The head revision — the whole chain's, not the slice's.
        public let rev: Int
        public let base: SyncCrypto.Blob?
        public let deltas: [(rev: Int, blob: SyncCrypto.Blob)]

        public init(rev: Int, base: SyncCrypto.Blob?, deltas: [(rev: Int, blob: SyncCrypto.Blob)]) {
            self.rev = rev; self.base = base; self.deltas = deltas
        }
    }

    /// The shop's own cloud settings, as far as reading needs them.
    public struct Connection: Sendable {
        public let url: String
        public let shopId: String
        /// Still `__enc__` here. Opened at the moment of the request and never
        /// held — see `Secrets`.
        public let storedToken: String

        public init(url: String, shopId: String, storedToken: String) {
            self.url = url; self.shopId = shopId; self.storedToken = storedToken
        }
    }

    // MARK: - The request

    /// Every request this app makes to the service, built in one place.
    ///
    /// One place because of the header. khayt-cloud records the delta
    /// capability of each credential it hears from, on **every** route, and the
    /// gate is unanimous — `deltaGateOpen` returns false the moment one
    /// `delta_capable = 0` row exists, which closes delta sync for the whole
    /// shop and sends every other device back to uploading the entire store on
    /// each save. A second call site that forgot it would do that silently, and
    /// on the send path it would also defeat itself: `POST /deltas` answers 404
    /// to a shop whose gate it has just closed.
    ///
    /// The claim is true and that is what earns it — `store(_:dek:engine:)`
    /// folds `base + deltas` through `KhaytSync.applyDeltas`, the same rule the
    /// desktop folds with. It comes off again if that ever stops being so.
    public static func request(_ connection: Connection, token: String,
                        method: String, tail: String) throws -> URLRequest {
        guard let base = URL(string: connection.url), base.scheme == "https" else {
            // Not a preference: the token goes in a header, and http would put
            // a shop's shop-wide credential on the wire in the clear.
            throw Failure.badAddress(connection.url)
        }
        // `uriComponent`, not `.alphanumerics` — see the note there. Every shop
        // id Khayt issues contains an underscore, and escaping it produced a
        // path the server has no route for.
        let path = "/v1/shops/" + connection.shopId.uriComponent + tail
        guard let url = URL(string: base.absoluteString.trimmingTrailingSlash + path) else {
            throw Failure.badAddress(connection.url)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "x-delta-capable")
        return request
    }

    /// The session every request built by `request(...)` goes through.
    ///
    /// Its delegate follows a redirect only to the SAME scheme, host and port.
    /// The `Authorization: Bearer` header is the shop's shop-wide credential,
    /// and a 30x from the cloud host (or anything that can answer for it)
    /// pointing somewhere else must not carry it along — the 30x comes back
    /// to the caller as the answer instead. Sep 2026 security review.
    nonisolated public static let session = URLSession(configuration: .ephemeral,
                                                        delegate: SameHostRedirects(), delegateQueue: nil)

    /// One cold pull.
    ///
    /// `fetch` is a seam so the whole path can be exercised without a network
    /// or a shop's real credentials — every test in `CloudReaderTests` uses it,
    /// and none of them has ever spoken to the service.
    ///
    /// ── `since` IS NOT AN OPTIMISATION ───────────────────────────────────
    ///
    /// khayt-cloud's own words. Without it a device that is already current
    /// re-downloads the base AND the entire chain on every pull — and
    /// `sendToCloud` pulls before every push, so a shop paid for its whole
    /// book on every save. A device holding rev N asks for N+1 onward.
    ///
    /// WHAT COMES BACK IS DIFFERENT, and that is the part to get right: the
    /// base is included ONLY when the caller is behind it. A warm pull
    /// answers with deltas and no base, so there is nothing to fold them onto
    /// unless the caller kept the store it had at `since` — see `store(_:…)`
    /// and the Mac app's `Shop.cloudSeen`. Passing `since` without keeping that store turns
    /// every warm pull into `Failure.noBase`.
    ///
    /// `memory`, when given, is the highest revision this device has seen for
    /// the shop: a reply below it is refused (`wentBackwards`) and never
    /// returned, and a reply at or above it raises it. See `RevisionMemory`.
    public static func pull(_ connection: Connection, token: String, since: Int? = nil,
                     memory: RevisionMemory? = nil,
                     fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Reply {
        let tail = since.map { "/store?since=\($0)" } ?? "/store"
        let request = try self.request(connection, token: token, method: "GET", tail: tail)
        let (data, response) = try await fetch(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        // Nothing has ever been pushed for this shop. A VIEWER still reads, so
        // a 403 here is a genuine credential problem rather than a role — the
        // roles only ever stop a write.
        case 204: throw Failure.noStoreYet
        case 401, 403: throw Failure.unauthorised
        default:
            // The service answers with a sentence written for a person. A
            // store whose blob has gone missing from object storage now says
            // so in a 500 — it used to answer 204, which read as "nothing has
            // been sent yet" and is a very different thing to tell a shop.
            throw Failure.http(code, CloudWriter.said(data))
        }

        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            throw Failure.malformed("it did not decode")
        }
        let rev = body.rev ?? 0
        if let memory {
            if let seen = memory.highest(connection), rev < seen {
                memory.refused(connection, rev: rev)
                throw Failure.wentBackwards(seen: seen, got: rev)
            }
            memory.saw(connection, rev: rev)
        }
        return Reply(rev: rev, base: body.ciphertext,
                     deltas: (body.deltas ?? []).map { (rev: $0.rev, blob: $0.ciphertext) })
    }

    private struct Body: Decodable {
        let rev: Int?
        let ciphertext: SyncCrypto.Blob?
        let deltas: [Delta]?
        struct Delta: Decodable {
            let rev: Int
            let ciphertext: SyncCrypto.Blob
        }
    }

    // MARK: - The store

    /// Decrypt the base and fold the chain onto it — the same order `pull()`
    /// uses in cloud-backend.js.
    /// `onto` is the store this device already holds for the revision it asked
    /// from — the ONLY thing a warm `?since=` pull can be folded onto, because
    /// the server sends no base to a caller that is not behind one. Nil is a
    /// cold pull, where the base always comes down and this is unused.
    ///
    /// It is not a fallback for a missing base on a COLD pull: no base and
    /// nothing known is still `noBase`, because folding a chain onto an empty
    /// store would hand back a book missing everything that predates it and
    /// call it the cloud's.
    public static func store(_ reply: Reply, dek: Data, engine: KhaytEngine,
                      onto known: [String: JSONValue]? = nil) async throws -> Folded {
        var base: [String: JSONValue]
        if let baseBlob = reply.base {
            base = try SyncCrypto.store(baseBlob, dek: dek)
        } else if let known {
            base = known
        } else {
            throw Failure.noBase
        }
        guard !reply.deltas.isEmpty else {
            return Folded(store: base, chain: 0, applied: 0, removed: 0)
        }
        let payloads = try reply.deltas.map { try SyncCrypto.store($0.blob, dek: dek) }
        let out = try await engine.foldDeltas(base: base, deltas: payloads)
        return Folded(store: out.store, chain: payloads.count,
                      applied: out.applied, removed: out.removed)
    }

    /// What the cloud's side of the comparison is built on.
    ///
    /// Carried so it can be SHOWN. "Nineteen jobs are newer here" means one
    /// thing if thirteen changes were folded onto the base and something else
    /// entirely if none were — and the two are indistinguishable from the
    /// answer alone.
    public struct Folded: Sendable {
        public let store: [String: JSONValue]
        /// How many encrypted changes the server sent after the base.
        public let chain: Int
        /// How many records those changes actually wrote.
        public let applied: Int
        /// How many they deleted.
        public let removed: Int

        public init(store: [String: JSONValue], chain: Int, applied: Int, removed: Int) {
            self.store = store; self.chain = chain; self.applied = applied; self.removed = removed
        }
    }
}

extension CloudReader {

    /// The highest revision of each shop's store this device has seen.
    ///
    /// ── ROLLBACK AND REPLAY, CHECKED ON THIS SIDE ONLY ───────────────────
    ///
    /// The store and its deltas are sealed with the shop's data key, so a
    /// compromised or misbehaving server cannot WRITE a store this app would
    /// open. It can still hand back an OLD one: a base and chain it served
    /// last month, under whatever `rev` it likes, and every device would fold
    /// it and treat the shop's newer records as the ones to overwrite. The
    /// ciphertext does not bind the revision (the wire format is shared with
    /// the desktop, the phone and khayt-cloud, and is not this app's to
    /// change), so the only defence a client has alone is memory: a cloud
    /// that answers BELOW a revision this device has already seen has gone
    /// backwards, and that is refused, not applied.
    ///
    /// What it does not stop: a server that replays old ciphertext under a
    /// NEW, higher rev. Closing that needs the revision inside the AEAD's
    /// associated data — a format change every client has to make together.
    ///
    /// Raised by every pull that is accepted and SET by every push the server
    /// confirms (`confirmed`), because a whole-book push after a cloud reset
    /// legitimately restarts the count and the server has just told this
    /// device so in answer to its own write. Kept per cloud address and shop,
    /// in user defaults (it is a number, not a secret), so a relaunch
    /// remembers it — an in-memory check would be reset by the very restart a
    /// rollback is most likely to be noticed after.
    ///
    /// A shop that reset or restored its cloud on purpose says so with
    /// `accept`, which takes the refused revision as the new mark.
    public final class RevisionMemory: @unchecked Sendable {
        private let defaults: UserDefaults?
        private var memory: [String: Int] = [:]
        private var pending: [String: Int] = [:]
        private let lock = NSLock()

        /// `nil` keeps it in memory only — for a book with no file behind it,
        /// and for tests.
        public init(defaults: UserDefaults?) { self.defaults = defaults }

        public static let standard = RevisionMemory(defaults: .standard)

        static func key(_ c: Connection) -> String {
            "khayt.cloud.highestRev." + c.url.lowercased().trimmingTrailingSlash + "|" + c.shopId
        }

        public func highest(_ c: Connection) -> Int? {
            let k = Self.key(c)
            return lock.withLock {
                if let defaults { return defaults.object(forKey: k) as? Int }
                return memory[k]
            }
        }

        private func set(_ c: Connection, _ rev: Int) {
            let k = Self.key(c)
            lock.withLock {
                pending[k] = nil
                if let defaults { defaults.set(rev, forKey: k) } else { memory[k] = rev }
            }
        }

        /// A pull was accepted at `rev`: raise the mark, never lower it.
        public func saw(_ c: Connection, rev: Int) {
            if let seen = highest(c), seen >= rev { return }
            set(c, rev)
        }

        /// The server accepted this device's own push and is now at `rev`.
        public func confirmed(_ c: Connection, rev: Int) { set(c, rev) }

        func refused(_ c: Connection, rev: Int) {
            let k = Self.key(c)
            lock.withLock { pending[k] = rev }
        }

        /// The revision last refused for this shop, while it is still refused.
        public func refusal(_ c: Connection) -> Int? {
            let k = Self.key(c)
            return lock.withLock { pending[k] }
        }

        /// The shop says the older cloud is the right one: take the refused
        /// revision as the mark. Nothing to accept is a no-op.
        @discardableResult
        public func accept(_ c: Connection) -> Bool {
            guard let rev = refusal(c) else { return false }
            set(c, rev)
            return true
        }
    }
}

private extension String {
    var trimmingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

/// A redirect is followed only to the same scheme, host and port as the
/// request it came from — see `CloudReader.session`.
public final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    public override init() { super.init() }

    public static func allows(from original: URL?, to next: URL?) -> Bool {
        guard let a = original, let b = next,
              let ha = a.host?.lowercased(), let hb = b.host?.lowercased(), !ha.isEmpty else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && ha == hb && a.port == b.port
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        let from = task.currentRequest?.url ?? task.originalRequest?.url
        return Self.allows(from: from, to: request.url) ? request : nil
    }
}
