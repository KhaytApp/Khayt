import SwiftUI
import KhaytCore

/// Converting a 3MF, with the desktop converter's choices.
///
/// The menu used to convert the moment a printer was picked: no summary, no
/// bed check, every colour left in the slot it came in, and no way to ask for
/// Full Spectrum or band-swap though the engine could do both
/// (`Converter.convert`). This sheet is the desktop's convert modal
/// (`renderer/converter.js` `openConvertModal`) for the Mac:
///
/// - what the file is — the printer it was set up for, its nozzle, layer,
///   material, print time and colours — and whether it fits the target's bed;
/// - how its colours reach the target: slot by slot, matched to the spools a
///   machine has loaded (`lib/spool-match.js`), Full Spectrum mixing, or
///   band-swap pauses, each offered only when the shared rule says the target
///   can do it (`lib/printer-profiles.js`);
/// - and then the same save panel and library import as before.
///
/// Every figure on it is a shared rule's (`KhaytEngine.convertPreview`), read
/// off the main thread. The options it hands the conversion are the desktop's,
/// by the same names (`slotMap`, `fullSpectrum`, `bandSwap`, `spoolMerge`, …).
struct ConvertSheet: View {
    static let width: CGFloat = 520

    let shop: Shop
    let request: Shop.ConvertRequest

    enum Plan: String, Hashable { case slots, spools, fullSpectrum, bandSwap }

    /// `""` is the standard 3MF: the vendor's settings stripped.
    @State private var targetId = ""
    @State private var preview: KhaytEngine.ConvertPreview?
    /// The same, with the meshes read, for Full Spectrum and band-swap.
    @State private var plans: KhaytEngine.ConvertPreview?
    @State private var problem: String?
    @State private var planProblem: String?
    @State private var loadingPlans = false
    @State private var plan: Plan = .slots
    @State private var slotMap: [Int] = []
    @State private var spoolMachine = ""
    @State private var spoolEdits: [Int]?
    @State private var match: KhaytEngine.SpoolMatch?
    @State private var started = false
    /// "Split into plates (one file each)", for a project of two plates or more.
    @State private var splitPlates = false
    /// Keep the prime tower and drop variable layer height (`vlhGuard`).
    @State private var keepTower = false
    /// Which read is the newest: a target picked while the last was still
    /// reading must not have its answer overwritten by the older one.
    @State private var generation = 0

    private var words: Words { shop.words }
    private var colours: [KhaytEngine.ConvertPreview.Filament] { preview?.filaments ?? [] }
    /// Retargeted for the printer, rather than saved as a Generic 3MF.
    private var retargets: Bool { preview?.ok == true && preview?.generic != true && preview?.cross != true }

