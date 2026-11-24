import SwiftUI
import KhaytCore

// "Loaded on this printer" on the machine sheet, and "Link a spool" (Mac
// file, page 25, frames 1 and 2; signed Nov 22). What each head holds, from
// its spool tag (a Snapmaker U1) or from the printer's own word for it, and
// which of the shop's spools that is.
//
// KHAYT NEVER CHANGES A SPOOL BY ITSELF. Linking remembers which spool is in
// a head (`machines[].headSpools`, the record the other app writes and a
// phone's route writes: `Shop.linkTray`). Adding a spool from a tag is one
// new spool with no price. An existing spool's weight, price and colour stay
// as the shop entered them. Both are always a click.
//
// The words are the other app's (`mach.heads_*`), so the two say it the same.

extension Shop {
    /// What each head holds, read now: nil for a printer whose heads cannot
    /// be read (not Moonraker, not connected), and for one that reports
    /// neither tags nor anything loaded.
    func machineHeads(_ machineId: String) async -> [KhaytEngine.HeadRow]? {
        // lock: system — reads the printer's spool tags (one read-only GET) and this Mac's own book; nothing is written.
        guard let engine, let found = headsMachine(machineId) else { return nil }
        let machine = found.machine
        guard !machine.isRetired, machine.printerApi?.type == "moonraker", PrinterWatch.notWatched(machine) == nil else { return nil }
        var detect: JSONValue = .null
        do {
            let base: URL
            if let stand = trayBaseForTests { base = stand } else { base = try await PrinterWatch.baseURL(machine, engine: engine) }
            var key = machine.printerApi?.apiKey ?? ""
            if let build = source.build { key = (try? await Secrets.open(key, for: build)) ?? "" }
            let answer = try await PrinterWatch.get(base, path: "/printer/objects/query?filament_detect", key: key,
                                                    type: "moonraker", timeout: 10, fetch: trayFetchForTests)
            detect = HeadActuals.filamentDetect(in: answer) ?? .null
        } catch {
            // The printer is off: what it last said was loaded is still worth showing.
        }
        let reported = headsLoadedForTests ?? printers.readings[machine.id]?.status?.loaded ?? []
        let loaded: JSONValue = .array(reported.map { .object(["slot": .number(Double($0.slot)), "hex": .string($0.hex), "material": .string($0.material)]) })
        guard detect != .null || !reported.isEmpty else { return nil }
        let book = trayBookForTests ?? lanRestBook
        return try? await engine.machineHeads(filamentDetect: detect, loaded: loaded, spools: Self.rows(book, "inventory"),
                                              linked: found.raw["headSpools"] ?? .null)
    }

    private func headsMachine(_ id: String) -> (raw: [String: JSONValue], machine: Machine)? {
        for row in Self.rows(trayBookForTests ?? lanRestBook, "machines") {
            guard case .object(let o) = row, Self.recordId(row) == id,
                  let data = try? JSONEncoder().encode(row),
                  let machine = try? JSONDecoder().decode(Machine.self, from: data) else { continue }
            return (o, machine)
        }
        return nil
    }

    /// The shop's spool with that id, raw, for its label and what is left.
    func headSpool(_ id: String) -> [String: JSONValue]? {
        for row in Self.rows(trayBookForTests ?? lanRestBook, "inventory") {
            if case .object(let o) = row, Self.recordId(row) == id { return o }
        }
        return nil
    }

    /// May whoever is at this Mac add a spool from a tag? (inventory/create,
    /// as the other app asks.)
    var mayAddSpoolFromTag: Bool { lockAllows("inventory", "create") }

