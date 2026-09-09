import SwiftUI
import KhaytCore

/// The selected model, in detail.
///
/// What a shop asks before putting a file back on a printer: how big is it, how
/// many colours, how many swaps, when did it last run, and where is the file.
struct LibraryInspector: View {
    let shop: Shop

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
                    if let how = howItPrints(file) {
                        LayerRule()
                        how
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
