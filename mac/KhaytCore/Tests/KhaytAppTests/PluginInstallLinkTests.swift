import Foundation
import Testing
import CryptoKit
import KhaytCore
@testable import KhaytApp

/// `khayt://plugin/install?id=…&version=…`: the link names a connector and
/// opens the consent sheet; it never installs. Everything it shows comes from
/// Khayt's own signed index and a manifest Khayt signed.
@MainActor
struct PluginInstallLinkTests {

    static let lamhaId = "app.khayt.samples.lamha"
    static let keyId = "khayt-2026-11"
    nonisolated static let manifestURL = "https://khaytapp.com/connectors/lamha.json"

    @Test("only the exact shape is a link: an id, a version, nothing else")
    func shape() throws {
        let ok = try #require(PluginInstallLink(URL(string: "khayt://plugin/install?id=app.khayt.samples.lamha&version=1.1.1")!))
        #expect(ok.id == Self.lamhaId && ok.version == "1.1.1")
        #expect(PluginInstallLink(URL(string: "KHAYT://Plugin/install?version=2.0.0-beta.1&id=com.example.ship")!)?.version == "2.0.0-beta.1")
        for bad in [
            "khayt://plugin/install",
            "khayt://plugin/install?id=app.khayt.samples.lamha",
            "khayt://plugin/install?version=1.0.0",
            "khayt://plugin/install?id=app.khayt.samples.lamha&version=1.0.0&url=https://evil.example/m.json",
            "khayt://plugin/install?id=app.khayt.samples.lamha&id=com.evil.x&version=1.0.0",
            "khayt://plugin/install?id=app.khayt.samples.lamha&version=1.0.0#frag",
            "khayt://plugin/install/now?id=app.khayt.samples.lamha&version=1.0.0",
            "khayt://plugin/remove?id=app.khayt.samples.lamha&version=1.0.0",
            "khayt://plugins/install?id=app.khayt.samples.lamha&version=1.0.0",
            "https://plugin/install?id=app.khayt.samples.lamha&version=1.0.0",
            "khayt://plugin/install?id=Lamha&version=1.0.0",
            "khayt://plugin/install?id=../../etc/passwd&version=1.0.0",
            "khayt://plugin/install?id=app.khayt.samples.lamha&version=latest",
            "khayt://plugin/install?id=app.khayt.samples.lamha&version=1.0.0%0A2",
            "khayt://plugin/install?id=app.khayt.samples.lamha&version=",
            "khayt://plugin/install?id=" + String(repeating: "a", count: 99) + ".bb&version=1.0.0",
            "khayt://user:pw@plugin/install?id=app.khayt.samples.lamha&version=1.0.0",
        ] {
            #expect(PluginInstallLink(URL(string: bad)!) == nil, Comment(rawValue: bad))
        }
        // It is never read as one of the navigating links, nor as a New Job link.
        let url = URL(string: "khayt://plugin/install?id=app.khayt.samples.lamha&version=1.1.1")!
        #expect(NewJobLink(url) == nil)
    }

