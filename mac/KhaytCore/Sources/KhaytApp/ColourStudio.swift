import SwiftUI
import KhaytCore

/// Matching a colour to filament the shop already owns, and blending two spools
/// into a gradient.
///
/// ── WHY THIS IS NOT A COLOUR PICKER ───────────────────────────────────────
///
/// Every number on this screen is `lib/color-mix.js` — sRGB to CIELAB, then
/// CIEDE2000 for the distance, and linear light for the mixing. None of it is
/// arithmetic written here, and that matters more than usual: the obvious
/// implementation is Euclidean distance between hex triples, and it is wrong in
/// a way that hands a shop the wrong spool. It ranks a dark blue closer to
/// black than to a slightly lighter blue, because sRGB is not perceptually
/// uniform. The same goes for the blend — averaging two hex values mixes in
/// gamma-encoded space and produces a muddy midpoint that no filament looks
/// like.
///
/// The Electron app calls this the Colour Studio and this screen is its two
/// panels, in its words: `cmix.*`, translated in nine languages already.
///
/// ── WHAT IT DELIBERATELY IS NOT ───────────────────────────────────────────
///
/// Not the multicolour print planner. That is contextual in Khayt — launched
/// from a library card, assigning a FILE's colours to filaments — and belongs
/// with the model, not on a screen of its own.
struct ColourStudio: View {
    @Bindable var shop: Shop

    /// A hex the shop typed, or picked. Not a `Color`: what goes to the module
    /// is `#RRGGBB`, and going through SwiftUI's `Color` and back rounds the
    /// value through a colour space on the way.
    @State private var target = "#2E6F9E"
    @State private var matches: [ColourMatch] = []

    @State private var fromSpool: String?
    @State private var toSpool: String?
    @State private var steps = 5.0
    @State private var ramp: [String] = []

    /// Only the spools that carry a usable colour. A filament recorded as
    /// "black" with no hex cannot be measured against anything, and showing it
    /// in a ranked list with no distance would be a row that means nothing.
    private var coloured: [Spool] {
        shop.spools.filter { Swatch.rgb(fromHex: $0.color) != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(shop.words.callIt("cmix.subtitle"))
                    .font(.callout).foregroundStyle(.secondary)
                if coloured.isEmpty {
                    EmptyHere(title: shop.words.callIt("cmix.no_filaments"))
                        .frame(maxWidth: .infinity)
                } else {
                    matcher
                    blender
                }
            }
            .padding(Metric.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Khayt.ground)
        // NO `.navigationTitle` and no `.toolbar`: the window owns both, and a
        // detail screen that sets either rebuilds the window's toolbar. See
        // the note in `Portfolio.shown` for what that costs.
        .task(id: target) { await match() }
        .task(id: blendKey) { await mix() }
        .onAppear {
            if fromSpool == nil { fromSpool = coloured.first?.id }
            if toSpool == nil { toSpool = coloured.dropFirst().first?.id ?? coloured.first?.id }
        }
    }

    // MARK: - Match a colour to what is on the shelf

    private var matcher: some View {
        DetailSection(shop.words.callIt("cmix.matcher.title")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ColorPicker("", selection: Binding(
                        get: { Self.swiftUI(target) ?? .blue },
                        set: { target = Self.hex($0) ?? target }
                    ), supportsOpacity: false)
                        .labelsHidden()
                    TextField("", text: $target)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .frame(width: 110)
                    Spacer()
                }
                // What ΔE means, in Khayt's own words rather than in a comment
                // only the source can see.
                Text(shop.words.callIt("cmix.matcher.hint"))
                    .font(.caption).foregroundStyle(.tertiary)
                if matches.isEmpty {
                    Text(shop.words.callIt("cmix.no_filaments"))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(matches) { m in
                            row(m)
                            if m.id != matches.last?.id { Divider().padding(.leading, 34) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .card(padding: 0)
                }
            }
        }
    }

