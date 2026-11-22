import Foundation

/// ── WHICH EXTENSIONS MAY START THE BROWSER HOST ──────────────────────────
///
/// THE ONE FILE TO EDIT AFTER A STORE UPLOAD.
///
/// A Chromium browser starts `khayt-browser-host` only for an extension whose
/// id is in the host manifest's `allowed_origins`, and a store assigns that id
/// on the first upload — so until Save to Khayt is in the Chrome Web Store and
/// Edge Add-ons these lists are EMPTY, and Settings says Chrome, Edge, Brave
/// and Vivaldi are waiting for the store. A shop that loads the extension
/// unpacked (a developer) adds its id with
///
///     defaults write app.khayt.mac mac.sfw_devExtensionIds -array <id>
///
/// (`BrowserHosts.devIdsKey`; `extension-khayt/README.md` says how to read the
/// id off chrome://extensions). Firefox needs no wait: its id is chosen by the
/// extension itself (`browser_specific_settings.gecko.id` in `pack.mjs`).
///
/// After a Settings ▸ Install has been clicked with an older list, the row
/// shows Update: the manifest it wrote names fewer ids than this file does.
public enum BrowserExtensionIds {

    /// TODO(store): the id the Chrome Web Store assigns Save to Khayt on its
    /// first upload (Developer Dashboard ▸ the item ▸ "Item ID", 32 letters
    /// a–p). Brave and Vivaldi install from the Chrome Web Store, so this one
    /// id serves them too.
    public static let chromeWebStore: [String] = ["dfaafmaijpbjlfchomelcndpinphnpln"]

    /// TODO(store): the id Microsoft Edge Add-ons assigns on its first upload
    /// (Partner Center ▸ the extension ▸ Extension overview ▸ "Extension ID").
    /// Different from the Chrome Web Store's; Edge can install from either
    /// store, so the host manifest names both.
    public static let edgeAddOns: [String] = ["phaddgncdojaiihhbcdgcnokfogmhdbk"]

    /// TODO(store): true once Save to Khayt is listed on addons.mozilla.org
    /// under its gecko id (`BrowserHosts.firefoxExtensionId`). Until then
    /// the id is only what the extension CLAIMS, and whoever lists an add-on
    /// with it first could start the host — so Settings keeps Firefox's
    /// Install waiting for the store, as Chromium's does.
    public static let firefoxListed = true

    /// Every store id, in the order a manifest names them.
    public static var store: [String] { chromeWebStore + edgeAddOns }

    /// A Chromium extension id: 32 letters from a to p (a base-16 digest
    /// spelled with letters).
    public static func isChromiumId(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }
}
