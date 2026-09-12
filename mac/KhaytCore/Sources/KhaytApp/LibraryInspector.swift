import SwiftUI
import KhaytCore

/// The selected model, in detail.
///
/// What a shop asks before putting a file back on a printer: how big is it, how
/// many colours, how many swaps, when did it last run, and where is the file.
struct LibraryInspector: View {
    let shop: Shop
    @State private var setups: KhaytEngine.PrintSetups?
    @State private var versions: KhaytEngine.PrintVersions?
    @State private var parts: KhaytEngine.PrintParts?

    var body: some View {
        if shop.fileSelection.count > 1 {
            ManyModels(shop: shop)
        } else if let file = shop.selectedFile {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(file)
                    LayerRule()
                    theFile(file)
                    if !file.palette.isEmpty {
                        LayerRule()
                        filament(file)
                    }
                    if let mesh = file.mesh {
                        LayerRule()
                        geometry(mesh, file.id)
                    }
                    // Only for something with a mesh to walk. A gcode is a list
                    // of moves and there is no geometry in it to judge.
                    if file.sourceFile?.kind == "model" {
                        LayerRule()
                        risk(file)
                    }
                    if let how = howItPrints(file) {
                        LayerRule()
                        how
                    }
                    // Only where there is more than one. A print always HAS a
                    // version; almost every file has exactly one, and a section
                    // headed "versions" over a list of one is a heading that
                    // says nothing.
                    // Only for a print that IS several files. One file is
                    // the ordinary case and a "parts" heading over a list of
                    // one says nothing.
                    if let parts, parts.multi {
                        LayerRule()
                        PartsSection(parts: parts, shop: shop)
                    }
                    if let versions, versions.many {
                        LayerRule()
                        VersionsSection(versions: versions, shop: shop)
                    }
                    if let setups, setups.total > 0 {
                        LayerRule()
                        SetupsSection(setups: setups, shop: shop)
                    }
                    provenance(file)
                    actions(file)
            if let notes = file.testedNotes, !notes.isEmpty {
                        LayerRule()
                        DetailSection(shop.words.callIt("doc.notes")) { Text(notes).textSelection(.enabled) }
                    }
                }
                .padding(16)
            }
            // Keyed on the file, not on the book: these are facts about one
            // record and nothing else on this screen moves them.
            .task(id: file.id) {
                setups = await shop.setups(for: file.id)
                versions = await shop.versions(for: file.id)
                parts = await shop.parts(for: file.id)
            }
        } else {
            EmptyHere(title: shop.words.callIt("mac.no_model"), message: shop.words.callIt("mac.no_model_hint"), mark: .library)
        }
    }

    /// The file, reachable. Buttons rather than only a context menu: a menu you
    /// have to know is there is a feature for the person who wrote it.
    @ViewBuilder private func actions(_ file: LibraryFile) -> some View {
        if let url = shop.modelFile(for: file) {
            HStack(spacing: 8) {
                Button { FileActions.reveal(url) } label: {
                    Label(shop.words.callIt("mac.reveal"), systemImage: "folder")
                }
                Button { FileActions.open(url) } label: {
                    Label(shop.words.callIt("mac.open"), systemImage: "arrow.up.forward.app")
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ file: LibraryFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // A fixed height, not an aspect ratio. `Thumbnail` is a ZStack over
            // a Rectangle and has no size of its own, and asking for a 1:1 fit
            // inside a vertical ScrollView leaves the height unresolved — the
            // whole inspector drew as an empty column.
            Thumbnail(source: shop.thumbnail(for: file))
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 6) {
                // A control only when it would do something. While the Electron
                // app has the book this is a star that reports, not a button
                // that lies — a disabled toggle invites people to keep pressing.
                if shop.canWrite {
                    Button {
                        shop.toggleFavourite(file)
                    } label: {
                        Image(systemName: file.isFavourite ? "star.fill" : "star")
                            .foregroundStyle(file.isFavourite ? AnyShapeStyle(.yellow)
                                                             : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .help(shop.words.callIt(file.isFavourite ? "mac.unmake_favourite" : "mac.make_favourite"))
                } else if file.isFavourite {
                    Image(systemName: "star.fill").foregroundStyle(Khayt.marked)
                }
                Text(file.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
            }
            if let problem = shop.writeProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Khayt.attention)
                    .textSelection(.enabled)
            }
            if let group = file.groupName {
                Label(group, systemImage: "square.stack")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let tags = file.tags, !tags.isEmpty {
                Text(tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
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
                DetailLine(shop.words.callIt("mac.last_run"), day.formatted(date: .abbreviated, time: .omitted))
            }
            // Where the bytes are is worth stating plainly. "On this Mac" and
            // "in the records but not here" look identical in a grid, and only
            // one of them can be put on a printer this afternoon.
            if shop.fileIsPresent(file) {
                DetailLine(shop.words.callIt("mac.on_this_mac"), "✓", dim: true)
            } else {
                DetailLine(shop.words.callIt("mac.on_this_mac"), shop.words.callIt("mac.not_found"), warn: true)
            }
        }
    }

    private func filament(_ file: LibraryFile) -> some View {
        DetailSection(shop.words.callIt("mac.filament")) {
            ForEach(Array(file.palette.enumerated()), id: \.offset) { i, colour in
                HStack(spacing: 8) {
                    Swatch(rgb: colour.rgb)
                    Text(colour.label ?? shop.words.callIt("mac.filament_n", ["n": .number(Double(i + 1))]))
                        .font(.callout)
                    Spacer(minLength: 8)
                    if let g = colour.grams {
                        Text("\(Format.mm(g)) \(shop.words.callIt("common.grams"))")
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

    /// What the slicer was told to do with this model.
    ///
    /// The question a shop asks second, after "which model is this": a folder
    /// holds the same shape sliced for a U1 and for an X1 Carbon, at three layer
    /// heights, one with support and one without, and the pictures are
    /// identical.
    ///
    /// NO PRINT TIME AND NO FILAMENT WEIGHT. Those exist only in a SLICED 3MF
    /// and not one of the 43 files in this shop's library carries them; a row
    /// that is empty on every real file teaches people the panel is broken.
    ///
    /// Absent entirely for a model whose file says nothing — an STL, a 3MF a CAD
    /// program wrote — for the same reason `provenance` is absent when nobody
    /// recorded a licence.
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
    /// because the Quick Look preview is a separate bundle that shows the same
    /// facts and cannot import this app. See `PrintFactLines`.
    @MainActor
    static func lines(from facts: KhaytEngine.PrintFacts?,
                      words: Words) -> [PrintFactLines.Line] {
        PrintFactLines.lines(from: facts,
                             word: { words.callIt($0) },
                             counting: words.counting)
    }

    static func number(_ v: Double) -> String { PrintFactLines.number(v) }

    /// Where it came from, and what may be done with it.
    ///
    /// Absent entirely for a model nobody has recorded a licence for. That is
    /// deliberate: a library that has just been imported has recorded none, and
    /// a panel that said "not recorded" on four hundred models would teach
    /// people to stop reading it. What it must never do is imply a refusal —
    /// unknown is not "you may not sell this".
    @ViewBuilder
    private func provenance(_ file: LibraryFile) -> some View {
        if let standing = shop.licences[file.id], standing.known || !standing.source.isEmpty {
            DetailSection(shop.words.callIt("plib.provenance")) {
                if !standing.source.isEmpty {
                    DetailLine(shop.words.callIt("plib.source"), standing.source)
                }
                if standing.known {
                    // ONE ROW, and the words are in the licence's own name:
                    // every language spells the NonCommercial ones "… — not for
                    // sale". A separate warning line said the same thing twice
                    // and had to borrow "Status" as a label, so the panel showed
                    // two rows both called Status. Amber for the eye, the
                    // sentence for the reader, one line for both.
                    DetailLine(shop.words.callIt("plib.licence"),
                               shop.words.callIt("plib.licence_"
                                                 + standing.licence.replacingOccurrences(of: "-", with: "_")),
                               warn: standing.sellable == false)
                }
            }
        }
    }

    private func geometry(_ mesh: LibraryFile.Mesh, _ id: String) -> some View {
        DetailSection(shop.words.callIt("mac.mesh")) {
            DetailLine(shop.words.callIt("set.store_size"), "\(Format.mm(mesh.x)) × \(Format.mm(mesh.y)) × \(Format.mm(mesh.z)) mm")
            DetailLine(shop.words.callIt("mac.triangles"), Format.count(mesh.triangles), dim: true)
            // WHETHER IT GOES ON A BED THE SHOP OWNS, which is the question a
            // maker asks before any other and which this app could not answer:
            // the rule lived inside the converter. Silent when nothing is
            // known — a machine with no bed recorded is not a machine that
            // refuses the model, and saying so would be a warning about a fact
            // nobody has.
            if let fit = shop.fits[id], fit.checked > 0 {
                DetailLine(shop.words.callIt("fit.title"), fitWords(fit),
                           warn: fit.verdict == "none")
            }
        }
    }

    /// What is likely to go wrong with this print.
    ///
    /// THREE STATES, and the third one is the reason this is not just a list.
    /// A shop on the default setting has not walked this mesh, so there is
    /// nothing to show and a button to ask — and an empty section headed
    /// "before you quote this" would read as "nothing to worry about", which is
    /// a different and much worse answer than "not looked yet".
    @ViewBuilder private func risk(_ file: LibraryFile) -> some View {
        DetailSection(shop.words.callIt("risk.title")) {
            if shop.riskRunning.contains(file.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(shop.words.callIt("risk.looking")).foregroundStyle(.secondary)
                }
            } else if let report = shop.risks[file.id] {
                if report.note.isEmpty {
                    // The answer for most functional parts, and worth saying
                    // out loud: a section that only ever speaks up when
                    // something is wrong leaves the shop unable to tell
                    // "checked, fine" from "not checked".
                    //
                    // Quiet, though. It read louder than the warnings in the
                    // first photograph of it, which is the wrong way round.
                    Text(shop.words.callIt("risk.clear"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        // `risk.head` IS the section's own title — "Before you
                        // quote this:" — written for the other app's quote
                        // screen, which has no heading above these lines. Here
                        // it printed the same sentence twice, once in small
                        // caps and once in prose.
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
                // The record is here and the file is not — an external library
                // that is not mounted. Nothing to walk, and offering a button
                // that cannot work is worse than saying so.
                Text(shop.words.callIt("mac.not_found")).foregroundStyle(.secondary)
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

    private func fitWords(_ fit: KhaytEngine.Fit) -> String {
        let machine = fit.machine.flatMap { row -> String? in
            guard case .object(let o) = row, case .string(let name)? = o["name"] else { return nil }
            return name
        } ?? ""
        switch fit.verdict {
        case "fits": return shop.words.callIt("fit.yes", ["machine": .string(machine)])
        case "rotate": return shop.words.callIt("fit.rotate", ["machine": .string(machine)])
        default: return shop.words.callIt("fit.no")
        }
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
                bits.append("\(shop.words.callIt("conv.src_layer")) \(mm.formatted(.number.precision(.fractionLength(0...2))))")
            }
            if let mm = setup.nozzleMm {
                bits.append("\(shop.words.callIt("conv.src_nozzle")) \(mm.formatted(.number.precision(.fractionLength(0...2))))")
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
                                .font(.caption2).foregroundStyle(Khayt.cyan)
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
        if let g = v.grams {
            bits.append("\(g.formatted(.number.precision(.fractionLength(0)))) \(shop.words.callIt("common.grams"))")
        }
        if let h = v.hours {
            bits.append("\(h.formatted(.number.precision(.fractionLength(1)))) \(shop.words.callIt("common.hours_short"))")
        }
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
                                .font(.system(size: 8)).foregroundStyle(Khayt.cyan)
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
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
    }
}
