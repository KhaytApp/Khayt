import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KhaytCore

/// The shop's products: vault files listed for sale on makerrun.com.
///
/// ── WHAT EACH SHEET DECIDES ───────────────────────────────────────────────
///
/// * The LIST says, per product, whether makerrun can show it, whether it is
///   released, and how many buyers it has; and below, the sales webhooks that
///   let a sale deliver itself and the makerrun connection.
/// * The EDITOR is the listing: plaintext and public, except which files it
///   holds. Nothing is released by saving it.
/// * The RELEASE sheet is the trust change. It lists exactly the files and
///   versions Khayt Cloud will be able to read, in the words the privacy
///   policy uses (khaytapp.com/privacy, website #74: change them there
///   first), and nothing is sent until the shop confirms.
/// * BUYERS: who has a link, how much they have used, delivering by hand
///   (a bank transfer, an order from elsewhere) and revoking.
struct VaultProductsSheet: View {
    let shop: Shop

    @State private var products: [VaultProducts.Product] = []
    @State private var released: [String: VaultProducts.ReleaseState] = [:]
    @State private var hooks: [VaultProducts.SalesHook] = []
    @State private var connections: [VaultProducts.Connection] = []
    @State private var names: [String: String] = [:]
    @State private var loading = true
    @State private var problem: String?
    @State private var editing: VaultProductEditTarget?
    @State private var releasing: VaultProducts.Product?
    @State private var buyersOf: VaultProducts.Product?
    @State private var askingRemove: VaultProducts.Product?
    private let preloaded: Bool

    /// `shown` draws these products without asking the cloud: for a photograph.
    init(shop: Shop, shown: [VaultProducts.Product]? = nil, released: [String: VaultProducts.ReleaseState] = [:]) {
        self.shop = shop
        preloaded = shown != nil
        _products = State(initialValue: shown ?? [])
        _released = State(initialValue: released)
        _loading = State(initialValue: shown == nil)
    }

    private var words: Words { shop.words }
    private var live: [VaultProducts.Product] { products.filter { !$0.isRemoved } }

