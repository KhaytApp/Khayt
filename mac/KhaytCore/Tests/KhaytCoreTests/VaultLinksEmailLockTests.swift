import Foundation
import Testing
@testable import KhaytCore

/// Phase 2b of the vault links (`docs/api-contract.md` "Phase 2b" in
/// khayt-cloud): the email lock, Khayt's takedowns and the recipient on an
/// event, against `VaultStub`'s grant routes. No network, no Keychain.
struct VaultLinksEmailLockTests {

    typealias Bench = VaultClientTests.Bench

    static let password = "mint tea at the souq"

    func links(_ b: Bench, store: VaultLinkMemoryStore = VaultLinkMemoryStore()) -> VaultLinks {
        var l = VaultLinks(client: b.stub.client(), keys: b.keys, secrets: store)
        l.scryptN = 1024
        return l
    }

    func sources(_ b: Bench) async throws -> [VaultLinks.Source] {
        try await b.stub.client().files(since: 0).files.map { VaultLinks.Source(row: $0, lastSeenSeq: nil) }
    }

    /// The JSON bodies of every grant POST and PATCH.
    func grantBodies(_ b: Bench) -> [(method: String, body: [String: Any])] {
        b.stub.log.filter { $0.url.contains("/vault/grants") && ($0.method == "POST" || $0.method == "PATCH") }.map {
            ($0.method, ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]) ?? [:])
        }
    }

    /// Open the link as its page would: no shop token, with the stub's proof
    /// cookie when `as` is given.
    func open(_ b: Bench, _ grantId: String, as email: String? = nil) async throws -> Int {
        var r = URLRequest(url: URL(string: "https://cloud.test/v1/s/" + grantId)!)
        r.httpMethod = "GET"
        if let email { r.setValue("kvs=" + email, forHTTPHeaderField: "Cookie") }
        return S3.status(try await b.stub.fetch(r).1)
    }

    // MARK: - Checking the addresses

    @Test("Vault links email lock: addresses are trimmed, lower-cased and de-duplicated, in order, blanks skipped")
    func tidiesAddresses() throws {
        #expect(try VaultLinks.emailLock(["  Sara@Example.COM ", "", "omar@shop.sa", "sara@example.com", " \n"])
                == ["sara@example.com", "omar@shop.sa"])
        // 50 is the most; repeats do not count against it.
        let fifty = (0..<50).map { "p\($0)@x.sa" }
        #expect(try VaultLinks.emailLock(fifty + ["P0@X.SA"]).count == 50)
    }

    @Test("Vault links email lock: none, over 50 and malformed addresses are refused, naming the one typed")
    func refusesBadLists() {
        #expect(throws: VaultLinks.Failure.noEmails) { try VaultLinks.emailLock([]) }
        #expect(throws: VaultLinks.Failure.noEmails) { try VaultLinks.emailLock(["", "  "]) }
        #expect(throws: VaultLinks.Failure.tooManyEmails(51)) {
            try VaultLinks.emailLock((0..<51).map { "p\($0)@x.sa" })
        }
        for bad in ["sara", "sara@", "@example.com", "sara@example", "sara@.com", "sara@example.", "sa ra@x.sa",
                    "sara@@x.sa", "a@b@c.sa", String(repeating: "a", count: 250) + "@x.sa"] {
            #expect(throws: VaultLinks.Failure.notAnEmail(bad)) { try VaultLinks.emailLock(["ok@x.sa", " " + bad]) }
        }
    }

    /// The stub's `cleanEmailLock` is a line-for-line port of `src/vault.js`.
    @Test("Vault links email lock: the client agrees with the cloud's check, case by case")
    func sameSyntaxAsTheCloud() {
        let cases = ["a@b.c", "a.b+c@d-e.f.g", "سارة@مثال.السعودية", "a@b..c", "a@.b.c", "a@b.c.", ".a@b.c",
                     "a@b", "a b@c.d", "a@b c.d", "a@@b.c", "", "@", "a@b.cd\u{00A0}", "a\t@b.c",
                     String(repeating: "a", count: 248) + "@b.cd", String(repeating: "a", count: 250) + "@b.cd"]
        for c in cases {
            let ours = (try? VaultLinks.emailLock([c])) != nil
            let theirs = VaultStub.cleanEmailLock([c]) != nil
            #expect(ours == theirs, "\(c.debugDescription): client \(ours), cloud \(theirs)")
        }
    }

    @Test("Vault links email lock: a pasted list splits on commas (Latin and Arabic), semicolons, spaces and lines")
    func splitsPastedText() {
        #expect(VaultLinks.emails(in: "a@x.sa, b@x.sa;c@x.sa\nd@x.sa  e@x.sa،f@x.sa\u{061B}g@x.sa,,")
                == ["a@x.sa", "b@x.sa", "c@x.sa", "d@x.sa", "e@x.sa", "f@x.sa", "g@x.sa"])
        #expect(VaultLinks.emails(in: "  \n ").isEmpty)
    }

    // MARK: - Create, set, clear

    @Test("Vault links email lock: a link is made locked, and the list is sent tidied")
    func createLocked() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "kit.stl")
        let made = try await links(b).create(try await sources(b),
                                             options: .init(emailLock: [" Sara@Example.com", "omar@shop.sa"]))
        #expect(grantBodies(b).first?.body["emailLock"] as? [String] == ["sara@example.com", "omar@shop.sa"])
        let g = try await b.stub.client().grant(made.link.grantId)
        #expect(g.emailLock == ["sara@example.com", "omar@shop.sa"] && g.state == .ok)
        // No lock asked: the field is not sent at all.
        _ = try await links(b).create(try await sources(b), options: .init())
        #expect(grantBodies(b).last?.body.keys.contains("emailLock") == false)
        #expect(try await b.stub.client().grants().contains { $0.emailLock == nil })
    }

    @Test("Vault links email lock: a bad list is refused before anything is sent")
    func badListSendsNothing() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "kit.stl")
        let s = try await sources(b)
        let before = b.stub.log.count
        await #expect(throws: VaultLinks.Failure.notAnEmail("sara@")) {
            try await links(b).create(s, options: .init(emailLock: ["sara@"]))
        }
        await #expect(throws: VaultLinks.Failure.noEmails) {
            try await links(b).create(s, options: .init(emailLock: []))
        }
        #expect(b.stub.log.count == before)
    }

    @Test("Vault links email lock: set it on a link, change it, and take it off with null")
    func setChangeClear() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "kit.stl")
        let l = links(b)
        let gid = try await l.create(try await sources(b), options: .init()).link.grantId
        var g = try await l.setEmailLock(gid, ["Sara@Example.com"])
        #expect(g.emailLock == ["sara@example.com"])
        g = try await l.setEmailLock(gid, ["omar@shop.sa", "sara@example.com"])
        #expect(g.emailLock == ["omar@shop.sa", "sara@example.com"])
        g = try await l.removeEmailLock(gid)
        #expect(g.emailLock == nil)
        let patches = grantBodies(b).filter { $0.method == "PATCH" }.map(\.body)
        #expect(patches.count == 3)
        #expect(patches[0]["emailLock"] as? [String] == ["sara@example.com"])
        #expect(patches[2]["emailLock"] is NSNull && patches[2].count == 1)
        // A bad change is refused here, with nothing sent.
        let before = b.stub.log.count
        await #expect(throws: VaultLinks.Failure.tooManyEmails(51)) {
            try await l.setEmailLock(gid, (0..<51).map { "p\($0)@x.sa" })
        }
        #expect(b.stub.log.count == before)
    }

    // MARK: - The cloud's refusals

    @Test("Vault links email lock: 422 mail-off and bad-email-lock read as their own failures")
    func unprocessable() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "kit.stl")
        let l = links(b), store = VaultLinkMemoryStore()
        let gid = try await l.create(try await sources(b), options: .init()).link.grantId
        b.stub.mailOff = true
        await #expect(throws: VaultClient.Failure.mailOff) {
            try await links(b, store: store).create(try await sources(b), options: .init(emailLock: ["a@x.sa"]))
        }
        #expect(store.count == 0)
        await #expect(throws: VaultClient.Failure.mailOff) { try await l.setEmailLock(gid, ["a@x.sa"]) }
        // Taking a lock off needs no email, so it still works.
        #expect(try await l.removeEmailLock(gid).emailLock == nil)
        b.stub.mailOff = false
        // A list the client would never send, straight at the route.
        await #expect(throws: VaultClient.Failure.badEmailLock) {
            try await b.stub.client().patchGrant(gid, VaultClient.GrantPatch(emailLock: .set(["not an address"])))
        }
        #expect(VaultClient.failure(422, Data(#"{"reason":"bad-email-lock"}"#.utf8)) == .badEmailLock)
        #expect(VaultClient.failure(422, Data(#"{"reason":"mail-off"}"#.utf8)) == .mailOff)
        #expect(VaultClient.failure(409, Data(#"{"reason":"disabled"}"#.utf8)) == .disabled)
        #expect(VaultClient.failure(403, Data(#"{"reason":"links-disabled"}"#.utf8)) == .linksDisabled)
        // A plain 403 is still a role refusal.
        #expect(VaultClient.failure(403, Data(#"{"error":"viewer"}"#.utf8)) == .notAllowed)
    }

    @Test("Vault links email lock: 403 links-disabled stops a new link, and nothing is kept for it")
    func linksDisabled() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "kit.stl")
        b.stub.linksDisabled = true
        let store = VaultLinkMemoryStore()
        await #expect(throws: VaultClient.Failure.linksDisabled) {
            try await links(b, store: store).create(try await sources(b), options: .init())
        }
        #expect(store.count == 0 && b.stub.grants.isEmpty)
    }

    // MARK: - Turned off by Khayt

    @Test("Vault links email lock: a link Khayt turned off refuses every change but Revoke")
    func disabledOnlyRevokes() async throws {
        let b = Bench()
        for i in 0..<2 { try b.stub.seed(keys: b.keys, name: "f\(i).stl") }
        let all = try await sources(b)
        let store = VaultLinkMemoryStore()
        let l = links(b, store: store)
        let gid = try await l.create([all[0]], options: .init(maxDownloads: 2, emailLock: ["a@x.sa"])).link.grantId
        b.stub.takedown(gid, reason: "Reported for copyright")

        let g = try #require(try await l.list().first { $0.grantId == gid })
        #expect(g.state == .disabled && g.isDisabled)
        #expect(g.disabledReason == "Reported for copyright" && g.disabledAt != nil)
        #expect(g.emailLock == ["a@x.sa"])

        let patchesBefore = b.stub.grantPatches
        await #expect(throws: VaultClient.Failure.disabled) { try await l.addDownloads(gid, 5) }
        await #expect(throws: VaultClient.Failure.disabled) { try await l.extend(gid, to: nil) }
        await #expect(throws: VaultClient.Failure.disabled) { try await l.setEmailLock(gid, ["b@x.sa"]) }
        await #expect(throws: VaultClient.Failure.disabled) { try await l.removeEmailLock(gid) }
        await #expect(throws: VaultClient.Failure.disabled) { try await l.addItems(gid, [all[1]]) }
        await #expect(throws: VaultClient.Failure.disabled) { try await l.removeItems(gid, fileIds: [all[0].row.fileId]) }
        #expect(b.stub.grantPatches == patchesBefore + 6)
        #expect(b.stub.grant(gid)?.emailLock == ["a@x.sa"] && b.stub.grant(gid)?.items.count == 1)
        // The page is told it ended.
        #expect(try await open(b, gid, as: "a@x.sa") == 410)

        // Revoke goes through, and forgets the secret.
        let after = try await l.revoke(gid)
        #expect(b.stub.grant(gid)?.revoked == true && after.state == .disabled)
        #expect(store.count == 0)
    }

    @Test("Vault links email lock: a disabled link keeps its secret but is not copyable, and comes back when Khayt turns it on")
    func disabledKeepsSecret() async throws {
        let b = Bench()
        try b.stub.seed(keys: b.keys, name: "kit.stl")
        let store = VaultLinkMemoryStore()
        let l = links(b, store: store)
        let gid = try await l.create(try await sources(b), options: .init()).link.grantId
        b.stub.takedown(gid, reason: nil)
        var (grants, local) = await l.tidy(try await l.list())
        #expect(grants.first?.state == .disabled && grants.first?.disabledReason == nil)
        #expect(local[gid] == VaultLinks.Local.none && store.count == 1)
        b.stub.takedown(gid, reason: nil, on: false)
        (grants, local) = await l.tidy(try await l.list())
        #expect(grants.first?.state == .ok && local[gid] == .copyable)
    }

    @Test("Vault links email lock: a grant from before phase 2b decodes with no lock and not disabled")
    func olderGrantDecodes() throws {
        let json = #"{"grantId":"AAAAAAAAAAAAAAAAAAAAAA","state":"ok","limits":{},"items":[],"emailLock":[],"disabledReason":"  "}"#
        let g = try JSONDecoder().decode(VaultClient.Grant.self, from: Data(json.utf8))
        #expect(g.emailLock == nil && g.disabledReason == nil && !g.isDisabled)
        let bare = try JSONDecoder().decode(VaultClient.Grant.self,
                                            from: Data(#"{"grantId":"AAAAAAAAAAAAAAAAAAAAAA"}"#.utf8))
        #expect(bare.emailLock == nil && bare.disabledAt == nil)
    }

    // MARK: - Who opened it

    @Test("Vault links email lock: an event names the address that proved itself; an open link's events name nobody")
    func recipients() async throws {
        let b = Bench()
        for i in 0..<2 { try b.stub.seed(keys: b.keys, name: "f\(i).stl") }
        let all = try await sources(b)
        let l = links(b)
        let locked = try await l.create([all[0]], options: .init(emailLock: ["sara@example.com"])).link.grantId
        let plain = try await l.create([all[1]], options: .init()).link.grantId

        #expect(try await self.open(b, locked) == 403)                    // no proof yet
        #expect(try await self.open(b, locked, as: "omar@shop.sa") == 403) // not on the lock
        #expect(try await self.open(b, locked, as: "Sara@Example.com") == 200)
        #expect(try await self.open(b, plain) == 200)

        let e = try #require(try await l.events(locked).first)
        #expect(e.kind == "open" && e.recipient == "sara@example.com")
        #expect(try await l.events(plain).first?.recipient == nil)
    }

    // MARK: - What still never leaves this device

    @Test("Vault links email lock: with a lock and a password, the secret, link key and password still never leave")
    func secretStillNeverSent() async throws {
        let b = Bench()
        for i in 0..<2 { try b.stub.seed(keys: b.keys, name: "f\(i).stl") }
        let store = VaultLinkMemoryStore()
        let l = links(b, store: store)
        let made = try await l.create(try await sources(b),
                                      options: .init(password: Self.password, note: "for Sara",
                                                     emailLock: ["sara@example.com"]))
        let gid = made.link.grantId
        try await l.setEmailLock(gid, ["sara@example.com", "omar@shop.sa"])
        try await l.removeEmailLock(gid)
        _ = try await l.events(gid)
        b.stub.takedown(gid, reason: "x")
        _ = await l.tidy(try await l.list())

        let kept = try #require(await store.load(shopId: VaultStub.shopId, grantId: gid))
        let secret = made.link.secret
        let needles = [VaultCrypto.base64url(secret), secret.base64EncodedString(), VaultCrypto.hex(secret),
                       VaultCrypto.base64url(kept.linkKey), kept.linkKey.base64EncodedString(),
                       VaultCrypto.hex(kept.linkKey), Self.password, "for Sara", made.link.url]
        var sawLock = false
        for entry in b.stub.log {
            let wire = (entry.url + "\n" + String(decoding: entry.body, as: UTF8.self) + "\n"
                + entry.headers.map { $0.key + ": " + $0.value }.joined(separator: "\n"))
                .replacingOccurrences(of: "\\/", with: "/")
            for n in needles { #expect(!wire.contains(n), "\(entry.method) \(entry.url) carries a secret") }
            #expect(entry.body.range(of: secret) == nil && entry.body.range(of: kept.linkKey) == nil)
            if wire.contains("omar@shop.sa") { sawLock = true }
        }
        // The addresses DO go: the cloud needs them to send the codes.
        #expect(sawLock)
        // And the options print the lock as a count, the password withheld.
        let printed = String(reflecting: VaultLinks.Options(password: Self.password, emailLock: ["sara@example.com"]))
        #expect(!printed.contains(Self.password) && !printed.contains("sara@example.com"))
    }
}
