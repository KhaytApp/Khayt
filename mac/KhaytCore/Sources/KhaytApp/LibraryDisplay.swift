import SwiftUI
import KhaytCore

/// ── HOW THE LIBRARY IS LAID OUT ON THIS MAC ───────────────────────────────
///
/// Tile size and grid-or-list are a preference of the person at THIS Mac,
/// not a fact about the book: a shop with a 13-inch Air at the bench and a
/// Studio Display in the office wants different densities of the same
/// library. So they live in `UserDefaults`, never in `khayt-store.json`, and
/// a second Mac syncing the book does not inherit them.
///
/// One observable object rather than two `@AppStorage`s scattered over the
/// filter bar, the grid and the View menu: the menu's ⌘+ and the segmented
/// control in the row must be one value, and a test has to be able to read
/// and step it without drawing anything.
@MainActor @Observable
final class LibraryDisplay {
    static let shared = LibraryDisplay()

    nonisolated static let tileKey = "khayt.library.tileSize"
    nonisolated static let layoutKey = "khayt.library.layout"

    @ObservationIgnored private let defaults: UserDefaults

    var tileSize: LibraryTileSize {
        didSet { defaults.set(tileSize.rawValue, forKey: Self.tileKey) }
    }
    var layout: LibraryLayout {
        didSet { defaults.set(layout.rawValue, forKey: Self.layoutKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tileSize = defaults.string(forKey: Self.tileKey).flatMap(LibraryTileSize.init(rawValue:)) ?? .medium
        layout = defaults.string(forKey: Self.layoutKey).flatMap(LibraryLayout.init(rawValue:)) ?? .grid
    }

    /// ⌘+. False at the largest, so the menu item can grey out.
    @discardableResult func larger() -> Bool {
        guard let next = tileSize.larger else { return false }
        tileSize = next
        return true
    }

    /// ⌘−. False at the smallest.
    @discardableResult func smaller() -> Bool {
        guard let next = tileSize.smaller else { return false }
        tileSize = next
        return true
    }

    func resetSize() { tileSize = .medium }
}

/// Three densities, not a slider. A slider gives a shop forty sizes it cannot
/// get back to; three named steps are three places a hand returns to.
enum LibraryTileSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }

    /// The NARROWEST a tile may be, in points. The grid fits as many columns
    /// of at least this as the width allows and then shares out what is left
    /// (`Wide.fill`), so there is never a dead band beside the last column.
    /// Small is a contact sheet — eight across a 1320-point window with the
    /// inspector open; Medium is about §10's tile; Large about twice Small.
    var points: CGFloat {
        switch self {
        case .small: 94
        case .medium: 140
        case .large: 200
        }
    }

    var larger: LibraryTileSize? {
        switch self {
        case .small: .medium
        case .medium: .large
        case .large: nil
        }
    }

    var smaller: LibraryTileSize? {
        switch self {
        case .small: nil
        case .medium: .small
        case .large: .medium
        }
    }

    /// Small is a contact sheet: one line of title, and none of the badges
    /// that only matter once a model has been picked out.
    var isCompact: Bool { self == .small }

    var wordKey: String {
        switch self {
        case .small: "mac.lg_size_small"
        case .medium: "mac.lg_size_medium"
        case .large: "mac.lg_size_large"
        }
    }

    var symbol: String {
        switch self {
        case .small: "square.grid.4x3.fill"
        case .medium: "square.grid.3x3.fill"
        case .large: "square.grid.2x2.fill"
        }
    }

    /// The longest side a thumbnail is decoded to for a tile `width` wide:
    /// twice the picture's width in points (a Retina screen), and no more. A
    /// small tile was decoded to 640 pixels like every other.
    static func pixels(width: CGFloat, scale: CGFloat) -> Int {
        Int(((width - 12) * max(1, min(scale, 2))).rounded(.up))
    }
}

