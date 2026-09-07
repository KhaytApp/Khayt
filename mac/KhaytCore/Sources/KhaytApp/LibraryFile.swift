import Foundation

/// One model in the shop's print library.
///
/// Decoded leniently, like `Order`, and for the same reason: this store is
/// written by the Electron app and a newer build will add fields. It is also
/// loose in its own right — `timesPrinted` and `lastPrinted` are absent on a
/// model that has never run, `setups` on most, `slicerProfileId` is null
/// throughout, and `createdAt` is a number on some records and a string on
/// others, which is why nothing here reads it.
struct LibraryFile: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let name: String
    let originalName: String?
    let updatedAt: String?
    let sourceFile: SourceFile?
    let parsed: Parsed?
    let colors: [Colour]?
    let swapCount: Int?
    let thumbFile: String?
    /// A `data:image/jpeg;base64,…` URI, inline in the store — not a path. A
    /// shop that has photographed a print carries the photo in `khayt-store.json`
    /// itself, which is most of why that file is large.
    let userPhoto: String?
    let testedNotes: String?
    let tags: [String]?
    /// The shop's own grouping, under the name the field has had since
    /// 3.7.0-beta.25. Records written by any earlier build carry only `folder`,
    /// and `assign()` writes both, so both are read.
    let group: String?
    /// What `group` used to be called. Nothing was migrated, deliberately.
    let folder: String?
    let material: String?
    let favorite: Bool?
    /// SHA-256 of the file's bytes.
    ///
    /// The CERTAIN half of `lib/model-identity.js`'s pair — "the bytes are
    /// identical. Same file." — against `geometryKey` below, which that module
    /// calls "a STRONG HINT and nothing more". Read because adding a model has
    /// to be able to say "you already have this", and that answer may only come
    /// from the hash.
    let contentHash: String?
    /// `triangles:volumeMm3:XxYxZ`, composed by `lib/model-identity.js`.
    let geometryKey: String?
    /// Where the model came from — a URL, a designer, or "my own design".
    let source: String?
    /// What its licence lets a shop do. `lib/model-licence.js` reads it; this
    /// only carries it.
    let licence: String?
    let timesPrinted: Int?
    let lastPrinted: String?

    struct SourceFile: Decodable, Hashable, Sendable {
        let filename: String?
        let originalName: String?
        let size: Double?
        let ext: String?
        let kind: String?
    }

    struct Parsed: Decodable, Hashable, Sendable {
        let printTimeMins: Double?
        let filamentGrams: Double?
        let filamentType: String?
        let slicer: String?
    }

    struct Colour: Decodable, Hashable, Sendable {
        let hex: String?
        let grams: Double?
        let label: String?
    }

    // MARK: - What the screen asks for

    var title: String { name.isEmpty ? (originalName ?? id) : name }
    var isFavourite: Bool { favorite == true }
    var printCount: Int { timesPrinted ?? 0 }
    var swaps: Int { swapCount ?? 0 }
    var palette: [Colour] { colors ?? [] }

    /// The group this model belongs to, or nil for ungrouped.
    ///
    /// **The PRESENCE of `folder` decides, not whether it holds anything.** A
    /// shop clearing the box on the older build leaves `folder: ''`, and that
    /// empty string is the instruction — falling back to `group` there would
    /// bring back the name they had just deleted. Only a record with no
    /// `folder` key at all falls through, which is what a product is.
    ///
    /// `folder` winning at all is a sync decision, not an accident: sync merges
    /// whole records last-writer-wins, and the older build's dialog writes only
    /// `folder`. Held to `KhaytOrganise.groupOf` by `OrganiseParityTests`.
    var groupName: String? { Self.groupName(folder: folder, group: group) }

    /// Split out from the property so the parity test can exercise the real
    /// rule. A test that restates the logic proves only that I can write it
    /// twice — and the first version of that test did exactly that, agreeing
    /// with a mistake.
    static func groupName(folder: String?, group: String?) -> String? {
        let name = normalise(folder != nil ? folder : group)
        return name.isEmpty ? nil : name
    }

    /// `String(raw).replace(/\s+/g, ' ').trim().slice(0, 60).trim()`, exactly.
    ///
    /// Deliberately does NOT strip control characters, though a NUL in a field
    /// like this has caused trouble elsewhere in Khayt. Whatever the two apps do
    /// here they must do identically, and JavaScript's `\s` does not match NUL —
    /// so neither does this. Divergence would file a model under one name here
    /// and another in the app beside it.
    static func normalise(_ raw: String?) -> String {
        guard let raw else { return "" }
        var out = String.UnicodeScalarView()
        var pendingSpace = false, started = false
        for scalar in raw.unicodeScalars {
            if Self.jsWhitespace.contains(scalar) {
                if started { pendingSpace = true }
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(scalar)
            started = true
        }
        // `.slice(0, 60)` counts UTF-16 code units, not Characters.
        let text = String(out)
        let units = Array(text.utf16)
        let cut = units.count <= 60 ? text : String(decoding: units.prefix(60), as: UTF16.self)
        return cut.trimmingCharacters(in: Self.jsWhitespaceSet)
    }

    /// The set JavaScript's `\s` matches. Written out rather than approximated
    /// with `.whitespacesAndNewlines`, which is close and not the same.
    static let jsWhitespace: Set<Unicode.Scalar> = [
        "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
        "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}",
        "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}",
        "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}",
        "\u{FEFF}",
    ]
    static let jsWhitespaceSet: CharacterSet = {
        var set = CharacterSet()
        for scalar in jsWhitespace { set.insert(scalar) }
        return set
    }()

    /// Bytes of the model file, if the record says.
    var size: Double? { sourceFile?.size }

    /// The mesh, unpacked from `geometryKey`. Nil for a model whose geometry was
    /// never measured — an unparsed upload, or one too large to open under the
    /// mesh budget.
    var mesh: Mesh? {
        guard let key = geometryKey else { return nil }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let tris = Int(parts[0]), let volume = Double(parts[1]) else { return nil }
        let dims = parts[2].split(separator: "x").compactMap { Double($0) }
        guard dims.count == 3 else { return nil }
        return Mesh(triangles: tris, volumeMm3: volume, x: dims[0], y: dims[1], z: dims[2])
    }

    struct Mesh: Hashable, Sendable {
        let triangles: Int
        let volumeMm3: Double
        let x: Double, y: Double, z: Double
    }
}