    /// "Link": this spool is in that head, or a new one from its tag is.
    /// `head` counts from zero. False, with `moveProblem` saying why, when
    /// nothing was written.
    @discardableResult
    func linkHead(_ machineId: String, head: Int, choice: TrayChoice, prefill: KhaytEngine.HeadRow.Prefill?) async -> Bool {
        // Linking edits the machine's record: the printer's connection, to the lock. Adding a spool is inventory/create.
        guard permittedPrinter("connection") else { return false }
        if choice == .create { guard permitted("inventory", "create") else { return false } }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return false }
        var fill: [String: JSONValue] = [:]
        if let prefill {
            fill["material"] = .string(prefill.material)
            if let c = prefill.color { fill["color"] = .string(c) }
            if let b = prefill.brand { fill["brand"] = .string(b) }
            if let w = prefill.weight { fill["weight"] = .number(w) }
        }
        do {
            if var book = trayBookForTests {
                _ = try await Self.linkTray(into: &book, machineId: machineId, head: head + 1, choice: choice, prefill: fill,
                                            engine: engine, newId: Self.uid("INV"), today: Self.today())
                trayBookForTests = book
                return true
            }
            guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return false }
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                _ = try await Self.linkTray(into: &root, machineId: machineId, head: head + 1, choice: choice, prefill: fill,
                                            engine: engine, newId: Self.uid("INV"), today: Self.today())
            }
            await load(source)
            return true
        } catch let refused as TrayRefused {
            moveProblem = refused.reason == "tag-unusable" ? words.callIt("inv.material_ph") : words.callIt("mac.move_gone")
            return false
        } catch {
            moveProblem = said(error)
            return false
        }
    }
}

/// How the heads section says things: the other app's own sentences.
@MainActor
enum HeadWords {
    /// Parts set side by side with a dot between, IN THE SHOP'S DIRECTION.
    ///
    /// A spool's maker and material are Latin words in an Arabic sentence
    /// ("PLA", "Snapmaker", "1.75"). Left to the bidi rule, two of them with
    /// only a dot between are one left-to-right run and are drawn in the
    /// wrong order, a number beside one jumps to its other side, and a line
    /// that BEGINS with one is laid out left to right altogether (all three
    /// seen in the first Arabic photographs). So in a right-to-left language
    /// the line starts by saying its direction and says it again at each dot.
    static func joined(_ parts: [String], _ words: Words, by separator: String = " · ") -> String {
        let shown = parts.filter { !$0.isEmpty }
        guard Direction.rtlLanguages.contains(words.language) else { return shown.joined(separator: separator) }
        let mark = "\u{200F}"
        let dot = separator.trimmingCharacters(in: .whitespaces)
        // A comma sits against the word before it; a dot has a space on each side.
        return mark + shown.joined(separator: dot == "," ? mark + "، " : " " + mark + dot + " ")
    }

    /// "1 kg" for a whole number of hundreds of grams from a kilo up, else "640 g". "" for nothing.
    static func weight(_ grams: Double?, _ words: Words) -> String {
        guard let g = grams, g > 0 else { return "" }
        if g >= 1000, g.truncatingRemainder(dividingBy: 100) == 0 {
            let kg = g / 1000
            return words.callIt("mach.heads_kg", ["n": .string(Money.quantity(kg, decimals: kg == kg.rounded() ? 0 : 1))])
        }
        return words.callIt("mach.heads_g", ["n": .string(words.numeral(Int(g.rounded())))])
    }