    static func manifest() throws -> (data: Data, version: String, sha: String) {
        let data = try ConnectorInstallTests.sample("lamha-shipping")
        let m = Shop.object(try JSONDecoder().decode(JSONValue.self, from: data))
        let version = Shop.plainString(m["version"]) ?? ""
        return (data, version, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// A well-formed index (`lib/plugin-update.js`), issued an hour ago.
    static func index(version: String, sha: String, revoked: [String] = [], id: String = lamhaId,
                      issued: Date = Date().addingTimeInterval(-3600), requires: JSONValue? = nil) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id), "kind": .string("connector"), "version": .string(version),
            "url": .string(manifestURL), "sha256": .string(sha)]
        if let requires { row["requires"] = requires }
        if !revoked.isEmpty {
            row["revoked"] = .array(revoked.map { .object(["version": .string($0), "reason": .string("withdrawn")]) })
        }
        return .object([
            "khaytIndex": .number(1), "serial": .number(7),
            "issuedAt": .string(StoreWriter.iso(issued)), "expires": .string(StoreWriter.iso(issued.addingTimeInterval(45 * 86400))),
            "entries": .array([.object(row)])])
    }

    actor Asked {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }

    /// A shop that may install, whose fetch answers the manifest and records what was asked.
    static func shop(serving data: Data?) async -> (Shop, Asked) {
        let shop = await ConnectorInstallTests.shop()
        shop.pretendsWritable = true
        let asked = Asked()
        shop.connectorFetch = { url, _ in
            await asked.add(url)
            guard let data, url.absoluteString == manifestURL else { throw URLError(.badServerResponse) }
            return data
        }
        return (shop, asked)
    }

    @Test("the listed, signed version opens the consent sheet and writes nothing")
    func offers() async throws {
        let m = try Self.manifest()
        let (shop, asked) = await Self.shop(serving: m.data)
        let before = shop.settingsValue
        let link = PluginInstallLink(id: Self.lamhaId, version: m.version)
        #expect(await shop.offerConnector(from: link, index: Self.index(version: m.version, sha: m.sha), signedBy: Self.keyId) == nil)
        let offer = try #require(shop.connectorOffer)
        #expect(offer.manifestId == Self.lamhaId && offer.version == m.version)
        #expect(offer.reviewedBy != nil, "the sheet is built from a manifest Khayt signed")
        #expect(shop.settingsValue == before, "nothing is installed until the shop presses Install")
        #expect(await asked.urls.map(\.absoluteString) == [Self.manifestURL], "fetched from where the index says, nowhere else")
    }

    @Test("a connector that needs a newer Khayt is refused before anything is downloaded, as an update would be held")
    func needsNewerKhayt() async throws {
        let m = try Self.manifest()
        let link = PluginInstallLink(id: Self.lamhaId, version: m.version)
        func offer(_ requires: JSONValue?, app: String = "4.0.0", schema: Int = 1) async -> (Shop.InstallLinkRefusal?, [URL], Bool) {
            let (shop, asked) = await Self.shop(serving: m.data)
            let refusal = await shop.offerConnector(from: link, index: Self.index(version: m.version, sha: m.sha, requires: requires),
                                                    signedBy: Self.keyId, appVersion: app, schema: schema)
            return (refusal, await asked.urls, shop.connectorOffer != nil)
        }
        // A newer Mac app than this one.
        var (refusal, urls, sheet) = await offer(.object(["mac": .string("4.1.0")]))
        #expect(refusal == .newer && urls.isEmpty && !sheet, "the manifest was fetched for a connector this Khayt cannot run")
        // A newer schema.
        (refusal, urls, sheet) = await offer(.object(["schema": .number(2)]))
        #expect(refusal == .newer && urls.isEmpty && !sheet)
        // Met exactly, or exceeded: offered.
        (refusal, urls, sheet) = await offer(.object(["mac": .string("4.0.0"), "schema": .number(1)]))
        #expect(refusal == nil && urls.count == 1 && sheet)
        (refusal, _, sheet) = await offer(.object(["mac": .string("3.9.0")]), app: "4.0.0-beta.42")
        #expect(refusal == nil && sheet)
        // Another platform's minimum is not this Mac's.
        (refusal, _, sheet) = await offer(.object(["desktop": .string("9.0.0"), "ios": .string("9.0.0")]))
        #expect(refusal == nil && sheet)
        // The rule is asked with plain numbers, never a made-up version compared as text
        // (under some languages' sort order "-1" did not come before "0.9").
        let engineSource = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift"), encoding: .utf8)
        #expect(engineSource.contains("U.planUpdate({ version: '0' }, {}, Object.assign({}, row, { version: '1', revoked: [] }), ctx)"))
        #expect(!engineSource.contains("planUpdate({ version: '-1' }"))
        // No requirement at all.
        (refusal, _, sheet) = await offer(nil)
        #expect(refusal == nil && sheet)
    }

    @Test("every way it can go wrong is a refusal with no sheet")
    func refusals() async throws {
        let m = try Self.manifest()
        let link = PluginInstallLink(id: Self.lamhaId, version: m.version)
        let good = Self.index(version: m.version, sha: m.sha)

        // An index nobody signed, and one that has expired.
        var (shop, asked) = await Self.shop(serving: m.data)
        #expect(await shop.offerConnector(from: link, index: good, signedBy: nil) == .index)
        let old = Self.index(version: m.version, sha: m.sha, issued: Date().addingTimeInterval(-60 * 86400))
        #expect(await shop.offerConnector(from: link, index: old, signedBy: Self.keyId) == .index)
        #expect(await asked.urls.isEmpty, "no manifest is fetched on an index that cannot be trusted")
        #expect(shop.connectorOffer == nil)

        // Not listed; another version listed; this version withdrawn.
        #expect(await shop.offerConnector(from: PluginInstallLink(id: "com.example.unknown", version: "1.0.0"), index: good, signedBy: Self.keyId) == .unlisted)
        #expect(await shop.offerConnector(from: PluginInstallLink(id: Self.lamhaId, version: "0.9.0"), index: good, signedBy: Self.keyId) == .otherVersion)
        let withdrawn = Self.index(version: m.version, sha: m.sha, revoked: [m.version])
        #expect(await shop.offerConnector(from: link, index: withdrawn, signedBy: Self.keyId) == .withdrawn)
        #expect(await asked.urls.isEmpty && shop.connectorOffer == nil)

        // The bytes are not the ones the index promised.
        let wrongSha = Self.index(version: m.version, sha: String(repeating: "0", count: 64))
        #expect(await shop.offerConnector(from: link, index: wrongSha, signedBy: Self.keyId) == .manifest)
        // The download fails.
        (shop, asked) = await Self.shop(serving: nil)
        #expect(await shop.offerConnector(from: link, index: good, signedBy: Self.keyId) == .manifest)
        // A manifest Khayt did not sign, even with the right hash.
        var tampered = Shop.object(try JSONDecoder().decode(JSONValue.self, from: m.data))
        tampered["domains"] = .array([.string("evil.example")])
        let bad = try JSONEncoder().encode(JSONValue.object(tampered))
        let badSha = SHA256.hash(data: bad).map { String(format: "%02x", $0) }.joined()
        (shop, asked) = await Self.shop(serving: bad)
        #expect(await shop.offerConnector(from: link, index: Self.index(version: m.version, sha: badSha), signedBy: Self.keyId) == .manifest)
        // The right bytes under another id: the link cannot be pointed at a different connector.
        (shop, asked) = await Self.shop(serving: m.data)
        let other = PluginInstallLink(id: "com.example.other", version: m.version)
        #expect(await shop.offerConnector(from: other, index: Self.index(version: m.version, sha: m.sha, id: "com.example.other"), signedBy: Self.keyId) == .manifest)
        #expect(shop.connectorOffer == nil)
    }

    @Test("switched off, read-only, or not allowed by the lock: nothing is fetched")
    func gates() async throws {
        let m = try Self.manifest()
        let link = PluginInstallLink(id: Self.lamhaId, version: m.version)
        let (shop, asked) = await Self.shop(serving: m.data)
        #expect(await shop.offerConnector(from: link, switchedOn: false) == .off)
        shop.pretendsWritable = false
        #expect(await shop.offerConnector(from: link, switchedOn: true) == .notAllowed)
        #expect(await shop.offerConnector(from: link, index: Self.index(version: m.version, sha: m.sha), signedBy: Self.keyId) == .notAllowed)
        #expect(await asked.urls.isEmpty)

        let locked = await OperatorLockTests.shop()
        locked.pretendsWritable = true
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333"), ("OP-m", "2222")] as [(String, String)?] {
            locked.lockNow()
            if let who { #expect(await locked.signIn(who.0, pin: who.1) == .ok) }
            #expect(locked.mayInstallConnectors == locked.lockAllows("settings", "edit"), Comment(rawValue: who?.0 ?? "nobody"))
            if !locked.lockAllows("settings", "edit") {
                #expect(await locked.offerConnector(from: link, switchedOn: true) == .notAllowed)
            }
        }
    }

    @Test("an index the outer call cannot verify is refused before any manifest is asked for")
    func unsignedOverTheWire() async throws {
        let m = try Self.manifest()
        let shop = await ConnectorInstallTests.shop()
        shop.pretendsWritable = true
        let asked = Asked()
        let index = Self.index(version: m.version, sha: m.sha)
        shop.connectorFetch = { url, _ in
            await asked.add(url)
            return try JSONEncoder().encode(index)
        }
        #expect(await shop.offerConnector(from: PluginInstallLink(id: Self.lamhaId, version: m.version), switchedOn: true) == .index)
        #expect(await asked.urls == [Shop.connectorIndexURL], "only the index was fetched")
    }

    @Test("every refusal has a sentence, and each says nothing was installed")
    func words() async {
        let shop = await ConnectorInstallTests.shop()
        for refusal in ["off", "notAllowed", "index", "unlisted", "otherVersion", "withdrawn", "newer", "manifest"] {
            let said = shop.words.callIt("mac.pil_" + refusal, ["id": .string("com.example.ship"), "v": .string("1.2.0")])
            #expect(!said.hasPrefix("mac.") && !said.contains("{"), Comment(rawValue: said))
        }
        #expect(Shop.InstallLinkRefusal(rawValue: "otherVersion") == .otherVersion)
    }
}
