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
/// still never a phone, an email, an address or a secret. A customer's name
/// typed into a model's title, project or tags is replaced the same way the
/// books tools replace it, unless the shop shares names (`CustomerNames`), and
/// a phone, email or IBAN typed there is taken out whatever the setting
/// (`Outgoing`).
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
    /// These models as an assistant may read them: every free text in them —
    /// title, project, category, tags, material, designer — through
    /// `Outgoing`, so a customer's name becomes its label (unless the shop
    /// shares names) and a phone, an email, an IBAN or a long number typed
    /// into any of them is taken out whatever the setting. One crossing into
    /// the rules for the whole library. The licence is an SPDX-like id, not a
    /// person.
    static func cleaned(_ models: [Library.Model], _ out: Outgoing) async -> [Library.Model] {
        var texts: [String] = []
        for m in models {
            texts.append(m.title)
            texts.append(contentsOf: [m.group, m.category, m.material, m.designer].map { $0 ?? "" })
            texts.append(contentsOf: m.tags)
        }
        var clean = await out.clean(texts).makeIterator()
        func next() -> String { clean.next() ?? CustomerNames.redacted }
        func optional(_ v: String?) -> String? { let c = next(); return v == nil ? nil : c }
        return models.map { m in
            let title = next()
            let group = optional(m.group), category = optional(m.category)
            let material = optional(m.material), designer = optional(m.designer)
            let tags = m.tags.map { _ in next() }
            return Library.Model(
                id: m.id, title: title, group: group, category: category, tags: tags,
                material: material, designer: designer, licence: m.licence,
                sellable: m.sellable, timesPrinted: m.timesPrinted, lastPrinted: m.lastPrinted,
                sizeBytes: m.sizeBytes, fileKind: m.fileKind)
        }
    }

    /// Everything about this model a search should look at, folded once.
    var haystack: String {
        ([title, group, category, material, designer, licence] + tags)
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }
}