    /// A spool as the shop knows it: brand, material and colour variant, or its id.
    static func spoolLabel(_ spool: [String: JSONValue]?) -> String {
        guard let spool else { return "" }
        let parts = ["brand", "material", "colourVariant"].compactMap { key -> String? in
            if case .string(let s)? = spool[key], !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            return nil
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if case .string(let id)? = spool["id"] { return id }
        return ""
    }

    static func left(_ spool: [String: JSONValue]?, _ words: Words) -> String {
        var grams: Double?
        if case .number(let w)? = spool?["weight"] { grams = w }
        let said = weight(grams, words)
        return said.isEmpty ? words.callIt("mach.heads_g", ["n": .string(words.numeral(0))]) : said
    }

    /// "Tool 1 · PLA SnapSpeed · Polymaker", or "Tool 4 · Nothing loaded".
    static func title(_ row: KhaytEngine.HeadRow, spool: [String: JSONValue]?, _ words: Words) -> String {
        let n: [String: JSONValue] = ["n": .string(words.numeral(row.head + 1))]
        if row.tag == nil, row.live == nil, spool == nil { return words.callIt("mach.heads_nothing", n) }
        var material = ""
        if let tag = row.tag { material = [tag.material, tag.sub].filter { !$0.isEmpty }.joined(separator: " ") }
        else if let live = row.live { material = live.material }
        else if case .string(let m)? = spool?["material"] { material = m }
        let maker = row.tag.map { $0.manufacturer.isEmpty ? $0.vendor : $0.manufacturer } ?? ""
        return joined([words.callIt("mach.heads_tool", n), material, maker], words)
    }

    /// "Tag read · 1 kg spool", or "Set on the printer · no tag"; "" for neither.
    static func how(_ row: KhaytEngine.HeadRow, _ words: Words) -> String {
        if let tag = row.tag {
            let size = weight(tag.weightG, words)
            return joined([words.callIt("mach.heads_tag_read"), size.isEmpty ? "" : words.callIt("mach.heads_spool_of", ["size": .string(size)])], words)
        }
        return row.live == nil ? "" : words.callIt("mach.heads_set_on_printer")
    }

    /// The third line, and whether it is the amber "nothing matches".
    static func linkLine(_ row: KhaytEngine.HeadRow, spool: [String: JSONValue]?, _ words: Words) -> (text: String, unmatched: Bool) {
        if let spool {
            return (words.callIt("mach.heads_linked", ["spool": .string(spoolLabel(spool)), "left": .string(left(spool, words))]), false)
        }
        if row.tag != nil, row.match == "new" { return (words.callIt("mach.heads_no_match"), true) }
        return (words.callIt("mach.heads_not_linked"), false)
    }

    /// "PLA SnapSpeed · Polymaker · 500 g · 1.75 mm": what the tag says, for the sheet's first line. "" with no tag.
    static func fromTag(_ row: KhaytEngine.HeadRow, _ words: Words) -> String {
        guard let tag = row.tag else { return "" }
        let mm = tag.diameterMm.map { words.callIt("mach.heads_mm", ["n": .string(Money.quantity($0, decimals: 2))]) } ?? ""
        let maker = tag.manufacturer.isEmpty ? tag.vendor : tag.manufacturer
        return joined([tag.material, maker, weight(tag.weightG, words), mm], words)
    }
}

/// Frame 1: one line per head, under the sheet's other rows.
struct MachineHeadsSection: View {
    let shop: Shop
    let machineId: String
    /// A capture's stand-ins.
    var pretend: [KhaytEngine.HeadRow]?
    @State private var rows: [KhaytEngine.HeadRow]?
    @State private var linking: Linking?

    struct Linking: Identifiable { let row: KhaytEngine.HeadRow; let adding: Bool; var id: Int { row.head } }
    /// A capture draws the buttons as a shop that may edit sees them (the sample book lets nobody).
    private var mayEdit: Bool { shop.canMoveJobs || pretend != nil }

    var body: some View {
        let words = shop.words
        Group {
            if let rows = pretend ?? rows {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in line(row, words) }
                    Text(words.callIt("mach.heads_note"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem = shop.moveProblem {
                        Text(problem).font(.callout).foregroundStyle(Khayt.late).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task(id: machineId) { if pretend == nil { rows = await shop.machineHeads(machineId) } }
        .shopSheet(item: $linking) { asked in
            LinkHeadSheet(shop: shop, machineId: machineId, row: asked.row, adding: asked.adding) {
                rows = await shop.machineHeads(machineId)
            }
        }
    }

    @ViewBuilder private func line(_ row: KhaytEngine.HeadRow, _ words: Words) -> some View {
        let spool = row.spoolId.flatMap { shop.headSpool($0) }
        let how = HeadWords.how(row, words)
        let link = HeadWords.linkLine(row, spool: spool, words)
        let empty = row.tag == nil && row.live == nil && spool == nil
        HStack(alignment: .top, spacing: 8) {
            // A head with nothing in it is a dashed ring: a solid one would
            // read as a white spool, which is a real colour (seen in the
            // first photograph, where an off-white PETG and an empty head
            // looked the same).
            Circle()
                .fill(Swatch.rgb(fromHex: row.hex).map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color.clear)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(empty ? 0.5 : 0.55),
                                               style: StrokeStyle(lineWidth: 1, dash: empty ? [2, 2] : [])))
                .frame(width: 12, height: 12).padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(HeadWords.title(row, spool: spool, words)).font(.system(size: 13, weight: .medium))
                if !how.isEmpty { Text(how).font(.system(size: 11)).foregroundStyle(.secondary) }
                if !empty {
                    Text(link.text).font(.system(size: 12)).foregroundStyle(link.unmatched ? Khayt.attention : .secondary)
                }
            }
            Spacer(minLength: 8)
            if !empty {
                Button(words.callIt(spool == nil ? "mach.heads_link" : "mach.heads_change")) { linking = Linking(row: row, adding: false) }
                    .controlSize(.small).disabled(!mayEdit)
                // A tag like nothing on the shelf: adding it is offered beside linking, never done by itself.
                if spool == nil, row.prefill != nil, row.match == "new", shop.mayAddSpoolFromTag {
                    Button(words.callIt("mach.heads_add")) { linking = Linking(row: row, adding: true) }
                        .controlSize(.small).disabled(!mayEdit)
                }
            }
        }
    }
}

/// Frame 2: "Tool 2 — which spool is this?"
struct LinkHeadSheet: View {
    let shop: Shop
    let machineId: String
    let row: KhaytEngine.HeadRow
    /// Opened from "Add spool…": the new spool starts chosen.
    let adding: Bool
    let done: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: String
    @State private var saving = false

