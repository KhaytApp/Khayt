import Foundation
import Testing
@testable import KhaytCore

/// Private share links (`VaultLinks`) against `VaultStub`'s grant routes.
/// No network, no Keychain: secrets go to `VaultLinkMemoryStore`.
struct VaultLinksTests {

    typealias Bench = VaultClientTests.Bench

    static let password = "mint tea at the souq"

    /// Links over the bench's stub. scrypt at N=2^10 unless a test wants the
    /// real cost; the recipient side is told the same N.
    func links(_ b: Bench, store: VaultLinkMemoryStore = VaultLinkMemoryStore(), scryptN: Int = 1024) -> VaultLinks {
        var l = VaultLinks(client: b.stub.client(), keys: b.keys, secrets: store)
        l.scryptN = scryptN
        return l
    }

    /// Every file in the stub's feed, as sources.
    func sources(_ b: Bench) async throws -> [VaultLinks.Source] {
        var out: [VaultLinks.Source] = [], since = 0
        while true {
            let page = try await b.stub.client().files(since: since)
            out += page.files.map { VaultLinks.Source(row: $0, lastSeenSeq: nil) }
            since = page.rev
            if !page.more { break }
        }
        return out
    }

    /// The bodies of every grant POST and PATCH, decoded.
    func grantWrites(_ b: Bench) -> [(method: String, size: Int, items: Int)] {
        b.stub.log.filter { $0.url.contains("/vault/grants") && ($0.method == "POST" || $0.method == "PATCH") }.map {
            let o = (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]
            return ($0.method, $0.body.count, (o?["items"] as? [Any])?.count ?? 0)
        }
    }

    // MARK: - Batching

