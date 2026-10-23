import Foundation
import Testing
@testable import KhaytCore

/// The security review's fixes (#2032): half-made links, dead links'
/// secrets, the parser, and what never prints.
struct VaultLinksPendingTests {

    typealias Bench = VaultClientTests.Bench

    /// A store that remembers every save, to see the pending marker come and go.
    final class Recording: VaultLinkSecretStore, @unchecked Sendable {
        let inner = VaultLinkMemoryStore()
        let lock = NSLock()
        var saves: [VaultLinkSecret] = []
        func save(_ s: VaultLinkSecret, shopId: String, grantId: String) async -> Bool {
            lock.withLock { saves.append(s) }
            return await inner.save(s, shopId: shopId, grantId: grantId)
        }
        func load(shopId: String, grantId: String) async -> VaultLinkSecret? { await inner.load(shopId: shopId, grantId: grantId) }
        func forget(shopId: String, grantId: String) async { await inner.forget(shopId: shopId, grantId: grantId) }
    }

    final class Clock: @unchecked Sendable {
        let lock = NSLock(); var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    func links(_ b: Bench, _ store: any VaultLinkSecretStore, clock: Clock? = nil) -> VaultLinks {
        var l = VaultLinks(client: b.stub.client(), keys: b.keys, secrets: store)
        l.scryptN = 1024
        if let clock { l.now = { clock.now } }
        return l
    }

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

    @Test("Vault links: a link sent in batches is kept PENDING until the last batch, then whole")
    func pendingUntilWhole() async throws {
        let b = Bench()
        for i in 0..<501 { try b.stub.seed(keys: b.keys, name: "p\(i)") }
        let store = Recording()
        let l = links(b, store)
        let made = try await l.create(try await sources(b), options: .init())
        #expect(store.saves.map(\.isPending) == [true, false])
        #expect(await l.link(made.link.grantId) == made.link)
        // One batch: never pending at all.
        let one = Recording()
        _ = try await links(b, one).create(Array(try await sources(b).prefix(3)), options: .init())
        #expect(one.saves.map(\.isPending) == [false])
    }

    /// The app dies between the POST and the PATCHes, or the cleanup revoke
    /// cannot reach the cloud: the same state either way.
    @Test("Vault links: a half-made link whose cleanup failed is incomplete, never copyable, and revoked after 10 minutes")
    func halfMadeIsSwept() async throws {
        let b = Bench()
        for i in 0..<501 { try b.stub.seed(keys: b.keys, name: "p\(i)") }
        b.stub.failPatchNumber = 1
        b.stub.failRevoke = true
        let store = VaultLinkMemoryStore(), clock = Clock()
        let l = links(b, store, clock: clock)
        var gid = ""
        do {
            _ = try await l.create(try await sources(b), options: .init())
            Issue.record("made a link with a file missing")
        } catch VaultLinks.Failure.incomplete(let id, _, _, let revoked, _) {
            gid = id
            #expect(!revoked)   // and so reported as NOT revoked
        }
        // Live on the cloud, kept here as pending, and not offered for copying.
        #expect(b.stub.grant(gid)?.revoked == false)
        #expect(await store.load(shopId: VaultStub.shopId, grantId: gid)?.isPending == true)
        #expect(await l.link(gid) == nil)

        b.stub.failRevoke = false
        var t = await l.tidy(try await l.list())
        #expect(t.local[gid] == .incomplete)
        #expect(b.stub.grant(gid)?.revoked == false)   // still inside the grace period

        clock.advance(VaultLinks.pendingGrace + 1)
        t = await l.tidy(try await l.list())
        #expect(b.stub.grant(gid)?.revoked == true)
        #expect(t.grants.first { $0.grantId == gid }?.state == .revoked)
        #expect(t.local[gid] == VaultLinks.Local.none && store.count == 0)
    }

    @Test("Vault links: a link revoked, expired or used up elsewhere has its secret forgotten here")
    func deadLinksForgotten() async throws {
        let b = Bench()
        for i in 0..<2 { try b.stub.seed(keys: b.keys, name: "f\(i)") }
        let store = VaultLinkMemoryStore()
        let l = links(b, store)
        let s = try await sources(b)
        let a = try await l.create([s[0]], options: .init()), c = try await l.create([s[1]], options: .init())
        b.stub.revokeElsewhere(a.link.grantId)
        let t = await l.tidy(try await l.list())
        #expect(t.local[a.link.grantId] == VaultLinks.Local.none && t.local[c.link.grantId] == .copyable)
        #expect(await l.link(a.link.grantId) == nil && store.count == 1)
    }

    @Test("Vault links: a '/s/' inside the fragment is not a link, and does not trap")
    func parseFragmentSlashS() throws {
        #expect(throws: (any Error).self) { try VaultLink.parse("https://x/#a/s/b") }
        #expect(throws: (any Error).self) { try VaultLink.parse("#/s/") }
    }

    @Test("Vault links: the stored record reads v1 as whole and keeps the pending time in v2")
    func recordFormat() throws {
        let s = VaultCrypto.newLinkSecret(), k = VaultCrypto.newLinkSecret()
        let v1 = try #require(VaultLinkSecret(bytes: Data([1]) + s + k))
        #expect(v1.secret == s && v1.linkKey == k && !v1.isPending)
        let when = Date(timeIntervalSince1970: 1_800_000_123)
        let v2 = VaultLinkSecret(secret: s, linkKey: k, pendingSince: when)
        #expect(VaultLinkSecret(bytes: v2.bytes) == v2 && v2.bytes.count == 73)
        #expect(VaultLinkSecret(bytes: v2.done().bytes)?.isPending == false)
        #expect(VaultLinkSecret(bytes: Data([3]) + s + k) == nil)
    }

    @Test("Vault links: secrets do not print through dump or reflection either")
    func mirrorsRedact() async throws {
        let s = VaultCrypto.newLinkSecret(), k = VaultCrypto.newLinkSecret()
        let kept = VaultLinkSecret(secret: s, linkKey: k)
        let options = VaultLinks.Options(password: "mint tea at the souq", note: "for Sara")
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "x.stl")
        let prepared = try links(b, VaultLinkMemoryStore()).prepare(try await sources(b)[0])
        for value in [kept as Any, options, prepared] {
            var out = ""
            dump(value, to: &out)
            out += String(reflecting: value) + String(describing: value)
            for needle in [VaultCrypto.hex(s), VaultCrypto.hex(k), VaultCrypto.hex(prepared.dk), "mint tea", "Sara",
                           s.base64EncodedString(), prepared.dk.base64EncodedString()] {
                #expect(!out.contains(needle))
            }
        }
        #expect(VaultClient.failure(422, Data(#"{"reason":"not-yet"}"#.utf8)) == .notYet)
    }
}
