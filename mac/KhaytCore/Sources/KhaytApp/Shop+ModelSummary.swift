import Foundation
import KhaytCore

/// The decision facts about one model, in one glance: how long, how much
/// plastic, what it costs to make, what it sells for, and where it can go.
///
/// ── NO SECOND FORMULA ─────────────────────────────────────────────────────
///
/// Cost to make is the CATALOGUE's cost: the parts a product made from this
/// model would start with (`modelPartsDraft`, the same figures, plates and
/// consumables), priced by the shared pricing rule (`priceProduct`). So the
/// number on the model and the cost of the product made from it are one
/// number, and a change to the shop's rates moves both.
///
/// Time and grams come from the same answer — the slicer's when the file was
/// sliced, the mesh estimate otherwise, and `estimated` says which.
struct ModelSummary: Equatable, Sendable {
    var hours: Double?
    var grams: Double?
    /// A weight or a time came from the geometry, not from a slice.
    var estimated = false
    var cost: Double?
    var product: LinkedProduct?
    var machines: [MachineFit] = []

    struct LinkedProduct: Equatable, Sendable {
        let id: String
        let name: String
        let price: Double
        /// On price, 0…1; nil when the product has no price.
        let margin: Double?
        /// Below `settings.minMarginPct`, when the shop set one.
        let belowFloor: Bool
    }

    struct MachineFit: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let state: ModelReadiness.State
    }

    /// Every machine that said anything is too small for it.
    var tooBigEverywhere: Bool {
        !machines.isEmpty && machines.allSatisfy { $0.state == .tooBig }
    }
}

extension Shop {

    /// The machines a 3D model can go on at all: printers that build in three
    /// dimensions. A laser bed or a UV flatbed holds a model's footprint and
    /// says nothing about printing it — the old "Fits" line could name the
    /// laser cutter.
    var modelMachines: [Machine] {
        machinesInUse.filter { ["fdm", "resin"].contains(kind(of: $0)?.kind ?? "fdm") }
    }

    /// A machine's bed record, as the fit rule reads it.
    func bed(of machineId: String) -> JSONValue? {
        guard let row = machineRows.first(where: { Self.recordId($0) == machineId }),
              case .object(let o) = row, let bed = o["bed"], case .object = bed else { return nil }
        return bed
    }

    /// Where this model can go, machine by machine — fit AND spools, through
    /// the one rule (`ModelReadiness`). Machines that know nothing are left
    /// out rather than shown as a refusal.
    ///
    /// ONE ANSWER FOR THE PAGE, THE TILE AND THE FILTER: the inspector's
    /// "Where it can print", the tile's printer chips (`libraryFitChips`) and
    /// Fits <machine> (`libraryFitSets`) all read this, and it is worked out
    /// once per model per change to what it depends on (`machineFitsKey`) —
    /// never again because the grid redrew.
    func machineFits(for file: LibraryFile) -> [ModelSummary.MachineFit] {
        let memo = refreshMachineFitsMemo()
        if let known = memo.machineFits[file.id] { return known }
        let made = workOutMachineFits(for: file)
        memo.machineFits[file.id] = made
        memo.work.fitBuilds += 1
        return made
    }

    /// The tile's printer chips: `machineFits`, as `LibraryFitChips` orders
    /// and trims it. Memoised with it.
    func libraryFitChips(_ file: LibraryFile) -> LibraryFitChips.Row {
        let memo = refreshMachineFitsMemo()
        if let known = memo.fitChips[file.id] { return known }
        let row = LibraryFitChips.row(machineFits(for: file).map { ($0.id, $0.name, $0.state) })
        memo.fitChips[file.id] = row
        return row
    }

    /// Per machine that prints in 3D, the models whose chip for it is on the
    /// tile — what Fits <machine> narrows to. Once per change, over the book.
    func libraryFitSets() -> [String: Set<String>] {
        let memo = refreshMachineFitsMemo()
        if let known = memo.fitSets { return known }
        memo.work.fitSetBuilds += 1
        var sets: [String: Set<String>] = [:]
        for machine in modelMachines { sets[machine.id] = [] }
        for file in files {
            for fit in machineFits(for: file) where LibraryFitChips.shows(fit.state) {
                sets[fit.id, default: []].insert(file.id)
            }
        }
        memo.fitSets = sets
        return sets
    }

    /// Everything a model's fits are worked out from: the records and the
    /// book (meshes, colours, beds, machines — `libraryFactsKey`) and the
    /// derived revision, which moves whenever the last recount's spool sets
    /// do (`spoolReadyByMachine`). A machine's loaded spools changing starts
    /// that recount (`loadedChanged`), so the live readings are NOT read here:
    /// a tile that read them would redraw every time a printer reported in.
    func machineFitsKey() -> [Int] {
        _ = spoolReadyByMachine.count
        return libraryFactsKey()
    }

