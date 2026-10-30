import Foundation
import KhaytCore

/// A product begun from the library's selection: the vault files it starts with.
struct VaultProductRequest: Identifiable {
    let id = UUID()
    let fileIds: [String]
    let titles: [String]
}

/// Selling vault files through makerrun.com, as the library uses it
/// (`VaultProducts` is the client; khayt-cloud "Phase 3a/3b" the contract).
///
/// ── ONLY WHEN THE LIBRARY IS IN THE VAULT ─────────────────────────────────
///
/// A product lists vault files, so like share links it is offered only while
/// the vault is the library's remote (`libraryOnVault`), and absent otherwise.
/// The cloud answers 404 for all of it until the vault is switched on there,
/// and 402 `no-publishing` on a plan that does not include selling: both are
/// said in the sheet, plainly, and nothing else happens.
///
/// ── WHO HOLDS THE MONEY ──────────────────────────────────────────────────
///
/// Nobody here. A buyer pays at the creator's own checkout; this app never
/// sees a card, a payout or a fee. What it does is decide WHICH files the
/// cloud may deliver (`release`), and the sheet says what that means before
/// the shop agrees.
extension Shop {

    /// The products client over the library's own vault remote, or nil when
    /// the remote is not the vault or will not open here.
    func vaultProductsEngine() async -> (products: VaultProducts, remote: VaultRemote)? {
        guard libraryOnVault, let config = await cloudConfig(), case .vault(let v) = config.remote else { return nil }
        return (VaultProducts(client: v.sync.client, keys: v.sync.keys), v)
    }

    /// Begin a product from a model, or from the selection it is part of.
    /// Models with no vault copy are left out and said; none at all is said
    /// instead of opening an empty product.
    func sellAsProduct(_ file: LibraryFile) async {
        guard libraryOnVault, canWrite, permitted("cloud", "edit") else { return }
        let picked = selectedIds
        let files = picked.contains(file.id) && picked.count > 1 ? selectedFiles : [file]
        guard let engine = await vaultProductsEngine() else {
            moveProblem = words.callIt("mac.vl_err_vault_off"); return
        }
        try? await engine.remote.sync.pull()
        let state = engine.remote.sync.load()
        var ids: [String] = [], titles: [String] = []
        for f in files {
            guard let fid = state.records[f.id], let e = state.files[fid], !e.trashed, e.row?.headVersion != nil,
                  !ids.contains(fid) else { continue }
            ids.append(fid); titles.append(f.title)
        }
        guard !ids.isEmpty else { moveProblem = Shop.say(words, "mac.vl_err_missing", files.count); return }
        makingProduct = VaultProductRequest(fileIds: ids, titles: titles)
        showingVaultProducts = true
    }

    /// The files in a release whose model may not be SOLD AS A FILE, by name.
    ///
    /// Selling a file is not selling a print. A NonCommercial or platform
    /// licence forbids it outright, and a bought commercial licence almost
    /// always covers printed copies only. A model with no licence recorded that
    /// came from somewhere (`source`, `sourceUrl`) was downloaded, so the same
    /// question stands. Only the shop's own work (`own`) and the licences that
    /// let anyone redistribute commercially (CC0, BY, BY-SA, BY-ND) pass.
    /// A warning, not a refusal: the shop may hold a licence this app has not
    /// been told about.
    nonisolated static func resaleDoubts(_ fileIds: [String], records: [String: String],
                                         files: [LibraryFile]) -> [String] {
        let free: Set<String> = ["own", "cc0", "cc-by", "cc-by-sa", "cc-by-nd"]
        var byFile: [String: LibraryFile] = [:]
        for (recordId, fileId) in records {
            if let f = files.first(where: { $0.id == recordId }) { byFile[fileId] = f }
        }
        return fileIds.compactMap { fid in
            guard let f = byFile[fid] else { return nil }
            let licence = ModelLicence.find(f.licence)?.id ?? ""
            if free.contains(licence) { return nil }
            let fromSomewhere = !(f.sourceUrl ?? "").isEmpty || !(f.source ?? "").isEmpty
            guard !licence.isEmpty || fromSomewhere else { return nil }
            return f.title
        }
    }

    /// The vault files a release would send, each at its current version.
    /// Files gone from the vault come back in `missing`.
    nonisolated static func releaseSources(_ fileIds: [String], state: VaultSyncState)
        -> (sources: [VaultLinks.Source], missing: [String]) {
        var out: [VaultLinks.Source] = [], missing: [String] = []
        for fid in fileIds {
            guard let e = state.files[fid], !e.trashed, let row = e.row, row.headVersion != nil else {
                missing.append(fid); continue
            }
            out.append(VaultLinks.Source(row: row, lastSeenSeq: e.seq))
        }
        return (out, missing)
    }

    /// What went wrong, in the shop's language, by the cloud's reason.
    func productProblem(_ error: Error) -> String {
        if let r = error as? VaultProducts.Refusal {
            let key = "mac.vp_err_" + r.reason.replacingOccurrences(of: "-", with: "_")
            let said = words.callIt(key, ["n": .number(Double(max(r.fileIds.count, 1)))])
            if said != key { return said }
            if !r.error.isEmpty { return words.callIt("mac.vp_err_cloud", ["why": .string(r.error)]) }
            return words.callIt("mac.vp_err_cloud", ["why": .string("\(r.status) \(r.reason)")])
        }
        if case VaultClient.Failure.vaultOff = error { return words.callIt("mac.vl_err_vault_off") }
        return linkProblem(error)
    }

    /// A payment provider as the shop knows it. Brand names are not
    /// translated; the words are for the ones that have an Arabic name.
    func providerName(_ p: String) -> String {
        let brands = ["stripe": "Stripe", "gumroad": "Gumroad", "lemonsqueezy": "Lemon Squeezy", "payhip": "Payhip",
                      "streampay": "StreamPay", "kofi": "Ko-fi", "etsy": "Etsy", "patreon": "Patreon"]
        if let b = brands[p] { return b }
        return words.callIt("mac.vp_prov_" + p, fallback: p)
    }
}

extension Shop {
    /// Whether the files and versions about to be released are exactly the
    /// ones the release sheet showed.
    nonisolated static func releaseMatches(shown: [String: Int], now: [String: Int]) -> Bool {
        !shown.isEmpty && shown == now
    }
}
