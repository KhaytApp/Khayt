import SwiftUI
import AppKit
import KhaytCore

/// The MakerRun tab of Maker Tools: browse the public catalogue, read a
/// design, and download a hosted file into the library.
///
/// The desktop's panel is `renderer/bedready-makerrun.js` (Bed Ready only
/// there); its words are borrowed whole (`mr.*`). Browsing needs no account,
/// as there. Downloading runs under this Mac's linked account.
///
/// ── HOW THIS MAC SIGNS IN ─────────────────────────────────────────────────
///
/// The desktop is handed its token by a `bedready://` link from
/// makerrun.com/app-link. This app does not claim that scheme: the Bed Ready
/// app owns it, and two apps registered for one scheme means the link lands
/// in whichever macOS picks. The same page shows a code to copy for exactly
/// the case where the link cannot open the app; the Mac takes that code and
/// exchanges it at once, so a wrong one is said now.
struct MakerRunBrowser: View {
    @Bindable var shop: Shop

    @State private var query = MakerRun.Query()
    @State private var typed = ""
    @State private var designs: [MakerRun.Design] = []
    @State private var page: MakerRun.Page?
    @State private var loading = false
    @State private var problem: String?
    @State private var selected: MakerRun.Design.ID?
    @State private var detail: MakerRun.DesignDetail?
    @State private var detailProblem: String?
    @State private var detailLoading = false
    @State private var covers: [String: NSImage] = [:]
    @State private var terms: KhaytEngine.MakerRunTerms?
    @State private var seq = 0

    var body: some View {
        let w = shop.words
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                MakerRunAccount(shop: shop)
                filters
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                results
                pager
            }
            .padding(12)
            .frame(minWidth: 380, idealWidth: 460)

