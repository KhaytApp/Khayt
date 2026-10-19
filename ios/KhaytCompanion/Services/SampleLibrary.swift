import Foundation

/// The sample shop's library, kept on the phone: there is no Mac to ask. The
/// same search and folder rules as `GET /api/library` (`docs/LAN_API.md`), so
/// the screen reads it exactly as it reads a real shop's.
enum SampleLibrary {
    static let items: [LibraryItem] = {
        let json = #"""
        [
          {"id":"PF-sample-lantern","name":"Lantern","folder":"Home/Lighting","category":"Decor","tags":["gift","multicolour"],"material":"PLA Silk","ext":"3mf","favorite":true,"timesPrinted":6,"lastPrinted":"2026-08-12","thumb":false,"estimable":true,"printTimeMins":318,"grams":154,"plates":[{"index":1,"name":"Body","printTimeMins":205,"grams":112},{"index":2,"name":"Cap","printTimeMins":113,"grams":42}],"testedNotes":"Silk PLA at 220. Glue stick on the cap plate."},
          {"id":"PF-sample-vase","name":"Spiral vase","folder":"Home","category":"Decor","tags":["vase mode"],"material":"PLA","ext":"3mf","favorite":false,"timesPrinted":2,"lastPrinted":"2026-07-30","thumb":false,"estimable":true,"printTimeMins":214,"grams":52},
          {"id":"PF-sample-dallah","name":"Dallah coffee pot","folder":"Gifts","category":"Gifts","tags":["ramadan","gift"],"material":"PETG","ext":"3mf","favorite":true,"timesPrinted":4,"thumb":false,"estimable":true,"printTimeMins":412,"grams":146.3},
          {"id":"PF-sample-king-1","name":"KING Abdulaziz — relief 200mm","folder":"Saudi Kings","category":"Wall art","tags":["relief","portrait"],"material":"PLA+ 2.0","ext":"3mf","favorite":true,"timesPrinted":7,"lastPrinted":"2026-08-12","thumb":false,"estimable":true,"testedNotes":"Bed at 65. The first layer on the beard lifts if the plate is not clean."},
          {"id":"PF-sample-falcon","name":"Falcon hood","folder":"Gifts","category":"Gifts","tags":["falconry"],"material":"TPU 95A","ext":"stl","favorite":false,"timesPrinted":12,"thumb":false,"estimable":true},
          {"id":"PF-sample-bracket","name":"Shelf bracket","folder":"Parts","category":"Functional","tags":["engineering"],"material":"PA-CF","ext":"stl","favorite":false,"timesPrinted":2,"thumb":false,"estimable":true},
          {"id":"PF-sample-gripper","name":"Soft gripper","folder":"Parts","category":"Functional","tags":["flexible"],"material":"TPU 95A","ext":"step","favorite":false,"timesPrinted":0,"thumb":false,"estimable":false}
        ]
        """#
        return (try? JSONDecoder().decode([LibraryItem].self, from: Data(json.utf8))) ?? []
    }()

    static func page(query: String, folder: String, offset: Int = 0, limit: Int = 50) -> LibraryPage {
        page(items, query: query, folder: folder, offset: offset, limit: limit)
    }

    /// Any library held on the phone, paged as the Mac pages it.
    static func page(_ items: [LibraryItem], query: String, folder: String, offset: Int = 0, limit: Int = 50) -> LibraryPage {
        let (folders, found) = search(items, query: query, folder: folder)
        let slice = Array(found.dropFirst(offset).prefix(limit))
        return LibraryPage(total: found.count, offset: offset, folders: folders, items: slice)
    }

    /// Every word must appear in the name, folder, tags or category, ignoring
    /// case and diacritics. Without words: the models directly in `folder`,
    /// and its immediate sub-folders with how many models sit under each.
    static func search(_ all: [LibraryItem], query: String, folder: String) -> ([LibraryFolder], [LibraryItem]) {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        let order: (LibraryItem, LibraryItem) -> Bool = { a, b in
            a.favorite != b.favorite ? a.favorite : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if !words.isEmpty {
            let hits = all.filter { item in
                let hay = fold(([item.name, item.folder ?? "", item.category ?? ""] + item.tags).joined(separator: " "))
                return words.allSatisfy { hay.contains($0) }
            }
            return ([], hits.sorted(by: order))
        }
        let here = all.filter { ($0.folder ?? "") == folder }.sorted(by: order)
        let prefix = folder.isEmpty ? "" : folder + "/"
        var counts: [String: Int] = [:]
        for item in all {
            guard let f = item.folder, f.hasPrefix(prefix), f != folder else { continue }
            let child = f.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
            if !child.isEmpty { counts[prefix + child, default: 0] += 1 }
        }
        let folders = counts.map { LibraryFolder(path: $0.key, name: String($0.key.dropFirst(prefix.count)), count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (folders, here)
    }
}
