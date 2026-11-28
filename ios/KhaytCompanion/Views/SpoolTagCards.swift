import SwiftUI

/// A spool tag on a head (signed frame 7a): "Snapmaker U1 · head 2 / The tag
/// says … / Matches your spool …" with Link to this spool and Choose another,
/// or "No spool like it on your shelf" with Add spool from the tag. Everything
/// shown is the Mac's reading and the Mac's match; a tap asks the Mac to
/// record it. Khayt never changes a spool without a tap.
struct SpoolTagCards: View {
    let machineId: String
    let machineName: String

    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var health: ConnectionHealth
    @State private var trays: [PrinterTray] = []
    @State private var spools: [InventorySpool] = []
    @State private var working: Int?
    @State private var notes: [Int: String] = [:]
    /// Heads where "Add spool from the tag" was sent and no answer came
    /// (keyed by head and tag). The Mac may still be adding it, and a read
    /// taken at once can come back before its write: until a read shows the
    /// head linked, Add is not offered again there, so a second tap can
    /// never add a second spool (review of #2699).
    @State private var addUnanswered: Set<String> = []
    /// Each head's colour name (`lib/colour-name.js`), by head.
    @State private var names: [Int: String] = [:]
    /// Heads with a spool linked that the printer reads as empty, as
    /// `lib/head-spools.js shown` says ("not-in-printer").
    @State private var notInPrinter: Set<Int> = []

    static func slot(_ tray: PrinterTray) -> String { "\(tray.head)|\(tray.key)" }

    /// Whether Add may be offered for this head now.
    static func mayOfferAdd(_ tray: PrinterTray, unanswered: Set<String>) -> Bool {
        tray.match.kind == "new" && tray.linked == nil && !unanswered.contains(slot(tray))
    }

