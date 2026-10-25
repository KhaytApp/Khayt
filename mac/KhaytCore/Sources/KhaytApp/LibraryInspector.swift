import SwiftUI
import KhaytCore

/// The selected model, in detail.
///
/// ── ONE GLANCE, THEN THE DETAIL ───────────────────────────────────────────
///
/// It was one long undifferentiated scroll, about 1,600 points of it: the
/// header, an empty "Drop a photo here" box second from the top, the file,
/// the filament, the mesh, an estimate in grams and hours with no money in it,
/// and the Quote and Job buttons near the BOTTOM — hidden entirely when the
/// file was online only (library audit, Oct 2026). A shop opens a model to
/// decide whether to print it, quote it or sell it, and the answer was spread
/// over the whole column.
///
/// So the page opens on a SUMMARY CARD (`ModelSummaryCard`): the picture
/// (drop a photo on it to set it), the title, and the decision facts — time,
/// grams, cost to make, the catalogue price and margin, and which machines it
/// fits and is ready on — with Quote, New Job and Add to Catalogue right
/// there. Everything else follows in sections ordered by the task, each one
/// folding away and remembered (`InspectorSection`).
struct LibraryInspector: View {
    let shop: Shop
    @State private var setups: KhaytEngine.PrintSetups?
    @State private var versions: KhaytEngine.PrintVersions?
    @State private var parts: KhaytEngine.PrintParts?
    @State private var summary: ModelSummary?
    /// The model whose bought-licence proof is being edited.
    @State private var proofFor: LibraryFile?

    /// What the summary depends on: the record, and the catalogue it is
    /// priced against. A product saved or a rate changed moves the rows.
    private struct SummaryKey: Equatable {
        let file: LibraryFile
        let products: [KhaytEngine.CatalogueRow]
        let shelf: Int
        /// The shop's minimum margin, which colours the margin.
        let floor: Double?
    }

    var body: some View {
        if shop.selectedFiles.count > 1 {
            ManyModels(shop: shop)
        } else if let file = shop.selectedFile {
            ScrollViewReader { proxy in
                ScrollView { page(file) }
                    .onChange(of: shop.libraryInspectorScrollTo) { _, to in
                        if let to { proxy.scrollTo(to, anchor: .top) }
                    }
                    .onAppear {
                        if let to = shop.libraryInspectorScrollTo { proxy.scrollTo(to, anchor: .top) }
                    }
            }
            // Keyed on the file, not on the book: these are facts about one
            // record and nothing else on this screen moves them.
            .task(id: file.id) {
                setups = await shop.setups(for: file.id)
                versions = await shop.versions(for: file.id)
                parts = await shop.parts(for: file.id)
            }
            .task(id: SummaryKey(file: file, products: shop.catalogueRows, shelf: shop.consumableRows.count,
                                     floor: Shop.plainNumber(shop.settingsDict["minMarginPct"]))) {
                summary = await shop.modelSummary(for: file)
            }
            // The previous model's figures never stand under this one's title
            // while its own are worked out.
            .onChange(of: file.id) { _, _ in summary = nil }
        } else {
            EmptyHere(title: shop.words.callIt("mac.no_model"), message: shop.words.callIt("mac.no_model_hint"), mark: .library)
        }
    }