    static let new = "\u{0}new"

    /// What starts chosen is decided here, not when the sheet appears: a
    /// sheet that is photographed never "appears", and would show no choice.
    init(shop: Shop, machineId: String, row: KhaytEngine.HeadRow, adding: Bool, done: @escaping () async -> Void) {
        self.shop = shop
        self.machineId = machineId
        self.row = row
        self.adding = adding
        self.done = done
        _chosen = State(initialValue: Self.first(row, adding: adding, mayAdd: shop.mayAddSpoolFromTag))
    }

    /// What can be chosen, in order: the linked spool first when there is
    /// one, then the rule's candidates, then "Add as a new spool".
    @MainActor static func options(_ row: KhaytEngine.HeadRow, mayAdd: Bool) -> [String] {
        var ids: [String] = []
        if let linked = row.spoolId { ids.append(linked) }
        for id in row.candidates where !ids.contains(id) { ids.append(id) }
        if row.prefill != nil, mayAdd { ids.append(new) }
        return ids
    }

    /// What starts chosen: the linked spool, else the best candidate, else the new spool.
    @MainActor static func first(_ row: KhaytEngine.HeadRow, adding: Bool, mayAdd: Bool) -> String {
        let all = options(row, mayAdd: mayAdd)
        if adding, all.contains(new) { return new }
        return all.first ?? ""
    }

    var body: some View {
        let words = shop.words
        let options = Self.options(row, mayAdd: shop.mayAddSpoolFromTag)
        let from = HeadWords.fromTag(row, words)
        SheetFrame(width: 520) {
            Text(words.callIt("mach.heads_which", ["n": .string(words.numeral(row.head + 1))]))
                .font(.system(size: 15, weight: .semibold))
            if !from.isEmpty {
                Text(words.callIt("mach.heads_from_tag", ["what": .string(from)])).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if options.isEmpty {
                Text(words.callIt("mach.heads_none_to_link")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("", selection: $chosen) {
                    ForEach(options, id: \.self) { id in option(id, words).tag(id) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            Text(words.callIt("mach.heads_link_note")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = shop.moveProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Khayt.late).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(words.callIt("mach.heads_link_btn")) {
                    saving = true
                    Task {
                        let ok = await shop.linkHead(machineId, head: row.head, choice: chosen == Self.new ? .create : .link(chosen),
                                                     prefill: row.prefill)
                        saving = false
                        if ok { await done(); dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || saving)
            }
        }
        .onAppear { shop.moveProblem = nil }
    }

    /// One choice: its name and what is left, and why it is offered.
    @MainActor static func said(_ id: String, row: KhaytEngine.HeadRow, shop: Shop) -> (title: String, sub: String) {
        let words = shop.words
        if id == new {
            let what = HeadWords.joined([row.prefill?.material ?? "", HeadWords.weight(row.prefill?.weight, words)], words, by: ", ")
            return (words.callIt("mach.heads_add_new"), words.callIt("mach.heads_add_new_sub", ["what": .string(what)]))
        }
        let spool = shop.headSpool(id)
        let title = HeadWords.joined([HeadWords.spoolLabel(spool), words.callIt("mach.heads_left", ["left": .string(HeadWords.left(spool, words))])], words)
        // "Best match" is the rule's one strong match; any other candidate is the same material and colour.
        let sub = row.candidates.first == id ? words.callIt(row.match == "link" ? "mach.heads_best" : "mach.heads_same")
            : (row.candidates.contains(id) ? words.callIt("mach.heads_same") : "")
        return (title, sub)
    }

    @ViewBuilder private func option(_ id: String, _ words: Words) -> some View {
        let said = Self.said(id, row: row, shop: shop)
        VStack(alignment: .leading, spacing: 1) {
            Text(said.title).font(.system(size: 13))
            if !said.sub.isEmpty { Text(said.sub).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}