    var body: some View {
        SheetFrame(width: Self.width) {
            Text(words.callIt("conv.title")).font(.headline)
            Text(request.file.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(words.callIt("conv.target")).foregroundStyle(.secondary)
                    Picker("", selection: $targetId) {
                        ForEach(shop.printerProfiles) { p in Text(p.name).tag(p.id) }
                        Divider()
                        Text(words.callIt("mac.standard_3mf")).tag("")
                    }
                    .labelsHidden()
                }
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let preview, preview.ok {
                summary(preview)
                fit(preview)
                if preview.generic == true {
                    note(words.callIt("conv.normalize_note"))
                } else if preview.cross == true {
                    note(words.callIt("conv.cross_note", ["t": .string(preview.targetName ?? "")]))
                } else if colours.isEmpty {
                    note(words.callIt("conv.no_colours"))
                } else {
                    splitChoice(preview)
                    if splitting {
                        note(words.callIt("mac.cv_split_note", [
                            "n": .string(Money.quantity(Double(preview.plates ?? 0), decimals: 0)),
                            "t": .string(preview.targetName ?? "")]))
                    } else {
                        colourPlan(preview)
                    }
                }
                towerChoice(preview)
            } else {
                ProgressView(words.callIt("conv.analyzing")).controlSize(.small)
            }
        } footer: {
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { shop.pendingConvert = nil }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("conv.convert"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConvert || shop.converting)
            }
        }
        .task {
            guard !started else { return }
            started = true
            targetId = request.targetId ?? ""
            await read()
        }
        .onChange(of: targetId) { _, _ in Task { await read() } }
        .onChange(of: spoolMachine) { _, _ in spoolEdits = nil; Task { await rematch() } }
        .onChange(of: plan) { _, now in if now == .spools { Task { await rematch() } } }
    }

    // MARK: - What the file is

    @ViewBuilder private func summary(_ p: KhaytEngine.ConvertPreview) -> some View {
        let m = p.meta
        VStack(alignment: .leading, spacing: 6) {
            Text(words.callIt("conv.detected") + " · " + (p.flavour ?? "")).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if let printer = m?.printerModel, !printer.isEmpty { fact("conv.src_printer", printer) }
                if let mesh = request.file.mesh {
                    fact("conv.src_size", [mesh.x, mesh.y, mesh.z].map { Money.quantity($0, decimals: 0) }
                        .joined(separator: " × ") + " mm")
                }
                if let nozzle = m?.nozzle { fact("conv.src_nozzle", Money.quantity(nozzle, decimals: 2) + " mm") }
                if let layer = m?.layerHeight { fact("conv.src_layer", Money.quantity(layer, decimals: 2) + " mm") }
                if let grams = m?.totalGrams, grams > 0 {
                    fact("conv.src_material", Money.grams(grams) + " " + words.callIt("common.grams"))
                }
                if let minutes = m?.printMinutes, minutes > 0 {
                    fact("conv.src_time", PrintFigures.duration(minutes: minutes, words))
                }
            }
            .font(.callout)
            if !colours.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(colours.enumerated()), id: \.offset) { _, f in
                        Swatch(rgb: Swatch.rgb(fromHex: f.color), size: 14)
                    }
                    Text(Money.quantity(Double(colours.count), decimals: 0) + " " + words.callIt("conv.colours"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fact(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(words.callIt(key)).foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// The bed check: `lib/print-fit.js` through `fitWarnings`, on the size the
    /// library measured. A model never measured is said to be unchecked rather
    /// than shown as fitting.
    @ViewBuilder private func fit(_ p: KhaytEngine.ConvertPreview) -> some View {
        if p.generic != true, p.bed?.x != nil {
            if request.file.mesh == nil {
                note(words.callIt("mac.cv_fit_unknown"))
            } else if let warnings = p.fitWarnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label(words.callIt("conv.fit_no"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Khayt.attention)
                    ForEach(warnings, id: \.self) { w in
                        Text(w).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
            } else {
                Label(words.callIt("conv.fit_ok"), systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - One file per plate, and the prime tower

    /// Offered for a retarget of a project with two plates or more that can
    /// each stand alone (`lib/plate-split.js` `listPlatesMembers`).
    @ViewBuilder private func splitChoice(_ p: KhaytEngine.ConvertPreview) -> some View {
        if retargets, (p.plates ?? 0) >= 2 {
            Toggle(words.callIt("mac.cv_split"), isOn: $splitPlates)
        }
    }

    /// The target is Snapmaker Orca, which will not slice variable layer
    /// height with a prime tower — the one place `vlhGuard` decides anything.
    private var targetIsSnapmaker: Bool {
        if shop.printerProfiles.first(where: { $0.id == targetId })?.supportsMixedFilament == true { return true }
        return (preview?.targetName ?? "").localizedCaseInsensitiveContains("snapmaker")
    }

    @ViewBuilder private func towerChoice(_ p: KhaytEngine.ConvertPreview) -> some View {
        if retargets, p.variableLayerHeight == true, targetIsSnapmaker {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(words.callIt("mac.cv_keep_tower"), isOn: $keepTower)
                note(words.callIt("mac.cv_keep_tower_note"))
            }
        }
    }

    // MARK: - How the colours reach the printer

    private var offeredPlans: [Plan] {
        var out: [Plan] = [.slots]
        if !shop.machinesWithLoadedSpools.isEmpty { out.append(.spools) }
        if plans?.fullSpectrum?.available == true { out.append(.fullSpectrum) }
        if plans?.bandSwapEligible == true { out.append(.bandSwap) }
        return out
    }

    private func planName(_ plan: Plan) -> String {
        switch plan {
        case .slots: words.callIt("mac.cv_plan_slots")
        case .spools: words.callIt("conv.spool_title")
        case .fullSpectrum: words.callIt("mac.cv_plan_fs")
        case .bandSwap: words.callIt("mac.cv_plan_band")
        }
    }

    @ViewBuilder private func colourPlan(_ p: KhaytEngine.ConvertPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if offeredPlans.count > 1 {
                Picker(words.callIt("mac.cv_colour_plan"), selection: $plan) {
                    ForEach(offeredPlans, id: \.self) { Text(planName($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if loadingPlans {
                ProgressView(words.callIt("conv.fs_planning")).controlSize(.small)
            } else if let planProblem {
                note(planProblem)
            }
            switch plan {
            case .slots: slotTable(p)
            case .spools: spoolTable(p)
            case .fullSpectrum: fullSpectrum(p)
            case .bandSwap: bandSwap(p)
            }
        }
    }

    /// One row per colour of the file → a slot on the target, as the
    /// desktop's remap table: every slot the printer has, and at least as
    /// many as the file has colours.
    @ViewBuilder private func slotTable(_ p: KhaytEngine.ConvertPreview) -> some View {
        let slots = max(p.maxColors ?? colours.count, colours.count)
        VStack(alignment: .leading, spacing: 4) {
            note(words.callIt("conv.remap_hint"))
            ForEach(Array(colours.enumerated()), id: \.offset) { i, f in
                HStack(spacing: 8) {
                    Swatch(rgb: Swatch.rgb(fromHex: f.color), size: 16)
                    Text((f.color ?? "").uppercased()).font(.callout.monospaced())
                    if let g = f.grams {
                        Text(Money.grams(g) + " " + words.callIt("common.grams"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { i < slotMap.count ? slotMap[i] : i },
                                                  set: { if i < slotMap.count { slotMap[i] = $0 } })) {
                        ForEach(0..<slots, id: \.self) { s in
                            Text(words.callIt("conv.slot") + " " + Money.quantity(Double(s + 1), decimals: 0)).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            if Set(slotMap).count != slotMap.count {
                Label(words.callIt("conv.dup_slots"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func spoolTable(_ p: KhaytEngine.ConvertPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            note(words.callIt("conv.spool_hint"))
            Picker(words.callIt("conv.spool_source"), selection: $spoolMachine) {
                ForEach(shop.machinesWithLoadedSpools) { m in
                    let live = !(shop.printers.readings[m.id]?.status?.loaded ?? []).isEmpty
                    Text(words.callIt(live ? "conv.spool_src_live" : "conv.spool_src_typed",
                                      ["name": .string(m.name)])).tag(m.id)
                }
            }
            if let match {
                if match.ok {
                    ForEach(match.rows, id: \.index) { row in
                        HStack(spacing: 8) {
                            Swatch(rgb: Swatch.rgb(fromHex: row.hex), size: 16)
                            Image(systemName: "arrow.forward").foregroundStyle(.secondary).font(.caption)
                            Swatch(rgb: Swatch.rgb(fromHex: row.spoolHex), size: 16)
                            Picker("", selection: Binding(get: { row.slot }, set: { moveRow(row.index, to: $0) })) {
                                ForEach(match.usable, id: \.self) { s in
                                    Text(words.callIt("conv.slot") + " " + Money.quantity(Double(s + 1), decimals: 0)).tag(s)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            Text(words.callIt("conv.spool_q_" + row.quality) + " · ΔE "
                                 + Money.quantity(row.deltaE, decimals: 0))
                                .font(.caption).foregroundStyle(row.quality == "poor" ? Khayt.attention : .secondary)
                            if row.materialMismatch, let spool = row.spoolMaterial {
                                Label(spool, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(Khayt.attention)
                            }
                        }
                    }
                }
                ForEach(spoolWarnings(match), id: \.self) { w in
                    Text(w).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status = spoolStatus(match, colours: colours.count) {
                    Text(status.text).font(.callout)
                        .foregroundStyle(status.refused ? Khayt.attention : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func moveRow(_ index: Int, to slot: Int) {
        var edits = match?.map ?? []
        guard index < edits.count else { return }
        edits[index] = slot
        spoolEdits = edits
        Task { await rematch() }
    }

    /// The desktop panel's warning sentences (`converter-spools.js`), in the
    /// shared catalogue's words.
    private func spoolWarnings(_ m: KhaytEngine.SpoolMatch) -> [String] {
        m.warnings.compactMap { w in
            switch w.code {
            case "material":
                return words.callIt("conv.spool_material", [
                    "n": .string(Money.quantity(Double((w.index ?? 0) + 1), decimals: 0)),
                    "file": .string(w.file ?? ""), "spool": .string(w.spool ?? ""),
                    "slot": .string(Money.quantity(Double(w.slot ?? 0), decimals: 0))])
            case "beyond-target":
                return words.callIt("conv.spool_beyond", [
                    "slots": .string((w.slots ?? []).map { Money.quantity(Double($0), decimals: 0) }.joined(separator: ", ")),
                    "n": .string(Money.quantity(Double(w.n ?? 0), decimals: 0))])
            case "no-spools":
                return words.callIt("conv.spool_no_spools")
            default:
                return nil
            }
        } + (m.rows.contains { $0.quality == "poor" }
             ? [words.callIt("conv.spool_far_count",
                             ["n": .string(Money.quantity(Double(m.rows.filter { $0.quality == "poor" }.count), decimals: 0))])]
             : [])
    }

    private func spoolStatus(_ m: KhaytEngine.SpoolMatch, colours n: Int) -> (text: String, refused: Bool)? {
        guard m.ok else { return nil }
        func num(_ v: Int) -> JSONValue { .string(Money.quantity(Double(v), decimals: 0)) }
        switch m.kind {
        case "refused":
            let r = m.refusal
            switch r?.code {
            case "slot-past-end":
                return (words.callIt("conv.spool_refused_end", ["slot": num(r?.slot ?? 0), "n": num(r?.n ?? 0)]), true)
            case "slot-past-printer":
                return (words.callIt("conv.spool_refused_printer", ["slot": num(r?.slot ?? 0), "n": num(r?.n ?? 0)]), true)
            default:
                return (words.callIt("conv.spool_refused_bad"), true)
            }
        case "merge":
            return (words.callIt("conv.spool_applies_merge", ["n": num(n), "k": num(preview?.maxColors ?? n)]), false)
        case "grow":
            return (words.callIt("conv.spool_applies_grow", ["n": num(n), "k": num((m.map.max() ?? 0) + 1)]), false)
        case "slotMap":
            return (words.callIt("conv.spool_applies_map"), false)
        default:
            return (words.callIt("conv.spool_none"), false)
        }
    }

    @ViewBuilder private func fullSpectrum(_ p: KhaytEngine.ConvertPreview) -> some View {
        if let fs = plans?.fullSpectrum, fs.available {
            let heads = fs.heads ?? []
            VStack(alignment: .leading, spacing: 6) {
                note(words.callIt("conv.fs_toggle", ["n": .string(Money.quantity(
                    Double(max(0, colours.count - (p.maxColors ?? 0))), decimals: 0))]))
                Text(words.callIt("conv.fs_load")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Array(heads.enumerated()), id: \.offset) { _, h in
                        HStack(spacing: 4) {
                            Swatch(rgb: Swatch.rgb(fromHex: h.hex), size: 16)
                            Text(h.hex).font(.caption.monospaced())
                        }
                    }
                }
                Text(words.callIt("conv.fs_mixes")).font(.caption).foregroundStyle(.secondary)
                if (fs.mixes ?? []).isEmpty {
                    note(words.callIt("conv.fs_no_mix"))
                }
                ForEach(Array((fs.mixes ?? []).enumerated()), id: \.offset) { _, mix in
                    HStack(spacing: 6) {
                        Swatch(rgb: Swatch.rgb(fromHex: mix.srcHex), size: 14)
                        Image(systemName: "arrow.forward").font(.caption).foregroundStyle(.secondary)
                        Text(recipe(mix, heads: heads)).font(.caption)
                        if let de = mix.deltaE {
                            Text("ΔE " + Money.quantity(de, decimals: 1)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// "65% head 1 + 35% head 2" — the head by number as well as by colour,
    /// so the recipe does not rest on telling two swatches apart.
    private func recipe(_ mix: KhaytEngine.ConvertPreview.Mix, heads: [KhaytEngine.ConvertPreview.Head]) -> String {
        let head = { (id: Int) -> String in
            let hex = id >= 1 && id <= heads.count ? heads[id - 1].hex + " " : ""
            return hex + "(" + words.callIt("conv.fs_head", ["n": .string(Money.quantity(Double(id), decimals: 0))]) + ")"
        }
        guard mix.weights.count > 1 else { return head(mix.ids.first ?? 1) }
        return zip(mix.ids, mix.weights).map { Money.quantity($0.1, decimals: 0) + "% " + head($0.0) }
            .joined(separator: " + ")
    }

    @ViewBuilder private func bandSwap(_ p: KhaytEngine.ConvertPreview) -> some View {
        if let bands = plans?.bands, bands.banded == true {
            VStack(alignment: .leading, spacing: 4) {
                note(words.callIt("conv.band_toggle", [
                    "n": .string(Money.quantity(Double(colours.count), decimals: 0)),
                    "s": .string(Money.quantity(Double(bands.manualSwaps ?? 0), decimals: 0))]))
                let swaps = bands.instructions ?? []
                if swaps.isEmpty {
                    note(words.callIt("conv.band_no_swap"))
                } else {
                    Text(words.callIt("conv.band_pauses")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(swaps.enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 6) {
                            Swatch(rgb: Swatch.rgb(fromHex: s.toColour), size: 14)
                            Text(words.callIt("conv.band_swap_at", [
                                "h": .string(Money.quantity(Double(s.toolhead), decimals: 0)),
                                "z": .string(Money.quantity(s.z, decimals: 1))])).font(.caption)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reading, and converting

    private func read() async {
        generation += 1
        let mine = generation
        preview = nil; plans = nil; problem = nil; planProblem = nil; match = nil; spoolEdits = nil
        splitPlates = false; keepTower = false
        plan = .slots
        guard let engine = shop.engine, let source = shop.modelFile(for: request.file) else {
            problem = words.callIt("mac.not_found"); return
        }
        let target = shop.convertTarget(targetId.isEmpty ? nil : targetId)
        let bounds: [String: JSONValue]? = request.file.mesh.map {
            ["x": .number($0.x), "y": .number($0.y), "z": .number($0.z)]
        }
        let first: KhaytEngine.ConvertPreview
        do {
            first = try await Converter.preview(source, target: target, bounds: bounds, plans: false, engine: engine)
        } catch let failure as Converter.Failure {
            if mine == generation { problem = failure.said(words) }
            return
        } catch {
            if mine == generation { problem = shop.said(error) }
            return
        }
        guard mine == generation else { return }
        preview = first
        if !first.ok { problem = first.error ?? words.callIt("conv.analyze_failed"); return }
        slotMap = Array(0..<(first.filaments?.count ?? 0))
        if spoolMachine.isEmpty || !shop.machinesWithLoadedSpools.contains(where: { $0.id == spoolMachine }) {
            spoolMachine = shop.machinesWithLoadedSpools.first?.id ?? ""
        }
        // The colour plans read the paint inside the mesh, so they are asked
        // only when the target could use one — and in the background, with
        // the slot table already on screen.
        guard first.fullSpectrumCapable == true else { return }
        loadingPlans = true
        defer { if mine == generation { loadingPlans = false } }
        do {
            let second = try await Converter.preview(source, target: target, bounds: bounds, plans: true, engine: engine)
            if mine == generation { plans = second }
        } catch let failure as Converter.Failure {
            if mine == generation { planProblem = failure.said(words) }
        } catch {
            if mine == generation { planProblem = shop.said(error) }
        }
    }

    private func rematch() async {
        guard plan == .spools, let engine = shop.engine, let p = preview, p.ok, !spoolMachine.isEmpty else {
            match = nil; return
        }
        let cols: [[String: JSONValue]] = colours.map {
            ["hex": .string($0.color ?? ""), "material": .string($0.type ?? "")]
        }
        match = try? await engine.spoolMatch(colours: cols, loaded: shop.loadedSlots(for: spoolMachine),
                                             slotCount: p.maxColors, flavour: p.flavour ?? "", map: spoolEdits)
    }

    /// What this sheet adds to the conversion, or nil when it cannot convert
    /// as chosen (a spool match the converter would refuse).
    private var options: [String: JSONValue]? {
        guard var out = colourOptions else { return nil }
        if keepTower, retargets, preview?.variableLayerHeight == true, targetIsSnapmaker {
            out["vlhGuard"] = .string("keep-prime-tower")
        }
        return out
    }

    /// Splitting into plates: each plate's own colours, so no colour plan.
    private var splitting: Bool { splitPlates && retargets && (preview?.plates ?? 0) >= 2 }

    private var colourOptions: [String: JSONValue]? {
        guard let p = preview, p.ok else { return nil }
        if p.generic == true { return [:] }
        if p.cross == true { return ["mode": .string("normalize")] }
        if splitting { return [:] }
        switch plan {
        case .slots:
            guard !slotMap.isEmpty, slotMap != Array(0..<slotMap.count) else { return [:] }
            return ["slotMap": .array(slotMap.map { .number(Double($0)) })]
        case .spools:
            guard let m = match, m.ok, m.kind != "refused" else { return nil }
            if case .object(let extra)? = m.options { return extra }
            return [:]
        case .fullSpectrum:
            return plans?.fullSpectrum?.available == true ? ["fullSpectrum": .bool(true)] : nil
        case .bandSwap:
            return plans?.bandSwapEligible == true ? ["bandSwap": .bool(true)] : nil
        }
    }

    private var canConvert: Bool { options != nil && problem == nil }

    private func commit() {
        guard let extra = options else { return }
        let file = request.file
        let target = targetId.isEmpty ? nil : targetId
        shop.pendingConvert = nil
        if splitting {
            // The paint comes in only when a plate needs a colour map of its own.
            let bind = colours.count > (preview?.maxColors ?? Int.max)
            Task { await shop.convertModelPlates(file, targetId: target, extra: extra, bindMeshes: bind) }
            return
        }
        Task { await shop.convertModel(file, targetId: target, extra: extra) }
    }
}