    private func row(_ m: ColourMatch) -> some View {
        HStack(spacing: 10) {
            Swatch(rgb: Swatch.rgb(fromHex: m.color), size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text([m.material, m.colourVariant].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " — "))
                    .lineLimit(1)
                if let weight = m.weight {
                    Text(Money.grams(weight) + " " + shop.words.callIt("common.grams"))
                        .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            // ΔE is the module's word for it and the number a shop can learn:
            // under 1 nobody can tell them apart, 2-3 is a good match on a
            // printed part, past 10 they are two colours. Said as a figure
            // rather than as "good/bad", because where the line falls depends
            // on the part.
            Text("ΔE " + Money.figure(m.deltaE))
                .font(.callout).monospacedDigit()
                .foregroundStyle(m.deltaE < 3 ? AnyShapeStyle(Khayt.done)
                                              : AnyShapeStyle(.secondary))
        }
        .padding(.vertical, 7)
    }

    // MARK: - Blend two spools

    private var blendKey: String { "\(fromSpool ?? "")|\(toSpool ?? "")|\(Int(steps))" }

    private var blender: some View {
        DetailSection(shop.words.callIt("cmix.blend.title")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    spoolPicker($fromSpool)
                    // `forward`, not `right`. The two are the same glyph in
                    // English and the difference only shows in Arabic, where
                    // the pickers swap sides and a fixed right-pointing arrow
                    // then says the gradient runs from the TO colour to the
                    // FROM one — the opposite of the swatches underneath it.
                    // `arrow.forward` turns with the writing direction.
                    Image(systemName: "arrow.forward").foregroundStyle(.tertiary)
                    spoolPicker($toSpool)
                    Spacer(minLength: 12)
                    Text(shop.words.callIt("cmix.steps")).foregroundStyle(.secondary)
                    Stepper("\(Int(steps))", value: $steps, in: 2...12)
                        .monospacedDigit().fixedSize()
                }
                Text(shop.words.callIt("cmix.blend.hint"))
                    .font(.caption).foregroundStyle(.tertiary)
                if !ramp.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(ramp.enumerated()), id: \.offset) { _, hex in
                            Rectangle()
                                .fill(Self.swiftUI(hex) ?? .clear)
                                .frame(height: 46)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack(spacing: 8) {
                        ForEach(Array(ramp.enumerated()), id: \.offset) { _, hex in
                            Text(hex.uppercased())
                                .font(.system(size: 10)).monospaced()
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func spoolPicker(_ selection: Binding<String?>) -> some View {
        Picker("", selection: selection) {
            Text(shop.words.callIt("cmix.filament")).tag(String?.none)
            ForEach(coloured) { spool in
                Text([spool.material, spool.colourVariant].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " — "))
                    .tag(String?.some(spool.id))
            }
        }
        .labelsHidden()
        .frame(width: 200)
    }

    // MARK: - Asking the module

    private func match() async {
        guard let engine = shop.engine, Swatch.rgb(fromHex: target) != nil else { matches = []; return }
        matches = (try? await engine.nearestFilaments(
            to: target, among: shop.inventoryRows, limit: 8)) ?? []
    }

    private func mix() async {
        guard let engine = shop.engine,
              let a = coloured.first(where: { $0.id == fromSpool })?.color,
              let b = coloured.first(where: { $0.id == toSpool })?.color else { ramp = []; return }
        ramp = (try? await engine.gradient(a, b, steps: Int(steps))) ?? []
    }

    // MARK: - Hex both ways

    /// `#RRGGBB` for the screen. Nil rather than a guess, so an unfinished
    /// value typed into the field does not paint a wrong colour on the way.
    static func swiftUI(_ hex: String) -> Color? {
        guard let c = Swatch.rgb(fromHex: hex) else { return nil }
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// What the picker chose, as the module's own notation.
    ///
    /// THROUGH sRGB, deliberately. A `Color` from the system picker can be in
    /// Display P3, and reading its components without converting gives numbers
    /// outside 0-1 for a saturated colour — which becomes a hex of `#00FF00`
    /// for something that is not green.
    static func hex(_ color: Color) -> String? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let f = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      f(srgb.redComponent), f(srgb.greenComponent), f(srgb.blueComponent))
    }
}