enum LibraryLayout: String, CaseIterable, Identifiable, Sendable {
    case grid, list
    var id: String { rawValue }
    var wordKey: String { self == .grid ? "mac.lg_view_grid" : "mac.lg_view_list" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

// MARK: - What a tile says

/// The facts a shop decides by — how long, how much plastic, what it sells
/// for — as numbers, before any of them is written in words.
///
/// ── WHERE EACH ONE COMES FROM ─────────────────────────────────────────────
///
/// Nothing here is worked out fresh. Each is a figure the app already holds:
///
///   TIME, GRAMS — what the slicer wrote into the file (`parsed`, read by
///   `SlicerFigures`), the per-colour weights a multi-colour slice keeps
///   instead (`colors[].grams`, the same sum `lib/part-from-print-file.js`
///   makes), and failing both the inspector's "If you print this" estimate
///   from the mesh (`Shop.estimates`). An estimate is MARKED as one (≈): the
///   inspector draws them in separate sections for the same reason.
///
///   PRICE — the catalogue's own final price (`catalogueRows`) for a product
///   whose every part is this one file (`printFileId`). A kit that uses the
///   model as one part of five is not this model's price, so it is not shown.
struct LibraryFacts: Equatable, Sendable {
    var minutes: Double?
    var minutesEstimated = false
    var grams: Double?
    var gramsEstimated = false
    var price: Double?

    var isEmpty: Bool { minutes == nil && grams == nil && price == nil }

    /// The mesh estimate, unless the mesh is bigger than every printer the
    /// shop has a bed for. A model that fits no machine is either measured
    /// at the wrong scale or not printable as it is, and either way "≈59h ·
    /// ≈2.1 kg" on its tile is a confident number about a print that will not
    /// happen. See `Shop.tooBigForEveryModelMachine`.
    static func usable(_ estimate: KhaytEngine.MeshEstimate?, tooBigEverywhere: Bool) -> KhaytEngine.MeshEstimate? {
        tooBigEverywhere ? nil : estimate
    }

    /// From the file alone: what its slicer recorded. No estimate, no price.
    static func sliced(_ file: LibraryFile) -> LibraryFacts {
        of(file, estimate: nil, price: nil)
    }

    static func of(_ file: LibraryFile, estimate: (grams: Double, hours: Double)?, price: Double?) -> LibraryFacts {
        var out = LibraryFacts()
        if let m = file.parsed?.printTimeMins, m > 0 {
            out.minutes = m
        } else if let e = estimate, e.hours > 0 {
            out.minutes = e.hours * 60
            out.minutesEstimated = true
        }
        let colourGrams = file.palette.reduce(0) { $0 + max(0, $1.grams ?? 0) }
        if let g = file.parsed?.filamentGrams, g > 0 {
            out.grams = g
        } else if colourGrams > 0 {
            out.grams = colourGrams
        } else if let e = estimate, e.grams > 0 {
            out.grams = e.grams
            out.gramsEstimated = true
        }
        if let price, price > 0 { out.price = price }
        return out
    }

    // MARK: Said

    /// "4h 32m · 57 g · 85 ⃁", with ≈ in front of a figure that is an estimate.
    /// Empty when there is nothing to say — the caller falls back to the old
    /// line (who made it, how often printed).
    @MainActor
    static func line(_ facts: LibraryFacts, words: Words, currency: String) -> String {
        var bits: [String] = []
        if let m = facts.minutes { bits.append(duration(m, words: words, approximate: facts.minutesEstimated)) }
        if let g = facts.grams { bits.append(weight(g, words: words, approximate: facts.gramsEstimated)) }
        if let p = facts.price { bits.append(price(p, currency: currency)) }
        return bits.joined(separator: " \u{00B7} ")
    }

    /// The print time as every other screen says it — `PrintFigures`, the
    /// inspector's and the machine cards' own (`PrinterWatch.spell`): "45m",
    /// "4h 32m", "6h 0m". One formatter, so a tile, the list and the model
    /// page never disagree about the same print.
    ///
    /// `approximate` puts ≈ in front, as the inspector does: in Arabic the
    /// mark takes the line's direction and sits beside the number on its
    /// leading side.
    @MainActor
    static func duration(_ minutes: Double, words: Words, approximate: Bool = false) -> String {
        (approximate ? "\u{2248}" : "") + PrintFigures.duration(minutes: max(1, minutes), words)
    }

    /// The weight as every other screen says it (`PrintFigures`): "57 g",
    /// "2.1 kg".
    @MainActor
    static func weight(_ grams: Double, words: Words, approximate: Bool = false) -> String {
        (approximate ? "\u{2248}" : "") + PrintFigures.weight(max(1, grams), words)
    }

    /// Whole when it is whole: a tile has no room for ".00".
    static func price(_ amount: Double, currency: String) -> String {
        let whole = amount.rounded() == amount
        return Money.quantity(amount, decimals: whole ? 0 : 2) + " " + Money.mark(currency)
    }
}

extension Shop {
    /// What each model's catalogue price is, by file id — only for a product
    /// made of that one file. Built once per change to the book.
    nonisolated static func pricesByFile(products: [JSONValue],
                                          finals: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for case .object(let product) in products {
            guard case .string(let id)? = product["id"], let final = finals[id], final > 0,
                  case .array(let parts)? = product["parts"], !parts.isEmpty else { continue }
            var only: String?
            var single = true
            for case .object(let part) in parts {
                guard case .string(let file)? = part["printFileId"], !file.isEmpty else { single = false; break }
                if only == nil { only = file } else if only != file { single = false; break }
            }
            // The first product in the catalogue's own order wins, so the
            // figure does not change with the order a dictionary iterates.
            if single, let only, out[only] == nil { out[only] = final }
        }
        return out
    }

    /// This model's facts, from the memo — worked out once per change to the
    /// book, the estimates or the catalogue, never per draw.
    func libraryFacts(_ file: LibraryFile) -> LibraryFacts {
        let memo = libraryMemo
        refreshFactsMemo()
        if let known = memo.facts[file.id] { return known }
        let e = LibraryFacts.usable(estimates[file.id], tooBigEverywhere: tooBigForEveryModelMachine(file))
        let made = LibraryFacts.of(file, estimate: e.map { ($0.grams, $0.hours) },
                                   price: memo.prices[file.id])
        memo.facts[file.id] = made
        memo.work.factBuilds += 1
        return made
    }

    /// The tile's second line, in this shop's words — kept per model per
    /// language, so a scroll back up the grid formats nothing.
    func libraryFactsLine(_ file: LibraryFile) -> String {
        let memo = libraryMemo
        refreshFactsMemo()
        let language = words.language + "|" + currency
        if memo.factLinesLanguage != language {
            memo.factLinesLanguage = language
            memo.factLines = [:]
        }
        if let known = memo.factLines[file.id] { return known }
        let said = LibraryFacts.line(libraryFacts(file), words: words, currency: currency)
        memo.factLines[file.id] = said
        return said
    }

    /// Is this model bigger than every 3D printer the shop has a bed for?
    ///
    /// The shared rule (`ModelReadiness`, the inspector's own), over the
    /// machines that print in three dimensions (`modelMachines` — not the
    /// laser or the UV flatbed). False when no bed is known or there is no
    /// mesh: unknown is not a refusal.
    func tooBigForEveryModelMachine(_ file: LibraryFile) -> Bool {
        guard let mesh = file.mesh else { return false }
        let bounds = ModelReadiness.bounds(x: mesh.x, y: mesh.y, z: mesh.z)
        let states = modelMachines.compactMap { machine -> ModelReadiness.State? in
            guard let bed = bed(of: machine.id) else { return nil }
            return ModelReadiness.state(bounds: bounds, bed: bed, spoolsReady: nil)
        }
        return !states.isEmpty && states.allSatisfy { $0 == .tooBig }
    }

    /// The machine rows a model's fit is asked of: those that build in three
    /// dimensions, by the same rule as `modelMachines`. A machine whose kind
    /// is not known yet counts as a printer, as it does there.
    nonisolated static func modelMachineRows(_ rows: [JSONValue],
                                             kinds: [String: KhaytEngine.MachineKind]) -> [JSONValue] {
        rows.filter { row in
            guard let id = recordId(row) else { return true }
            return ["fdm", "resin"].contains(kinds[id]?.kind ?? "fdm")
        }
    }

    /// What the facts were made from. Read here so SwiftUI follows them.
    func libraryFactsKey() -> [Int] {
        _ = estimates.count
        _ = fits.count
        _ = machineKinds.count
        _ = catalogueRows.count
        return [filesRevision, libraryDerivedRevision, bookRevision]
    }

    private func refreshFactsMemo() {
        let key = libraryFactsKey()
        let memo = libraryMemo
        guard memo.factsKey != key else { return }
        memo.factsKey = key
        memo.facts = [:]
        memo.factLines = [:]
        let finals = Dictionary(catalogueRows.map { ($0.id, $0.final) }, uniquingKeysWith: { a, _ in a })
        memo.prices = Self.pricesByFile(products: productRows, finals: finals)
    }
}

// MARK: - The picture's ground and its placeholder

enum LibraryTile {
    /// The surface a model's picture sits on — the token both the drawn
    /// placeholder and a rendered preview (its white keyed out, see
    /// `ThumbnailStore.matte`) are laid on. A step off the window's warm
    /// ground in each appearance, so a tile reads as a tile without a border.
    static let well = Khayt.adaptive(light: 0xE4DFD5, dark: 0x24211C, name: "khaytLibraryWell")
}

/// A model with no picture yet: a build plate, seen at the angle the slicers
/// draw it, with a printed block standing on it — tinted with the model's
/// first filament when the file says what that is.
///
/// It replaces a grey `cube.transparent`, which is the system's generic "3D"
/// and says nothing about a print shop. Quiet on purpose: a library half of
/// whose models are unsliced STLs must not be a wall of illustrations.
struct ModelPlaceholder: View {
    /// The first filament's colour, when known.
    var tint: Color?

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let ink = Color.primary
            ZStack {
                PlatePath()
                    .fill(ink.opacity(0.06))
                PlatePath()
                    .stroke(ink.opacity(0.16), lineWidth: max(0.75, s / 160))
                PlateGrid()
                    .stroke(ink.opacity(0.07), lineWidth: max(0.5, s / 260))
                BlockPath(face: .top)
                    .fill((tint ?? ink).opacity(tint == nil ? 0.10 : 0.55))
                BlockPath(face: .left)
                    .fill((tint ?? ink).opacity(tint == nil ? 0.16 : 0.75))
                BlockPath(face: .right)
                    .fill((tint ?? ink).opacity(tint == nil ? 0.22 : 0.9))
                BlockPath(face: .outline)
                    .stroke(ink.opacity(0.18), lineWidth: max(0.75, s / 180))
            }
            // Inset rather than sized: the drawing is the middle 62% of the
            // square, whatever the square is.
            .padding(.horizontal, (geo.size.width - s * 0.62) / 2)
            .padding(.vertical, (geo.size.height - s * 0.62) / 2)
        }
        .accessibilityHidden(true)
    }

