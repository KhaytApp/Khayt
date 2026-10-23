import Foundation
import AppKit
import KhaytCore

/// The models a share link is being made for: library record ids, and their
/// titles for the sheet's heading.
struct VaultShareRequest: Identifiable {
    let id = UUID()
    let recordIds: [String]
    let titles: [String]
}

/// Private share links over the vault (`VaultLinks`), as the library uses them.
///
/// ── ONLY WHEN THE LIBRARY'S REMOTE IS THE VAULT ─────────────────────────
///
/// A link shares a vault file, so there is nothing to share from a bucket, a
/// Drive or a library with no remote. Every way in — Share by Private Link on
/// a model, the Links button on the library's strip, the sheets themselves —
/// asks `libraryOnVault` first, and is absent, not disabled, otherwise.
///
/// The vault is still dark in production: nothing in the settings selects it
/// yet (`CloudLibrary.pick` knows a bucket and a Drive), so on every shop
/// today this is false and none of it is drawn. It turns on with the remote,
/// not with a separate switch, so the two cannot disagree.
extension Shop {

    var libraryOnVault: Bool { libraryRemoteId?.hasPrefix(CloudLibrary.vaultIdentityPrefix) == true }

    /// Share this model, or the selection when it is part of one (as the
    /// other model actions do).
    func shareByLink(_ file: LibraryFile) {
        guard libraryOnVault else { return }
        let picked = selectedIds
        let files = picked.contains(file.id) && picked.count > 1 ? selectedFiles : [file]
        sharingByLink = VaultShareRequest(recordIds: files.map(\.id), titles: files.map(\.title))
    }

    /// The link engine over the library's own vault remote, with the secrets
    /// kept in this Mac's Keychain (see `VaultLinkSecret` for why there).
    /// Nil when the remote is not the vault, or its key will not open here.
    func vaultLinkEngine() async -> (links: VaultLinks, remote: VaultRemote)? {
        guard libraryOnVault, let config = await CloudLibrary.config(settings: settingsDict, build: source.build),
              case .vault(let v) = config.remote else { return nil }
        return (VaultLinks(client: v.sync.client, keys: v.sync.keys, secrets: VaultLinkKeychain()), v)
    }

    enum LinkOutcome {
        case made(VaultLinks.Created)
        case refused(String)
        /// Khayt turned off this shop's share links (403 links-disabled): the
        /// sheet explains it and offers no second try.
        case turnedOff(String)
    }

    /// Make the link. Every model must have a copy in the vault: a link that
    /// quietly left some out would be worse than one that says so.
    func makeShareLink(_ request: VaultShareRequest, options: VaultLinks.Options) async -> LinkOutcome {
        guard canWrite else { return .refused(words.callIt("mac.vl_err_not_allowed")) }
        guard let engine = await vaultLinkEngine() else { return .refused(words.callIt("mac.vl_err_vault_off")) }
        do {
            try await engine.remote.sync.pull()
            let (sources, missing) = VaultLinks.sources(recordIds: request.recordIds, state: engine.remote.sync.load())
            if !missing.isEmpty {
                return .refused(Shop.say(words, "mac.vl_err_missing", missing.count))
            }
            return .made(try await engine.links.create(sources, options: options))
        } catch VaultClient.Failure.linksDisabled {
            return .turnedOff(linkProblem(VaultClient.Failure.linksDisabled))
        } catch {
            return .refused(linkProblem(error))
        }
    }

