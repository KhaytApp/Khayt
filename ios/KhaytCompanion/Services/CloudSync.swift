import Foundation
import KhaytCore

/**
 * Syncing this phone's book through Khayt Cloud, for when the Mac is not on
 * the same Wi-Fi.
 *
 * ── THE SAME CLIENT AS THE MAC ────────────────────────────────────────────
 *
 * Every request goes through `CloudReader.request` in KhaytCore — the Mac's
 * own client, moved there so this phone would not grow a second one. It sends
 * `x-delta-capable` on every call, which is not a detail: khayt-cloud records
 * the capability per device, and ONE device that omits it closes the delta
 * gate for the whole shop and sends every Mac back to uploading its entire
 * book on each save (`docs/api-contract.md`, "Common headers").
 *
 * ── THIS PHONE NEVER UPLOADS A WHOLE STORE ────────────────────────────────
 *
 * `PUT /store` replaces the cloud's copy and drops the delta chain. The phone
 * holds a SLICE of the shop (`BookScope`), so a whole store from here would
 * be the slice — every older order the phone never carried would be gone for
 * every device. So this file appends (`POST /deltas`) and nothing else. When
 * the chain is full (`409 compact`) or the shop takes no deltas (404), the
 * changes stay on the phone, counted, and the Mac — which holds everything —
 * is the one that compacts.
 *
 * ── ONE BOOK, ONE BASELINE, TWO WAYS HOME ─────────────────────────────────
 *
 * What is pending is `changesToSend(book, baseline)`, whichever way it goes.
 * A pull folds the cloud's changes into the book AND the baseline, so what
 * arrived from the cloud is never mistaken for an edit made here and sent
 * straight back. A send that the cloud accepts makes the baseline the book,
 * as a send the Mac accepts does.
 */
@MainActor
struct CloudSync {

    let book: CompanionBook
    let engine: KhaytEngine
    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    enum Pulled: Equatable {
        /// The shop has never pushed anything to the cloud.
        case nothingYet
        /// A first pull: the cloud's book, sliced to what a phone carries.
        case whole(records: Int)
        /// Changes since the last pull, folded in.
        case changes(Int)
    }

    enum Pushed: Equatable {
        case nothingToSend
        case sent(count: Int, rev: Int)
        /// The cloud will not take changes one at a time right now — its chain
        /// is full, or the shop takes no deltas. Only a device holding the
        /// whole book can fix that, and this phone does not.
        case needsTheMac
        /// A viewer's sign-in: it reads and never sends.
        case readOnly
    }

    // MARK: - Signing in

    /// Sign this phone in: email and password for a device token, then the
    /// shop's passphrase to open its data key. Nothing is saved here — the
    /// caller saves the session once it has worked.
    static func signIn(url: String, email: String, password: String, passphrase: String,
                       engine: KhaytEngine, session: URLSession? = nil) async throws -> CloudSession {
        let signedIn = try await CloudSignIn.logIn(url: url, email: email, password: password,
                                                   engine: engine, session: session)
        guard case .object(let keyset)? = signedIn.keyset else { throw CloudSignIn.Failure.noKeyset }
        let dek = try Self.openKey(keyset: keyset, passphrase: passphrase)
        return CloudSession(url: try await engine.cloudBaseUrl(url), shopId: signedIn.shopId,
                            token: signedIn.token, dek: dek, role: signedIn.role, seenRev: nil)
    }

    /// The keyset's passphrase-wrapped key, opened with the stretching the
    /// keyset itself names — the Mac's own steps (`Shop.connectCloud`).
    static func openKey(keyset: [String: JSONValue], passphrase: String) throws -> Data {
        guard case .object(let fields)? = keyset["wrappedByPassphrase"],
              let wrapped = try? JSONDecoder().decode(SyncCrypto.Blob.self,
                                                      from: JSONEncoder().encode(JSONValue.object(fields)))
        else { throw CloudReader.Failure.malformed("the keyset has no passphrase-wrapped key") }
        return try SyncCrypto.unwrapDek(secret: passphrase, wrapped: wrapped,
                                        kdf: SyncCrypto.Kdf.from(keyset["kdf"]))
    }

    private func connection(_ s: CloudSession) -> CloudReader.Connection {
        CloudReader.Connection(url: s.url, shopId: s.shopId, storedToken: "")
    }

    // MARK: - Live printers

