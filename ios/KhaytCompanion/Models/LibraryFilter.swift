import Foundation
import KhaytCore

/// The library's two filter menus, Colour and File type, as the phone asks
/// for them and — for the libraries it holds itself — answers them.
///
/// ── THE CONTRACT (`GET /api/library?…&colour=blue,black&type=3mf,stl`) ────
///
/// - OR within a menu, AND across the two menus and with `q` and `folder`.
/// - Colour keys are `ColourFamily.tokens` (eleven families, then `multi` and
///   `none`); a model with two or more families is under each AND `multi`.
///   File type keys are `ModelFileType` (`3mf stl step obj gcode other
///   nofile`). Unknown keys are ignored; an empty choice narrows nothing.
/// - `facets` counts every key of each menu over `q` + `folder` + the OTHER
///   menu's choice — never its own, so a row's count is what ticking it
///   would add.
///
/// The rule for which family a colour is in, and which type a file is, is
/// KhaytCore's (`ColourFamily`, `ModelFileType`), ports of the lib files the
/// Mac and the desktop run. Nothing here decides either.
struct LibraryFilter: Equatable, Hashable, Sendable {
    var colours: Set<String> = []
    var types: Set<String> = []

    static let colourKeys = ColourFamily.tokens
    static let typeKeys = ModelFileType.allCases.map(\.rawValue)

    init(colours: Set<String> = [], types: Set<String> = []) {
        self.colours = colours.intersection(Self.colourKeys)
        self.types = types.intersection(Self.typeKeys)
    }

    var isEmpty: Bool { colours.isEmpty && types.isEmpty }

    /// The chosen keys in menu order, as the query sends them; nil for none.
    var colourParam: String? { Self.joined(colours, Self.colourKeys) }
    var typeParam: String? { Self.joined(types, Self.typeKeys) }

    /// The picks in menu order, for the pills.
    var orderedColours: [String] { Self.colourKeys.filter(colours.contains) }
    var orderedTypes: [String] { Self.typeKeys.filter(types.contains) }

    private static func joined(_ picks: Set<String>, _ order: [String]) -> String? {
        let keys = order.filter(picks.contains)
        return keys.isEmpty ? nil : keys.joined(separator: ",")
    }

    /// `colour=…;type=…` (the debug launch flag) or a query's two values:
    /// comma-separated keys, any case, unknown ones dropped.
    static func keys(_ raw: String?, among order: [String]) -> Set<String> {
        guard let raw else { return [] }
        let said = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return Set(said).intersection(order)
    }

    init(launchFlag: String) {
        var c: Set<String> = [], t: Set<String> = []
        for part in launchFlag.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].trimmingCharacters(in: .whitespaces).lowercased() {
            case "colour", "color": c = Self.keys(kv[1], among: Self.colourKeys)
            case "type": t = Self.keys(kv[1], among: Self.typeKeys)
            default: break
            }
        }
        self.init(colours: c, types: t)
    }

    /// The query items of one `GET /api/library`, with the two menus only
    /// when something is chosen in them.
    static func queryItems(query: String, folder: String, offset: Int, limit: Int,
                           filter: LibraryFilter) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "folder", value: folder),
                     URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))]
        if let c = filter.colourParam { items.append(URLQueryItem(name: "colour", value: c)) }
        if let t = filter.typeParam { items.append(URLQueryItem(name: "type", value: t)) }
        return items
    }

    // MARK: - Answering it on the phone

    func matchesColour(_ item: LibraryItem) -> Bool {
        colours.isEmpty || item.colourKeys.contains(where: colours.contains)
    }

    func matchesType(_ item: LibraryItem) -> Bool {
        types.isEmpty || types.contains(item.fileType)
    }

    func matches(_ item: LibraryItem) -> Bool { matchesColour(item) && matchesType(item) }

    /// Each menu counted over `found` (already narrowed by `q` and `folder`)
    /// and the other menu's choice. Every key is present, zeros too.
    func facets(_ found: [LibraryItem]) -> LibraryFacets {
        var colour = Dictionary(uniqueKeysWithValues: Self.colourKeys.map { ($0, 0) })
        var type = Dictionary(uniqueKeysWithValues: Self.typeKeys.map { ($0, 0) })
        for item in found {
            if matchesType(item) { for k in item.colourKeys { colour[k, default: 0] += 1 } }
            if matchesColour(item) { type[item.fileType, default: 0] += 1 }
        }
        return LibraryFacets(colour: colour, type: type)
    }
}