    @Test("Vault links: batches hold at most 500 items, whatever their size")
    func batchesByCount() throws {
        let item = VaultClient.GrantItem(fileId: "f", version: 1, wrappedKey: Data(count: 60), linkMeta: Data(count: 100))
        let list = Array(repeating: item, count: 1001)
        let out = try VaultLinks.batches(list, firstEnvelope: 50, restEnvelope: 12, maxItems: 500, maxBytes: 1 << 30)
        #expect(out.map(\.count) == [500, 500, 1])
        #expect(try VaultLinks.batches(Array(list.prefix(500)), firstEnvelope: 50, restEnvelope: 12, maxItems: 500,
                                       maxBytes: 1 << 30).map(\.count) == [500])
    }

    @Test("Vault links: a batch fills to the byte limit exactly, and one byte less moves an item on")
    func batchesByBytes() throws {
        let item = VaultClient.GrantItem(fileId: "f", version: 1, wrappedKey: Data(count: 60), linkMeta: Data(count: 300))
        let n = VaultLinks.jsonBytes(item.json)
        let first = 80, rest = VaultLinks.patchEnvelope
        // Three items and two commas fit in the first body exactly.
        let exact = first + 3 * n + 2
        let a = try VaultLinks.batches(Array(repeating: item, count: 6), firstEnvelope: first, restEnvelope: rest,
                                       maxItems: 500, maxBytes: exact)
        #expect(a.first?.count == 3)
        let b = try VaultLinks.batches(Array(repeating: item, count: 6), firstEnvelope: first, restEnvelope: rest,
                                       maxItems: 500, maxBytes: exact - 1)
        #expect(b.first?.count == 2)
        // And the sum the batcher reckons is the size JSONSerialization writes.
        let body = VaultClient.createBody(grantId: String(repeating: "g", count: 22), items: Array(a[0]),
                                          limits: nil, password: false, ownerNote: nil)
        let envelope = VaultLinks.jsonBytes(VaultClient.createBody(grantId: String(repeating: "g", count: 22),
                                                                   items: [], limits: nil, password: false,
                                                                   ownerNote: nil))
        #expect(VaultLinks.jsonBytes(body) == envelope + 3 * n + 2)
        // One item bigger than a whole request is refused, not sent.
        #expect(throws: VaultLinks.Failure.tooBig(fileId: "f")) {
            try VaultLinks.batches([item], firstEnvelope: first, restEnvelope: rest, maxItems: 500, maxBytes: n)
        }
    }

    @Test("Vault links: 501 files are one POST of 500 and one PATCH of 1, and the link holds all 501")
    func fiveHundredAndOne() async throws {
        let b = Bench()
        for i in 0..<501 { try b.stub.seed(keys: b.keys, name: "part-\(i).stl") }
        let made = try await links(b).create(try await sources(b), options: .init(maxDownloads: 5))
        #expect(made.items == 501 && made.requests == 2)
        #expect(grantWrites(b).map(\.items) == [500, 1])
        #expect(grantWrites(b).map(\.method) == ["POST", "PATCH"])
        #expect(b.stub.grant(made.link.grantId)?.items.count == 501)
    }

    @Test("Vault links: a selection over 16 MB is split by bytes, every body under the limit")
    func sixteenMegabytes() async throws {
        let b = Bench()
        // 2,400 chunks is a 10 GB file: its link meta is ~214 KB of base64,
        // so about 78 fit in a 16 MB body.
        for i in 0..<100 { try b.stub.seed(keys: b.keys, name: "big-\(i).3mf", chunks: 2400) }
        let made = try await links(b).create(try await sources(b), options: .init())
        let writes = grantWrites(b)
        #expect(writes.count >= 2 && made.requests == writes.count)
        #expect(writes.allSatisfy { $0.size <= VaultLinks.maxBodyBytes && $0.items <= VaultLinks.maxItems })
        #expect(writes.reduce(0) { $0 + $1.items } == 100)
        // Full: the first body could not have taken the next item.
        #expect(writes[0].size > VaultLinks.maxBodyBytes - 300 * 1024)
        #expect(b.stub.grant(made.link.grantId)?.items.count == 100)
    }

    @Test("Vault links: a later batch failing revokes the half-made link and forgets its secret")
    func laterBatchFails() async throws {
        let b = Bench()
        for i in 0..<501 { try b.stub.seed(keys: b.keys, name: "p\(i)") }
        b.stub.failPatchNumber = 1
        let store = VaultLinkMemoryStore()
        do {
            _ = try await links(b, store: store).create(try await sources(b), options: .init())
            Issue.record("a link was made with a file missing")
        } catch VaultLinks.Failure.incomplete(let gid, let sent, let total, let revoked, _) {
            #expect(sent == 500 && total == 501 && revoked)
            #expect(b.stub.grant(gid)?.revoked == true)
            #expect(store.count == 0)
        }
    }

    // MARK: - 409 grant-exists

    @Test("Vault links: a taken grant id gets a new id and everything sealed again for it")
    func grantExists() async throws {
        let b = Bench()
        let src = b.file("bracket.stl", VaultClientTests.bytes(5000))
        _ = try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys, spoolRoot: b.spool)
        let taken = String(repeating: "T", count: 22), fresh = VaultCrypto.newGrantId()
        b.stub.takenGrantIds = [taken]
        final class Ids: @unchecked Sendable { var list: [String]; init(_ l: [String]) { list = l } }
        let ids = Ids([taken, fresh])
        var l = links(b)
        l.newGrantId = { ids.list.removeFirst() }
        let made = try await l.create(try await sources(b), options: .init())
        #expect(made.link.grantId == fresh)
        #expect(b.stub.grantPosts == 2 && b.stub.grant(taken) == nil)
        // Sealed for the NEW id: the AAD names it, and the recipient opens it.
        let g = try #require(b.stub.grant(fresh))
        let item = try #require(g.items.values.first)
        _ = try VaultLinks.open(made.link, password: nil, fileId: g.order[0],
                                wrappedKey: Data(base64Encoded: item.wrappedKey)!,
                                linkMeta: Data(base64Encoded: item.linkMeta)!, scryptN: 1024)
    }

    @Test("Vault links: three taken ids in a row stop with a readable failure")
    func grantExistsEveryTime() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "x.stl")
        let taken = String(repeating: "T", count: 22)
        b.stub.takenGrantIds = [taken]
        var l = links(b)
        l.newGrantId = { taken }
        await #expect(throws: VaultLinks.Failure.noFreeGrantId) {
            try await l.create(try await sources(b), options: .init())
        }
        #expect(b.stub.grantPosts == 3)
    }

    // MARK: - The recipient's round trip

    /// Upload a real file, share it with a password, then be the recipient:
    /// only the link text and the password, no shop token, no vault key.
    @Test("Vault links: a recipient with only the URL fragment and the password unwraps the DK, opens linkMeta and the file")
    func recipientRoundTrip() async throws {
        let b = Bench()
        let data = VaultClientTests.bytes(VaultCrypto.chunkBytes + 777)
        let src = b.file("bracket.stl", data)
        _ = try await VaultUpload.run(b.job(src), client: b.stub.client(), keys: b.keys, spoolRoot: b.spool)
        // The REAL scrypt cost on both sides.
        let made = try await links(b, scryptN: VaultCrypto.linkScrypt.n)
            .create(try await sources(b), options: .init(maxDownloads: 3, password: Self.password))
        let text = made.link.url
        #expect(text.hasPrefix("https://cloud.test/s/" + made.link.grantId + "#"))

        // ── From here on, the recipient. ──
        let link = try VaultLink.parse(text)
        var r = URLRequest(url: URL(string: "https://cloud.test/v1/s/" + link.grantId)!)
        r.httpMethod = "GET"
        let (body, response) = try await b.stub.fetch(r)
        #expect(S3.status(response) == 200)
        let page = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(page["password"] as? Bool == true)
        let item = try #require((page["items"] as? [[String: Any]])?.first)
        let fileId = try #require(item["fileId"] as? String)
        let opened = try VaultLinks.open(link, password: Self.password, fileId: fileId,
                                         wrappedKey: Data(base64Encoded: item["wrappedKey"] as! String)!,
                                         linkMeta: Data(base64Encoded: item["linkMeta"] as! String)!)
        #expect(opened.meta.name == "bracket.stl" && opened.meta.size == data.count)
        #expect(opened.meta.uploadId == item["uploadId"] as? String)
        // And the bytes, every chunk checked against linkMeta's manifest.
        let reader = try VaultCrypto.ChunkReader(dk: opened.dk, fileId: fileId, uploadId: opened.meta.uploadId,
                                                 size: opened.meta.size, chunkHashes: opened.meta.manifest.chunks,
                                                 expectedManifestHash: opened.meta.manifestHash)
        var out = Data()
        for i in 0..<opened.meta.manifest.chunks.count {
            out += try reader.push(try #require(b.stub.objectBytes(fileId, item["version"] as! Int, i)))
        }
        _ = try reader.finish()
        #expect(out == data)
    }

    @Test("Vault links: a wrong password, or none, does not open a password link")
    func wrongPassword() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "kit.stl")
        let made = try await links(b).create(try await sources(b), options: .init(password: Self.password))
        let g = try #require(b.stub.grant(made.link.grantId))
        let item = try #require(g.items.values.first)
        let wk = Data(base64Encoded: item.wrappedKey)!, lm = Data(base64Encoded: item.linkMeta)!
        for wrong in ["mint tea at the souk", "Mint tea at the souq", nil] as [String?] {
            #expect(throws: VaultCrypto.Failure.authentication) {
                try VaultLinks.open(made.link, password: wrong, fileId: g.order[0], wrappedKey: wk, linkMeta: lm,
                                    scryptN: 1024)
            }
        }
        // The right one does.
        _ = try VaultLinks.open(made.link, password: Self.password, fileId: g.order[0], wrappedKey: wk, linkMeta: lm,
                                scryptN: 1024)
    }

    @Test("Vault links: a short password is refused before anything is sent")
    func weakPassword() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "kit.stl")
        let s = try await sources(b)
        let before = b.stub.log.count
        await #expect(throws: VaultLinks.Failure.weakPassword) {
            try await links(b).create(s, options: .init(password: "123456789"))
        }
        #expect(b.stub.log.count == before)
        // An empty password means none.
        let made = try await links(b).create(s, options: .init(password: ""))
        #expect(b.stub.grant(made.link.grantId)?.password == false)
    }

    // MARK: - The secret stays here

    @Test("Vault links: the secret, the link key and the password never appear in any request")
    func secretNeverSent() async throws {
        let b = Bench()
        for i in 0..<3 { try b.stub.seed(keys: b.keys, name: "f\(i).stl") }
        let store = VaultLinkMemoryStore()
        let l = links(b, store: store)
        let all = try await sources(b)
        let made = try await l.create(Array(all.prefix(2)), options: .init(maxDownloads: 2, password: Self.password,
                                                                         note: "for Sara"))
        try await l.addItems(made.link.grantId, [all[2]])
        _ = try await l.list()
        _ = try await l.events(made.link.grantId)
        try await l.addDownloads(made.link.grantId, 3)
        #expect(await l.link(made.link.grantId) == made.link)

        let secret = made.link.secret
        let kept = try #require(await store.load(shopId: VaultStub.shopId, grantId: made.link.grantId))
        #expect(kept.secret == secret)
        let needles = [VaultCrypto.base64url(secret), secret.base64EncodedString(), VaultCrypto.hex(secret),
                       VaultCrypto.base64url(kept.linkKey), kept.linkKey.base64EncodedString(),
                       VaultCrypto.hex(kept.linkKey), Self.password, "for Sara"]
        let log = b.stub.log
        #expect(log.count >= 6)
        for entry in log {
            let wire = entry.url + "\n" + String(decoding: entry.body, as: UTF8.self) + "\n"
                + entry.headers.map { $0.key + ": " + $0.value }.joined(separator: "\n")
            // JSONSerialization writes "/" as "\/"; look for both spellings.
            let unescaped = wire.replacingOccurrences(of: "\\/", with: "/")
            for n in needles { #expect(!unescaped.contains(n), "\(entry.method) \(entry.url) carries a secret") }
            // The raw bytes, too, in case a body were ever binary.
            #expect(entry.body.range(of: secret) == nil && entry.body.range(of: kept.linkKey) == nil)
        }
        // What prints is the id alone.
        for text in [String(describing: made.link), String(reflecting: made.link), String(describing: kept)] {
            #expect(!text.contains(VaultCrypto.base64url(secret)) && !text.contains(VaultCrypto.hex(secret)))
        }
    }

    // MARK: - Keeping a link

    @Test("Vault links: add downloads, extend, remove a file, events, and revoke (which forgets the secret)")
    func keepingALink() async throws {
        let b = Bench()
        for i in 0..<2 { try b.stub.seed(keys: b.keys, name: "f\(i).stl") }
        let store = VaultLinkMemoryStore()
        let l = links(b, store: store)
        let made = try await l.create(try await sources(b), options: .init(maxDownloads: 2, note: "for Sara"))
        let gid = made.link.grantId

        var g = try await l.addDownloads(gid, 3)
        #expect(g.limits.maxDownloads == 5 && g.remaining == 5)
        let end = try #require(Calendar.book.date(byAdding: .day, value: 14, to: Date()))
        g = try await l.extend(gid, to: end)
        #expect(g.limits.expiresAt == VaultLinks.iso(end))
        g = try await l.extend(gid, to: nil)
        #expect(g.limits.expiresAt == nil)
        g = try await l.removeItems(gid, fileIds: [g.items[0].fileId])
        #expect(g.items.count == 1)
        #expect(l.note(try await b.stub.client().grant(gid)) == "for Sara")
        #expect(b.stub.grant(gid)?.ownerNote?.contains("Sara") == false)

        var r = URLRequest(url: URL(string: "https://cloud.test/v1/s/" + gid)!); r.httpMethod = "GET"
        _ = try await b.stub.fetch(r)
        let events = try await l.events(gid)
        #expect(events.first?.kind == "open" && events.first?.deviceClass == "phone")

        g = try await l.revoke(gid)
        #expect(g.state == .revoked)
        #expect(await l.link(gid) == nil && store.count == 0)
        // The list shows it, revoked.
        #expect(try await l.list().first { $0.grantId == gid }?.state == .revoked)
    }

    @Test("Vault links: adding a file needs the link key this device kept")
    func addItemsElsewhere() async throws {
        let b = Bench()
        for i in 0..<2 { try b.stub.seed(keys: b.keys, name: "f\(i).stl") }
        let all = try await sources(b)
        let made = try await links(b).create([all[0]], options: .init(password: Self.password))
        // Another Mac: same shop, its own (empty) Keychain.
        await #expect(throws: VaultLinks.Failure.secretNotHere) {
            try await links(b).addItems(made.link.grantId, [all[1]])
        }
    }

    @Test("Vault links: a trashed file is not shared, and the client reads the cloud's link errors")
    func refusals() async throws {
        let b = Bench()
        let fid = try b.stub.seed(keys: b.keys, name: "f.stl")
        try await b.stub.client().trash(fileId: fid)
        await #expect(throws: VaultLinks.Failure.notShareable(fileId: fid, why: "in the Trash")) {
            try await links(b).create(try await sources(b), options: .init())
        }
        #expect(VaultClient.failure(402, Data(#"{"reason":"links-full","limit":3}"#.utf8)) == .linksFull(limit: 3))
        #expect(VaultClient.failure(402, Data(#"{"reason":"no-links"}"#.utf8)) == .noLinks)
        #expect(VaultClient.failure(409, Data(#"{"reason":"grant-exists"}"#.utf8)) == .grantExists)
        #expect(VaultClient.failure(422, Data(#"{"reason":"unknown-items","fileIds":["a"]}"#.utf8)) == .unknownItems(["a"]))
        #expect(VaultClient.failure(422, Data(#"{"reason":"downloads-cap","limit":10}"#.utf8)) == .downloadsCap(limit: 10))
    }

    @Test("Vault links: a link parses back, and the share page sits beside the API")
    func linkText() throws {
        let link = try VaultLink(origin: VaultLink.origin(forAPI: "https://cloud.khaytapp.com/"),
                                 grantId: VaultCrypto.newGrantId(), secret: VaultCrypto.newLinkSecret())
        #expect(link.url.hasPrefix("https://cloud.khaytapp.com/s/"))
        #expect(!link.url.contains("=") && link.url.split(separator: "#").last?.count == 43)
        #expect(try VaultLink.parse("  " + link.url + "\n") == link)
        #expect(throws: (any Error).self) { try VaultLink.parse("https://cloud.khaytapp.com/s/abc") }
    }

    @Test("Vault links: sources come from the sync state by library record, trashed ones missing")
    func sourcesFromState() {
        var st = VaultSyncState(shopId: "s", deviceId: "d")
        st.records = ["r1": "f1", "r2": "f2"]
        st.files["f2"] = VaultSyncState.Entry(seq: 1, head: 1, metaRev: 1, trashed: true, recordId: "r2", row: nil)
        let (s, missing) = VaultLinks.sources(recordIds: ["r1", "r2", "r3"], state: st)
        #expect(s.isEmpty && missing == ["r1", "r2", "r3"])
    }
}
