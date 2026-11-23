import Foundation
import SwiftUI
import KhaytCore

/// `khayt://plugin/install?id=…&version=…` — "Install in Khayt" on a
/// connector's page in the directory (`plugin-directory-design.md` 3.6).
///
/// ── THE LINK NAMES A CONNECTOR; IT INSTALLS NOTHING ──────────────────────
///
/// A web page can open a khayt:// link, so the link carries only an id and a
/// version: no manifest, no address to fetch from, no consent. What it does
/// is what the shop could do by hand: Khayt reads its OWN signed index, finds
/// that id, checks the listed version is the one named and is not withdrawn,
/// downloads the manifest from where the index says, checks it is the bytes
/// the index promised and that Khayt signed it, and opens the same consent
/// sheet as a hand install. The website cannot pre-tick, skip or soften
/// consent: the sheet is built from the signed manifest, and nothing is
/// written until the shop presses Install in it.
///
/// Anything that is not exactly this shape is refused when the URL is read:
/// another path, an extra or repeated field, an id that is not a connector
/// id, a version that is not a version.
struct PluginInstallLink: Equatable, Sendable {
    var id: String
    var version: String

    /// An id is `lib/plugin-manifest.js` ID_RE, reverse-DNS in lower case; a
    /// version is digits and dots with an optional pre-release or build tag.
    static func isId(_ s: String) -> Bool { s.wholeMatch(of: /^[a-z0-9]+(\.[a-z0-9][a-z0-9-]*)+$/) != nil }
    static func isVersion(_ s: String) -> Bool { s.wholeMatch(of: /^[0-9]+(\.[0-9]+){0,3}([-+][0-9A-Za-z.-]{1,24})?$/) != nil }
    static let maxId = 100
    static let maxVersion = 40

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "khayt",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.host?.lowercased() == "plugin", comps.percentEncodedPath == "/install",
              comps.fragment == nil, comps.user == nil, comps.password == nil, comps.port == nil,
              let items = comps.queryItems, items.count == 2,
              Set(items.map(\.name)) == ["id", "version"] else { return nil }
        let id = items.first { $0.name == "id" }?.value ?? ""
        let version = items.first { $0.name == "version" }?.value ?? ""
        guard id.count <= Self.maxId, Self.isId(id),
              version.count <= Self.maxVersion, Self.isVersion(version) else { return nil }
        self.id = id
        self.version = version
    }

    init(id: String, version: String) { self.id = id; self.version = version }
}

/// Opens Settings when something is handed to the app: the app delegate has
/// no SwiftUI environment. The shop window keeps its action here, as
/// `ShopWindowOpener` keeps the window's.
@MainActor
enum SettingsOpener {
    static var open: OpenSettingsAction?
}

@MainActor
extension Shop {

    /// Install links handed to the app, waiting for a book.
    static var openedInstallLinks: [PluginInstallLink] = [] {
        didSet {
            guard !openedInstallLinks.isEmpty else { return }
            openedLinksArrived = Date()
            NotificationCenter.default.post(name: .khaytOpenedLinks, object: nil)
        }
    }

    /// Why a link could not be put in front of the shop, or nil when the
    /// consent sheet is up.
    enum InstallLinkRefusal: String, Equatable {
        /// Connectors are not switched on in this build.
        case off
        /// Nobody may change settings here (the lock, a read-only window, the sample).
        case notAllowed
        /// The index could not be fetched, read or verified.
        case index
        /// The directory does not list this connector.
        case unlisted
        /// The directory lists another version than the link names.
        case otherVersion
        /// Khayt withdrew this version.
        case withdrawn
        /// The manifest could not be fetched, or is not the signed bytes promised.
        case manifest
    }

    /// The connector a link names, read from Khayt's own signed index and put
    /// in front of the shop as the consent sheet. Nothing is written here.
    func offerConnector(from link: PluginInstallLink, switchedOn: Bool = ConnectorsSwitch.isOn()) async -> InstallLinkRefusal? {
        guard switchedOn else { return .off }
        guard mayInstallConnectors, let engine else { return .notAllowed }
        let fetch = connectorFetch ?? Self.fetchConnectorBytes
        guard let bytes = try? await fetch(Self.connectorIndexURL, Self.connectorIndexMaxBytes),
              let index = try? JSONDecoder().decode(JSONValue.self, from: bytes),
              let message = try? await engine.pluginIndexMessage(index),
              let keys = try? await engine.pluginSigningKeys() else { return .index }
        let signedBy = Connectors.indexSignedBy(index: index, message: message, keys: keys)
        return await offerConnector(from: link, index: index, signedBy: signedBy)
    }

    /// Only somebody who may change settings, in a window that can write: a
    /// read-only window and the lock's other roles can browse, not install.
    var mayInstallConnectors: Bool { !needsSignIn && lockAllows("settings", "edit") && canWrite }

    /// The same, from an index already read. `signedBy` is the key id the
    /// index's signature was verified with, or nil: an index nobody signed is
    /// refused by the shared rule (`checkIndex`), as is an expired one.
    func offerConnector(from link: PluginInstallLink, index: JSONValue, signedBy: String?,
                        now: Date = Date()) async -> InstallLinkRefusal? {
        guard mayInstallConnectors, let engine else { return .notAllowed }
        let fetch = connectorFetch ?? Self.fetchConnectorBytes
        let ctx = JSONValue.object([
            "signedBy": signedBy.map(JSONValue.string) ?? .null,
            "nowMs": .number((now.timeIntervalSince1970 * 1000).rounded()),
        ])
        guard let found = try? await engine.pluginIndexListing(index: index, ctx: ctx, id: link.id), found.ok else { return .index }
        guard let row = found.row else { return .unlisted }
        if found.revoked.contains(link.version) { return .withdrawn }
        guard row.version == link.version else { return .otherVersion }
        guard let url = URL(string: row.url),
              let data = try? await fetch(url, Self.connectorManifestMaxBytes),
              let manifest = await verifiedConnectorManifest(data, sha256: row.sha256, engine: engine),
              case .object(let m) = manifest,
              m["id"] == .string(link.id), m["version"] == .string(link.version) else { return .manifest }
        // The same door as a hand install: the offer is built from the signed
        // manifest's own bytes, and refused again there if it may not install.
        guard await offerConnector(data) == nil else { return .manifest }
        return nil
    }

    /// Follow an install link: the consent sheet in Settings ▸ Integrations,
    /// or a sentence saying why not.
    func receive(_ link: PluginInstallLink) async {
        if let refusal = await offerConnector(from: link) {
            moveProblem = words.callIt("mac.pil_" + refusal.rawValue, ["id": .string(link.id), "v": .string(link.version)])
            return
        }
        settingsPane = .integrations
        SettingsOpener.open?()
    }
}
