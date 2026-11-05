import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import KhaytCore

/// HueForge on the Mac: a photo as a filament-painted relief for the
/// Snapmaker U1, and the zero-slicer 3MF it prints from.
///
/// The desktop's studio is `renderer/hueforge.js`; every number here is the
/// same `lib/hueforge.js` it runs (`StudioEngine`). This screen does what the
/// renderer does around those rules: reads the photo, keeps the stack, asks
/// for a plan when something changes, and writes the file.
///
/// ── THE PHOTO IS READ ONCE, AT ONE SIZE ───────────────────────────────────
///
/// At most 640 pixels on its longest side, exactly as the desktop's
/// `loadImageFile` reads it, and never again: changing the print's width or
/// height re-plans from the same pixels, and the filament picker
/// (`suggestFilaments`) is asked only when a photo arrives or the number of
/// colours changes. So the picks cannot flip because the maker typed a new
/// width — the reason Bed Ready's site passes a fixed-grid `pickFrom`
/// (bedready#92). The relief's own resolution follows the width inside
/// `planPainting`, as on the desktop.
///
/// What is not here yet, and is on the desktop: the calibration card (print
/// and photograph to measure TD), colour fixes by clicking an area, reordering
/// by drag and the preview of a hanger. The PR that added this lists them.
struct HueForgeStudio: View {
    @Bindable var shop: Shop
    @State private var model = HueForgeModel()

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    source
                    if model.picture != nil {
                        stack
                        settings
                    }
                }
                .padding(16)
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
            preview
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.replanKey) { model.replanSoon() }
    }

    private var words: Words { shop.words }

    // MARK: The photo

    private var source: some View {
        GroupBox(words.callIt("mac.hf_photo")) {
            VStack(alignment: .leading, spacing: 8) {
                if let name = model.pictureName {
                    Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(words.callIt("mac.hf_photo_hint")).font(.callout).foregroundStyle(.secondary)
                }
                Button(words.callIt(model.picture == nil ? "mac.hf_choose_photo" : "mac.hf_other_photo") + "\u{2026}") {
                    choosePhoto()
                }
                .disabled(model.reading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.read(url, owned: owned) }
            return true
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.read(url, owned: owned) }
    }

    /// The shop's coloured spools, as the book holds them — the picker snaps
    /// its colours to these, as the desktop's `ownedColored` does.
    private var owned: [JSONValue] {
        shop.spools.compactMap { s -> JSONValue? in
            guard let color = s.color, !color.isEmpty else { return nil }
            var o: [String: JSONValue] = ["color": .string(color), "material": .string(s.material)]
            if let w = s.weight { o["weight"] = .number(w) }
            if let v = s.colourVariant { o["colourVariant"] = .string(v) }
            return .object(o)
        }
    }

    // MARK: The stack

    private var stack: some View {
        GroupBox(words.callIt("mac.hf_stack")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(words.callIt(model.mode == .relief ? "mac.hf_stack_hint" : "mac.hf_stack_hint_flat"))
                    .font(.caption).foregroundStyle(.secondary)
                // By identity, not position (`RowsByIDTests`): a TD field that
                // commits after its row was removed writes nothing.
                ForEach(Array(model.ids.enumerated()), id: \.element) { i, id in
                    filamentRow(i, id)
                }
                HStack {
                    Stepper(value: $model.maxColors, in: 2...4) {
                        Text(words.callIt("mac.hf_colours", ["n": .number(Double(model.maxColors))]))
                    }
                    Spacer()
                    Button(words.callIt("mac.hf_suggest")) { Task { await model.suggest(owned: owned) } }
                    Button(words.callIt("mac.hf_add")) { model.addFilament() }
                        .disabled(model.filaments.count >= 4)
                }
            }
            .padding(4)
        }
    }

    private func filamentRow(_ i: Int, _ id: UUID) -> some View {
        HStack(spacing: 8) {
            Text(words.callIt("mac.hf_head", ["n": .number(Double(i + 1))]))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: model.filament(id)?.hex ?? "") ?? .gray) },
                set: { model.setColour(id, NSColor($0).hexString) }), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(words.callIt("mac.hf_colour"))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.filament(id)?.hex ?? "").font(.caption.monospaced())
                if let name = model.filament(id)?.name {
                    Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if model.mode == .relief {
                Text(words.callIt("mac.hf_td")).font(.caption).foregroundStyle(.secondary)
                TextField(words.callIt("mac.hf_td"), value: Binding(
                    get: { model.filament(id)?.td ?? 1 },
                    set: { model.setTd(id, $0) }), format: .number.precision(.fractionLength(0...2)).locale(Money.digits))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                    .help(words.callIt("mac.hf_td_help"))
            }
            Button { model.move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(i == 0)
                .accessibilityLabel(words.callIt("mac.hf_move_up"))
            Button { model.move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(i >= model.filaments.count - 1)
                .accessibilityLabel(words.callIt("mac.hf_move_down"))
            Button { model.remove(i) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).disabled(model.filaments.count <= 1)
                .accessibilityLabel(words.callIt("mac.hf_remove"))
        }
    }

    // MARK: Print settings

    private var settings: some View {
        GroupBox(words.callIt("mac.hf_settings")) {
            Form {
                Picker(words.callIt("mac.hf_mode"), selection: $model.mode) {
                    Text(words.callIt("mac.hf_mode_relief")).tag(HueForgeModel.Mode.relief)
                    Text(words.callIt("mac.hf_mode_flat")).tag(HueForgeModel.Mode.flat)
                }
                Picker(words.callIt("mac.hf_layer"), selection: $model.settings.layerH) {
                    ForEach(HueForgeModel.layerPresets, id: \.self) { h in
                        Text(words.callIt("mac.hf_mm", ["n": .string(String(format: "%.2f", h))])).tag(h)
                    }
                }
                number("mac.hf_width", $model.settings.widthMm, 40...(model.mode == .flat ? 270 : 1000), step: 5)
                number("mac.hf_height", $model.settings.heightMm, 0.8...6, step: 0.1)
                if model.mode == .relief {
                    Stepper(value: $model.settings.baseLayers, in: 1...20) {
                        Text(words.callIt("mac.hf_base", ["n": .number(Double(model.settings.baseLayers))]))
                    }
                    Stepper(value: $model.settings.vivid, in: 1...10) {
                        Text(words.callIt("mac.hf_vivid", ["n": .number(Double(model.settings.vivid))]))
                    }
                    .help(words.callIt("mac.hf_vivid_help"))
                    Stepper(value: $model.settings.smooth, in: 0...3) {
                        Text(words.callIt("mac.hf_smooth", ["n": .number(Double(model.settings.smooth))]))
                    }
                    Picker(words.callIt("mac.hf_hanger"), selection: $model.settings.hang) {
                        Text(words.callIt("mac.hf_hang_none")).tag("")
                        Text(words.callIt("mac.hf_hang_hole")).tag("hole")
                        Text(words.callIt("mac.hf_hang_loop")).tag("loop")
                    }
                    if !model.settings.hang.isEmpty {
                        number("mac.hf_hole", $model.settings.holeMm, 2...12, step: 0.5)
                    }
                }
            }
            .formStyle(.columns)
            .padding(4)
        }
    }

    private func number(_ key: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        LabeledContent(words.callIt(key)) {
            HStack(spacing: 4) {
                TextField(words.callIt(key), value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }),
                    format: .number.precision(.fractionLength(0...2)).locale(Money.digits))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Stepper("", value: value, in: range, step: step).labelsHidden()
                Text(words.callIt("mac.unit_mm")).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The preview and the export

    private var preview: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5))
                if let image = model.previewImage {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        .padding(12)
                        .accessibilityLabel(words.callIt("mac.hf_preview"))
                } else if model.reading {
                    ProgressView(words.callIt("mac.hf_reading"))
                } else {
                    EmptyHere(title: words.callIt("mac.hf_empty"), message: words.callIt("mac.hf_empty_hint"))
                }
                if model.planning {
                    VStack { HStack { Spacer(); ProgressView().controlSize(.small).padding(10) }; Spacer() }
                }
            }
            verdict
            HStack {
                if let note = model.note {
                    Text(note).font(.callout).foregroundStyle(model.noteIsProblem ? AnyShapeStyle(Khayt.late) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .lineLimit(2)
                }
                Spacer()
                if model.mode == .relief {
                    Button(words.callIt("mac.hf_export_stl") + "\u{2026}") { Task { await model.exportStl(words) } }
                        .disabled(!model.canExport || model.exporting)
                }
                Button(words.callIt("mac.hf_export_3mf") + "\u{2026}") { Task { await model.export3MF(words) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canExport || model.exporting)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var verdict: some View {
        if model.mode == .relief, let plan = model.relief {
            HStack(spacing: 14) {
                Text(words.callIt("mac.hf_match", ["n": .string(String(format: "%.1f", plan.meanDeltaE))]))
                Text(words.callIt(plan.automatic ? "mac.hf_automatic" : "mac.hf_reloads"))
                Text(words.callIt("mac.hf_swaps", ["n": .number(Double(plan.swaps))]))
                Text(words.callIt("mac.hf_layers", ["n": .number(Double(plan.totalLayers))]))
                if plan.tiled {
                    Text(words.callIt("mac.hf_tiles", ["cols": .number(Double(plan.tileCols)),
                                                       "rows": .number(Double(plan.tileRows))]))
                        .foregroundStyle(Khayt.attention)
                }
                Spacer()
                ForEach(Array(plan.slots.enumerated()), id: \.offset) { _, hex in
                    Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(width: 14, height: 14)
                }
            }
            .font(.callout)
        } else if model.mode == .flat, let plan = model.flat {
            HStack(spacing: 14) {
                Text(words.callIt("mac.hf_flat_exact", ["n": .number(Double(plan.palette.count))]))
                Spacer()
                ForEach(Array(plan.palette.enumerated()), id: \.offset) { _, hex in
                    Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(width: 14, height: 14)
                }
            }
            .font(.callout)
        }
    }
}

/// What the studio holds between edits.
@MainActor
@Observable
final class HueForgeModel {
    enum Mode: String, Hashable { case relief, flat }

    /// The desktop's four layer heights (`LAYER_PRESETS`).
    static let layerPresets = [0.04, 0.08, 0.12, 0.16]
    /// The longest side the photo is read at — the desktop's `WORK_MAX`.
    nonisolated static let workMax = 640

    var picture: StudioEngine.Picture?
    var pictureName: String?
    var mode: Mode = .relief
    var filaments: [StudioEngine.Filament] = [] {
        // A row's identity, kept beside it: replaced with the list, carried
        // through every add, remove and move below.
        didSet { if ids.count != filaments.count { ids = filaments.map { _ in UUID() } } }
    }
    private(set) var ids: [UUID] = []

    func filament(_ id: UUID) -> StudioEngine.Filament? {
        ids.firstIndex(of: id).flatMap { filaments.indices.contains($0) ? filaments[$0] : nil }
    }
    var maxColors = 4 { didSet { if maxColors != oldValue { Task { await suggest(owned: lastOwned) } } } }
    var settings = StudioEngine.ReliefSettings()
    var relief: StudioEngine.ReliefPlan?
    var flat: StudioEngine.FlatPlan?
    var previewImage: CGImage?
    var reading = false
    var planning = false
    var exporting = false
    var note: String?
    var noteIsProblem = false

    private var lastOwned: [JSONValue] = []
    private var planTask: Task<Void, Never>?

    /// Everything a plan depends on. A change re-plans, a moment later.
    var replanKey: String {
        "\(mode.rawValue)|\(filaments.map { "\($0.hex):\($0.td)" }.joined(separator: ","))|\(settings.layerH)|\(settings.heightMm)|\(settings.widthMm)|\(settings.baseLayers)|\(settings.vivid)|\(settings.smooth)|\(pictureName ?? "")"
    }

    var canExport: Bool {
        !planning && (mode == .relief ? relief != nil : (flat?.parts ?? 0) > 0)
    }

    /// The name the export is saved under: the photo's, without its extension.
    var stem: String {
        let base = (pictureName as NSString?)?.deletingPathExtension ?? ""
        return base.isEmpty ? (mode == .flat ? "hueforge-flat" : "hueforge") : base
    }

    // MARK: Reading the photo

    func read(_ url: URL, owned: [JSONValue]) async {
        lastOwned = owned
        reading = true
        note = nil
        defer { reading = false }
        let decoded = try? await Studio.offMain { try Self.decode(url) }
        guard let decoded, let engine = await Studio.engine() else {
            note = Words.upfront("mac.hf_unreadable"); noteIsProblem = true
            return
        }
        do {
            try await engine.setPicture(decoded)
        } catch {
            note = Words.upfront("mac.hf_unreadable"); noteIsProblem = true
            return
        }
        picture = decoded
        pictureName = url.lastPathComponent
        relief = nil; flat = nil; previewImage = nil
        await suggest(owned: owned)
    }

    /// The photo as RGBA, at most `workMax` on its longest side and turned
    /// the way its EXIF says — what a browser canvas hands the desktop.
    nonisolated static func decode(_ url: URL) throws -> StudioEngine.Picture {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w0 = props[kCGImagePropertyPixelWidth] as? Int,
              var h0 = props[kCGImagePropertyPixelHeight] as? Int, w0 > 0, h0 > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        if let o = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&w0, &h0) }
        return try picture(from: src, width: w0, height: h0)
    }

    nonisolated static func picture(from src: CGImageSource, width w0: Int, height h0: Int) throws -> StudioEngine.Picture {
        let scale = min(1, Double(workMax) / Double(max(w0, h0)))
        let w = max(1, Int((Double(w0) * scale).rounded()))
        let h = max(1, Int((Double(h0) * scale).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w0, h0),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try rgba(image, width: w, height: h)
    }

    /// Draw a picture into `width`×`height` RGBA. Opaque photos read exactly
    /// as a canvas reads them; a transparent pixel reads premultiplied (black
    /// where a canvas keeps its colour), which no relief can print anyway.
    nonisolated static func rgba(_ image: CGImage, width w: Int, height h: Int) throws -> StudioEngine.Picture {
        var bytes = Data(count: w * h * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { throw CocoaError(.fileReadCorruptFile) }
        return StudioEngine.Picture(width: w, height: h, rgba: bytes)
    }

    // MARK: The stack

    func suggest(owned: [JSONValue]) async {
        lastOwned = owned
        guard picture != nil, let engine = await Studio.engine() else { return }
        guard let picked = try? await engine.suggest(owned: owned, maxColors: maxColors), !picked.isEmpty else { return }
        ids = []
        filaments = picked
        // The desktop's opaque foundation, ~0.4 mm (`autoPalette`).
        settings.baseLayers = min(20, max(2, Int((0.4 / settings.layerH).rounded())))
    }

    func setColour(_ id: UUID, _ hex: String?) {
        guard let i = ids.firstIndex(of: id), filaments.indices.contains(i), let hex, !hex.isEmpty else { return }
        filaments[i].hex = hex.uppercased()
        filaments[i].name = nil
        Task {
            if let engine = await Studio.engine(), let td = try? await engine.defaultTd(hex),
               let k = ids.firstIndex(of: id), filaments.indices.contains(k), filaments[k].hex == hex.uppercased() {
                filaments[k].td = td
            }
        }
    }

    func setTd(_ id: UUID, _ td: Double) {
        guard let i = ids.firstIndex(of: id), filaments.indices.contains(i) else { return }
        filaments[i].td = min(50, max(0.1, td))
    }

    func move(_ i: Int, by d: Int) {
        let j = i + d
        guard filaments.indices.contains(i), filaments.indices.contains(j), ids.count == filaments.count else { return }
        ids.swapAt(i, j)
        filaments.swapAt(i, j)
    }

    func remove(_ i: Int) {
        guard filaments.count > 1, filaments.indices.contains(i), ids.count == filaments.count else { return }
        ids.remove(at: i)
        filaments.remove(at: i)
    }

    /// A fifth head does not exist on the U1; the desktop adds a white.
    func addFilament() {
        guard filaments.count < 4 else { return }
        ids.append(UUID())
        filaments.append(StudioEngine.Filament(hex: "#FFFFFF", td: 5))
    }

    // MARK: Planning

    func replanSoon() {
        planTask?.cancel()
        guard picture != nil, !filaments.isEmpty else { return }
        planTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await plan()
        }
    }

    private func plan() async {
        guard let engine = await Studio.engine() else { return }
        planning = true
        defer { planning = false }
        let fils = filaments, s = settings, m = mode
        do {
            if m == .relief {
                let r = try await engine.planRelief(fils, s)
                guard !Task.isCancelled else { return }
                relief = r; flat = nil
                previewImage = r.flatMap { Self.cgImage($0.preview, $0.width, $0.height) }
            } else {
                let f = try await engine.planFlat(colors: max(2, min(4, maxColors)), widthMm: min(270, s.widthMm),
                                                  heightMm: s.heightMm, filaments: fils.map(\.hex))
                guard !Task.isCancelled else { return }
                flat = f; relief = nil
                previewImage = f.flatMap { Self.cgImage($0.preview, $0.width, $0.height) }
            }
            if note != nil && !noteIsProblem { note = nil }
        } catch {
            note = Words.upfront("mac.hf_plan_failed"); noteIsProblem = true
        }
    }

    nonisolated static func cgImage(_ rgba: Data, _ w: Int, _ h: Int) -> CGImage? {
        guard w > 0, h > 0, rgba.count >= w * h * 4, let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The preview as a PNG no longer than `maxSide` — the plate thumbnail the
    /// desktop embeds (`solvePreviewPng`), so Orca and Finder show a picture.
    nonisolated static func png(_ image: CGImage, maxSide: Int) -> Data? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: Export

    /// Zip one piece: the rule's members in its order, the thumbnails drawn here.
    nonisolated static func archive(_ piece: StudioEngine.Piece, big: Data?, small: Data?) throws -> Data {
        var members: [ZipWrite.Member] = []
        for m in piece.members {
            if m.thumbnail {
                let png = m.name.hasSuffix("_small.png") ? (small ?? big) : big
                members.append(ZipWrite.Member(m.name, png ?? Data(), store: true))
            } else {
                members.append(ZipWrite.Member(m.name, Data((m.text ?? "").utf8)))
            }
        }
        return try ZipWrite.archive(members)
    }

    func export3MF(_ words: Words) async {
        guard canExport, let engine = await Studio.engine() else { return }
        let suffix = mode == .flat ? "-flat-U1.3mf" : "-U1.3mf"
        guard let url = Studio.askWhereToSave(safeStem + suffix, type: "3mf") else { return }
        exporting = true
        defer { exporting = false }
        let big = previewImage.flatMap { Self.png($0, maxSide: 512) }
        let small = previewImage.flatMap { Self.png($0, maxSide: 128) }
        do {
            let pieces = mode == .flat
                ? try await engine.flatPieces(name: stem, layerH: settings.layerH, widthMm: min(270, settings.widthMm),
                                              heightMm: settings.heightMm, thumbnail: big != nil)
                : try await engine.reliefPieces(name: stem, settings: settings, thumbnail: big != nil)
            guard !pieces.isEmpty else { note = words.callIt("mac.hf_empty_model"); noteIsProblem = true; return }
            let written = try await Studio.offMain { () throws -> Int in
                var count = 0
                // Tiles go side by side under the one name the maker chose,
                // as the desktop saves them: stem-r1c2-U1.3mf.
                let stemPath = url.path.replacing(/(-flat)?(-U1)?\.3mf$/.ignoresCase(), with: "")
                for piece in pieces {
                    let data = try Self.archive(piece, big: big, small: small)
                    let out = piece.tag.map { URL(fileURLWithPath: stemPath + $0 + "-U1.3mf") } ?? url
                    try data.write(to: out, options: .atomic)
                    count += 1
                }
                return count
            }
            note = written > 1
                ? words.callIt("mac.hf_saved_tiles", ["n": .number(Double(written))])
                : words.callIt("mac.hf_saved")
            noteIsProblem = false
        } catch {
            note = words.callIt("mac.hf_export_failed"); noteIsProblem = true
        }
    }

    func exportStl(_ words: Words) async {
        guard mode == .relief, relief != nil, let engine = await Studio.engine() else { return }
        guard let url = Studio.askWhereToSave(safeStem + "-U1.stl", type: "stl") else { return }
        exporting = true
        defer { exporting = false }
        do {
            guard let data = try await engine.reliefStl(settings: settings) else {
                note = words.callIt("mac.hf_empty_model"); noteIsProblem = true; return
            }
            try await Studio.offMain { try data.write(to: url, options: .atomic) }
            note = words.callIt("mac.hf_saved_stl"); noteIsProblem = false
        } catch {
            note = words.callIt("mac.hf_export_failed"); noteIsProblem = true
        }
    }

    /// The desktop's file-name rule: anything but word characters, dots and
    /// dashes becomes an underscore.
    var safeStem: String { stem.replacing(/[^\w.-]+/, with: "_") }
}