    var body: some View {
        SheetFrame(width: 600) {
            HStack {
                Text(words.callIt("mac.vp_title")).font(.headline)
                Spacer()
                Button(words.callIt("mac.vl_refresh")) { Task { await load() } }.disabled(loading)
                Button(words.callIt("mac.vp_new") + "\u{2026}") { editing = .new([]) }
                    .disabled(!shop.canWrite || loading)
            }
            Text(words.callIt("mac.vp_explain"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Over the plan after a move down: new products, edits, previews
            // and releases are paused; removing a product still works.
            VaultLapseNotice(shop: shop, display: shop.vaultLapseDisplay)
            if loading && products.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if live.isEmpty && problem == nil {
                Text(words.callIt("mac.vp_none")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(live) { p in
                row(p)
                Divider()
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention).fixedSize(horizontal: false, vertical: true)
            }
            if !loading {
                VaultSalesHooksBlock(shop: shop, hooks: $hooks)
                connectionBlock
            }
        } footer: {
            HStack {
                Spacer()
                Button(words.callIt("common.close")) { shop.showingVaultProducts = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .task { if !preloaded { await load() } }
        .shopSheet(item: $editing) { target in
            VaultProductEditor(shop: shop, target: target, names: names) { saved in
                editing = nil
                if let saved { upsert(saved) }
            }
        }
        .shopSheet(item: $releasing) { p in
            VaultReleaseSheet(shop: shop, product: p, names: names) { state in
                releasing = nil
                if let state { released[p.productId] = state }
            }
        }
        .shopSheet(item: $buyersOf) { p in VaultBuyersSheet(shop: shop, product: p) { buyersOf = nil } }
        .confirmationDialog(words.callIt("mac.vp_remove_title"),
                            isPresented: Binding(get: { askingRemove != nil }, set: { if !$0 { askingRemove = nil } }),
                            presenting: askingRemove) { p in
            Button(words.callIt("mac.vp_remove"), role: .destructive) { Task { await remove(p) } }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        } message: { _ in Text(words.callIt("mac.vp_remove_body")) }
    }

    private func title(_ p: VaultProducts.Product) -> String {
        let t = words.language == "ar" ? p.title.ar : p.title.en
        return t.isEmpty ? (p.title.en.isEmpty ? p.title.ar : p.title.en) : t
    }

    @ViewBuilder private func row(_ p: VaultProducts.Product) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(p)).font(.body.weight(.medium)).lineLimit(1)
                if let price = p.priceText, !price.isEmpty {
                    Text(verbatim: "\u{2066}" + price + "\u{2069}").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if p.status == "unpublished" {
                    CapsLabel(words.callIt("mac.vp_unpublished"), tint: Role.text2)
                } else if p.makerrunListable {
                    CapsLabel(words.callIt("mac.vp_listable"), tint: Role.ok)
                } else {
                    CapsLabel(words.callIt("mac.vp_not_listable"), tint: Khayt.attention)
                }
            }
            Text(releaseLine(p)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(words.callIt("mac.vp_edit") + "\u{2026}") { editing = .edit(p) }.disabled(!shop.canWrite)
                Button(words.callIt("mac.vp_release") + "\u{2026}") { releasing = p }.disabled(!shop.canWrite)
                Button(words.callIt("mac.vp_buyers") + "\u{2026}") { buyersOf = p }
                Spacer()
                Button(words.callIt("mac.vp_remove") + "\u{2026}", role: .destructive) { askingRemove = p }
                    .disabled(!shop.canWrite)
            }
            .controlSize(.small)
        }
    }

    private func releaseLine(_ p: VaultProducts.Product) -> String {
        let files = Shop.say(words, "mac.vp_n_files", p.files.count)
        guard let r = released[p.productId], let at = r.releasedAt else {
            return files + " · " + words.callIt("mac.vp_not_released")
        }
        // A file added to the listing since the last release is not on sale yet.
        let behind = Set(p.files).subtracting(r.items.map(\.fileId)).count
        let day = Calendar.localDay(ofInstant: at)
        var line = files + " · " + words.callIt("mac.vp_released_on", ["day": .string(day)])
        if behind > 0 { line += " · " + Shop.say(words, "mac.vp_n_unreleased", behind) }
        return line
    }

    @ViewBuilder private var connectionBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "makerrun.com").font(.subheadline.weight(.semibold))
            if let c = connections.first(where: { $0.client == "makerrun" }) {
                Text(words.callIt("mac.vp_makerrun_connected", ["name": .string(c.shopName ?? "")]))
                    .font(.callout)
                Button(words.callIt("mac.vp_makerrun_disconnect")) { Task { await disconnect() } }
                    .controlSize(.small).disabled(!shop.canWrite)
            } else {
                Text(words.callIt("mac.vp_makerrun_how")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func upsert(_ p: VaultProducts.Product) {
        if let i = products.firstIndex(where: { $0.productId == p.productId }) { products[i] = p }
        else { products.insert(p, at: 0) }
    }

    private func load() async {
        loading = true; problem = nil
        defer { loading = false }
        guard let engine = await shop.vaultProductsEngine() else { problem = words.callIt("mac.vl_err_vault_off"); return }
        Task { await shop.refreshVaultLapse(force: true) }
        do {
            try? await engine.remote.sync.pull()
            names = await shop.vaultFileNames(engine.remote)
            products = try await engine.products.products()
            var r: [String: VaultProducts.ReleaseState] = [:]
            for p in products where !p.isRemoved {
                if let s = try? await engine.products.releaseState(p.productId) { r[p.productId] = s }
            }
            released = r
            hooks = (try? await engine.products.salesHooks()) ?? []
            connections = (try? await engine.products.connections()) ?? []
            if let start = shop.makingProduct {
                shop.makingProduct = nil
                editing = .new(start.fileIds)
            }
        } catch {
            problem = shop.productProblem(error)
        }
    }

    private func remove(_ p: VaultProducts.Product) async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        guard let engine = await shop.vaultProductsEngine() else { return }
        do { try await engine.products.remove(p.productId); await load() }
        catch { problem = shop.productProblem(error) }
    }

    private func disconnect() async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        guard let engine = await shop.vaultProductsEngine() else { return }
        do { try await engine.products.disconnect("makerrun"); connections.removeAll { $0.client == "makerrun" } }
        catch { problem = shop.productProblem(error) }
    }
}

/// What the editor opens on.
enum VaultProductEditTarget: Identifiable {
    case new([String])
    case edit(VaultProducts.Product)
    var id: String {
        switch self {
        case .new(let ids): return "new:" + ids.joined(separator: ",")
        case .edit(let p): return p.productId
        }
    }
}

// MARK: - The listing

struct VaultProductEditor: View {
    let shop: Shop
    let target: VaultProductEditTarget
    /// fileId → name, for the files picker.
    let names: [String: String]
    let done: (VaultProducts.Product?) -> Void

    @State private var draft: VaultProducts.Draft
    @State private var previews: [VaultProducts.Preview]
    @State private var limitDays: Bool
    @State private var working = false
    @State private var problem: String?

    private var words: Words { shop.words }

    /// The licences a creator usually means, by code. "Other" keeps what was typed.
    static let licences: [(code: String, key: String)] = [
        ("personal", "mac.vp_lic_personal"), ("commercial", "mac.vp_lic_commercial"),
        ("CC-BY-4.0", "mac.vp_lic_ccby"), ("CC-BY-NC-4.0", "mac.vp_lic_ccbync"),
    ]

    init(shop: Shop, target: VaultProductEditTarget, names: [String: String],
         done: @escaping (VaultProducts.Product?) -> Void) {
        self.shop = shop; self.target = target; self.names = names; self.done = done
        switch target {
        case .new(let ids):
            var d = VaultProducts.Draft(); d.files = ids
            d.licence = .init(code: "personal", name: shop.words.callIt("mac.vp_lic_personal"))
            _draft = State(initialValue: d); _previews = State(initialValue: [])
            _limitDays = State(initialValue: false)
        case .edit(let p):
            _draft = State(initialValue: VaultProducts.Draft(p)); _previews = State(initialValue: p.previews)
            _limitDays = State(initialValue: p.delivery.validDays != nil)
        }
    }

    private var productId: String? { if case .edit(let p) = target { return p.productId } else { return nil } }

    /// What the cloud will refuse, said before it is asked.
    private var invalid: String? {
        if draft.title.en.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.title.ar.trimmingCharacters(in: .whitespaces).isEmpty { return words.callIt("mac.vp_need_title") }
        guard let url = URL(string: draft.checkoutUrl.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              url.host != nil else { return words.callIt("mac.vp_need_checkout") }
        if draft.files.isEmpty { return words.callIt("mac.vp_need_files") }
        if draft.licence.name.trimmingCharacters(in: .whitespaces).isEmpty { return words.callIt("mac.vp_need_licence") }
        return nil
    }

    var body: some View {
        SheetFrame(width: 560) {
            Text(words.callIt(productId == nil ? "mac.vp_new_title" : "mac.vp_edit_title")).font(.headline)
            Text(words.callIt("mac.vp_public_note")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(words.callIt("mac.vp_title_en")).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("", text: $draft.title.en).textFieldStyle(.roundedBorder)
                        .environment(\.layoutDirection, .leftToRight)
                }
                GridRow {
                    Text(words.callIt("mac.vp_title_ar")).foregroundStyle(.secondary)
                    TextField("", text: $draft.title.ar).textFieldStyle(.roundedBorder)
                        .environment(\.layoutDirection, .rightToLeft)
                }
                GridRow {
                    Text(words.callIt("mac.vp_desc_en")).foregroundStyle(.secondary)
                    TextField("", text: $draft.description.en, axis: .vertical).textFieldStyle(.roundedBorder)
                        .lineLimit(2...5).environment(\.layoutDirection, .leftToRight)
                }
                GridRow {
                    Text(words.callIt("mac.vp_desc_ar")).foregroundStyle(.secondary)
                    TextField("", text: $draft.description.ar, axis: .vertical).textFieldStyle(.roundedBorder)
                        .lineLimit(2...5).environment(\.layoutDirection, .rightToLeft)
                }
                GridRow {
                    Text(words.callIt("mac.vp_kind")).foregroundStyle(.secondary)
                    Picker("", selection: $draft.kind) {
                        Text(words.callIt("mac.vp_kind_paid")).tag("paid")
                        Text(words.callIt("mac.vp_kind_members")).tag("members")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                GridRow {
                    Text(words.callIt("mac.vp_provider")).foregroundStyle(.secondary)
                    Picker("", selection: $draft.provider) {
                        ForEach(VaultProducts.providers, id: \.self) { p in
                            Text(shop.providerName(p)).tag(p)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text(words.callIt("mac.vp_checkout")).foregroundStyle(.secondary)
                    TextField("", text: $draft.checkoutUrl, prompt: Text(verbatim: "https://buy.stripe.com/…"))
                        .textFieldStyle(.roundedBorder).environment(\.layoutDirection, .leftToRight)
                }
                GridRow {
                    Text(words.callIt("mac.vp_provider_id")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("", text: $draft.providerProductId).textFieldStyle(.roundedBorder)
                            .environment(\.layoutDirection, .leftToRight)
                        Text(words.callIt("mac.vp_provider_id_hint")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text(words.callIt("mac.vp_price")).foregroundStyle(.secondary)
                    TextField("", text: $draft.priceText, prompt: Text(verbatim: "SAR 25"))
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                }
                GridRow {
                    Text(words.callIt("mac.vp_licence")).foregroundStyle(.secondary)
                    licencePicker
                }
            }
            filesBlock
            deliveryBlock
            if productId != nil { previewsBlock }
            Toggle(words.callIt("mac.vp_hide"), isOn: Binding(get: { draft.status == "unpublished" },
                                                             set: { draft.status = $0 ? "unpublished" : "active" }))
            if let msg = problem ?? (draft.files.isEmpty && draft.title.en.isEmpty ? nil : invalid) {
                Text(msg).font(.callout).foregroundStyle(Khayt.attention).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(words.callIt("common.cancel")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(words.callIt("common.save")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || invalid != nil || !shop.canWrite)
            }
        }
    }

    @ViewBuilder private var licencePicker: some View {
        let code = Self.licences.contains { $0.code == draft.licence.code } ? draft.licence.code : "other"
        HStack {
            Picker("", selection: Binding(get: { code }, set: { picked in
                if let l = Self.licences.first(where: { $0.code == picked }) {
                    draft.licence = .init(code: l.code, name: words.callIt(l.key))
                } else {
                    draft.licence = .init(code: "other", name: "")
                }
            })) {
                ForEach(Self.licences, id: \.code) { Text(words.callIt($0.key)).tag($0.code) }
                Text(words.callIt("mac.vp_lic_other")).tag("other")
            }
            .labelsHidden().fixedSize()
            if code == "other" {
                TextField("", text: $draft.licence.name, prompt: Text(words.callIt("mac.vp_lic_name")))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder private var filesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(words.callIt("mac.vp_files")).font(.subheadline.weight(.semibold))
            Text(words.callIt("mac.vp_files_hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let all = names.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(all, id: \.key) { fid, name in
                        Toggle(name, isOn: Binding(get: { draft.files.contains(fid) }, set: { on in
                            if on { if !draft.files.contains(fid) { draft.files.append(fid) } }
                            else { draft.files.removeAll { $0 == fid } }
                        }))
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Text(Shop.say(words, "mac.vp_n_files", draft.files.count)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var deliveryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(words.callIt("mac.vp_delivery")).font(.subheadline.weight(.semibold))
            HStack {
                Stepper(value: $draft.delivery.maxDownloads, in: 1...1000) {
                    Text(Shop.say(words, "mac.vp_n_downloads", draft.delivery.maxDownloads))
                }
                Toggle(words.callIt("mac.vp_per_file"), isOn: $draft.delivery.perFile).toggleStyle(.checkbox)
            }
            HStack {
                Toggle(words.callIt("mac.vp_valid_for"), isOn: Binding(get: { limitDays }, set: { on in
                    limitDays = on; draft.delivery.validDays = on ? (draft.delivery.validDays ?? 30) : nil
                })).toggleStyle(.checkbox)
                if limitDays {
                    Stepper(value: Binding(get: { draft.delivery.validDays ?? 30 }, set: { draft.delivery.validDays = $0 }),
                            in: 1...3650) {
                        Text(words.counting(draft.delivery.validDays ?? 30, "mac.cloudlib_n_days"))
                    }
                }
            }
            Text(words.callIt("mac.vp_delivery_hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var previewsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(words.callIt("mac.vp_previews")).font(.subheadline.weight(.semibold))
            HStack {
                Text(Shop.say(words, "mac.vp_n_previews", previews.count)).font(.callout)
                Spacer()
                Button(words.callIt("mac.vp_add_preview") + "\u{2026}") { Task { await addPreview() } }
                    .disabled(previews.count >= 8 || working)
                if !previews.isEmpty {
                    Button(words.callIt("mac.vp_clear_previews")) { Task { await clearPreviews() } }.disabled(working)
                }
            }
            Text(words.callIt("mac.vp_previews_hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        working = true; problem = nil
        defer { working = false }
        guard let engine = await shop.vaultProductsEngine() else { problem = words.callIt("mac.vl_err_vault_off"); return }
        do {
            if let productId { done(try await engine.products.update(productId, draft)) }
            else { done(try await engine.products.create(draft)) }
        } catch {
            problem = shop.productProblem(error)
        }
    }

    private func addPreview() async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        guard let productId else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard data.count <= 2 * 1024 * 1024 else { problem = words.callIt("mac.vp_err_preview_big"); return }
        let mime = UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) == true ? "image/png" : "image/jpeg"
        working = true; defer { working = false }
        guard let engine = await shop.vaultProductsEngine() else { return }
        do {
            let p = try await engine.products.addPreview(productId, image: data, mime: mime)
            if !previews.contains(where: { $0.hash == p.hash }) { previews.append(p) }
        } catch { problem = shop.productProblem(error) }
    }

    private func clearPreviews() async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        guard let productId else { return }
        working = true; defer { working = false }
        guard let engine = await shop.vaultProductsEngine() else { return }
        do { previews = try await engine.products.setPreviews(productId, []).previews }
        catch { problem = shop.productProblem(error) }
    }
}

// MARK: - The release

struct VaultReleaseSheet: View {
    let shop: Shop
    let product: VaultProducts.Product
    let names: [String: String]
    let done: (VaultProducts.ReleaseState?) -> Void

    @State private var lines: [(fileId: String, name: String, version: Int)] = []
    @State private var missing: [String] = []
    @State private var dropping: [String] = []
    @State private var working = false
    @State private var loading = true
    @State private var problem: String?
    @State private var result: VaultProducts.Released?
    private let preloaded: Bool

    private var words: Words { shop.words }

    /// `shown` draws these files without asking the cloud: for a photograph.
    init(shop: Shop, product: VaultProducts.Product, names: [String: String],
         shown: [(fileId: String, name: String, version: Int)]? = nil,
         done: @escaping (VaultProducts.ReleaseState?) -> Void) {
        self.shop = shop; self.product = product; self.names = names; self.done = done
        preloaded = shown != nil
        _lines = State(initialValue: shown ?? [])
        _loading = State(initialValue: shown == nil)
    }

    var body: some View {
        SheetFrame(width: 500) {
            Text(words.callIt("mac.vp_release_title")).font(.headline)
            if let result {
                Label(words.callIt("mac.vp_released", ["n": .number(Double(result.items))]),
                      systemImage: "checkmark.circle.fill").foregroundStyle(Khayt.done)
                if result.grantsUpdated + result.grantsQueued > 0 {
                    Text(Shop.say(words, "mac.vp_buyers_updated", result.grantsUpdated + result.grantsQueued))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(words.callIt("mac.vp_release_list")).font(.callout.weight(.medium))
                if loading { ProgressView() }
                ForEach(lines, id: \.fileId) { l in
                    HStack {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text(l.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(words.callIt("mac.vp_version", ["v": .number(Double(l.version))]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !missing.isEmpty {
                    Text(Shop.say(words, "mac.vp_missing", missing.count)).font(.callout)
                        .foregroundStyle(Khayt.attention).fixedSize(horizontal: false, vertical: true)
                }
                // The privacy policy's own sentences (website #74). Change them
                // there first, then here.
                Text(words.callIt("mac.vp_release_promise"))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Role.line2.opacity(0.4)))
                if !dropping.isEmpty {
                    Text(Shop.say(words, "mac.vp_dropping", dropping.count)).font(.callout)
                        .foregroundStyle(Khayt.attention).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                if result == nil {
                    Button(words.callIt("common.cancel")) { done(nil) }.keyboardShortcut(.cancelAction)
                    Button(words.callIt(dropping.isEmpty ? "mac.vp_release_confirm" : "mac.vp_release_confirm_drop")) {
                        Task { await release() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || loading || lines.isEmpty || !shop.canWrite)
                } else {
                    Button(words.callIt("common.close")) {
                        done(.init(releasedAt: result?.releasedAt, items: lines.map { .init(fileId: $0.fileId, version: $0.version) }))
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .task { if !preloaded { await prepare() } }
    }

    private func prepare() async {
        loading = true; defer { loading = false }
        guard let engine = await shop.vaultProductsEngine() else { problem = words.callIt("mac.vl_err_vault_off"); return }
        try? await engine.remote.sync.pull()
        let (sources, gone) = Shop.releaseSources(product.files, state: engine.remote.sync.load())
        lines = sources.compactMap { s in
            guard let v = s.row.headVersion?.version else { return nil }
            return (s.row.fileId, names[s.row.fileId] ?? s.row.fileId, v)
        }
        missing = gone
        // Files on sale before that are not in the listing now: taking them
        // out of the release is said, and the confirm button says it too.
        if let state = try? await engine.products.releaseState(product.productId) {
            dropping = state.items.map(\.fileId).filter { !product.files.contains($0) || gone.contains($0) }
        }
    }

    private func release() async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        working = true; problem = nil
        defer { working = false }
        guard let engine = await shop.vaultProductsEngine() else { problem = words.callIt("mac.vl_err_vault_off"); return }
        try? await engine.remote.sync.pull()
        let (sources, _) = Shop.releaseSources(product.files, state: engine.remote.sync.load())
        // Exactly what the sheet showed, or nothing. The feed is read again
        // here, and in between another device can upload a new version or
        // restore a file shown as missing — releasing either would make the
        // cloud able to read something the shop never confirmed (beta.6 review).
        let shown = Dictionary(uniqueKeysWithValues: lines.map { ($0.fileId, $0.version) })
        let now = Dictionary(uniqueKeysWithValues: sources.compactMap { s in
            s.row.headVersion.map { (s.row.fileId, $0.version) } })
        guard Shop.releaseMatches(shown: shown, now: now) else {
            await prepare()
            problem = words.callIt("mac.vp_release_changed")
            return
        }
        do {
            result = try await engine.products.release(product.productId, files: sources, unrelease: dropping)
        } catch {
            problem = shop.productProblem(error)
        }
    }
}

// MARK: - Buyers

struct VaultBuyersSheet: View {
    let shop: Shop
    let product: VaultProducts.Product
    let done: () -> Void

    @State private var buyers: [VaultProducts.Buyer] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var told: String?
    @State private var email = ""
    @State private var orderRef = ""
    @State private var note = ""
    @State private var working = false
    @State private var askingRevoke: VaultProducts.Buyer?
    private let preloaded: Bool

    private var words: Words { shop.words }

    /// `shown` draws these buyers without asking the cloud: for a photograph.
    init(shop: Shop, product: VaultProducts.Product, shown: [VaultProducts.Buyer]? = nil, done: @escaping () -> Void) {
        self.shop = shop; self.product = product; self.done = done
        preloaded = shown != nil
        _buyers = State(initialValue: shown ?? [])
        _loading = State(initialValue: shown == nil)
    }

    var body: some View {
        SheetFrame(width: 540) {
            Text(words.callIt("mac.vp_buyers_title")).font(.headline)
            if loading && buyers.isEmpty { ProgressView() }
            else if buyers.isEmpty { Text(words.callIt("mac.vp_no_buyers")).font(.callout).foregroundStyle(.secondary) }
            ForEach(buyers) { b in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: b.buyerEmail).environment(\.layoutDirection, .leftToRight)
                        Text(words.callIt("mac.vp_buyer_line", [
                            // Isolated, so a Latin name or order number does not
                            // turn an Arabic line around (beta.6 UI review).
                            "provider": .string("\u{2068}" + shop.providerName(b.provider) + "\u{2069}"),
                            "order": .string("\u{2068}" + b.orderId + "\u{2069}"), "used": .number(Double(b.used)),
                        ]))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(words.callIt("mac.vp_status_" + b.status, fallback: b.status)).font(.caption)
                        .foregroundStyle(b.status == "paid" ? Khayt.done : Role.text2)
                    if b.status == "paid" {
                        Button(words.callIt("mac.vl_revoke") + "\u{2026}", role: .destructive) { askingRevoke = b }
                            .controlSize(.small).disabled(!shop.canWrite)
                    }
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(words.callIt("mac.vp_add_buyer")).font(.subheadline.weight(.semibold))
                Text(words.callIt("mac.vp_add_buyer_hint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $email, prompt: Text(verbatim: "buyer@example.com")).textFieldStyle(.roundedBorder)
                    .environment(\.layoutDirection, .leftToRight)
                HStack {
                    TextField("", text: $orderRef, prompt: Text(words.callIt("mac.vp_order_ref"))).textFieldStyle(.roundedBorder)
                    TextField("", text: $note, prompt: Text(words.callIt("mac.vp_note"))).textFieldStyle(.roundedBorder)
                }
                Button(words.callIt("mac.vp_deliver")) { Task { await add() } }
                    .disabled(working || !VaultLinks.isEmail(email.trimmingCharacters(in: .whitespacesAndNewlines)) || !shop.canWrite)
            }
            if let told { Text(told).font(.callout).foregroundStyle(Khayt.done) }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack { Spacer(); Button(words.callIt("common.close")) { done() }.keyboardShortcut(.cancelAction) }
        }
        .task { if !preloaded { await load() } }
        .confirmationDialog(words.callIt("mac.vp_revoke_title"),
                            isPresented: Binding(get: { askingRevoke != nil }, set: { if !$0 { askingRevoke = nil } }),
                            presenting: askingRevoke) { b in
            Button(words.callIt("mac.vl_revoke"), role: .destructive) { Task { await revoke(b) } }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        } message: { _ in Text(words.callIt("mac.vp_revoke_body")) }
    }

    private func load() async {
        loading = true; defer { loading = false }
        guard let engine = await shop.vaultProductsEngine() else { problem = words.callIt("mac.vl_err_vault_off"); return }
        do { buyers = try await engine.products.buyers(product.productId) }
        catch { problem = shop.productProblem(error) }
    }

    private func add() async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        working = true; problem = nil; told = nil
        defer { working = false }
        guard let engine = await shop.vaultProductsEngine() else { return }
        do {
            let r = try await engine.products.addBuyer(product.productId, email: email,
                                                       orderRef: orderRef.isEmpty ? nil : orderRef,
                                                       note: note.isEmpty ? nil : note)
            told = words.callIt(r.duplicate == true ? "mac.vp_already_delivered" : "mac.vp_delivered")
            email = ""; orderRef = ""; note = ""
            await load()
        } catch {
            problem = shop.productProblem(error)
        }
    }

    private func revoke(_ b: VaultProducts.Buyer) async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        guard let engine = await shop.vaultProductsEngine() else { return }
        do { try await engine.products.revokeBuyer(product.productId, grantId: b.grantId); await load() }
        catch { problem = shop.productProblem(error) }
    }
}

// MARK: - Sales webhooks

/// Stripe, Lemon Squeezy and Gumroad tell Khayt Cloud about a sale, and the
/// buyer gets their link with no one at the Mac. The secret is pasted once
/// and never shown again; Gumroad's address carries its secret and is shown
/// only when it is made.
struct VaultSalesHooksBlock: View {
    let shop: Shop
    @Binding var hooks: [VaultProducts.SalesHook]
    @State private var provider = "stripe"
    @State private var secret = ""
    @State private var shownURL: String?
    @State private var working = false
    @State private var problem: String?

    private var words: Words { shop.words }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(words.callIt("mac.vp_hooks")).font(.subheadline.weight(.semibold))
            Text(words.callIt("mac.vp_hooks_hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(hooks, id: \.provider) { h in
                HStack {
                    Text(shop.providerName(h.provider))
                    if let u = h.url { copyable(u) } else { Text(words.callIt("mac.vp_hook_set")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(words.callIt("mac.wa_hook_remove"), role: .destructive) { Task { await remove(h.provider) } }
                        .controlSize(.small).disabled(working || !shop.canWrite)
                }
            }
            HStack {
                Picker("", selection: $provider) {
                    ForEach(VaultProducts.salesProviders, id: \.self) {
                        Text(shop.providerName($0)).tag($0)
                    }
                }
                .labelsHidden().fixedSize()
                SecureField(provider == "gumroad" ? words.callIt("mac.vp_hook_gumroad_ph") : words.callIt("mac.vp_hook_secret"),
                            text: $secret)
                    .textFieldStyle(.roundedBorder)
                Button(words.callIt("mac.vp_hook_save")) { Task { await save() } }
                    .disabled(working || !shop.canWrite || (provider != "gumroad" && secret.isEmpty))
            }
            if let shownURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text(words.callIt(provider == "gumroad" ? "mac.vp_hook_url_once" : "mac.vp_hook_url")).font(.caption)
                    copyable(shownURL)
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(Khayt.attention) }
        }
    }

    private func copyable(_ u: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: u).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) }
            label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(words.callIt("mac.ik_copy"))
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func save() async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        working = true; problem = nil; defer { working = false }
        guard let engine = await shop.vaultProductsEngine() else { return }
        do {
            shownURL = try await engine.products.setSalesHook(provider, secret: secret.isEmpty ? nil : secret)
            secret = ""
            hooks = (try? await engine.products.salesHooks()) ?? hooks
        } catch { problem = shop.productProblem(error) }
    }

    private func remove(_ p: String) async {
        guard shop.permitted("cloud", "edit") else { problem = shop.moveProblem; return }
        working = true; defer { working = false }
        guard let engine = await shop.vaultProductsEngine() else { return }
        do { try await engine.products.removeSalesHook(p); hooks.removeAll { $0.provider == p } }
        catch { problem = shop.productProblem(error) }
    }
}

