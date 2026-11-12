import Foundation

/// Which colour FAMILY a filament colour belongs to — red, orange, yellow,
/// green, blue, purple, pink, brown, black, grey or white — and which Colour
/// filter rows a model is found under.
///
/// ── A PORT, HELD TO THE ORIGINAL ──────────────────────────────────────────
///
/// The rule is `lib/colour-family.js`, which the desktop and the iPhone will
/// read too; its header says where every threshold is and why they are set in
/// HSL. This is that file in Swift, and `ColourFamilyParityTests` runs the two
/// over the whole colour cube and refuses a difference.
///
/// Native rather than asked of the engine because the library's matcher is
/// synchronous and runs over every model per keystroke
/// (`Shop.libraryAxisMisses`), and the engine is an actor. The arithmetic is
/// only + − × ÷ on the 8-bit channels, in the same order as the JavaScript,
/// which IEEE 754 fixes bit for bit — so the two cannot round apart at a
/// boundary.
public enum ColourFamily: String, CaseIterable, Sendable, Hashable {
    case red, orange, yellow, green, blue, purple, pink, brown, black, grey, white

    /// A model with two or more different families.
    public static let multi = "multi"
    /// A model with no readable colour on its record.
    public static let none = "none"

    /// Every id the Colour filter can hold, in menu order.
    public static let tokens: [String] = allCases.map(\.rawValue) + [multi, none]

    /// One typical colour for the swatch beside the name (`SWATCH` in the
    /// lib). Drawn, never matched against.
    public var swatchHex: String {
        switch self {
        case .red: "#D92D20"
        case .orange: "#F28C28"
        case .yellow: "#F2C811"
        case .green: "#2E9E4F"
        case .blue: "#2F6FDE"
        case .purple: "#7F56D9"
        case .pink: "#F27EB2"
        case .brown: "#8B5A2B"
        case .black: "#1A1A1A"
        case .grey: "#9AA0A6"
        case .white: "#FFFFFF"
        }
    }

    /// `(r, g, b)`, 0–255, from a hex colour: 3 or 6 digits, with or without
    /// '#', any case, spaces around it ignored; the alpha of a 4- or 8-digit
    /// one is dropped. Nil for anything else.
    public static func rgb(ofHex hex: String?) -> (r: Int, g: Int, b: Int)? {
        guard let hex else { return nil }
        var s = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "#" { s = s.dropFirst() }
        var digits: [Int] = []
        digits.reserveCapacity(8)
        for c in s.unicodeScalars {
            // ASCII only: `hexDigitValue` also reads full-width digits, which
            // the JavaScript's [0-9a-fA-F] does not.
            guard c.isASCII, let v = Character(c).hexDigitValue else { return nil }
            digits.append(v)
            if digits.count > 8 { return nil }
        }
        switch digits.count {
        case 3, 4: return (digits[0] * 17, digits[1] * 17, digits[2] * 17)
        case 6, 8: return (digits[0] * 16 + digits[1], digits[2] * 16 + digits[3], digits[4] * 16 + digits[5])
        default: return nil
        }
    }

    /// The family of one colour given as channels 0–255 (`familyOfRgb`).
    public static func family(r: Int, g: Int, b: Int) -> ColourFamily {
        let hi = max(r, g, b), lo = min(r, g, b)
        let spread = hi - lo
        let sum = hi + lo
        let light = Double(sum) / 510
        if light < 0.10 { return .black }
        if light > 0.93 { return .white }
        let sat = spread == 0 ? 0 : Double(spread) / Double(255 - abs(sum - 255))
        let wash = hi == 0 ? 0 : Double(spread) / Double(hi)
        if sat < 0.15 || wash < 0.12 || spread < 24 {
            if light < 0.20 { return .black }
            if light > 0.85 { return .white }
            return .grey
        }
        var hue: Double
        if hi == r { hue = 60 * (Double(g - b) / Double(spread)) }
        else if hi == g { hue = 60 * (Double(b - r) / Double(spread)) + 120 }
        else { hue = 60 * (Double(r - g) / Double(spread)) + 240 }
        if hue < 0 { hue += 360 }

        if hue >= 345 || hue < 14 {
            if light >= 0.72 { return .pink }
            if wash < 0.45 && light >= 0.55 { return .pink }
            if wash < 0.50 && light < 0.45 { return .brown }
            return .red
        }
        if hue < 50 {
            if light < 0.42 { return .brown }
            if wash < 0.45 && light < 0.85 { return .brown }
            return hue < 42 ? .orange : .yellow
        }
        if hue < 70 { return light < 0.35 ? .green : .yellow }
        if hue < 188 { return .green }
        if hue < 255 { return .blue }
        if hue < 290 { return .purple }
        if hue < 320 { return light >= 0.60 ? .pink : .purple }
        if light >= 0.45 { return .pink }
        return hue < 335 ? .purple : .red
    }