            Group {
                if let id = selected, let design = designs.first(where: { $0.id == id }) {
                    MakerRunDesignPanel(shop: shop, summary: design, detail: detail,
                                        loading: detailLoading, problem: detailProblem,
                                        cover: design.cover.flatMap { covers[$0] })
                } else {
                    EmptyHere(title: w.callIt("mr.browse_title"), message: w.callIt("mac.mkr_choose"))
                }
            }
            .frame(minWidth: 340, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            terms = await shop.makerRunTerms()
            await load()
        }
        .onChange(of: selected) { _, id in Task { await openDetail(id) } }
    }

    private var filters: some View {
        let w = shop.words
        return VStack(alignment: .leading, spacing: 6) {
            TextField(w.callIt("mr.search_ph"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit { query.q = typed; refilter() }
            HStack(spacing: 8) {
                Picker(w.callIt("mr.category"), selection: Binding(get: { query.category },
                                                                  set: { query.category = $0; refilter() })) {
                    Text(w.callIt("mr.all_categories")).tag("")
                    ForEach(terms?.categories ?? [], id: \.value) { c in Text(c.label).tag(c.value) }
                }
                .labelsHidden()
                Picker(w.callIt("mr.material"), selection: Binding(get: { query.material },
                                                                  set: { query.material = $0; refilter() })) {
                    Text(w.callIt("mr.any_material")).tag("")
                    Text(w.callIt("mr.mat_rigid")).tag("rigid")
                    Text(w.callIt("mr.mat_flexible")).tag("flexible")
                    Text(w.callIt("mr.mat_multi")).tag("multi")
                }
                .labelsHidden()
            }
            HStack(spacing: 8) {
                Picker(w.callIt("mr.price"), selection: Binding(get: { query.forSale.map { $0 ? 1 : 2 } ?? 0 },
                                                               set: { v in query.forSale = v == 0 ? nil : v == 1; refilter() })) {
                    Text(w.callIt("mr.price_any")).tag(0)
                    Text(w.callIt("mr.price_free")).tag(2)
                    Text(w.callIt("mr.price_sale")).tag(1)
                }
                .labelsHidden()
                Toggle(w.callIt("mr.verified_only"), isOn: Binding(get: { query.verified },
                                                                   set: { query.verified = $0; refilter() }))
            }
            .controlSize(.small)
        }
    }

    private var results: some View {
        List(designs, selection: $selected) { d in
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                    if let url = d.cover, let image = covers[url] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 56, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .task(id: d.cover) { await loadCover(d.cover) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title).font(.callout).lineLimit(1)
                    Text(subtitle(d)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if d.verification.badge {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Khayt.done)
                        .help(shop.words.callIt("mr.verified"))
                }
            }
            .tag(d.id)
        }
        .overlay {
            if loading { ProgressView().controlSize(.small) }
            else if designs.isEmpty && problem == nil {
                Text(shop.words.callIt("mr.no_results")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ d: MakerRun.Design) -> String {
        let w = shop.words
        var bits: [String] = []
        if let c = d.creator, !c.isEmpty { bits.append(c) }
        if let cat = d.category, let label = terms?.categories.first(where: { $0.value == cat })?.label { bits.append(label) }
        if let sale = d.sale {
            bits.append(sale.price.map { w.callIt("mr.for_sale_price", ["price": .string(Words.plain(.number($0))),
                                                                       "currency": .string(sale.currency ?? "")]) }
                        ?? w.callIt("mr.for_sale"))
        } else {
            bits.append(w.callIt("mr.free"))
        }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder private var pager: some View {
        if let page, page.total > 0 {
            let w = shop.words
            HStack {
                Button(w.callIt("mr.prev")) { query.offset = max(0, query.offset - query.limit); Task { await load() } }
                    .disabled(query.offset == 0 || loading)
                Spacer()
                Text(w.callIt("mr.showing", ["from": .string(w.numeral(page.offset + 1)),
                                             "to": .string(w.numeral(page.offset + page.returned)),
                                             "total": .string(w.numeral(page.total))]))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(w.callIt("mr.next")) { query.offset += query.limit; Task { await load() } }
                    .disabled(page.offset + page.returned >= page.total || loading)
            }
            .controlSize(.small)
        }
    }

    private func refilter() {
        query.offset = 0
        selected = nil
        Task { await load() }
    }

    private func load() async {
        seq += 1
        let mine = seq
        loading = true
        problem = nil
        let q = query
        let result: Result<MakerRun.DesignList, Error>
        do { result = .success(try await shop.makerRun.listDesigns(q)) } catch { result = .failure(error) }
        // A newer search started while this one was in flight.
        guard mine == seq else { return }
        loading = false
        switch result {
        case .success(let list):
            designs = list.designs
            page = list.page
        case .failure(let error):
            designs = []
            page = nil
            problem = shop.saidMakerRun(error)
        }
    }

    private func openDetail(_ id: MakerRun.Design.ID?) async {
        detail = nil
        detailProblem = nil
        guard let id else { return }
        detailLoading = true
        defer { if selected == id { detailLoading = false } }
        do {
            let d = try await shop.makerRun.design(id)
            if selected == id { detail = d }
        } catch {
            if selected == id { detailProblem = shop.saidMakerRun(error) }
        }
    }

    private func loadCover(_ address: String?) async {
        guard let address, covers[address] == nil else { return }
        guard let data = try? await shop.makerRun.cover(address), let image = NSImage(data: data) else { return }
        covers[address] = image
    }
}

/// One design, in detail: its licence, verification, the files the library
/// can take, and its print profiles.
struct MakerRunDesignPanel: View {
    let shop: Shop
    let summary: MakerRun.Design
    let detail: MakerRun.DesignDetail?
    let loading: Bool
    let problem: String?
    let cover: NSImage?

    @State private var working: String?
    @State private var note: String?
    @State private var noteIsProblem = false
    @State private var addedId: String?
    @State private var commercial: Bool??

    var body: some View {
        let w = shop.words
        let d = detail?.design ?? summary
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let cover {
                    Image(nsImage: cover).resizable().aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    if d.coverAiGenerated {
                        Text(w.callIt("mac.mkr_cover_ai")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(d.title).font(.title3.weight(.semibold))
                if let c = d.creator, !c.isEmpty {
                    Text(w.callIt("mr.by_creator", ["name": .string(c)])).font(.caption).foregroundStyle(.secondary)
                }
                if d.nsfw {
                    Text(w.callIt("mr.nsfw_note")).font(.caption).foregroundStyle(Khayt.attention)
                }
                Text(w.callIt("mac.mkr_downloads", ["n": .string(w.numeral(Int(d.downloadCount)))]))
                    .font(.caption).foregroundStyle(.secondary)
                licence(d)
                verification(d.verification)
                if let sale = d.sale {
                    Text(sale.price.map { w.callIt("mr.for_sale_price", ["price": .string(Words.plain(.number($0))),
                                                                        "currency": .string(sale.currency ?? "")]) }
                         ?? w.callIt("mr.for_sale"))
                        .font(.callout)
                    Text(w.callIt("mr.sale_external")).font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView().controlSize(.small) }
                if let problem { Text(problem).font(.callout).foregroundStyle(Khayt.attention) }
                if let detail { files(detail) ; profiles(detail) }
                if !d.description.isEmpty {
                    DetailSection(w.callIt("mr.description")) {
                        Text(Self.shortened(d.description))
                            .font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note {
                    Text(note).font(.callout)
                        .foregroundStyle(noteIsProblem ? Khayt.attention : Khayt.done)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let addedId {
                        Button(w.callIt("mac.mkr_show_model")) { shop.showInLibrary(addedId) }
                    }
                    if let page = d.url.flatMap(URL.init(string:)) ?? MakerRun.pageURL(slug: d.slug) {
                        Button(w.callIt("mr.open_page")) { NSWorkspace.shared.open(page) }
                    }
                }
                .controlSize(.small)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: d.license) { commercial = try? await shop.engine?.commercialUse(d.license) }
        .onChange(of: summary.slug) { _, _ in note = nil; addedId = nil }
    }

    /// The description, cut at 1,500 characters as the desktop cuts it.
    static func shortened(_ text: String) -> String {
        text.count > 1500 ? String(text.prefix(1500)) + "\u{2026}" : text
    }

    private func licence(_ d: MakerRun.Design) -> some View {
        let w = shop.words
        let use = commercial ?? nil
        return DetailSection(w.callIt("mr.licence")) {
            Text(d.license ?? w.callIt("mr.licence_none")).font(.callout.weight(.semibold))
            Text(w.callIt(use == true ? "mr.lic_commercial" : use == false ? "mr.lic_noncommercial" : "mr.lic_check"))
                .font(.caption)
                .foregroundStyle(use == true ? Khayt.done : use == false ? Khayt.attention : Color.secondary)
        }
    }

    private func verification(_ v: MakerRun.Verification) -> some View {
        let w = shop.words
        return DetailSection(w.callIt("mr.verification")) {
            tick(v.badge, w.callIt("mr.v_badge"))
            tick(v.fileChecked, w.callIt("mr.v_file"))
            tick(v.printPhotoConfirmed, w.callIt("mr.v_photo"))
            if let p = v.printer, !p.name.isEmpty {
                Text(w.callIt("mr.v_printer", ["printer": .string(p.name)])).font(.caption)
            }
        }
    }

    private func tick(_ on: Bool, _ label: String) -> some View {
        Label(label, systemImage: on ? "checkmark" : "minus")
            .font(.caption)
            .foregroundStyle(on ? Khayt.done : Color.secondary)
    }

    /// The files — by `listingKind`, never by `external` or a missing link: a
    /// LINKED listing's file lives on another site, a PRINT listing sells the
    /// finished object, and only a HOSTED one's files come into the library.
    @ViewBuilder private func files(_ detail: MakerRun.DesignDetail) -> some View {
        let w = shop.words
        let d = detail.design
        DetailSection(w.callIt("mr.files")) {
            switch d.listingKind {
            case "linked":
                Text(w.callIt("mr.files_external")).font(.callout).foregroundStyle(.secondary)
            case "print":
                Text(w.callIt("mac.mkr_listing_print")).font(.callout).foregroundStyle(.secondary)
            default:
                let hosted = detail.downloadable
                if hosted.isEmpty {
                    Text(w.callIt("mr.files_none")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(hosted) { f in
                    HStack(spacing: 8) {
                        Text(f.filename).font(.callout).lineLimit(1).truncationMode(.middle)
                        if let size = f.sizeBytes {
                            Text(Format.bytes(size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if working == f.filename {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(d.license.map { w.callIt("mr.download_under", ["licence": .string($0)]) }
                                   ?? w.callIt("mr.download_no_licence")) {
                                Task { await download(d, f) }
                            }
                            .controlSize(.small)
                            .disabled(working != nil || !shop.canWrite)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func profiles(_ detail: MakerRun.DesignDetail) -> some View {
        let w = shop.words
        if !detail.profiles.isEmpty {
            DetailSection(w.callIt("mr.profiles")) {
                ForEach(Array(detail.profiles.enumerated()), id: \.offset) { _, p in
                    let colours = (p.colorCount ?? 0) > 1
                        ? w.callIt("mr.n_colours", ["n": .string(w.numeral(Int(p.colorCount ?? 0)))]) : ""
                    let bits = [[p.printerBrand, p.printerModel].compactMap { $0 }.joined(separator: " "),
                                p.filamentType ?? "", colours].filter { !$0.isEmpty }
                    HStack(spacing: 4) {
                        Text(bits.isEmpty ? w.callIt("mr.profile_unnamed") : bits.joined(separator: " · "))
                            .font(.caption)
                        if p.badge { Image(systemName: "checkmark").font(.caption).foregroundStyle(Khayt.done) }
                    }
                }
            }
        }
    }

    private func download(_ d: MakerRun.Design, _ f: MakerRun.File) async {
        let w = shop.words
        guard await shop.makerRun.isLinked() else {
            noteIsProblem = true
            note = w.callIt("mr.err_relink") + " " + w.callIt("mr.signin_download")
            return
        }
        working = f.filename
        noteIsProblem = false
        note = w.callIt("mr.downloading", ["name": .string(f.filename)])
        defer { working = nil }
        do {
            let id = try await shop.downloadFromMakerRun(d, file: f)
            addedId = id
            note = w.callIt("mr.added", ["name": .string(d.title)])
        } catch {
            noteIsProblem = true
            note = shop.saidMakerRun(error, downloading: true)
        }
    }
}

/// The linked account: connect with the code, or disconnect.
struct MakerRunAccount: View {
    let shop: Shop
    @State private var linked: Bool?
    @State private var code = ""
    @State private var linking = false
    @State private var problem: String?
    @State private var askUnlink = false

    var body: some View {
        let w = shop.words
        VStack(alignment: .leading, spacing: 6) {
            Text(w.callIt("mac.mkr_account")).font(.headline)
            if linked == true {
                HStack {
                    Label(w.callIt("mac.mkr_linked"), systemImage: "link").font(.callout)
                    Spacer()
                    Button(w.callIt("mac.mkr_unlink")) { askUnlink = true }.controlSize(.small)
                }
            } else if linked == false {
                Text(w.callIt("mac.mkr_not_linked")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(w.callIt("mac.mkr_code_hint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(w.callIt("mac.mkr_open_link_page")) { NSWorkspace.shared.open(MakerRun.signInURL()) }
                    SecureField(w.callIt("mac.mkr_code"), text: $code)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await link() } }
                    if linking { ProgressView().controlSize(.small) }
                    else {
                        Button(w.callIt("mac.mkr_link")) { Task { await link() } }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .controlSize(.small)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { linked = await shop.makerRun.isLinked() }
        .confirmationDialog(w.callIt("mac.mkr_unlink_q"), isPresented: $askUnlink) {
            Button(w.callIt("mac.mkr_unlink"), role: .destructive) {
                Task { await shop.makerRun.unlink(); linked = false }
            }
        } message: { Text(w.callIt("mac.mkr_unlink_body")) }
    }

    private func link() async {
        let typed = code
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        linking = true
        problem = nil
        defer { linking = false }
        do {
            try await shop.makerRun.link(code: typed)
            code = ""
            linked = true
        } catch {
            problem = shop.saidMakerRun(error)
            linked = await shop.makerRun.isLinked()
        }
    }
}