    private func refreshMachineFitsMemo() -> LibraryMemo {
        let memo = libraryMemo
        let key = machineFitsKey()
        if memo.machineFitsKey != key {
            memo.machineFitsKey = key
            memo.machineFits = [:]
            memo.fitChips = [:]
            memo.fitSets = nil
        }
        return memo
    }

    /// `machineFits`, worked out — only ever through the memo above.
    private func workOutMachineFits(for file: LibraryFile) -> [ModelSummary.MachineFit] {
        let bounds = file.mesh.map { ModelReadiness.bounds(x: $0.x, y: $0.y, z: $0.z) }
        return modelMachines.compactMap { machine in
            let spools: Bool? = {
                guard !loadedSlots(for: machine.id).isEmpty else { return nil }
                if spoolReadyByMachine[machine.id]?.contains(file.id) == true { return true }
                // A file that names no colours cannot be told apart by them:
                // the spool half has nothing to say.
                return (file.colors ?? []).isEmpty ? nil : false
            }()
            guard let state = ModelReadiness.state(bounds: bounds, bed: bed(of: machine.id), spoolsReady: spools)
            else { return nil }
            return .init(id: machine.id, name: machine.name, state: state)
        }
    }

    /// The catalogue product this model is a part of — the first, when it is
    /// in several. `printFileId` is the join (`productFromFile`).
    nonisolated static func linkedProductId(_ fileId: String, in products: [JSONValue]) -> String? {
        for product in products {
            guard case .object(let o) = product, case .array(let parts)? = o["parts"] else { continue }
            if parts.contains(where: { part in
                if case .object(let p) = part, case .string(let id)? = p["printFileId"] { return id == fileId }
                return false
            }) { return recordId(product) }
        }
        return nil
    }

    func modelSummary(for file: LibraryFile) async -> ModelSummary {
        var out = ModelSummary()
        out.machines = machineFits(for: file)
        // `modelPart` reports through `productProblem`; this is a look, not a
        // product being made, so whatever the screen was saying stays said.
        let said = productProblem
        let draft = await modelPartsDraft(file)
        productProblem = said
        if let draft, let priced = await priceProduct(parts: draft.parts, margin: nil, components: nil),
           priced.parts > 0 {
            out.cost = priced.cost > 0 ? priced.cost : nil
            out.hours = priced.hours > 0 ? priced.hours : nil
            out.grams = priced.grams > 0 ? priced.grams : nil
            out.estimated = draft.estimated
        }
        if let id = Self.linkedProductId(file.id, in: productRows),
           let row = catalogueRows.first(where: { $0.id == id }),
           let record = productRows.first(where: { Self.recordId($0) == id }) {
            // The product's OWN cost — all its parts, components and
            // packaging — through the rule its price came from.
            var cost: Double?
            if let engine, let p = try? await engine.priceProduct(record, inventory: inventoryRows,
                                                                  settings: settingsDict,
                                                                  consumables: consumableRows) {
                cost = p.cost
            }
            let margin = cost.flatMap { ModelMargin.onPrice(price: row.final, cost: $0) }
            out.product = .init(id: id, name: row.name, price: row.final, margin: margin,
                                belowFloor: ModelMargin.belowFloor(margin, floorPct: Self.plainNumber(settingsDict["minMarginPct"])))
        }
        return out
    }
}

// MARK: - Several models at once

extension Shop {

    /// Add a tag to every selected model, keeping the tags each already has.
    ///
    /// `tagSelection` REPLACES — typing the full set is how a shop says
    /// "these are the same kind of thing". Adding one is the other everyday
    /// question ("mark these as Ramadan"), and replacing would wipe whatever
    /// else each one carried. Through the engine's `normaliseTags`, so a tag
    /// already in use keeps its spelling.
    func addTagToSelection(_ typed: String) async {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        guard let engine, let tags = try? await engine.normaliseTags(typed, known: tagsInUse), !tags.isEmpty
        else {
            writeProblem = words.callIt("mac.group_unknown")
            return
        }
        editFiles(ids, named: words.callIt("mac.li_add_tag_action")) { record in
            record["tags"] = .array(Self.mergedTags(record["tags"], adding: tags).map { .string($0) })
        }
    }

