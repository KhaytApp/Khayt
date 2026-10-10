import Foundation
import KhaytCore

/// The shop's models, read for an assistant to ask about.
///
/// ── WHAT THIS DELIBERATELY CANNOT SEE ─────────────────────────────────────
///
/// The library, and nothing else. Not a customer, not a price, not an invoice,
/// not a payment, not the shop's own contact details. Khayt's book holds all
/// of that in one file, and a server that reads the file could just as easily
/// answer "what is Nouf's phone number" — so what the LIBRARY tools can answer
/// is decided HERE, once, by never lifting anything else out of the book.
///
/// The books tools are `Books`, a separate reader with its own, deliberately
/// chosen fields: money and customer NAMES, read through the shared rules, and
/// still never a phone, an email, an address or a secret.
///
/// READ-ONLY, and it never opens the store for writing. Khayt may be running
/// and holding the lock; nothing here cares, because nothing here changes
/// anything.
struct Library: Sendable {

    struct Model: Sendable, Codable {
        let id: String
        let title: String
        /// The project it is filed under, if any.
        let group: String?
        let category: String?
        let tags: [String]
        let material: String?
        /// Who made it — read out of the model file, or typed by the shop.
        let designer: String?
        /// The licence id Khayt recognises, if one was recorded.
        let licence: String?
        /// Whether a print of this may be SOLD. Nil is NOT a no: it is nobody
        /// having said, which the rest of Khayt is careful to keep distinct.
        let sellable: Bool?
        let timesPrinted: Int
        let lastPrinted: String?
        let sizeBytes: Int?
        let fileKind: String?
    }

    let models: [Model]

    /// Khayt's own book, where Khayt keeps it.
    static func storeURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/khayt/khayt-store.json")
    }

    /// The book's bytes, READ ONLY. A primary that will not parse beside a
    /// `.prev` that does — what an interrupted save leaves — is answered from
    /// the `.prev`, as the app opens it, but nothing is copied or repaired
    /// here: putting the file back is the app's job, under its lock.
    static func bookData(at url: URL = storeURL()) throws -> Data {
        let data = try Data(contentsOf: url)
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        if let older = try? Data(contentsOf: url.appendingPathExtension("prev")),
           (try? JSONSerialization.jsonObject(with: older)) != nil { return older }
        return data
    }

    static func read(from url: URL = storeURL()) throws -> Library {
        try read(data: bookData(at: url))
    }

    static func read(data: Data) throws -> Library {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let book = root as? [String: Any],
              let rows = book["printFiles"] as? [[String: Any]] else {
            return Library(models: [])
        }
        return Library(models: rows.compactMap(Self.model(from:)))
    }

    private static func model(from row: [String: Any]) -> Model? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        // A model a conversion replaced is put aside rather than deleted. It is
        // not one of the things a shop is choosing between today, so it is not
        // one of the things an assistant should offer.
        if let archived = row["archivedAt"] as? String, !archived.isEmpty { return nil }

        func text(_ key: String) -> String? {
            guard let s = row[key] as? String else { return nil }
            let tidy = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return tidy.isEmpty ? nil : tidy
        }
        let source = row["sourceFile"] as? [String: Any]
        let licence = text("licence")
        return Model(
            id: id,
            title: text("name") ?? text("originalName") ?? id,
            // `folder` if the key is there at all, then `group` — the rule the
            // grid files a model under. Splitting on `group` alone would report
            // a model under one project and draw it in another.
            group: (row["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text("group"),
            category: text("category"),
            tags: (row["tags"] as? [String])?.filter { !$0.isEmpty } ?? [],
            material: text("material"),
            designer: text("source"),
            licence: licence,
            sellable: ModelLicence.sellable(licence),
            timesPrinted: (row["timesPrinted"] as? Int) ?? 0,
            lastPrinted: text("lastPrinted"),
            sizeBytes: source?["size"] as? Int,
            fileKind: (source?["ext"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() })
    }
}

extension Library.Model {
    /// Everything about this model a search should look at, folded once.
    var haystack: String {
        ([title, group, category, material, designer, licence] + tags)
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }
}