    /// The plate: a rhombus in the lower part of the square.
    private struct PlatePath: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.42))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.70))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.70))
            p.closeSubpath()
            return p
        }
    }

    /// Two lines across the plate, the texture of a PEI sheet's grid.
    private struct PlateGrid: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let top = CGPoint(x: r.midX, y: r.minY + r.height * 0.42)
            let right = CGPoint(x: r.maxX, y: r.minY + r.height * 0.70)
            let bottom = CGPoint(x: r.midX, y: r.maxY)
            let left = CGPoint(x: r.minX, y: r.minY + r.height * 0.70)
            for t in [0.33, 0.66] {
                p.move(to: lerp(top, left, t)); p.addLine(to: lerp(right, bottom, t))
                p.move(to: lerp(top, right, t)); p.addLine(to: lerp(left, bottom, t))
            }
            return p
        }
        private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    enum Face { case top, left, right, outline }

    /// A small block standing in the middle of the plate.
    private struct BlockPath: Shape {
        let face: Face
        func path(in r: CGRect) -> Path {
            let w = r.width * 0.21, h = r.height * 0.105, lift = r.height * 0.24
            let cx = r.midX, base = r.minY + r.height * 0.70
            // Bottom diamond's corners, then the same lifted.
            let bl = CGPoint(x: cx - w, y: base), bb = CGPoint(x: cx, y: base + h), br = CGPoint(x: cx + w, y: base)
            let tl = CGPoint(x: bl.x, y: bl.y - lift), tb = CGPoint(x: bb.x, y: bb.y - lift)
            let tr = CGPoint(x: br.x, y: br.y - lift), tt = CGPoint(x: cx, y: base - h - lift)
            var p = Path()
            switch face {
            case .top: p.addLines([tl, tt, tr, tb]); p.closeSubpath()
            case .left: p.addLines([tl, tb, bb, bl]); p.closeSubpath()
            case .right: p.addLines([tb, tr, br, bb]); p.closeSubpath()
            case .outline:
                p.addLines([tl, tt, tr, br, bb, bl]); p.closeSubpath()
                p.move(to: tl); p.addLine(to: tb); p.addLine(to: tr)
                p.move(to: tb); p.addLine(to: bb)
            }
            return p
        }
    }
}

extension LibraryFile {
    /// The first filament's colour, for the placeholder.
    var firstColour: Color? {
        guard let rgb = palette.lazy.compactMap(\.rgb).first else { return nil }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