    /// The tags a record ends with: what it had, then each new one it did not
    /// already carry (case-insensitively), in order.
    nonisolated static func mergedTags(_ had: JSONValue?, adding: [String]) -> [String] {
        var out: [String] = []
        if case .array(let rows)? = had {
            for case .string(let t) in rows where !t.isEmpty { out.append(t) }
        }
        for t in adding where !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            out.append(t)
        }
        return out
    }

    /// Set the material on every selected model — what the file is printed
    /// in, the `material` field the library already shows and filters on.
    /// Empty clears it.
    func setMaterialOnSelection(_ typed: String) {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        let material = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        // The shop's existing spelling of the same material, so "pla" does
        // not become a second chip beside "PLA".
        let known = materialsInUse.first { $0.caseInsensitiveCompare(material) == .orderedSame } ?? material
        editFiles(ids, named: words.callIt("mac.li_set_material_action")) { record in
            record["material"] = known.isEmpty ? .null : .string(known)
        }
    }

    /// The materials the library's models say they are printed in, most used
    /// first.
    var materialsInUse: [String] {
        var counts: [String: Int] = [:]
        for f in files { if let m = f.material?.trimmingCharacters(in: .whitespaces), !m.isEmpty { counts[m, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Free up space for each selected model, one after another, through the
    /// one-model path (`freeUpSpace(model:)`) and its proofs. A model an open
    /// job needs is LEFT, as the whole-library pass leaves it, and counted at
    /// the end — there is no one-model question to ask from a selection.
    func freeUpSpace(models: [LibraryFile]) async {
        var skipped = 0
        for file in models {
            await freeUpSpace(model: file)
            if pendingFreeUp != nil { pendingFreeUp = nil; skipped += 1; continue }
            if cloudLibraryProblem != nil { return }
        }
        if skipped > 0 {
            cloudLibraryProblem = words.callIt("mac.li_free_skipped", ["n": .number(Double(skipped))])
        }
    }

    /// Keep each selected model on this Mac (or stop), one by one through
    /// `keepOnThisMac`, which brings an online-only one back first.
    func keepOnThisMac(models: [LibraryFile], _ keep: Bool) async {
        for file in models { await keepOnThisMac(file, keep) }
    }
}

/// What several selected models come to together.
struct SelectionTotals: Equatable, Sendable {
    var count = 0
    var hours = 0.0
    var grams = 0.0
    var bytes = 0.0
    /// How many had a time or a weight to add — the rest add nothing, and a
    /// total that silently skips them reads as a complete one.
    var withFigures = 0
    var onlineOnly = 0
    var notHere = 0
    /// Any time or weight in the sum came from the mesh estimate, so the
    /// total is drawn with ≈ like each of the tiles it adds up.
    var anyEstimated = false
}

extension Shop {

    /// Each model's time and weight as the summary card shows them: the
    /// slicer's when it was sliced, else the mesh estimate.
    nonisolated static func totals(_ files: [LibraryFile],
                                   estimates: [String: KhaytEngine.MeshEstimate],
                                   onlineOnly: (LibraryFile) -> Bool,
                                   present: (LibraryFile) -> Bool) -> SelectionTotals {
        var t = SelectionTotals()
        for f in files {
            t.count += 1
            t.bytes += f.size ?? 0
            let e = estimates[f.id]
            let mins = f.parsed?.printTimeMins ?? 0
            let h = mins > 0 ? mins / 60 : (e?.hours ?? 0)
            let g = (f.parsed?.filamentGrams ?? 0) > 0 ? (f.parsed?.filamentGrams ?? 0) : (e?.grams ?? 0)
            if h > 0 || g > 0 { t.withFigures += 1 }
            if (mins <= 0 && h > 0) || ((f.parsed?.filamentGrams ?? 0) <= 0 && g > 0) { t.anyEstimated = true }
            // An older version's figures: ≈ like any estimate (review M1).
            if f.figuresStale, h > 0 || g > 0 { t.anyEstimated = true }
            t.hours += max(0, h)
            t.grams += max(0, g)
            if onlineOnly(f) { t.onlineOnly += 1 } else if !present(f) { t.notHere += 1 }
        }
        return t
    }

    func selectionTotals(_ files: [LibraryFile]) -> SelectionTotals {
        Self.totals(files, estimates: estimates, onlineOnly: { self.isInCloudOnly($0) },
                    present: { self.fileIsPresent($0) })
    }

    /// Selected ids that are NOT drawn as a tile right now — inside a folder
    /// tile, behind a filter. No action here touches them (`selectedFiles`),
    /// and the pane says how many, so the count a shop says yes to is the
    /// whole truth (27 Sep 2026: 34 models went with a hidden selection).
    var selectedButHidden: Int {
        let shown = Set(selectedFiles.map(\.id))
        return fileSelection.count { !shown.contains($0) }
    }
}

/// One way to say a print's time and weight on the model page and the
/// multi-select pane — the same "6h 52m" the machine cards use
/// (`PrinterWatch.spell`), and whole grams or kilos past a thousand. The page
/// said "6.9 h" on the card and "6.9 hrs" under it, beside a grid saying
/// "6h 52m" for the same print.
enum PrintFigures {

    @MainActor
    static func duration(minutes: Double, _ words: Words) -> String {
        PrinterWatch.spell(max(0, minutes) * 60, words)
    }

    @MainActor
    static func duration(hours: Double, _ words: Words) -> String {
        duration(minutes: hours * 60, words)
    }

    /// "146 g", "2.1 kg".
    @MainActor
    static func weight(_ grams: Double, _ words: Words) -> String {
        if grams >= 1000 {
            return Money.quantity(grams / 1000, decimals: 1) + " " + words.callIt("mac.unit_kg")
        }
        return Money.quantity(max(0, grams).rounded(), decimals: 0) + " " + words.callIt("mac.unit_g")
    }
}
