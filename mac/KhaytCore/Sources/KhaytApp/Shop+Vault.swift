import Foundation
import KhaytCore

/// The Khayt Vault as this shop's library remote: the shop's own space on
/// Khayt Cloud, every file sealed on this Mac before it leaves.
///
/// ── WHAT OPENS IT ─────────────────────────────────────────────────────────
///
/// The book CHOOSES it (`printLibrary.vault.enabled`, Settings › Online
/// storage), and the shop OPENS it: the vault's keys come from the cloud's
/// data key, which only an unlocked shop holds (`cloudDek`). Locked, signed
/// out or on the sample book, `vaultRemote` is nil and the library has no
/// remote to use — nothing is uploaded anywhere else in its place, which is
/// the rule for a bucket secret that will not open on this Mac too.
///
/// The cloud answers 404 for every vault route until the vault is switched on
/// there (`VaultClient.Failure.vaultOff`), and the pane offers the vault only
/// once `vaultAvailability` has seen it answer — so on a cloud with the vault
/// off, none of this is reachable.
extension Shop {

    /// This Mac, as the vault records which device uploaded a version. Made
    /// once and kept in this Mac's defaults: a device id is not a secret and
    /// does not belong in the book, which every device shares.
    nonisolated static let vaultDeviceKey = "khayt.vault.deviceId"
    nonisolated static func vaultDeviceId(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: vaultDeviceKey),
           id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil { return id }
        let id = "mac-" + VaultCrypto.hex(VaultCrypto.newLinkSecret().prefix(8))
        defaults.set(id, forKey: vaultDeviceKey)
        return id
    }

    /// The signed-in cloud's address and session token, opened for one use.
    func vaultSession() async -> (CloudReader.Connection, String)? {
        guard let build = source.build, Self.cloudConnected(settingsDict),
              let connection = try? CloudReader.connection(settingsDict),
              let token = try? await Secrets.open(connection.storedToken, for: build), !token.isEmpty
        else { return nil }
        return (connection, token)
    }

    /// The vault, opened with this shop's keys, or nil when it cannot be
    /// opened here: no unlocked cloud, no library folder, the sample book.
    func vaultRemote() async -> VaultRemote? {
        guard let dek = cloudDek, let build = source.build, let root = libraryRoots?.primary,
              let (connection, token) = await vaultSession(),
              let keys = try? VaultKeys(shopDek: dek) else { return nil }
        let client = VaultClient(connection: connection, token: token, fetch: CloudLibrary.fetch)
        let sync = VaultSync(client: client, keys: keys, appFolder: build.vaultStateFolder(),
                             libraryRoot: URL(fileURLWithPath: root), deviceId: Self.vaultDeviceId())
        return VaultRemote(sync: sync, spoolRoot: build.vaultStateFolder().appending(path: "vault-spool"))
    }

    /// What the cloud says about this shop's vault, for the settings pane.
    enum VaultAvailability: Equatable {
        /// Not signed in to Khayt Cloud, or the cloud is locked on this Mac.
        case needsCloud
        /// The cloud has no vault switched on (404): nothing is offered.
        case off
        /// Usable, with how full it is.
        case ready(VaultClient.Usage)
        /// The cloud did not answer as expected. Said, and nothing offered.
        case problem(String)
    }

    func vaultAvailability() async -> VaultAvailability {
        guard cloudDek != nil, let (connection, token) = await vaultSession() else { return .needsCloud }
        let client = VaultClient(connection: connection, token: token, fetch: CloudLibrary.fetch)
        do {
            return .ready(try await client.usage())
        } catch VaultClient.Failure.vaultOff {
            return .off
        } catch {
            return .problem(ErrorText.plain(error))
        }
    }

    /// Make the vault the library's remote, or stop using it. Every other
    /// remote is switched off by choosing it (`CloudLibrary.choose`); leaving
    /// it switches nothing else on. Files already in a Drive or a bucket stay
    /// there, and models are copied to the vault by the next backup.
    func useVault(_ on: Bool) async {
        guard permitted("settings", "edit") else { return }
        cloudLibraryProblem = nil
        guard let build = source.build else { cloudLibraryProblem = words.callIt("mac.settings_sample"); return }
        do {
            try await StoreWriter.updateAsync(build) { root in
                var settings = Self.settings(root)
                var library: [String: JSONValue] = [:]
                if case .object(let l)? = settings["printLibrary"] { library = l }
                CloudLibrary.choose(on ? .vault : .none, in: &library)
                settings["printLibrary"] = .object(library)
                root["settings"] = .object(settings)
            }
            await load(source)
            cloudLibraryNote = words.callIt(on ? "mac.vault_now_used" : "mac.vault_no_longer_used")
        } catch {
            cloudLibraryProblem = cloudSay(error)
        }
    }
}
