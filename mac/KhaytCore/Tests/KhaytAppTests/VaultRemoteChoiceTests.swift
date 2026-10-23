import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Khayt Vault as the library's remote: chosen in the book
/// (`printLibrary.vault`), usable only on a book signed in to Khayt Cloud,
/// and exclusive with the bucket and the Drive.
@MainActor
struct VaultRemoteChoiceTests {

    static let cloud: JSONValue = .object(["enabled": .bool(true), "shopId": .string("shop_V1"), "verified": .bool(true)])

    static func settings(_ library: [String: JSONValue], signedIn: Bool = true) -> [String: JSONValue] {
        var s: [String: JSONValue] = ["printLibrary": .object(library)]
        if signedIn { s["cloud"] = cloud }
        return s
    }

    static let drive: JSONValue = OnlineStoragePaneTests.shopsBook["printLibrary"].flatMap {
        if case .object(let l) = $0 { return l["gdrive"] } else { return nil }
    } ?? .null

    @Test("the vault switched on wins on a signed-in book, and its identity is the shop's")
    func vaultWins() {
        let lib: [String: JSONValue] = ["vault": .object(["enabled": .bool(true)]),
                                        "gdrive": Self.drive, "s3": OnlineStoragePaneTests.bucket(enabled: true)]
        let s = Self.settings(lib)
        #expect(CloudLibrary.remoteInUse(s) == .vault)
        #expect(CloudLibrary.remoteIdentity(s) == "vault:shop_V1")
        #expect(CloudLibrary.remoteIdentity(s)?.hasPrefix(CloudLibrary.vaultIdentityPrefix) == true)
    }

    @Test("signed out, a vault switched on is not the remote: the bucket or Drive is, as before")
    func signedOutFallsBack() {
        let lib: [String: JSONValue] = ["vault": .object(["enabled": .bool(true)]), "s3": OnlineStoragePaneTests.bucket(enabled: true)]
        #expect(CloudLibrary.remoteInUse(Self.settings(lib, signedIn: false)) == .bucket)
        #expect(CloudLibrary.remoteInUse(Self.settings(["vault": .object(["enabled": .bool(true)])], signedIn: false)) == .none)
        // And a book that never chose it is untouched by being signed in.
        #expect(CloudLibrary.remoteInUse(Self.settings(["gdrive": Self.drive])) == .drive)
    }

    @Test("choosing the vault switches the others off; choosing another, or none, switches it off")
    func choiceIsExclusive() {
        var lib: [String: JSONValue] = ["gdrive": Self.drive, "s3": OnlineStoragePaneTests.bucket(enabled: true)]
        CloudLibrary.choose(.vault, in: &lib)
        #expect(CloudLibrary.remoteInUse(Self.settings(lib)) == .vault)
        if case .object(let s3)? = lib["s3"] {
            #expect(s3["enabled"] == .bool(false))
            // The bucket's copy switch is written down before `enabled` is taken.
            #expect(s3["backUpNew"] == .bool(true))
        }
        if case .object(let gd)? = lib["gdrive"] { #expect(gd["enabled"] == .bool(false)) }
        CloudLibrary.choose(.drive, in: &lib)
        #expect(CloudLibrary.remoteInUse(Self.settings(lib)) == .drive)
        CloudLibrary.choose(.vault, in: &lib)
        CloudLibrary.choose(.none, in: &lib)
        if case .object(let v)? = lib["vault"] { #expect(v["enabled"] == .bool(false)) }
        // Leaving the vault switches nothing else on.
        if case .object(let gd)? = lib["gdrive"] { #expect(gd["enabled"] == .bool(false)) }
    }

    @Test("the copy switch is the vault's own, and on unless the shop turned it off")
    func vaultOptions() {
        var root: [String: JSONValue] = ["settings": .object(Self.settings(["vault": .object(["enabled": .bool(true)])]))]
        #expect(CloudLibrary.options(Self.settings(["vault": .object(["enabled": .bool(true)])])).backsUp)
        var o = CloudLibrary.Options(); o.backsUp = false
        CloudLibrary.applyOptions(o, using: .vault, to: &root)
        guard case .object(let s)? = root["settings"], case .object(let l)? = s["printLibrary"],
              case .object(let v)? = l["vault"] else { Issue.record("no vault block"); return }
        #expect(v["backUpNew"] == .bool(false))
        #expect(v["enabled"] == .bool(true), "the copy switch must not choose the remote")
        #expect(l["gdrive"] == nil, "no Drive invented")
    }

    @Test("a model moved to the vault is brought back from the vault first")
    func bringBackOrder() {
        #expect(CloudLibrary.route(provider: "vault") == .vault)
        #expect(CloudLibrary.remoteOrder(provider: "vault", current: .drive) == [.vault, .bucket, .drive])
        // A book that never chose the vault is never asked it.
        #expect(CloudLibrary.remoteOrder(provider: "gdrive", current: .drive) == [.drive, .bucket])
        #expect(CloudLibrary.remoteOrder(provider: nil, current: .bucket) == [.bucket, .drive])
        // While it is the remote, a model moved before is still looked for there last.
        #expect(CloudLibrary.remoteOrder(provider: "gdrive", current: .vault) == [.drive, .bucket, .vault])
        #expect(CloudLibrary.remoteOrder(provider: nil, current: .vault).first == .vault)
    }

    @Test("config needs the vault opened by the shop: chosen but not opened is no remote at all")
    func configNeedsTheOpenedVault() async throws {
        let s = Self.settings(["vault": .object(["enabled": .bool(true)]), "s3": OnlineStoragePaneTests.bucket(enabled: false)])
        #expect(await CloudLibrary.config(settings: s, build: nil, vault: nil) == nil,
                "a locked vault must not fall back to uploading somewhere else")
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-vault-choice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let connection = CloudReader.Connection(url: "https://cloud.test", shopId: "shop_V1", storedToken: "")
        let client = VaultClient(connection: connection, token: "t", fetch: { _ in throw URLError(.notConnectedToInternet) })
        let sync = VaultSync(client: client, keys: try VaultKeys(shopDek: Data(repeating: 7, count: 32)),
                             stateURL: dir.appending(path: "state.json"), deviceId: "mac-test")
        let config = await CloudLibrary.config(settings: s, build: nil, vault: VaultRemote(sync: sync, spoolRoot: dir))
        #expect(config?.isVault == true)
        #expect(config?.provider == "vault")
        #expect(config?.prefix == "")
    }

    @Test("this Mac's vault device id is made once and kept, in the id alphabet")
    func deviceId() throws {
        let defaults = try #require(UserDefaults(suiteName: "khayt-vault-device-\(UUID().uuidString)"))
        let a = Shop.vaultDeviceId(defaults)
        #expect(a == Shop.vaultDeviceId(defaults))
        #expect(a.range(of: "^mac-[0-9a-f]{16}$", options: .regularExpression) != nil)
        defaults.set("bad id with spaces", forKey: Shop.vaultDeviceKey)
        #expect(Shop.vaultDeviceId(defaults) != "bad id with spaces")
    }

    @Test("a shop with no cloud is never offered the vault, and the sample book cannot open one")
    func sampleIsNeedsCloud() async {
        let shop = Shop()
        await shop.load(.sample)
        #expect(await shop.vaultAvailability() == .needsCloud)
        #expect(await shop.vaultRemote() == nil)
    }
}