    /// What went wrong, in the shop's language. Never the error's own text,
    /// which is English (and never carries a secret: `VaultLink` withholds it).
    func linkProblem(_ error: Error) -> String {
        switch error {
        case VaultLinks.Failure.weakPassword: return words.callIt("mac.vl_password_rule")
        case VaultLinks.Failure.notShareable, VaultLinks.Failure.nothingToShare, VaultClient.Failure.unknownItems:
            return words.callIt("mac.vl_err_not_in_vault")
        case VaultLinks.Failure.incomplete(_, _, _, let revoked, _):
            // A cleanup revoke that failed is NOT "nothing was shared": the
            // half-made link is live until the shop revokes it.
            return words.callIt(revoked ? "mac.vl_err_incomplete" : "mac.vl_err_incomplete_live")
        case VaultLinks.Failure.tooBig, VaultClient.Failure.fileTooLarge: return words.callIt("mac.vl_err_too_big")
        case VaultClient.Failure.notFound("unknown-grant"): return words.callIt("mac.vl_err_unknown_grant")
        case VaultClient.Failure.notYet: return words.callIt("mac.vl_err_not_yet")
        case VaultLinks.Failure.secretNotHere: return words.callIt("mac.vl_err_other_mac")
        case VaultClient.Failure.linksFull(let limit):
            return words.callIt("mac.vl_err_links_full", ["n": .number(Double(limit))])
        case VaultClient.Failure.noLinks: return words.callIt("mac.vl_err_no_links")
        case VaultClient.Failure.downloadsCap(let limit):
            return words.callIt("mac.vl_err_downloads_cap", ["n": .number(Double(limit))])
        case VaultClient.Failure.vaultOff: return words.callIt("mac.vl_err_vault_off")
        case VaultClient.Failure.notAllowed: return words.callIt("mac.vl_err_not_allowed")
        case VaultClient.Failure.notAccepted: return words.callIt("mac.vl_err_signin")
        case VaultClient.Failure.rateLimited: return words.callIt("mac.vl_err_slow")
        // Phase 2b: the email lock, and Khayt's takedowns.
        case VaultLinks.Failure.noEmails: return words.callIt("mac.vl_lock_err_none")
        case VaultLinks.Failure.tooManyEmails:
            return words.callIt("mac.vl_lock_err_too_many", ["n": .number(Double(VaultLinks.maxEmails))])
        case VaultLinks.Failure.notAnEmail(let typed):
            return words.callIt("mac.vl_lock_err_bad", ["email": .string(Self.address(typed))])
        case VaultClient.Failure.badEmailLock: return words.callIt("mac.vl_err_bad_lock")
        case VaultClient.Failure.mailOff: return words.callIt("mac.vl_err_mail_off")
        case VaultClient.Failure.disabled: return words.callIt("mac.vl_err_disabled")
        case VaultClient.Failure.linksDisabled: return words.callIt("mac.vl_err_links_off")
        default: return words.callIt("mac.vl_err_generic")
        }
    }

    /// An email address inside a sentence: isolated LEFT TO RIGHT (LRI…PDI),
    /// with a left-to-right mark closing it, so one ending in a neutral
    /// ("omar@", as typed) keeps its shape in an Arabic line instead of
    /// reading "@omar" where the isolate alone is not honoured.
    nonisolated static func address(_ s: String) -> String { "\u{2066}" + s + "\u{200E}\u{2069}" }

    /// The vault's own names for its files, for the Links screen: fileId →
    /// the name in the file's sealed record. Read from this Mac's sync state,
    /// off the main actor: it reads a file and opens a record per vault file.
    func vaultFileNames(_ remote: VaultRemote) async -> [String: String] {
        await Task.detached(priority: .userInitiated) { Self.vaultFileNames(of: remote) }.value
    }

    nonisolated static func vaultFileNames(of remote: VaultRemote) -> [String: String] {
        let st = remote.sync.load()
        var out: [String: String] = [:]
        for (fid, e) in st.files {
            guard let row = e.row, let meta = try? VaultMeta.open(row, vaultKey: remote.sync.keys.vaultKey,
                                                                 lastSeenSeq: nil).meta else { continue }
            out[fid] = meta.name
        }
        return out
    }

    // MARK: - Sending a link

    /// The message that carries a link. Never the password: that goes by
    /// another way, or a forwarded message would carry both.
    func linkMessage(_ link: VaultLink) -> String {
        words.callIt("mac.vl_whatsapp_text", ["link": .string(link.url)])
    }

    /// On the pasteboard marked CONCEALED and TRANSIENT (nspasteboard.org):
    /// clipboard managers and history tools that honour the markers neither
    /// show nor keep it. The link is a key to the files.
    func copyLink(_ link: VaultLink) {
        let item = NSPasteboardItem()
        item.setString(link.url, forType: .string)
        for marker in Self.secretPasteboardMarkers { item.setData(Data(), forType: marker) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    nonisolated static let secretPasteboardMarkers = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    /// Open WhatsApp on this Mac with the message ready, for the shop to
    /// choose who it goes to. True when WhatsApp opened; otherwise the link is
    /// copied instead and the caller says so.
    ///
    /// THE APP'S OWN SCHEME, NEVER `wa.me`. A `https://wa.me/?text=…` link is
    /// an ordinary web request: the whole message, secret included, would sit
    /// in a URL sent to a web server and in the browser's history. The fragment
    /// stays off the cloud's wire only if it stays off every wire but the
    /// chat's own, so `whatsapp://send` hands the text straight to the app.
    func sendLinkOnWhatsApp(_ link: VaultLink) -> Bool {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let text = linkMessage(link).addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "whatsapp://send?text=" + text),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            copyLink(link)
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }
}
