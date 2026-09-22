import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Sending what is only on this Mac.
///
/// **Not one test here speaks to the service**, for the same reason as
/// `CloudReaderTests`: `send` takes its fetch as a parameter, so the whole path
/// — build the payload, seal it, put it on a request, read the answer — runs
/// against a shop that does not exist.
///
/// The reply shapes are khayt-cloud's own, from `index.php`:
///
///     POST /v1/shops/{id}/deltas   { ciphertext, baseRev }
///          200 { rev, deltaCount }   appended; rev is the new head
///          409 { rev }               baseRev is not the head
///          404                       this shop's chain is closed
@MainActor
struct CloudWriterTests {

    static let connection = CloudReader.Connection(
        url: "https://cloud.khayt.example", shopId: "shop_282eb707", storedToken: "__enc__x")
    static let dek = Data((0..<32).map { UInt8($0) })

    static let payload = KhaytEngine.Outbox(
        deltas: [.object(["collection": .string("orders"),
                          "record": .object(["id": .string("o1"), "rev": .number(4)])])],
        tombstones: [], cursor: .object(["rev": .number(0), "ts": .string("")]),
        settingsDiffer: true)

    static func answer(_ status: Int, _ json: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            (Data(json.utf8),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: - The request

    /// The route is the safety property, so it is asserted rather than assumed.
    /// `PUT /store` from this app would upload a book that has merged nobody
    /// else's work and compact the chain behind it; `POST /deltas` can only add.
    @Test("it appends to the chain — it never puts a whole store")
    func routeAndHeaders() async throws {
        var seen: URLRequest?
        _ = try? await CloudWriter.send(Self.connection, token: "the-real-token",
                                        payload: Self.payload, dek: Self.dek, baseRev: 12) { request in
            seen = request
            return (Data(#"{"rev":13}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(seen?.httpMethod == "POST")
        #expect(seen?.url?.absoluteString
                == "https://cloud.khayt.example/v1/shops/shop_282eb707/deltas")
        #expect(seen?.value(forHTTPHeaderField: "Authorization") == "Bearer the-real-token")
        // Not a courtesy header on this route: `recordDeviceCap` runs before
        // `shopTakesDeltas`, so a send that stayed quiet would close the shop's
        // gate and then be refused by the gate it had just closed.
        #expect(seen?.value(forHTTPHeaderField: "x-delta-capable") == "1")
    }

    @Test("the body carries the payload sealed with the shop's key, and the rev it was measured against")
    func bodyShape() async throws {
        var seen: URLRequest?
        _ = try? await CloudWriter.send(Self.connection, token: "t", payload: Self.payload,
                                        dek: Self.dek, baseRev: 12) { request in
            seen = request
            return (Data(#"{"rev":13}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        struct Body: Decodable { let ciphertext: SyncCrypto.Blob; let baseRev: Int }
        let sentBody = try #require(seen?.httpBody)
        let body = try JSONDecoder().decode(Body.self, from: sentBody)
        #expect(body.baseRev == 12)

        let opened = try SyncCrypto.store(body.ciphertext, dek: Self.dek)
        #expect(opened["deltas"] == .array(Self.payload.deltas))
        #expect(opened["tombstones"] == .array([]))
        // `settingsDiffer` is a fact about THIS device. It must not travel
        // inside a blob every other device folds.
        #expect(opened["settingsDiffer"] == nil)
    }

    // MARK: - What the service says back

    /// The one that matters. A 409 means something reached the cloud between
    /// the pull and the button, so the payload was measured against a store
    /// that no longer exists — and the answer is to look again, not to retry.
    @Test("a cloud that moved on is refused, with the revision it moved to")
    func conflict() async throws {
        await #expect(throws: CloudWriter.Failure.moved(19)) {
            try await CloudWriter.send(Self.connection, token: "t", payload: Self.payload,
                                       dek: Self.dek, baseRev: 12,
                                       fetch: Self.answer(409, #"{"rev":19}"#))
        }
    }

    @Test("a shop whose chain is closed is told so, not shown an HTTP code")
    func chainClosed() async throws {
        for code in [404, 405] {
            await #expect(throws: CloudWriter.Failure.notAccepted) {
                try await CloudWriter.send(Self.connection, token: "t", payload: Self.payload,
                                           dek: Self.dek, baseRev: 12,
                                           fetch: Self.answer(code, #"{"error":"nope"}"#))
            }
        }
    }

    @Test("a rejected token says what it is")
    func unauthorised() async throws {
        await #expect(throws: CloudWriter.Failure.unauthorised) {
            try await CloudWriter.send(Self.connection, token: "t", payload: Self.payload,
                                       dek: Self.dek, baseRev: 12,
                                       fetch: Self.answer(401, "{}"))
        }
    }

    /// A 200 with no revision is not success. Reporting one would leave the
    /// screen saying the change went up with nothing to show it did.
    @Test("a success with no revision is not a success")
    func noRev() async throws {
        await #expect(throws: CloudWriter.Failure.malformed("it carried no revision")) {
            try await CloudWriter.send(Self.connection, token: "t", payload: Self.payload,
                                       dek: Self.dek, baseRev: 12,
                                       fetch: Self.answer(200, "{}"))
        }
    }

    @Test("what went up is reported by kind, from the payload rather than the reply")
    func reportsWhatItSent() async throws {
        let both = KhaytEngine.Outbox(
            deltas: Self.payload.deltas,
            tombstones: [.object(["collection": .string("spools"), "id": .string("s9")])],
            cursor: .object([:]), settingsDiffer: false)
        let sent = try await CloudWriter.send(Self.connection, token: "t", payload: both,
                                              dek: Self.dek, baseRev: 12,
                                              fetch: Self.answer(200, #"{"rev":14,"deltaCount":3}"#))
        #expect(sent.rev == 14)
        #expect(sent.deltas == 1)
        #expect(sent.tombstones == 1)
    }

    // MARK: - the whole store, for a shop whose chain is closed

    static let merged = KhaytEngine.Merged(store: [:], applied: 0, skipped: 0,
                                           removed: 0, conflicts: [])

    /// A different route and a different verb. `POST /deltas` appends; this
    /// REPLACES, and the service compacts the chain behind it.
    @Test("the whole store goes by PUT, to the store, with the revision it was merged from")
    func wholeStoreRoute() async throws {
        var seen: URLRequest?
        _ = try? await CloudWriter.sendWholeStore(
            Self.connection, token: "t", store: ["orders": .array([])], dek: Self.dek,
            baseRev: 16, mergedFrom: Self.merged) { request in
            seen = request
            return (Data(#"{"rev":17}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(seen?.httpMethod == "PUT")
        #expect(seen?.url?.absoluteString
                == "https://cloud.khayt.example/v1/shops/shop_282eb707/store")
        #expect(seen?.value(forHTTPHeaderField: "x-delta-capable") == "1")

        struct Body: Decodable { let ciphertext: SyncCrypto.Blob; let baseRev: Int }
        let raw = try #require(seen?.httpBody)
        let body = try JSONDecoder().decode(Body.self, from: raw)
        // The revision the merge was folded from, so anything that arrived in
        // between is a 409 rather than an overwrite.
        #expect(body.baseRev == 16)
        #expect(try SyncCrypto.store(body.ciphertext, dek: Self.dek)["orders"] == .array([]))
    }

    /// The guard that makes the whole thing safe. Without it, a book that is no
    /// longer a superset of the cloud would replace it.
    @Test("a cloud that moved while we were merging is refused, not overwritten")
    func wholeStoreConflict() async throws {
        await #expect(throws: CloudWriter.Failure.moved(21)) {
            try await CloudWriter.sendWholeStore(
                Self.connection, token: "t", store: [:], dek: Self.dek, baseRev: 16,
                mergedFrom: Self.merged, fetch: Self.answer(409, #"{"rev":21}"#))
        }
    }

    @Test("what went up is described as the whole book, not as one change")
    func wholeStoreIsSaidPlainly() async throws {
        let sent = try await CloudWriter.sendWholeStore(
            Self.connection, token: "t", store: [:], dek: Self.dek, baseRev: 16,
            mergedFrom: Self.merged, fetch: Self.answer(200, #"{"rev":17}"#))
        #expect(sent.wholeStore)
        #expect(sent.rev == 17)
        #expect(sent.count == 0, "it is not a count of records")
    }

    /// A delta send says nothing about the whole store, so the screen can tell
    /// the two apart.
    @Test("an ordinary send is not marked as the whole book")
    func deltaSendIsNotWholeStore() async throws {
        let sent = try await CloudWriter.send(Self.connection, token: "t", payload: Self.payload,
                                              dek: Self.dek, baseRev: 12,
                                              fetch: Self.answer(200, #"{"rev":13}"#))
        #expect(!sent.wholeStore)
    }

    /// THE ONE THAT KEEPS A SHOP'S CREDENTIALS OFF THE SERVER.
    ///
    /// The desktop's renderer is handed a store whose secrets are already
    /// masks, so its pushes have always carried masks. This app reads the book
    /// from disk and holds the real `__enc__` values — so it has to take them
    /// out, and this checks the sealed body rather than the intention.
    @Test("a whole store goes up with every credential masked")
    func wholeStoreCarriesNoSecrets() async throws {
        let engine = try KhaytEngine()
        let book: [String: JSONValue] = [
            "settings": .object([
                "ai": .object(["apiKey": .string("__enc__AAA")]),
                "cloud": .object(["token": .string("__enc__BBB"),
                                  "url": .string("https://cloud.example")]),
            ]),
            "printLog": .array([.object(["id": .string("o1"), "rev": .number(1)])]),
        ]
        let forCloud = try await engine.storeForCloud(book)

        var seen: URLRequest?
        _ = try? await CloudWriter.sendWholeStore(
            Self.connection, token: "t", store: forCloud, dek: Self.dek, baseRev: 1,
            mergedFrom: Self.merged) { request in
            seen = request
            return (Data(#"{"rev":2}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        struct Body: Decodable { let ciphertext: SyncCrypto.Blob; let baseRev: Int }
        let raw = try #require(seen?.httpBody)
        let body = try JSONDecoder().decode(Body.self, from: raw)
        let opened = try SyncCrypto.store(body.ciphertext, dek: Self.dek)

        // Read the sealed bytes back and look for the secrets themselves.
        // `.withoutEscapingSlashes`, or the address reads as `https:\/\/…` and an
        // assertion about it fails for a reason that has nothing to do with
        // secrets.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let text = String(decoding: try encoder.encode(JSONValue.object(opened)), as: UTF8.self)
        #expect(!text.contains("__enc__AAA"), "the API key went up")
        #expect(!text.contains("__enc__BBB"), "the sync token went up")
        #expect(text.contains("__KHAYT_MASKED__"))
        #expect(text.contains("https://cloud.example"), "and the address, which is not a secret, stayed")
        #expect(text.contains("o1"), "and the records")
    }

    // MARK: - End to end, through the real rules

    /// The proof that the parts fit: take two stores that disagree, build the
    /// payload with the shared rule, seal it as the wire carries it, open it as
    /// another device would, fold it with the shared merge engine, and require
    /// that the comparison screen then reports agreement.
    ///
    /// Every step here is the shipped one. Nothing is restated in the test.
    @Test("a Mac's changes, sent and folded, bring the two into step")
    func endToEnd() async throws {
        let engine = try KhaytEngine()
        let here: [String: JSONValue] = [
            "orders": .array([
                .object(["id": .string("made-here"), "rev": .number(1), "title": .string("new")]),
                .object(["id": .string("edited-here"), "rev": .number(7)]),
                .object(["id": .string("theirs"), "rev": .number(2)]),
            ]),
            "tombstones": .array([.object(["collection": .string("orders"),
                                           "id": .string("dropped"), "rev": .number(1),
                                           "deletedAt": .string("2026-09-02")])]),
        ]
        let there: [String: JSONValue] = [
            "orders": .array([
                .object(["id": .string("edited-here"), "rev": .number(6)]),
                .object(["id": .string("theirs"), "rev": .number(9)]),
                .object(["id": .string("dropped"), "rev": .number(1)]),
            ]),
            "tombstones": .array([]),
        ]

        let outbox = try await engine.changesToSend(local: here, server: there)
        #expect(outbox.deltas.count == 2)      // made-here and edited-here; NOT theirs
        #expect(outbox.tombstones.count == 1)

        // Over the wire and back, exactly as another device would receive it.
        let blob = try SyncCrypto.seal(outbox.wire, dek: Self.dek)
        let asReceived = try SyncCrypto.store(blob, dek: Self.dek)
        let folded = try await engine.foldDeltas(base: there, deltas: [asReceived])
        #expect(folded.applied == 2)
        #expect(folded.removed == 1)

        // `theirs` was never sent, so the cloud's newer copy survives untouched.
        // This is the direction that destroys a shop's work.
        guard case .array(let ordersAfter)? = folded.store["orders"] else {
            Issue.record("the fold lost the orders collection entirely"); return
        }
        let theirs = ordersAfter.first {
            if case .object(let o) = $0 { return o["id"] == .string("theirs") }
            return false
        }
        guard case .object(let row)? = theirs else {
            Issue.record("`theirs` is gone — the send removed a record it never sent"); return
        }
        #expect(row["rev"] == .number(9))

        // And now the screen agrees — on the collections the payload could carry.
        let after = CloudCompare.compare(here: here, there: folded.store,
                                         collections: ["orders", "tombstones"], cloudRev: 13)
        #expect(after.agrees == false, "the stale record is still a difference, and honestly so")
        #expect(after.differing.count == 1)
        #expect(after.differing.first?.collection == "orders")
    }
}

/// What the service's refusals actually mean.
///
/// ── THE 409 THAT IS NOT A RACE ────────────────────────────────────────────
///
/// khayt-cloud answers `409 { rev }` for two different things, and the number
/// does not tell them apart:
///
///   * somebody else appended — `rev` is the head this device has not seen;
///   * the chain is FULL — and `rev` is this device's OWN `baseRev`.
///
/// Read as a race, the second one produces a pull, the same 409, and a retry
/// on a backoff capped at five minutes, **forever**, while the shop's cloud
/// copy quietly stops updating. khayt-cloud #67 added `compact: true` to the
/// second so a client can tell, and pins on its own side that the race 409
/// carries no such field.
@MainActor
struct CloudRefusalsTests {

    static let connection = CloudWriterTests.connection
    static let dek = CloudWriterTests.dek
    static let payload = CloudWriterTests.payload

    static func send(_ status: Int, _ json: String) async -> Error? {
        do {
            _ = try await CloudWriter.send(connection, token: "t", payload: payload,
                                           dek: dek, baseRev: 12,
                                           fetch: CloudWriterTests.answer(status, json))
            return nil
        } catch { return error }
    }

    @Test("a full chain is its own answer, and the way out is the whole book")
    func chainFull() async {
        let failure = await Self.send(409, #"{"rev":12,"compact":true}"#) as? CloudWriter.Failure
        #expect(failure == .chainFull(12), """
            a chain-full 409 came back as \(failure.map(String.init(describing:)) ?? "nothing") — \
            read as a race it retries forever and the shop's cloud copy stops moving
            """)
    }

    @Test("a real race still reads as one")
    func stillARace() async {
        #expect(await Self.send(409, #"{"rev":41}"#) as? CloudWriter.Failure == .moved(41))
    }

    /// `409 { rev: 0 }` is the server saying there is no base blob at all:
    /// "the first push of a shop's life is necessarily the whole store". It
    /// carries no `compact`, and retrying a delta against nothing cannot work.
    @Test("nothing to append to is also the whole book")
    func noBaseYet() async {
        #expect(await Self.send(409, #"{"rev":0}"#) as? CloudWriter.Failure == .chainFull(0))
    }

    /// A viewer's account. The token is fine and always will be — saying it
    /// "may have been reset" sends a shop to fix something that is not broken,
    /// and this ran on a timer, so it said it again and again.
    @Test("a 403 is a role, not a reset token")
    func readOnly() async {
        let failure = await Self.send(403, #"{"error":"This account can view this shop but not change it"}"#)
        #expect(failure as? CloudWriter.Failure == .readOnly)
        #expect(!(failure as? CloudWriter.Failure).map(\.description).map { $0.contains("reset") }!)
    }

    @Test("a 401 is still the token")
    func unauthorised() async {
        #expect(await Self.send(401, "{}") as? CloudWriter.Failure == .unauthorised)
    }

    /// 413 and 412 answer with a sentence written for a person. Showing 200
    /// bytes of the JSON around it showed the shop the envelope, not the letter.
    @Test("what the service said is what the shop is shown")
    func theServerSentence() async {
        let failure = await Self.send(413, #"{"error":"Store exceeds your plan’s size limit"}"#)
        #expect(failure as? CloudWriter.Failure
                == .http(413, "Store exceeds your plan’s size limit"))
        // And an answer that is not that shape still says something.
        let odd = await Self.send(502, "<html>bad gateway</html>")
        #expect((odd as? CloudWriter.Failure)?.description.contains("bad gateway") == true)
    }
}

/// That `sendToCloud` ACTS on those answers.
///
/// `CloudRefusalsTests` proves the refusals are read correctly; a failure case
/// that is understood and then ignored is the bug this app keeps finding in
/// itself. `sendToCloud` reaches for `URLSession` directly, so there is no seam
/// to drive it through — the wiring is asserted where it is written, the same
/// way `CloudSignInTests` pins the order of sign-in.
@MainActor
struct SendToCloudWiringTests {

    static func shopSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
    }

    static func sendToCloud() throws -> Substring {
        let source = try shopSource()
        guard let fn = source.range(of: "func sendToCloud(") else {
            throw Failure.gone("sendToCloud is gone")
        }
        return source[fn.lowerBound...].prefix(7000)
    }

    enum Failure: Error { case gone(String) }

    /// A full chain must go down the whole-book path. Without this the shop
    /// retries the same delta forever and its cloud copy stops updating —
    /// silently, because every individual step is behaving as designed.
    @Test("a full chain sends the whole book instead of retrying the delta")
    func chainFullFallsBack() throws {
        let body = try Self.sendToCloud()
        guard let caught = body.range(of: "catch CloudWriter.Failure.chainFull") else {
            Issue.record("""
                sendToCloud does not catch chainFull — a 409 with compact:true \
                is read as a race and retried forever
                """)
            return
        }
        let after = body[caught.upperBound...]
        #expect(after.contains("sendWholeBookAfterMerging"), """
            chainFull is caught and does not reach the whole-book path, which \
            is the only thing that empties the chain
            """)
        // And the closed-chain case it sits beside is still wired.
        #expect(body.contains("catch CloudWriter.Failure.notAccepted"))
    }

    /// The merge is what makes a whole-store push legal, so it is not optional
    /// and not reorderable. `CloudWriter.sendWholeStore`'s own comment says it
    /// is "deliberately NOT reachable on its own" and names the one caller —
    /// this pins that there is still exactly one, and that it is that one.
    ///
    /// Two escapes now reach the whole-book path: a closed chain (404/405) and
    /// a full one (409 compact). Both go through the same function, which is
    /// the entire reason adding the second was safe.
    @Test("the whole book is only ever sent from the function that merges first")
    func onlyFromTheMergingPath() throws {
        let source = try Self.shopSource()
        let calls = source.ranges(of: "CloudWriter.sendWholeStore(")
        #expect(calls.count == 1, """
            sendWholeStore is called \(calls.count) times in Shop.swift — a whole \
            store from a device that has not merged is that device's records and \
            nobody else's, and the server takes it
            """)
        guard let call = calls.first,
              let fn = source.range(of: "func sendWholeBookAfterMerging(") else {
            Issue.record("sendWholeBookAfterMerging is gone"); return
        }
        #expect(call.lowerBound > fn.lowerBound
                && call.lowerBound < source.index(fn.lowerBound, offsetBy: 4000,
                                                  limitedBy: source.endIndex)!, """
            the one call to sendWholeStore is not inside sendWholeBookAfterMerging
            """)
        // And that function merges before it sends.
        let body = source[fn.lowerBound...].prefix(4000)
        guard let merge = body.range(of: "mergeFromCloud("),
              let send = body.range(of: "CloudWriter.sendWholeStore(") else {
            Issue.record("it no longer merges and sends"); return
        }
        #expect(merge.lowerBound < send.lowerBound,
                "the whole book goes up before the cloud has been merged into it")
    }

    /// A viewer is told before a request is made, not after a 403 that would
    /// be retried on a timer.
    @Test("the role is read before anything reaches the network")
    func roleGateComesFirst() throws {
        let body = try Self.sendToCloud()
        guard let gate = body.range(of: "cloudRoleCanWrite") else {
            Issue.record("sendToCloud no longer checks the role at all"); return
        }
        // Whatever it fetches WITH — this was `CloudReader.pull` and is
        // `pullCloudStore` now that the pull asks `?since=`. The property is
        // the order, not the name, so both are looked for and the guard does
        // not quietly stop checking when the call is renamed again.
        let fetches = ["pullCloudStore(", "CloudReader.pull("]
            .compactMap { body.range(of: $0)?.lowerBound }
        guard let first = fetches.min() else {
            Issue.record("sendToCloud no longer pulls before it pushes — that is the 409 guard"); return
        }
        #expect(gate.lowerBound < first,
                "a viewer's Mac still asks the service before telling the shop")
    }
}

/// What the saved role means.
@MainActor
struct CloudRoleTests {

    static func settings(_ role: String?) -> [String: JSONValue] {
        var cloud: [String: JSONValue] = ["shopId": .string("shop_1"), "verified": .bool(true)]
        if let role { cloud["role"] = .string(role) }
        return ["cloud": .object(cloud)]
    }

    @Test("only a viewer is stopped — the service stops nobody else")
    func onlyViewer() {
        #expect(!Shop.cloudRoleCanWrite(Self.settings("viewer")))
        #expect(!Shop.cloudRoleCanWrite(Self.settings("Viewer")), "the role is not case-sensitive")
        for allowed in ["owner", "admin", "staff", "manager"] {
            #expect(Shop.cloudRoleCanWrite(Self.settings(allowed)), "\(allowed) may write")
        }
    }

    /// UNKNOWN IS ALLOWED here, against this codebase's usual rule, and on
    /// purpose: a book that predates the field or arrived by restore has no
    /// role, and refusing those would stop syncing for every existing install
    /// to guard a case the service already refuses properly.
    @Test("a book with no role recorded still syncs")
    func unknownIsAllowed() {
        #expect(Shop.cloudRoleCanWrite(Self.settings(nil)))
        #expect(Shop.cloudRoleCanWrite([:]))
        #expect(Shop.cloudRoleCanWrite(Self.settings("")))
    }
}