/// How the library is ordered.
///
/// The default is not "by name". `renderer/printfiles.js` sorts favourites
/// first and then most recently updated, and a shop that switches between the
/// two apps and finds its models in a different order has been given two
/// libraries. This app opens the same way round and offers the rest.
enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case khayt, name, size, lastPrinted, timesPrinted

    var id: String { rawValue }

    /// The key each one is named by, so the menu speaks the shop's language.
    var key: String {
        switch self {
        case .khayt: "mac.sort_default"
        case .name: "mac.name"
        case .size: "set.store_size"
        case .lastPrinted: "mac.last_run"
        case .timesPrinted: "mac.printed"
        }
    }

    func order(_ a: LibraryFile, _ b: LibraryFile) -> Bool {
        switch self {
        case .khayt:
            if a.isFavourite != b.isFavourite { return a.isFavourite }
            return (a.updatedAtDate ?? .distantPast) > (b.updatedAtDate ?? .distantPast)
        case .name:
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        case .size:
            // Biggest first: the reason to sort by size is to find what is
            // filling the disk, not to admire the small ones.
            return (a.size ?? 0) > (b.size ?? 0)
        case .lastPrinted:
            return (a.lastPrintedDate ?? .distantPast) > (b.lastPrintedDate ?? .distantPast)
        case .timesPrinted:
            if a.printCount != b.printCount { return a.printCount > b.printCount }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

extension LibraryFile {
    var updatedAtDate: Date? { Order.day(updatedAt) }
    var lastPrintedDate: Date? { Order.day(lastPrinted) }
}

extension LibraryFile.Colour {
    /// The swatch colour. An unparseable or absent hex shows as nothing rather
    /// than as black, which would read as a real filament choice.
    var rgb: (r: Double, g: Double, b: Double)? { Swatch.rgb(fromHex: hex) }
}
