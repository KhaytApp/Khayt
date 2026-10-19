import Foundation

/// One page of the shop's library, as `GET /api/library` answers it.
struct LibraryPage: Decodable, Equatable, Sendable {
    let total: Int
    let offset: Int
    let folders: [LibraryFolder]
    let items: [LibraryItem]

    private enum CodingKeys: String, CodingKey { case total, offset, folders, items }

    init(total: Int, offset: Int, folders: [LibraryFolder], items: [LibraryItem]) {
        self.total = total; self.offset = offset; self.folders = folders; self.items = items
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
    let thumb: Bool
    let estimable: Bool
    let printTimeMins: Double?
    let grams: Double?
    let plates: [Plate]
    let testedNotes: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, folder, category, tags, material, ext, favorite, timesPrinted, lastPrinted, thumb,
             estimable, printTimeMins, grams, plates, testedNotes
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
        // A recorded 0 is a slicer that measured nothing, not a free print.
        func positive(_ k: CodingKeys) -> Double? { (try? c.decode(Double.self, forKey: k)).flatMap { $0 > 0 ? $0 : nil } }
        printTimeMins = positive(.printTimeMins)
        grams = positive(.grams)
        plates = ((try? c.decode([Lenient<Plate>].self, forKey: .plates)) ?? []).compactMap(\.value)
    }
}