    /// The family of one hex colour, or nil when it cannot be read.
    public static func family(ofHex hex: String?) -> ColourFamily? {
        rgb(ofHex: hex).map { family(r: $0.r, g: $0.g, b: $0.b) }
    }

    /// The families among a model's colours, each once, in menu order.
    public static func families(ofHexes hexes: [String?]) -> [ColourFamily] {
        var seen: Set<ColourFamily> = []
        for hex in hexes { if let f = family(ofHex: hex) { seen.insert(f) } }
        return allCases.filter(seen.contains)
    }

    /// The Colour filter ids a model is found under (`tokensOf`): each family
    /// it has, then `multi` when it has two or more DIFFERENT ones — or
    /// `[none]` when no colour on it can be read.
    public static func tokens(ofHexes hexes: [String?]) -> [String] {
        let found = families(ofHexes: hexes).map(\.rawValue)
        if found.isEmpty { return [none] }
        return found.count >= 2 ? found + [multi] : found
    }
}

/// What kind of file a library model is: 3MF, STL, STEP, OBJ, G-code,
/// something else, or no file at all — the File type filter's rows.
///
/// A port of `lib/model-file-type.js` (the rule, and why a `.gcode.3mf` is
/// G-code, are in its header), held to it by `ColourFamilyParityTests`.
public enum ModelFileType: String, CaseIterable, Sendable, Hashable {
    case threeMF = "3mf"
    case stl, step, obj, gcode, other
    case noFile = "nofile"

    private static let byExt: [String: ModelFileType] = [
        "3mf": .threeMF, "stl": .stl, "step": .step, "stp": .step, "obj": .obj,
        "gcode": .gcode, "gco": .gcode, "g": .gcode, "bgcode": .gcode,
    ]

    /// A name's extension, lower case, without the dot; "" when it has none.
    public static func ext(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
            .last.map(String.init) ?? ""
        let chars = Array(leaf)
        guard let dot = chars.lastIndex(of: "."), dot > 0, dot < chars.count - 1 else { return "" }
        return String(chars[(dot + 1)...]).lowercased()
    }

    /// The type of one model, from what its record holds. `hasSourceFile` is
    /// whether the record has a `sourceFile` object at all; `names` are, in
    /// order, `sourceFile.filename`, `sourceFile.originalName`,
    /// `archiveMember` and `externalPath`.
    public static func type(hasSourceFile: Bool, ext stated: String?, kind: String?,
                            names: [String?]) -> ModelFileType {
        let names = names.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !hasSourceFile && names.isEmpty { return .noFile }
        var given = (hasSourceFile ? stated ?? "" : "").trimmingCharacters(in: .whitespacesAndNewlines)
        if given.hasPrefix(".") { given.removeFirst() }
        given = given.lowercased()
        let ext = !given.isEmpty ? given : (names.first.map(Self.ext(of:)) ?? "")
        if byExt[ext] == .gcode { return .gcode }
        if hasSourceFile, (kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gcode" {
            return .gcode
        }
        if names.contains(where: { $0.lowercased().hasSuffix(".gcode.3mf") }) { return .gcode }
        return byExt[ext] ?? .other
    }

    /// The type of a record as the book holds it (`typeOf(record)`).
    public static func type(of record: JSONValue?) -> ModelFileType {
        guard case .object(let r)? = record else { return .noFile }
        func text(_ o: [String: JSONValue], _ k: String) -> String? {
            if case .string(let s)? = o[k] { return s }
            return nil
        }
        var source: [String: JSONValue]?
        if case .object(let sf)? = r["sourceFile"] { source = sf }
        return type(hasSourceFile: source != nil,
                    ext: source.flatMap { text($0, "ext") }, kind: source.flatMap { text($0, "kind") },
                    names: [source.flatMap { text($0, "filename") }, source.flatMap { text($0, "originalName") },
                            text(r, "archiveMember"), text(r, "externalPath")])
    }
}
