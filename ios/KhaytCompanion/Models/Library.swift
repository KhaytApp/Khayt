import Foundation
import KhaytCore

/// One page of the shop's library, as `GET /api/library` answers it.
struct LibraryPage: Decodable, Equatable, Sendable {
    let total: Int
    let offset: Int
    let folders: [LibraryFolder]
    var items: [LibraryItem]
    /// How many models each Colour and File type row would find
    /// (`LibraryFilter`). Nil from a Mac that cannot filter yet: the phone
    /// then hides both menus rather than guess from its version.
    var facets: LibraryFacets?
    /// The REACH of the two menus: without `q`, this folder and everything
    /// under it; with `q`, the search results. `unfilteredTotal` is every
    /// model in the reach (M of "N of M"), `matchedTotal` those that pass both
    /// menus (N). `total` only pages `items` — in a folder, the models filed
    /// directly in it — so it can be 0 while `matchedTotal` is not, and the
    /// page is then sub-folders only. Both come with `facets`.
    var unfilteredTotal: Int?
    var matchedTotal: Int?
    /// N of "N of M": `matchedTotal`, or `total` from a Mac that sent facets
    /// without it.
    var shownTotal: Int { matchedTotal ?? total }
    /// Read from the phone's copy because the Mac could not be reached.
    var fromCopy = false

    private enum CodingKeys: String, CodingKey { case total, offset, folders, items, facets, unfilteredTotal, matchedTotal }

    init(total: Int, offset: Int, folders: [LibraryFolder], items: [LibraryItem],
         facets: LibraryFacets? = nil, unfilteredTotal: Int? = nil, matchedTotal: Int? = nil) {
        self.total = total; self.offset = offset; self.folders = folders; self.items = items
        self.facets = facets; self.unfilteredTotal = unfilteredTotal; self.matchedTotal = matchedTotal
    }

    /// Lenient per record: one model the phone cannot read is left out, not
    /// the whole page.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items = (try? c.decode([Lenient<LibraryItem>].self, forKey: .items))?.compactMap(\.value) ?? []
        self.items = items
        folders = (try? c.decode([Lenient<LibraryFolder>].self, forKey: .folders))?.compactMap(\.value) ?? []
        total = (try? c.decode(Int.self, forKey: .total)) ?? items.count
        offset = (try? c.decode(Int.self, forKey: .offset)) ?? 0
        facets = try? c.decodeIfPresent(LibraryFacets.self, forKey: .facets)
        unfilteredTotal = (try? c.decodeIfPresent(Int.self, forKey: .unfilteredTotal)).flatMap { $0 }
        matchedTotal = (try? c.decodeIfPresent(Int.self, forKey: .matchedTotal)).flatMap { $0 }
    }
}

private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct LibraryFolder: Decodable, Equatable, Hashable, Sendable, Identifiable {
    let path: String
    let name: String
    let count: Int
    var id: String { path }

    private enum CodingKeys: String, CodingKey { case path, name, count }

    init(path: String, name: String, count: Int) { self.path = path; self.name = name; self.count = count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = (try? c.decode(String.self, forKey: .name)) ?? path.split(separator: "/").last.map(String.init) ?? path
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

struct LibraryItem: Decodable, Equatable, Hashable, Sendable, Identifiable {
    struct Plate: Decodable, Equatable, Hashable, Sendable, Identifiable {
        let index: Int
        let name: String?
        let printTimeMins: Double?
        let grams: Double?
        var id: Int { index }
    }

    let id: String
    let name: String
    let folder: String?
    let category: String?
    let tags: [String]
    let material: String?
    let ext: String?
    let favorite: Bool
    let timesPrinted: Int?
    let lastPrinted: String?
    var thumb: Bool
    let estimable: Bool
    let printTimeMins: Double?
    let grams: Double?
    let plates: [Plate]
    let testedNotes: String?
    /// A new version the Mac has not measured yet (`figuresStaleFor`), as
    /// the phone's copy reads it.
    let figuresStale: Bool
    /// The colours it was sliced with, as hex (`colors: [{hex, grams}]`).
    let colors: [String]
    /// Its File type row (`ModelFileType`). The Mac's answer says only `ext`,
    /// so a model there without one reads as `nofile`; the phone's copy
    /// works it out from the whole record and sends `fileType`.
    let fileType: String

    /// Its Colour rows (`ColourFamily.tokens`): each family, `multi` for two
    /// or more, `none` for no colour on the record.
    var colourKeys: [String] { ColourFamily.tokens(ofHexes: colors) }

    private enum CodingKeys: String, CodingKey {
        case id, name, folder, category, tags, material, ext, favorite, timesPrinted, lastPrinted, thumb,
             estimable, printTimeMins, grams, plates, testedNotes, figuresStale, colors, fileType
    }

    private struct Swatch: Decodable {
        let hex: String?
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) { hex = s; return }
            enum K: String, CodingKey { case hex }
            hex = try? decoder.container(keyedBy: K.self).decode(String.self, forKey: .hex)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let title = (try? c.decode(String.self, forKey: .name))?.trimmingCharacters(in: .whitespaces) ?? ""
        name = title.isEmpty ? id : title
        func text(_ k: CodingKeys) -> String? {
            guard let v = try? c.decode(String.self, forKey: k), !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }
        folder = text(.folder); category = text(.category); material = text(.material)
        ext = text(.ext)?.lowercased(); lastPrinted = text(.lastPrinted); testedNotes = text(.testedNotes)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        favorite = (try? c.decode(Bool.self, forKey: .favorite)) ?? false
        timesPrinted = try? c.decode(Int.self, forKey: .timesPrinted)
        thumb = (try? c.decode(Bool.self, forKey: .thumb)) ?? false
        estimable = (try? c.decode(Bool.self, forKey: .estimable)) ?? false
        figuresStale = (try? c.decode(Bool.self, forKey: .figuresStale)) ?? false
        // A recorded 0 is a slicer that measured nothing, not a free print.
        func positive(_ k: CodingKeys) -> Double? { (try? c.decode(Double.self, forKey: k)).flatMap { $0 > 0 ? $0 : nil } }
        printTimeMins = positive(.printTimeMins)
        grams = positive(.grams)
        plates = ((try? c.decode([Lenient<Plate>].self, forKey: .plates)) ?? []).compactMap(\.value)
        colors = ((try? c.decode([Lenient<Swatch>].self, forKey: .colors)) ?? []).compactMap { $0.value?.hex }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let said = text(.fileType)?.lowercased(), ModelFileType(rawValue: said) != nil {
            fileType = said
        } else {
            fileType = ModelFileType.type(hasSourceFile: ext != nil, ext: ext, kind: nil, names: []).rawValue
        }
    }
}

/// `facets` in `GET /api/library`: for each Colour and each File type key, how
/// many models that row would find. Every key is meant to be there; one left
/// out reads as 0, an unknown one is dropped.
struct LibraryFacets: Decodable, Equatable, Sendable {
    var colour: [String: Int]
    var type: [String: Int]

    init(colour: [String: Int], type: [String: Int]) { self.colour = colour; self.type = type }

    private enum CodingKeys: String, CodingKey { case colour, type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func counts(_ k: CodingKeys, _ keys: [String]) throws -> [String: Int] {
            let raw = try c.decode([String: Lenient<Double>].self, forKey: k)
            var out: [String: Int] = [:]
            for key in keys { out[key] = raw[key]?.value.map { max(0, Int($0)) } ?? 0 }
            return out
        }
        colour = try counts(.colour, LibraryFilter.colourKeys)
        type = try counts(.type, LibraryFilter.typeKeys)
    }
}