    private var mayLink: Bool { PrinterTrays.mayLink(role: settings.effectiveRole) }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(PrinterTrays.shown(trays, notInPrinter: notInPrinter)) { tray in card(tray) }
            if !PrinterTrays.shown(trays, notInPrinter: notInPrinter).isEmpty {
                Text(L10n.tr("tray.foot"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: health.macInReach) { await load() }
    }

    private func load() async {
        guard PrinterTrays.asks(macInReach: health.macInReach, sampleShop: settings.isSampleShop) else { trays = []; return }
        trays = await api.printerTrays(machineId: machineId)
        // A head that now shows its spool has been answered.
        for tray in trays where tray.linked != nil { addUnanswered.remove(Self.slot(tray)) }
        if !trays.isEmpty { spools = (try? await api.fetchInventory()) ?? [] }
        let engine = try? BookReader.appWideEngine()
        (names, notInPrinter) = await Self.describe(trays, spools: spools, engine: engine, lang: L10n.engineLanguage)
    }

    /// The colour a head shows: the tag's colours; for a head read empty, the
    /// linked spool's own colour when the shelf records it as a colour.
    static func swatches(_ tray: PrinterTray, spools: [InventorySpool]) -> [String] {
        if !tray.colourHexes.isEmpty { return tray.colourHexes }
        guard tray.tag == nil, let id = tray.linked,
              let c = spools.first(where: { $0.id == id })?.color?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              PrinterTray.isPlainHex(c) else { return [] }
        return [c]
    }

    /// Each head's colour name and which heads are "not in the printer now",
    /// by the shared rules (`lib/colour-name.js`, `lib/head-spools.js`), so
    /// the phone says it as the Mac and the desktop do. The name is the
    /// spool's own when it has one, else the nearest everyday name, else none
    /// (the swatch stands alone). Without the engine: the spool's own name
    /// only, and an empty head with a link is still said, as the rule would.
    static func describe(_ trays: [PrinterTray], spools: [InventorySpool], engine: KhaytEngine?, lang: String) async -> ([Int: String], Set<Int>) {
        var names: [Int: String] = [:]
        var empty: Set<Int> = []
        for tray in trays {
            if tray.tag == nil, tray.linked != nil {
                let said = (try? await engine?.headSpoolsShown(linked: tray.linked, reportsEmpty: true)) ?? "not-in-printer"
                if said == "not-in-printer" { empty.insert(tray.head) }
            }
            let known = colourName(tray, spools: spools)
            if let hex = swatches(tray, spools: spools).first, let engine,
               let name = try? await engine.colourName(hex: hex, lang: lang, known: known) {
                names[tray.head] = name
            } else if let known {
                names[tray.head] = known
            }
        }
        return (names, empty)
    }

    static func spoolName(_ id: String?, in spools: [InventorySpool]) -> String? {
        guard let id, let s = spools.first(where: { $0.id == id }) else { return nil }
        let parts = [s.brand, s.material, colourWord(s.color)].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? id : parts.joined(separator: " ")
    }

    /// A spool's colour as words: "Galaxy Black", never a code like
    /// `#080A0D` (Turki, Nov 27: "the actual color showing, and color name
    /// if known"). The swatch shows the colour itself.
    static func colourWord(_ color: String?) -> String? {
        guard let c = color?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty, !c.hasPrefix("#") else { return nil }
        return c
    }

    /// The name of the tag's colour: the spool recorded in the head first,
    /// then the one the Mac matched it to. Nil when neither names it; the
    /// swatch then stands alone.
    /// This is the `known` name the shared rule is given; `describe` adds the
    /// nearest everyday name when there is none.
    static func colourName(_ tray: PrinterTray, spools: [InventorySpool]) -> String? {
        let suggested = tray.match.kind == "link" ? tray.match.spoolId : nil
        for id in [tray.linked, suggested] {
            if let id, let name = colourWord(spools.first(where: { $0.id == id })?.color) { return name }
        }
        return nil
    }

    /// The line under "The tag says": what the Mac's match found.
    static func matchWords(_ tray: PrinterTray, spools: [InventorySpool]) -> String {
        if let linked = spoolName(tray.linked, in: spools) { return L10n.format("tray.linked", linked) }
        // Recorded on the Mac, but not in this phone's copy of the shelf yet
        // (a spool just added): say so plainly, never "several match".
        if tray.linked != nil { return L10n.tr("tray.linked.unnamed") }
        switch tray.match.kind {
        case "link": return spoolName(tray.match.spoolId, in: spools).map { L10n.format("tray.match.link", $0) } ?? L10n.tr("tray.match.ask")
        case "ask": return L10n.tr("tray.match.ask")
        default: return L10n.tr("tray.match.new")
        }
    }

    /// The tag's colour, shown: a swatch per colour it names (the shared
    /// ringed swatch, so near-black shows on a dark card and off-white on a
    /// light one), and the colour's name beside it when it has one.
    private func colour(_ tray: PrinterTray) -> some View {
        let name = names[tray.head]
        return HStack(spacing: 8) {
            HStack(spacing: -6) {
                ForEach(Array(Self.swatches(tray, spools: spools).enumerated()), id: \.offset) { SpoolSwatch(hex: $0.element, size: 22) }
            }
            if let name {
                Text(name)
                    .font(.khayt(14, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name ?? L10n.tr("spool.form.colour"))
    }

    private func card(_ tray: PrinterTray) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("tray.title", machineName, tray.head))
                .font(.khayt(17, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.ink)
            if !Self.swatches(tray, spools: spools).isEmpty { colour(tray) }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tray.tag == nil ? L10n.tr("tray.not_in_printer")
                                         : L10n.format("tray.tag_says", tray.tagWords ?? L10n.tr("tray.tag_unknown")))
                        .font(.khayt(14.5, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.matchWords(tray, spools: spools))
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let weight = tray.weightWords {
                    Text(weight)
                        .font(.khayt(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                }
            }
            if mayLink, tray.linked == nil { buttons(tray) }
            if let note = notes[tray.head] {
                Text(note)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private func buttons(_ tray: PrinterTray) -> some View {
        let busy = working != nil
        HStack(spacing: 10) {
            if tray.match.kind == "link", let id = tray.match.spoolId {
                Button(L10n.tr("tray.do.link")) { Task { await ask(tray, .link(spoolId: id)) } }
                    .buttonStyle(.borderedProminent).tint(KhaytDesign.brand)
            }
            if Self.mayOfferAdd(tray, unanswered: addUnanswered) {
                Button(L10n.tr("tray.do.add")) { Task { await ask(tray, .create) } }
                    .buttonStyle(.borderedProminent).tint(KhaytDesign.brand)
            }
            if !choices(tray).isEmpty {
                Menu(L10n.tr(tray.match.kind == "link" ? "tray.do.choose" : "tray.do.choose_first")) {
                    ForEach(choices(tray)) { spool in
                        Button(Self.spoolName(spool.id, in: spools) ?? spool.id) { Task { await ask(tray, .link(spoolId: spool.id)) } }
                    }
                }
                .buttonStyle(.bordered)
            }
            if working == tray.head { ProgressView() }
        }
        .font(.khayt(13, .semibold, relativeTo: .footnote))
        .disabled(busy)
    }

    /// The spools "Choose another" offers: ONLY the ones the Mac itself
    /// proposed for this tag (`match.candidates`, best first), never the rest
    /// of the phone's shelf. The Mac's match already leaves out used-up,
    /// deleted and resin spools, so nothing is offered that it would refuse
    /// (Dev Hub, Nov 24). The one "Link to this spool" names is not repeated.
    private func choices(_ tray: PrinterTray) -> [InventorySpool] {
        Self.choices(tray, spools: spools)
    }

    static func choices(_ tray: PrinterTray, spools: [InventorySpool]) -> [InventorySpool] {
        let suggested = tray.match.kind == "link" ? tray.match.spoolId : nil
        var seen: Set<String> = []
        return (tray.match.candidates ?? []).compactMap { id in
            guard id != suggested, seen.insert(id).inserted else { return nil }
            return spools.first { $0.id == id }
        }
    }

    private func ask(_ tray: PrinterTray, _ what: PrinterTrays.Ask) async {
        guard working == nil else { return }
        working = tray.head
        defer { working = nil }
        let outcome = await api.setTraySpool(machineId: machineId, head: tray.head, seen: tray.key, what)
        switch outcome {
        case .linked:
            notes[tray.head] = L10n.tr("tray.done.linked")
            await load()
        case .created:
            notes[tray.head] = L10n.tr("tray.done.created")
            await load()
        case .changed(let now):
            notes[tray.head] = L10n.tr("tray.why.changed")
            if now.isEmpty { await load() } else { trays = now }
        case .refused(let reason):
            notes[tray.head] = PrinterTrays.words(reason)
        case .noAnswer:
            // The Mac may have done it (a `create` adds a spool): read what is
            // there now, and never send the same thing again blind.
            notes[tray.head] = L10n.tr("tray.why.no_answer")
            if what == .create { addUnanswered.insert(Self.slot(tray)) }
            await load()
        }
    }
}