    /// The printers' latest status as the Mac published it to Khayt Cloud
    /// (`GET /v1/shops/{id}/live/printers`, "Live channel & live printers" in
    /// khayt-cloud's `docs/api-contract.md`).
    ///
    /// Sealed with the shop's DEK in the store's own envelope, so it opens
    /// with the store's own `SyncCrypto` — no second cipher on this phone.
    /// `receivedAt` is the SERVER's clock: how stale a snapshot is does not
    /// depend on whether the Mac's clock is right.
    ///
    /// Nil when the Mac has never published (404) — the contract promises a
    /// 404 there, never an empty list, and an empty list would read as a shop
    /// with no printers.
    func livePrinters(_ session: CloudSession) async throws -> LiveSnapshot? {
        let request = try CloudReader.request(connection(session), token: session.token,
                                              method: "GET", tail: "/live/printers")
        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }

        struct Envelope: Decodable {
            let at: String?
            let receivedAt: String
            let ciphertext: SyncCrypto.Blob
        }
        struct Plain: Decodable {
            let printers: [MachineLiveStatus]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let plain = try SyncCrypto.openStore(envelope.ciphertext, dek: session.dek)
        let snapshot = try JSONDecoder().decode(Plain.self, from: plain)
        let received = ISO8601DateFormatter().date(from: envelope.receivedAt)
        return LiveSnapshot(printers: snapshot.printers, source: .cloud, reportedAt: received)
    }

    // MARK: - Pulling

    func pull(_ session: CloudSession, now: Date = Date()) async throws -> (CloudSession, Pulled) {
        var s = session
        let warm = s.seenRev != nil && book.exists
        let reply: CloudReader.Reply
        do {
            reply = try await CloudReader.pull(connection(s), token: s.token,
                                               since: warm ? s.seenRev : nil, fetch: fetch)
        } catch CloudReader.Failure.noStoreYet {
            return (s, .nothingYet)
        }

        // Behind the base — the chain was compacted since this phone last
        // looked, or this is the first pull. Either way the base came down.
        if reply.base != nil || !warm {
            let whole = try await CloudReader.store(reply, dek: s.dek, engine: engine)
            let taken = BookScope.take(from: whole.store, now: now)
            try await BookReader(book: book).adopt(taken.store, scope: taken.taken)
            s.seenRev = reply.rev
            return (s, .whole(records: CompanionAPIRecordCount.of(taken.store)))
        }

        guard !reply.deltas.isEmpty else {
            s.seenRev = reply.rev
            return (s, .changes(0))
        }
        let payloads = try reply.deltas.map { try SyncCrypto.store($0.blob, dek: s.dek) }
        // Into the book, where edits made here win or lose by rev as usual —
        // swapped in only if nothing was written here while the engine folded.
        // See `CompanionBook.swap`.
        var folded: KhaytEngine.Folded?
        for _ in 1...3 {
            let local = try book.read()
            let attempt = try await engine.foldDeltas(base: local, deltas: payloads)
            if try book.swap(from: local, to: attempt.store) { folded = attempt; break }
        }
        guard let folded else { throw CompanionBook.Failure.busy }
        // …and into the baseline, so none of it reads as pending.
        if let baseline = book.baseline() {
            let seen = try await engine.foldDeltas(base: baseline, deltas: payloads)
            try book.replaceBaseline(with: seen.store)
        }
        s.seenRev = reply.rev
        return (s, .changes(folded.applied + folded.removed))
    }

    // MARK: - Pushing

    /// Send this phone's changes. Pulls first, so the send is measured against
    /// the cloud as it is; a race is pulled again and retried once.
    func push(_ session: CloudSession) async throws -> (CloudSession, Pushed) {
        guard session.canWrite else { return (session, .readOnly) }
        var (s, _) = try await pull(session)
        for attempt in 0..<2 {
            guard let baseline = book.baseline() else { return (s, .nothingToSend) }
            let outbox = try await engine.changesToSend(local: try book.read(), server: baseline)
            guard !outbox.isEmpty else { return (s, .nothingToSend) }
            guard let base = s.seenRev else { return (s, .needsTheMac) }
            do {
                let sent = try await CloudWriter.send(connection(s), token: s.token, payload: outbox,
                                                      dek: s.dek, baseRev: base, fetch: fetch)
                try book.markSynced()
                s.seenRev = sent.rev
                return (s, .sent(count: sent.count, rev: sent.rev))
            } catch CloudWriter.Failure.moved where attempt == 0 {
                (s, _) = try await pull(s)
            } catch CloudWriter.Failure.chainFull, CloudWriter.Failure.notAccepted {
                return (s, .needsTheMac)
            } catch CloudWriter.Failure.readOnly {
                return (s, .readOnly)
            }
        }
        return (s, .needsTheMac)
    }
}

/// How many records a store holds, for a sentence about a pull.
enum CompanionAPIRecordCount {
    static func of(_ store: [String: JSONValue]) -> Int {
        store.values.reduce(0) { total, value in
            if case .array(let rows) = value { return total + rows.count }
            return total
        }
    }
}