    /// The page itself, outside its scroll view so a snapshot can draw it:
    /// `ImageRenderer` draws nothing inside a `ScrollView`.
    @ViewBuilder func page(_ file: LibraryFile, summary given: ModelSummary? = nil) -> some View {
        let w = shop.words
        VStack(alignment: .leading, spacing: 18) {
            ModelSummaryCard(shop: shop, file: file, summary: given ?? summary)
                .id("model-title")
            // ── SAVED FROM A WEB PAGE ────────────────────────────────────
            if file.isFromWeb {
                InspectorSection(id: "web", title: w.callIt("mac.ws_sec_web"), symbol: "safari") {
                    WebSourceSection(shop: shop, file: file)
                }
            }
            // ── PRINT: what it takes and what can go wrong ───────────────
            InspectorSection(id: "print", title: w.callIt("mac.li_sec_print"), symbol: "printer") {
                if let sliced = slicedSection(file) { sliced }
                if !file.palette.isEmpty { filament(file) }
                // Only for something with a mesh to walk, and only while the
                // slicer has not answered both: beside a slice's own time and
                // weight a guess from the shape is a second, different number.
                if let estimate = shop.estimates[file.id], !Self.slicerSaidAnything(file) { priced(estimate) }
                if file.sourceFile?.kind == "model" { risk(file) }
                if let how = howItPrints(file) { how }
            }
            // ── THE FILE, AND WHERE ITS BYTES ARE ────────────────────────
            InspectorSection(id: "file", title: w.callIt("mac.li_sec_file"), symbol: "doc") {
                theFile(file)
                fileButtons(file)
                if shop.libraryHasRemote || shop.storageState(for: file) == .online {
                    StorageSection(shop: shop, file: file)
                        .id("model-storage")
                }
            }
            // ── THE SHAPE, AND WHICH BEDS IT GOES ON ─────────────────────
            if let mesh = file.mesh {
                InspectorSection(id: "shape", title: w.callIt("mac.li_sec_shape"), symbol: "cube") {
                    geometry(mesh, file)
                }
            }
            // ── WHAT IT IS MADE OF, AND HOW IT HAS BEEN MADE ─────────────
            // Parts only for a print that IS several files, versions only
            // where there is more than one: a heading over a list of one says
            // nothing.
            InspectorSection(id: "build", title: w.callIt("mac.li_sec_build"), symbol: "square.stack.3d.up") {
                if let parts, parts.multi { PartsSection(parts: parts, shop: shop) }
                if let versions, versions.many { VersionsSection(versions: versions, shop: shop) }
                if let setups, setups.total > 0 { SetupsSection(setups: setups, shop: shop) }
                ModelConsumablesSection(shop: shop, file: file)
            }
            // ── WHERE IT CAME FROM ───────────────────────────────────────
            if hasOrigin(file) {
                InspectorSection(id: "origin", title: w.callIt("mac.li_sec_origin"), symbol: "signature") {
                    provenance(file)
                    guides(file)
                }
            }
            if let notes = file.testedNotes, !notes.isEmpty {
                InspectorSection(id: "notes", title: w.callIt("mac.li_sec_notes"), symbol: "note.text") {
                    Text(notes).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !file.isArchived {
                InspectorSection(id: "archive", title: w.callIt("mac.li_sec_archive"), symbol: "archivebox",
                                 openByDefault: false) {
                    archiveButton(file)
                }
            }
        }
        .padding(16)
    }

    /// The slicer recorded both a time and a weight.
    static func fullySliced(_ file: LibraryFile) -> Bool {
        (file.parsed?.printTimeMins ?? 0) > 0 && (file.parsed?.filamentGrams ?? 0) > 0
    }

    /// The slicer — or the file's own per-colour weights — said a time or a
    /// weight. Then the summary card shows THOSE, and a guess from the shape
    /// beside them is a second, different answer for the same print (190.8 g
    /// · 5.34 hrs under a card saying 146 g · 6h 54m, review of #2056). The
    /// guess is shown only where nothing measured exists, and marked ≈.
    static func slicerSaidAnything(_ file: LibraryFile) -> Bool {
        (file.parsed?.printTimeMins ?? 0) > 0 || (file.parsed?.filamentGrams ?? 0) > 0
            || file.palette.contains { ($0.grams ?? 0) > 0 }
    }

    /// Provenance or guides to show. The section is absent otherwise — see
    /// `provenance` for why "not recorded" on four hundred models is worse.
    private func hasOrigin(_ file: LibraryFile) -> Bool {
        if let s = shop.licences[file.id], s.known || !s.source.isEmpty { return true }
        return !shop.guides(for: file).isEmpty
    }

    /// The file, reachable — Finder and the system's opener. The buttons that
    /// DECIDE something (quote, job, catalogue, Print next) are on the
    /// summary card; these are about the file itself. Print next was here
    /// too, as "Add to Print next", and moved up to the card: one mark, one
    /// place on the page.
    @ViewBuilder private func fileButtons(_ file: LibraryFile) -> some View {
        let url = shop.modelFile(for: file)
        FlowLayout(spacing: 8) {
            if let url {
                Button { FileActions.reveal(url) } label: {
                    Label(shop.words.callIt("mac.reveal"), systemImage: "folder")
                }
                Button { FileActions.open(url) } label: {
                    Label(shop.words.callIt("mac.open"), systemImage: "arrow.up.forward.app")
                }
            }
        }
        .controlSize(.small)
    }

    /// "Archive", on its own: it changes what the library offers, and does
    /// nothing to the file.
    private func archiveButton(_ file: LibraryFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shop.words.callIt("mac.archive_help"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { shop.archive([file.id]) } label: {
                Label(shop.words.callIt("mac.archive_model"), systemImage: "archivebox")
            }
            .controlSize(.small)
            .disabled(!shop.canWrite)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func theFile(_ file: LibraryFile) -> some View {
        DetailSection(shop.words.callIt("mac.file")) {
            if let original = file.sourceFile?.originalName ?? file.originalName {
                DetailLine(shop.words.callIt("mac.name"), original)
            }
            if let size = file.size { DetailLine(shop.words.callIt("set.store_size"), Format.bytes(size)) }
            if let material = file.material, !material.isEmpty {
                DetailLine(shop.words.callIt("plib.material"), material)
            }
            DetailLine(shop.words.callIt("mac.printed"), file.printCount == 0 ? shop.words.callIt("mac.never") : "\(file.printCount)×",
                       dim: file.printCount == 0)
            if let last = file.lastPrinted, let day = Order.day(last) {
                DetailLine(shop.words.callIt("mac.last_run"), shop.words.say(day, Date.FormatStyle(date: .abbreviated, time: .omitted)))
            }
            // Where the bytes are is worth stating plainly. "On this Mac" and
            // "in the records but not here" look identical in a grid, and only
            // one of them can be put on a printer this afternoon.
            // The FILE, not its folder (alpha.65 review, snapshot 42).
            if file.isWebOnly {
                // Saved from a page and not downloaded: nothing is missing.
                DetailLine(shop.words.callIt("mac.on_this_mac"), shop.words.callIt("mac.ws_not_downloaded"), dim: true)
            } else if shop.isInCloudOnly(file) {
                DetailLine(shop.words.callIt("mac.on_this_mac"), shop.words.callIt("mac.cloudlib_in_cloud"), dim: true)
            } else if shop.fileIsPresent(file) {
                DetailLine(shop.words.callIt("mac.on_this_mac"), "✓", dim: true)
            } else {
                DetailLine(shop.words.callIt("mac.on_this_mac"), shop.words.callIt("mac.li_not_here"), warn: true)
            }
        }
    }

    /// What the SLICER said: the whole project's time and weight, and — for a
    /// file sliced as several plates — each plate's own, with what it takes of
    /// each spool.
    ///
    /// A tester (Oct 2026): "I uploaded a multi plate 3mf and it only shows the
    /// filament data and time for one".
    func slicedSection(_ file: LibraryFile) -> AnyView? {
        let mins = file.parsed?.printTimeMins ?? 0, grams = file.parsed?.filamentGrams ?? 0
        guard mins > 0 || grams > 0 else { return nil }
        let plates = shop.plates(of: file)
        let w = shop.words
        func hours(_ m: Double) -> String { PrintFigures.duration(minutes: m, w) }
        func g(_ n: Double) -> String { PrintFigures.weight(n, w) }
        return AnyView(DetailSection(w.callIt(plates.isEmpty ? "mac.sliced_title" : "mac.sliced_project",
                                              ["plates": .string(w.counting(plates.count, "mac.n_plates"))])) {
            if mins > 0 { DetailLine(w.callIt("mac.est_time"), hours(mins), strong: true) }
            if grams > 0 { DetailLine(w.callIt("mac.est_filament"), g(grams), strong: true) }
            ForEach(plates, id: \.index) { plate in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plate.name.map { w.callIt("mac.plate_named", ["n": .number(Double(plate.index)), "name": .string($0)]) }
                             ?? w.callIt("mac.plate_n", ["n": .number(Double(plate.index))]))
                            .font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(hours(plate.minutes) + " · " + g(plate.grams))
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ForEach(Array(plate.filaments.enumerated()), id: \.offset) { _, f in
                        HStack(spacing: 6) {
                            Swatch(rgb: Swatch.rgb(fromHex: f.hex), size: 10)
                            Text(Self.slotLabel(f, words: w))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(g(f.grams)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.leading, 12)
                    }
                }
                .padding(.top, 4)
            }
        })
    }

    /// "Filament 2 · PLA": which spool slot it is AND what is in it.
    static func slotLabel(_ f: Shop.PlateFilament, words: Words) -> String {
        let slot: String = {
            if let n = Double(f.slot), n.isFinite, n >= 0, n < 1_000_000, n == n.rounded() {
                return words.callIt("mac.filament_n", ["n": .number(n)])
            }
            return f.slot.isEmpty ? "" : words.callIt("mac.filament_n", ["n": .string(f.slot)])
        }()
        switch (slot.isEmpty, f.material.isEmpty) {
        case (false, false): return slot + " · " + f.material
        case (false, true): return slot
        case (true, false): return f.material
        case (true, true): return words.callIt("mac.filament")
        }
    }

    /// The colours it needs and how many swaps. WHICH MACHINE it can start on
    /// is the summary card's line, from the one fit-aware rule — the per-
    /// machine "Ready to start" here sat under "Too big for every machine you
    /// have" and contradicted it.
    private func filament(_ file: LibraryFile) -> some View {
        DetailSection(shop.words.callIt("mac.filament")) {
            ForEach(Array(file.palette.enumerated()), id: \.offset) { i, colour in
                HStack(spacing: 8) {
                    Swatch(rgb: colour.rgb)
                    Text(colour.label ?? shop.words.callIt("mac.filament_n", ["n": .number(Double(i + 1))]))
                        .font(.callout)
                    Spacer(minLength: 8)
                    if let g = colour.grams {
                        Text(PrintFigures.weight(g, shop.words))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if file.swaps > 0 {
                DetailLine(shop.words.callIt("mac.swaps"), "\(file.swaps)", dim: true)
            }
        }
    }

    /// What the slicer was told to do with this model. Absent entirely for a
    /// model whose file says nothing — an STL, a 3MF a CAD program wrote.
    @ViewBuilder
    private func howItPrints(_ file: LibraryFile) -> (some View)? {
        let lines = Self.lines(from: shop.printFacts(for: file), words: shop.words)
        if !lines.isEmpty {
            DetailSection(shop.words.callIt("mac.how_it_prints")) {
                ForEach(lines, id: \.label) { line in
                    DetailLine(line.label, line.value, dim: line.dim)
                }
            }
        }
    }

    /// One line per thing the file actually said — the rule is in `KhaytCore`,
    /// because the Quick Look preview shows the same facts. See `PrintFactLines`.
    @MainActor
    static func lines(from facts: KhaytEngine.PrintFacts?,
                      words: Words) -> [PrintFactLines.Line] {
        PrintFactLines.lines(from: facts,
                             word: { words.callIt($0) },
                             counting: words.counting)
    }

    static func number(_ v: Double) -> String { PrintFactLines.number(v) }

    /// The papers that came with it — a creator pack's assembly instructions
    /// and colour guide. Absent when there are none.
    @ViewBuilder
    private func guides(_ file: LibraryFile) -> some View {
        let papers = shop.guides(for: file)
        if !papers.isEmpty {
            DetailSection(shop.words.callIt("mac.guides")) {
                ForEach(papers, id: \.self) { paper in
                    Button {
                        NSWorkspace.shared.open(paper)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(.secondary)
                            Text(paper.deletingPathExtension().lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(paper.lastPathComponent)
                }
            }
        }
    }

    /// Where it came from, and what may be done with it. Absent entirely for
    /// a model nobody has recorded a licence for: unknown is not "you may not
    /// sell this".
    @ViewBuilder
    private func provenance(_ file: LibraryFile) -> some View {
        if let standing = shop.licences[file.id], standing.known || !standing.source.isEmpty {
            DetailSection(shop.words.callIt("plib.provenance")) {
                if !standing.source.isEmpty {
                    DetailLine(shop.words.callIt("plib.source"), standing.source)
                }
                if standing.known {
                    // ONE ROW, in the licence's own name: every language spells
                    // the NonCommercial ones "… — not for sale".
                    DetailLine(shop.words.callIt("plib.licence"),
                               shop.words.callIt("plib.licence_"
                                                 + standing.licence.replacingOccurrences(of: "-", with: "_")),
                               warn: standing.sellable == false)
                }
                // ── A BOUGHT LICENCE, AND THE PROOF OF IT ─────────────────
                //
                // "Commercial" is only as good as the receipt; the last day it
                // covers turns amber once it has passed (`Shop.saleProblems`).
                if standing.licence == "commercial" {
                    if let until = file.licenceExpires, !until.isEmpty {
                        let lapsed = ModelLicence.expired(
                            .object(["licence": .string("commercial"), "licenceExpires": .string(until)]),
                            today: Shop.today())
                        DetailLine(shop.words.callIt(lapsed ? "mac.licence_lapsed" : "mac.licence_until"),
                                   until, warn: lapsed)
                    }
                    if let code = file.licenceCode, !code.isEmpty {
                        DetailLine(shop.words.callIt("mac.licence_code"), code)
                    }
                    if let link = file.licenceUrl, let url = URL(string: link) {
                        Link(shop.words.callIt("mac.licence_verify"), destination: url).font(.callout)
                    }
                    if shop.canMoveJobs {
                        Button(shop.words.callIt("mac.licence_proof") + "…") { proofFor = file }
                            .buttonStyle(.link).font(.callout)
                    }
                }
            }
            .shopSheet(item: $proofFor) { LicenceProofSheet(shop: shop, file: $0) }
        }
    }

    /// The box, the volume, and — machine by machine — whether it goes on
    /// the bed. The same rule as the summary card (`ModelReadiness`), so the
    /// two can never disagree; "Fits" used to name only the first machine it
    /// fitted, which could be the laser cutter.
    private func geometry(_ mesh: LibraryFile.Mesh, _ file: LibraryFile) -> some View {
        let w = shop.words
        let machines = shop.machineFits(for: file)
        return DetailSection(w.callIt("mac.mesh")) {
            DetailLine(w.callIt("set.store_size"), "\(Format.mm(mesh.x)) × \(Format.mm(mesh.y)) × \(Format.mm(mesh.z)) mm")
            if mesh.volumeMm3 > 0 {
                DetailLine(w.callIt("mac.li_volume"),
                           Money.quantity(mesh.volumeMm3 / 1000, decimals: 1) + " cm³", dim: true)
            }
            DetailLine(w.callIt("mac.triangles"), Format.count(mesh.triangles), dim: true)
            // Silent when nothing is known — a machine with no bed recorded
            // is not a machine that refuses the model.
            ForEach(machines) { m in
                let tooBig = m.state == .tooBig
                let turned = m.state == .readyTurned || m.state == .fitsTurned
                DetailLine(m.name,
                           w.callIt(tooBig ? "mac.li_state_too_big" : turned ? "mac.li_state_fits_turned" : "mac.li_state_fits"),
                           warn: tooBig)
            }
        }
    }

    /// What this model would take, before anybody slices it. WHERE THE RATE
    /// CAME FROM IS PART OF THE ANSWER: learned from this shop's own jobs and
    /// says how many, or Khayt's default and says so.
    @ViewBuilder private func priced(_ e: KhaytEngine.MeshEstimate) -> some View {
        DetailSection(shop.words.callIt("mac.est_title")) {
            DetailLine(shop.words.callIt("mac.est_filament"),
                       "\u{2248}\u{2009}" + PrintFigures.weight(e.grams, shop.words))
            DetailLine(shop.words.callIt("mac.est_time"),
                       "\u{2248}\u{2009}" + PrintFigures.duration(hours: e.hours, shop.words))
            if e.isCalibrated, let n = e.jobs, let rate = e.gramsPerHour {
                Text(shop.words.callIt("mac.est_learned",
                                       ["jobs": .number(Double(n)),
                                        "rate": .string(Money.figure(rate))]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(shop.words.callIt("mac.est_default"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The rule is explicit that a caller showing this number must check
            // `reliable` and say so.
            if e.shellUnreliable {
                Text(shop.words.callIt("mac.est_thin_walled"))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What is likely to go wrong with this print.
    ///
    /// THREE STATES, and the third one is the reason this is not just a list:
    /// "not looked yet" is a different answer from "nothing to worry about".
    ///
    /// It read "Before you quote: not found" for a model whose file is not on
    /// this Mac — two cryptic words for "I cannot look, and here is why". It
    /// now says what is missing and what to do about it.
    @ViewBuilder private func risk(_ file: LibraryFile) -> some View {
        DetailSection(shop.words.callIt("mac.li_risk_title")) {
            if shop.riskRunning.contains(file.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(shop.words.callIt("risk.looking")).foregroundStyle(.secondary)
                }
            } else if let report = shop.risks[file.id] {
                if report.note.isEmpty {
                    Text(shop.words.callIt("risk.clear"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        // `risk.head` is the other app's own heading for these
                        // lines; this section has one already.
                        ForEach(Array(report.note.enumerated()), id: \.offset) { _, line in
                            if line.key != "risk.head" {
                                Text(shop.words.callIt(line.key, line.vars ?? [:]))
                                    .font(line.strong == true ? .callout.weight(.medium) : .callout)
                                    .foregroundStyle(line.strong == true ? .primary : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else if shop.modelFile(for: file) == nil {
                // The record is here and the file is not. Nothing to walk,
                // and a button that cannot work is worse than saying so —
                // but say WHAT is missing and what to do.
                Text(shop.words.callIt(shop.isInCloudOnly(file) ? "mac.li_risk_online" : "mac.li_risk_no_file"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shop.words.callIt("risk.not_looked"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await shop.analyseRisk(file) }
                    } label: {
                        Label(shop.words.callIt("risk.look"), systemImage: "eye")
                    }
                    .controlSize(.small)
                }
            }
            if let problem = shop.riskProblem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
            }
        }
    }
}

/// One section of the model page: a heading that folds it away, and the
/// detail under it.
///
/// Folded or open is remembered PER SECTION in the user defaults, not per
/// model: a shop that never reads provenance folds it once, and it stays
/// folded on every model after.
struct InspectorSection<Content: View>: View {
    let id: String
    let title: String
    let symbol: String
    @AppStorage private var open: Bool
    @ViewBuilder let content: Content

    nonisolated static func defaultsKey(_ id: String) -> String { "libraryInspector.open." + id }

    init(id: String, title: String, symbol: String, openByDefault: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.id = id; self.title = title; self.symbol = symbol
        _open = AppStorage(wrappedValue: openByDefault, Self.defaultsKey(id))
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    // Forward when folded — mirrors itself in Arabic — and
                    // down when open, in both.
                    Image(systemName: open ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            if open {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.leading, 26)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { LayerRule() }
    }
}

/// The top of the model page: what it is, and whether to print, quote or sell
/// it — in one glance, with the buttons that act on the answer.
///
/// ── THE PHOTO IS DROPPED ON THE PICTURE ───────────────────────────────────
///
/// A separate "Drop a photo here" box sat second from the top, empty on
/// nearly every model, pushing the facts down by a third of the column. The
/// picture IS the place a photo goes (`Shop.thumbnail(for:)` already prefers
/// one), so a picture dropped on it sets it, and the small menu on its corner
/// chooses, replaces or removes one.
///
/// ── THE BUTTONS ARE ALWAYS THERE ──────────────────────────────────────────
///
/// Quote and Job were hidden entirely when the file was online only, so a
/// model moved off to save space read as one that could not be quoted. A
/// quote, a job and a product are priced from the record's figures, not the
/// file — they work either way, and the line above them says what the file
/// itself is needed for and offers to fetch it.
struct ModelSummaryCard: View {
    let shop: Shop
    let file: LibraryFile
    let summary: ModelSummary?
    @State private var dropTarget = false

    private var w: Words { shop.words }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            picture
            titleBlock
            facts
            catalogueLine
            whereItPrints
            availability
            actions
            PrintNextRow(shop: shop, file: file)
        }
    }

    // MARK: Picture

    private var picture: some View {
        // A fixed height, not an aspect ratio: `Thumbnail` has no size of its
        // own, and a 1:1 fit inside a vertical ScrollView drew nothing.
        Thumbnail(source: shop.thumbnail(for: file))
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(dropTarget ? Khayt.brand : .clear,
                                  style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
            .overlay(alignment: .bottom) {
                if dropTarget {
                    Text(w.callIt("mac.li_drop_photo"))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .overlay(alignment: .topTrailing) { photoMenu.padding(8) }
            .dropDestination(for: URL.self) { urls, _ in
                guard shop.canMoveJobs, let url = urls.first else { return false }
                shop.setLibraryPhoto(file.id, from: url)
                return true
            } isTargeted: { dropTarget = $0 }
            .help(w.callIt("mac.li_photo_help"))
    }

    private var photoMenu: some View {
        let has = LibraryPhoto.has(file)
        return Menu {
            Button(w.callIt(has ? "mac.lp_replace" : "mac.lp_add") + "\u{2026}") {
                shop.chooseLibraryPhoto(for: file.id)
            }
            if has {
                Button(w.callIt("mac.lp_remove")) { shop.clearLibraryPhoto(file.id) }
            }
        } label: {
            Image(systemName: has ? "photo.fill" : "camera")
                .font(.callout)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!shop.canMoveJobs)
        .help(w.callIt(has ? "mac.lp_replace" : "mac.lp_add"))
        .accessibilityLabel(w.callIt(has ? "mac.lp_replace" : "mac.lp_add"))
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // A control only when it would do something.
                if shop.canWrite {
                    Button {
                        shop.toggleFavourite(file)
                    } label: {
                        Image(systemName: file.isFavourite ? "star.fill" : "star")
                            .foregroundStyle(file.isFavourite ? AnyShapeStyle(Khayt.marked)
                                                             : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .help(shop.words.callIt(file.isFavourite ? "mac.unmake_favourite" : "mac.make_favourite"))
                    .accessibilityLabel(shop.words.callIt(file.isFavourite ? "mac.unmake_favourite" : "mac.make_favourite"))
                } else if file.isFavourite {
                    Image(systemName: "star.fill").foregroundStyle(Khayt.marked)
                }
                ModelTitle(shop: shop, file: file)
            }
            // What it is filed as, on one quiet line: the set, what it IS,
            // and its tags.
            if let meta = metaLine {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            // PUT ASIDE, and said so where the eye is, with the way back.
            if file.isArchived { archivedNote }
            if let problem = shop.writeProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Khayt.attention)
                    .textSelection(.enabled)
            }
            creatorAndCopies(file)
        }
    }

    private var metaLine: String? {
        var bits: [String] = []
        if let group = file.groupName, !group.isEmpty { bits.append(Shop.groupLeaf(group)) }
        if let category = file.category, !category.isEmpty { bits.append(category) }
        if let tags = file.tags, !tags.isEmpty { bits.append(tags.prefix(4).map { "#" + $0 }.joined(separator: " ")) }
        return bits.isEmpty ? nil : bits.map(Figure.isolated).joined(separator: " · ")
    }

    private var archivedNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(archivedSentence, systemImage: "archivebox")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { shop.unarchive([file.id]) } label: {
                Label(shop.words.callIt("mac.unarchive_model"), systemImage: "arrow.uturn.backward")
            }
            .controlSize(.small)
            .disabled(!shop.canWrite)
        }
    }

    private var archivedSentence: String {
        // In the book's calendar (`Words.say`), never `Calendar.current`.
        guard let when = Calendar.instant(file.archivedAt ?? "") else {
            return shop.words.callIt("mac.archived_undated")
        }
        let day = shop.words.say(when, .dateTime.day().month(.abbreviated).year())
        return shop.words.callIt("mac.archived_on", ["date": .string(day)])
    }

    /// Who made it, as a way to the rest of their models; and the copies of
    /// it the library holds, each a way to it.
    @ViewBuilder private func creatorAndCopies(_ file: LibraryFile) -> some View {
        if file.isLinked, let path = file.externalPath {
            Label(shop.words.callIt("mac.linked_where",
                                    ["path": .string(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)]),
                  systemImage: "link")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        if let creator = file.creator {
            Button {
                shop.libraryCreator = creator
                shop.shelf = .library(nil)
            } label: {
                Label(shop.words.callIt("mac.by_creator", ["name": .string(creator)]), systemImage: "person")
            }
            .buttonStyle(.link)
            .font(.callout)
            .help(shop.words.callIt("mac.creator_show_all"))
        }
        let copies = shop.duplicates(of: file)
        if !copies.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(shop.words.callIt("mac.duplicate_of", ["n": .number(Double(copies.count))]),
                      systemImage: "square.on.square")
                    .font(.callout.weight(.medium)).foregroundStyle(Khayt.attention)
                ForEach(copies) { copy in
                    Button(copy.title) { shop.select(copy, modifiers: .replace) }
                        .buttonStyle(.link).lineLimit(1)
                }
            }
        }
    }

    // MARK: The decision facts

    /// Time and grams: the summary's (the catalogue's own figures), else what
    /// the record says on its own while that is worked out.
    private var hours: Double? {
        if let h = summary?.hours { return h }
        if let m = file.parsed?.printTimeMins, m > 0 { return m / 60 }
        return shop.estimates[file.id].map(\.hours).flatMap { $0 > 0 ? $0 : nil }
    }

    private var grams: Double? {
        if let g = summary?.grams { return g }
        if let g = file.parsed?.filamentGrams, g > 0 { return g }
        return shop.estimates[file.id].map(\.grams).flatMap { $0 > 0 ? $0 : nil }
    }

    private var estimated: Bool {
        if let summary { return summary.estimated }
        return (file.parsed?.printTimeMins ?? 0) <= 0 || (file.parsed?.filamentGrams ?? 0) <= 0
    }

    private var facts: some View {
        let none = "\u{2014}"
        return VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 0) {
                GridRow {
                    fact(w.callIt("mac.li_print_time"),
                         hours.map { PrintFigures.duration(hours: $0, w) } ?? none,
                         unit: nil, approximate: estimated && hours != nil)
                    fact(w.callIt("mac.li_filament"),
                         grams.map { PrintFigures.weight($0, w) } ?? none,
                         unit: nil, approximate: estimated && grams != nil)
                    fact(w.callIt("mac.li_cost"),
                         summary?.cost.map { Money.figure($0) } ?? none,
                         unit: summary?.cost == nil ? nil : Money.mark(shop.currency))
                }
            }
            if hours == nil && grams == nil {
                Text(w.callIt("mac.li_no_figures"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if estimated {
                Text(w.callIt("mac.li_estimated_note"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `approximate` draws ≈ as its own leading mark — beside the number in
    /// both directions, never stranded after it in Arabic.
    private func fact(_ label: String, _ value: String, unit: String?, approximate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if approximate {
                    Text(verbatim: "\u{2248}").font(.callout).foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Khayt.recessed, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    /// The catalogue product this model is sold as, its price and margin — the
    /// margin coloured only when it is under the floor the shop set.
    @ViewBuilder private var catalogueLine: some View {
        if let product = summary?.product {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "tag").foregroundStyle(.secondary).font(.callout)
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        Task { shop.editingProduct = await shop.productForEditing(product.id) }
                    } label: {
                        Text(w.callIt("mac.li_sells_as", ["name": .string(product.name)]))
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help(w.callIt("mac.li_open_product"))
                    HStack(spacing: 6) {
                        Text(Money.text(product.price, shop.currency))
                            .font(.callout.weight(.semibold)).monospacedDigit()
                        if let margin = product.margin {
                            Text(verbatim: "·").foregroundStyle(.tertiary)
                            Text(w.callIt("mac.li_margin_pct", ["pct": .string(Money.quantity(margin * 100, decimals: 0))]))
                                .font(.callout).monospacedDigit()
                                .foregroundStyle(product.belowFloor || margin < 0 ? AnyShapeStyle(Khayt.late)
                                                                                  : AnyShapeStyle(.secondary))
                        }
                    }
                    if product.belowFloor, let floor = Shop.plainNumber(shop.settingsDict["minMarginPct"]) {
                        Text(w.callIt("mac.li_margin_below", ["min": .string(Money.quantity(floor, decimals: 0))]))
                            .font(.caption).foregroundStyle(Khayt.late)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if summary != nil {
            Label(w.callIt("mac.li_not_in_catalogue"), systemImage: "tag")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Which machines it goes on and can start on now — fit AND spools, the
    /// one rule (`ModelReadiness`), so this line and the Shape section never
    /// disagree the way "Too big for every machine" over "Ready to start" did.
    @ViewBuilder private var whereItPrints: some View {
        let machines = shop.machineFits(for: file)
        if !machines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(w.callIt("mac.li_where"))
                    .font(.caption).foregroundStyle(.secondary)
                if machines.allSatisfy({ $0.state == .tooBig }) {
                    Label(w.callIt("mac.li_too_big_all"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.callout).foregroundStyle(Khayt.late)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(machines) { m in machineChip(m) }
                    }
                }
            }
        }
    }

    private func machineChip(_ m: ModelSummary.MachineFit) -> some View {
        let (word, colour, mark) = Self.chip(m.state)
        return HStack(spacing: 4) {
            Image(systemName: mark).font(.caption2.weight(.bold)).foregroundStyle(colour)
            Text(Figure.isolated(m.name)).font(.caption.weight(.medium))
            Text(w.callIt(word)).font(.caption).foregroundStyle(colour == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(colour))
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Khayt.recessed, in: RoundedRectangle(cornerRadius: Radius.chip))
        .accessibilityElement(children: .combine)
    }

    static func chip(_ state: ModelReadiness.State) -> (String, Color, String) {
        switch state {
        case .ready: ("mac.li_state_ready", Khayt.done, "checkmark")
        case .readyTurned: ("mac.li_state_ready_turned", Khayt.done, "checkmark")
        case .needsSwap: ("mac.li_state_needs_swap", .secondary, "arrow.triangle.2.circlepath")
        case .fits: ("mac.li_state_fits", .secondary, "checkmark")
        case .fitsTurned: ("mac.li_state_fits_turned", .secondary, "rotate.right")
        case .tooBig: ("mac.li_state_too_big", Khayt.late, "xmark")
        }
    }

    /// Where the file is, when it is not here — said once, with the way to
    /// get it, beside the buttons that do not need it.
    @ViewBuilder private var availability: some View {
        if shop.isInCloudOnly(file) {
            VStack(alignment: .leading, spacing: 6) {
                Label(w.callIt("mac.li_online_only"), systemImage: "icloud")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { Task { await shop.bringBack(file) } } label: {
                        Label(shop.words.callIt(file.isLinked ? "mac.linked_download" : "mac.cloudlib_bring_back"),
                              systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(shop.cloudLibraryBusy)
                    if shop.cloudLibraryBusy { ProgressView().controlSize(.small) }
                }
                .controlSize(.small)
                if let problem = shop.cloudLibraryProblem {
                    Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if !shop.fileIsPresent(file) {
            Label(w.callIt("mac.li_missing_file"), systemImage: "questionmark.folder")
                .font(.caption).foregroundStyle(Khayt.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    /// Quote, New Job, Add to Catalogue — always, whatever the file's state.
    /// Side by side when they fit; Add to Catalogue under the other two in a
    /// narrow column or in Arabic.
    private var actions: some View {
        let quote = Button { Task { await shop.startJob(fromModels: [file], asQuote: true) } } label: {
            Label(w.callIt("mac.li_quote"), systemImage: "doc.text")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!shop.canMoveJobs)
        let job = Button { Task { await shop.startJob(fromModels: [file], asQuote: false) } } label: {
            Label(w.callIt("mac.li_new_job"), systemImage: "hammer")
        }
        .disabled(!shop.canMoveJobs)
        // The door to the catalogue, where it can be seen — it lived only in
        // a right-click menu, and a shop went looking for it.
        let catalogue = Button { Task { await shop.editingProduct = shop.productFromFile(file) } } label: {
            Label(w.callIt("mac.li_add_catalogue"), systemImage: "tag")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { quote; job; catalogue }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { quote; job }
                catalogue
            }
        }
        .controlSize(.regular)
    }
}

/// The settings this print is known to work at.
///
/// A file counted how many times it printed and how many times it failed, but
/// not WITH WHAT — so a shop reprinting a bracket six months later knew it
/// worked once and had no idea on which machine, in which material, at which
/// layer height. Which is the same as not knowing.
struct SetupsSection: View {
    let setups: KhaytEngine.PrintSetups
    let shop: Shop

    var body: some View {
        DetailSection(shop.words.callIt("setup.title")) {
            VStack(alignment: .leading, spacing: 8) {
                // What to reach for, said once and at the top. With every setup
                // failing this says so instead: "change something" is the
                // answer, and naming the least broken one wastes a spool.
                if let best = setups.setups.first(where: { $0.id == setups.recommendedId }) {
                    Row(setup: best, shop: shop, recommended: true)
                } else {
                    Text(shop.words.callIt("setup.none_good"))
                        .font(.callout).foregroundStyle(Khayt.late)
                }
                ForEach(setups.setups.filter { $0.id != setups.recommendedId }) {
                    Row(setup: $0, shop: shop, recommended: false)
                }
            }
        }
    }

    // NO ACCENT ON THE HEADING. It was tinted red when nothing had worked, and
    // `DetailSection` is explicit that a tinted header over an already-coloured
    // line is one signal said twice. The red sentence is the signal; a red
    // heading above it only costs the colour its meaning elsewhere.

    private struct Row: View {
        let setup: KhaytEngine.PrintSetups.Setup
        let shop: Shop
        let recommended: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(setup.name.isEmpty ? shop.words.callIt("mac.unnamed") : setup.name)
                            .font(.callout)
                            .foregroundStyle(setup.name.isEmpty ? AnyShapeStyle(.secondary)
                                                                : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        if recommended {
                            Image(systemName: "star.fill")
                                .font(.caption2).foregroundStyle(Khayt.done)
                        }
                    }
                    if let line { Text(line).font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(shop.words.callIt(Self.word(setup.status)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.colour(setup.status))
                    Text(tally).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        }

        /// The module composes this sentence in English. This app is read in
        /// Arabic too, so the line is built here from the fields against the
        /// locale — the VERDICT still comes from the rule, because that is a
        /// rule and this is only a caption.
        private var line: String? {
            var bits: [String] = []
            // Label first, so the line reads the same way round in Arabic as
            // in English. There is no short unit word for either in the
            // locales, and inventing two would mean nine translations.
            if let mm = setup.layerHeightMm {
                bits.append("\(shop.words.callIt("conv.src_layer")) \(mm.formatted(.number.precision(.fractionLength(0...2)).locale(shop.words.locale)))")
            }
            if let mm = setup.nozzleMm {
                bits.append("\(shop.words.callIt("conv.src_nozzle")) \(mm.formatted(.number.precision(.fractionLength(0...2)).locale(shop.words.locale)))")
            }
            let stuff = [setup.material, setup.colour].compactMap { $0 }.joined(separator: " ")
            if !stuff.isEmpty { bits.append(stuff) }
            if let machine = setup.machineName, !machine.isEmpty { bits.append(machine) }
            return bits.isEmpty ? nil : bits.joined(separator: " · ")
        }

        /// Never printed is not a score of nought. It is "nobody has tried
        /// this", and drawing it as 0/0 reads as a failure.
        private var tally: String {
            setup.ok == 0 && setup.failed == 0
                ? shop.words.callIt("setup.untried")
                : "\(setup.ok) / \(setup.ok + setup.failed)"
        }

        static func word(_ status: String) -> String {
            switch status {
            case "known-good": "setup.known_good"
            case "failed":     "setup.failed"
            default:           "setup.needs_test"
            }
        }

        static func colour(_ status: String) -> Color {
            switch status {
            case "known-good": Khayt.done
            case "failed":     Khayt.late
            default:           .secondary
            }
        }
    }
}

/// The alternatives this print exists as — big, small, coloured.
///
/// Not parts and not a group: parts print TOGETHER, a group is kept WITH each
/// other, and versions print INSTEAD OF each other. What makes one worth
/// listing is that it has its own time and weight, so a shop quoting off the
/// wrong one is wrong about the price.
struct VersionsSection: View {
    let versions: KhaytEngine.PrintVersions
    let shop: Shop

    var body: some View {
        DetailSection(shop.words.callIt("plib.versions")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(versions.versions) { version in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if version.id == versions.activeId {
                            Image(systemName: "largecircle.fill.circle")
                                .font(.caption2).foregroundStyle(Khayt.brand)
                        } else {
                            Image(systemName: "circle")
                                .font(.caption2).foregroundStyle(.quaternary)
                        }
                        Text(version.name.isEmpty ? shop.words.callIt("mac.unnamed") : version.name)
                            .font(.callout).lineLimit(1)
                            .foregroundStyle(version.name.isEmpty ? AnyShapeStyle(.secondary)
                                                                  : AnyShapeStyle(.primary))
                        Spacer(minLength: 6)
                        // Its own weight and time, which is the whole reason a
                        // version is modelled rather than filed as a second print.
                        if let text = size(version) {
                            Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func size(_ v: KhaytEngine.PrintVersions.Version) -> String? {
        var bits: [String] = []
        // The page's one format for both (`PrintFigures`).
        if let g = v.grams { bits.append(PrintFigures.weight(g, shop.words)) }
        if let h = v.hours { bits.append(PrintFigures.duration(hours: h, shop.words)) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}


/// The files this print is made of.
///
/// A head, two arms and a torso are ONE thing you print, not four. The Mac app
/// modelled a record as exactly one file, so a kit downloaded as ten STLs read
/// as a single entry with nine files quietly missing from it.
struct PartsSection: View {
    let parts: KhaytEngine.PrintParts
    let shop: Shop

    var body: some View {
        DetailSection(shop.words.callIt("mac.parts")) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(parts.parts) { part in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(part.filename).font(.callout).lineLimit(1).truncationMode(.middle)
                        // The one the card speaks for: its icon, its thumbnail,
                        // what "Open in slicer" resolves to.
                        if part.filename == parts.primary {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8)).foregroundStyle(Khayt.brand)
                                // A star with no explanation is decoration.
                                .help(shop.words.callIt("plib.part_primary"))
                        }
                        Spacer(minLength: 6)
                        // An unmeasured part says so. Left blank it reads as a
                        // gap in the layout, and the missing Total below has no
                        // visible cause — which is the one thing a reader has
                        // to be able to work out from this list.
                        Text(part.size.map(Self.bytes) ?? "—")
                            .font(.caption)
                            .foregroundStyle(part.size == nil ? AnyShapeStyle(.tertiary)
                                                              : AnyShapeStyle(.secondary))
                            .monospacedDigit()
                    }
                }
                // Only where every part could be measured. A total that
                // silently skips the parts it could not measure is a smaller
                // number presented as a complete one.
                if let total = parts.totalSize {
                    Divider().padding(.vertical, 1)
                    HStack {
                        Text(shop.words.callIt("common.total")).font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.bytes(total)).font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    static func bytes(_ v: Double) -> String {
        Format.fileSize(Int64(v))
    }
}

/// The model's title, and the field that renames it.
///
/// One field for every way in — the pencil here, the right-click menu, Model ▸
/// Rename — through `Shop.renamingFileId`. Return saves, Escape or clicking
/// away leaves the title as it was: a rename half-typed when the shop clicks
/// another model must not land on the model it was typed for.
private struct ModelTitle: View {
    let shop: Shop
    let file: LibraryFile
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var editing: Bool { shop.renamingFileId == file.id }

    var body: some View {
        Group {
            if editing {
                TextField(shop.words.callIt("mac.rename_model"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.weight(.semibold))
                    .focused($focused)
                    .onSubmit { save() }
                    .onExitCommand { shop.renamingFileId = nil }
                    .onChange(of: focused) { _, now in if !now { shop.renamingFileId = nil } }
                    .onAppear {
                        draft = file.name.isEmpty ? file.title : file.name
                        focused = true
                    }
                    .accessibilityLabel(shop.words.callIt("mac.rename_model"))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(file.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    if shop.canWrite {
                        Button { shop.renamingFileId = file.id } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(shop.words.callIt("mac.rename_model"))
                        .accessibilityLabel(shop.words.callIt("mac.rename_model"))
                    }
                }
            }
        }
        // Another model chosen while the field is open closes it.
        .onChange(of: file.id) { _, _ in shop.renamingFileId = nil }
    }

    private func save() {
        shop.rename(file.id, to: draft)
        shop.renamingFileId = nil
    }
}

/// Where this model's bytes are, and the two things a shop can do about it
/// for this model alone: free its space now, or keep it here for good.
///
/// Free up space is the verified path the whole-library pass takes
/// (`Shop.moveOut`): the copy online is asked for again and checked before the
/// file here goes. Keep on this Mac brings a model back first when it is
/// online only, and from then on Free up space leaves it alone.
private struct StorageSection: View {
    let shop: Shop
    let file: LibraryFile

    var body: some View {
        let state = shop.storageState(for: file) ?? (shop.isInCloudOnly(file) ? .online : .local)
        let kept = shop.isKeptOnThisMac(file)
        DetailSection(shop.words.callIt("mac.storage_section")) {
            VStack(alignment: .leading, spacing: 8) {
                Label(shop.words.callIt(Shop.storageWordKey(state)), systemImage: Shop.storageSymbol(state))
                    .font(.callout)
                HStack(spacing: 8) {
                    // A vault model on this Mac, with somewhere to go.
                    if !file.isLinked, state != .online, shop.libraryHasRemote {
                        Button { Task { await shop.freeUpSpace(model: file) } } label: {
                            Label(shop.words.callIt("mac.storage_free_one"), systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(kept || shop.cloudLibraryBusy || !shop.canWrite)
                        .help(shop.words.callIt(kept ? "mac.storage_free_kept" : "mac.storage_free_one_help"))
                    }
                    Toggle(shop.words.callIt("mac.storage_keep"), isOn: Binding(
                        get: { kept },
                        set: { on in Task { await shop.keepOnThisMac(file, on) } }))
                        .toggleStyle(.checkbox)
                        .disabled(shop.cloudLibraryBusy || shop.syncIndex == nil)
                        .help(shop.words.callIt("mac.storage_keep_help"))
                    if shop.cloudLibraryBusy { ProgressView().controlSize(.small) }
                }
                .controlSize(.small)
                if let note = shop.cloudLibraryNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // An open job needs it: asked, as the whole-library pass never moves
        // such a model at all.
        .confirmationDialog(
            shop.words.callIt("mac.storage_free_in_use_q"),
            isPresented: Binding(get: { shop.pendingFreeUp?.id == file.id },
                                 set: { if !$0 { shop.pendingFreeUp = nil } }),
            titleVisibility: .visible
        ) {
            Button(shop.words.callIt("mac.storage_free_anyway")) {
                shop.pendingFreeUp = nil
                Task { await shop.freeUpSpace(model: file, anyway: true) }
            }
            Button(shop.words.callIt("common.cancel"), role: .cancel) { shop.pendingFreeUp = nil }
        } message: {
            Text(shop.words.callIt("mac.storage_free_in_use"))
        }
    }
}

/// ── PRINT NEXT, ON THE CARD ──────────────────────────────────────────────
///
/// The mark that says "I mean to print this" — Printventory's Want, which is
/// the one state of theirs Khayt did not already know (a job is Queued and
/// Printing, `timesPrinted` is Printed). Toggled here, from the right-click
/// menu, the multi-select pane and Model ▸ Print Next (⌘B); a note says who
/// or what it is for. Starting a JOB from the model takes it off the list
/// (`Shop.clearPrintNext`); a quote leaves it.
struct PrintNextRow: View {
    let shop: Shop
    let file: LibraryFile
    @State private var typed = ""
    @FocusState private var editing: Bool

    private var w: Words { shop.words }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { shop.setPrintNext([file.id], on: !file.isPrintNext) } label: {
                Label(w.callIt(file.isPrintNext ? "mac.print_next_remove" : "mac.print_next_add"),
                      systemImage: file.isPrintNext ? "bookmark.fill" : "bookmark")
            }
            .controlSize(.small)
            .disabled(!shop.canWrite)
            .help(w.callIt("mac.print_next_help"))
            if file.isPrintNext {
                HStack(spacing: 6) {
                    Text(w.callIt("mac.print_next_for")).font(.caption).foregroundStyle(.secondary)
                    TextField(w.callIt("mac.print_next_for_hint"), text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .focused($editing)
                        .onSubmit(save)
                        .disabled(!shop.canWrite)
                }
            }
        }
        .onAppear { typed = file.printNextFor ?? "" }
        .onChange(of: file.id) { _, _ in typed = file.printNextFor ?? "" }
        .onChange(of: file.printNextFor) { _, now in if !editing { typed = now ?? "" } }
        // Kept when the field is left as well as on Return.
        .onChange(of: editing) { _, now in if !now { save() } }
    }

    private func save() {
        let now = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard now != (file.printNextFor ?? "").trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        shop.setPrintNextNote(file.id, now)
    }
}
