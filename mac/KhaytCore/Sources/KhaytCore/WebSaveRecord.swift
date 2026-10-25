import Foundation
import KhaytWebSave

/// A page saved from the browser, as a library record.
///
/// ── WHAT THE RECORD IS ────────────────────────────────────────────────────
///
/// A model the shop has found and not yet downloaded: a `printFiles` record
/// with NO `sourceFile` — the shape the book already allows for a model made
/// from a printer's own history (`renderer/printfiles.js` returns early on
/// one) — and these, every one of them already read by both apps:
///
///   name        the page's title. A TITLE, as `name` always is.
///   source      the creator, as an import writes the designer a file names.
///   licence     only when `ModelLicence.fromFile` can translate what the page
///               said; a platform's own terms stay "nobody has said".
///   tags        the page's, spelled the way the book already spells them.
///   printNextAt the Print next mark — Printventory's "Want" is this list.
///
/// and these, new, all under `source…` so they read as one thing:
///
///   sourceUrl         the page's canonical address
///   sourceSite        `printables`, `makerworld`, … or `web`
///   sourceLicenceText the licence as the page worded it
///   sourceNote        the page's description, cut short
///   sourceFiles       the model files the page links to, `{url, name}`
///   savedFromWebAt    when it was saved (ISO), and what "Saved from web" finds
///
/// ── THE SAME PAGE TWICE ───────────────────────────────────────────────────
///
/// Recognised by `WebSave.identity` against every record's `sourceUrl` — and
/// against `source`, where a shop typed a model-site address by hand before
/// there was a button for it. A second save UPDATES that record: the page's
/// own facts (`source…`) are brought up to date, and what the shop may have
/// changed — the title, the creator, the licence, a tag it removed — is only
/// ever filled where it is still blank. Archived records are matched too, so a
/// model put aside is not saved a second time beside itself.
public enum WebSaveRecord {

    public struct Outcome: Equatable, Sendable {
        public let id: String
        public let created: Bool
        /// The record has no picture yet, so the cover is worth fetching.
        public let wantsCover: Bool
    }

    /// The record `page` belongs to, if the book has one.
    public static func existing(_ page: WebSave.Page, in rows: [JSONValue]) -> String? {
        let want = WebSave.identity(of: page.url)
        var bySource: String?
        for case .object(let o) in rows {
            guard case .string(let id)? = o["id"] else { continue }
            if case .string(let url)? = o["sourceUrl"], WebSave.identity(of: url) == want { return id }
            if bySource == nil, case .string(let s)? = o["source"],
               let typed = WebSave.https(s), WebSave.identity(of: typed) == want { bySource = id }
        }
        return bySource
    }

    /// File `page` into `rows`: a new record under `newId`, or the one it
    /// already has brought up to date. `nowMs` is epoch milliseconds and
    /// `nowISO` the same moment as the store writes it.
    @discardableResult
    public static func apply(_ page: WebSave.Page, to rows: inout [JSONValue], newId: String,
                             nowMs: Double, nowISO: String) -> Outcome {
        var known: [JSONValue] = []
        for case .object(let o) in rows { if case .array(let t)? = o["tags"] { known += t } }
        let tags = Tags.normalise(.array(page.tags.map(JSONValue.string)), known: known)
        let licence = ModelLicence.fromFile(page.licence)?.id ?? ""

        if let id = existing(page, in: rows),
           let i = rows.firstIndex(where: { if case .object(let o) = $0, case .string(id)? = o["id"] { true } else { false } }),
           case .object(var record) = rows[i] {
            writeSource(page, into: &record, at: nowISO)
            func blank(_ key: String) -> Bool { text(record[key]).isEmpty }
            if blank("name") { record["name"] = .string(page.title) }
            if blank("source"), !page.creator.isEmpty { record["source"] = .string(page.creator) }
            // A typed address in `source` gives way to the creator: the
            // address now has its own field.
            else if let s = WebSave.https(text(record["source"])), WebSave.identity(of: s) == WebSave.identity(of: page.url),
                    !page.creator.isEmpty { record["source"] = .string(page.creator) }
            if blank("licence"), !licence.isEmpty { record["licence"] = .string(licence) }
            let had = Tags.normalise(record["tags"])
            if had.isEmpty, !tags.isEmpty { record["tags"] = .array(tags.map(JSONValue.string)) }
            if record["printNextAt"] == nil || record["printNextAt"] == .null {
                record["printNextAt"] = .string(nowISO)
            }
            StoreWriter.stamp(&record)
            rows[i] = .object(record)
            return Outcome(id: id, created: false, wantsCover: !hasPicture(record))
        }

        var record: [String: JSONValue] = [
            "id": .string(newId),
            "name": .string(page.title),
            "originalName": .string(""),
            "createdAt": .number(nowMs),
            "updatedAt": .string(nowISO),
            "parsed": .object([:]),
            "colors": .array([]),
            "swapCount": .number(0),
            "thumbFile": .null,
            "thumbSource": .null,
            "userPhoto": .null,
            "slicerProfileId": .null,
            "testedNotes": .string(""),
            "tags": .array(tags.map(JSONValue.string)),
            "material": .string(""),
            "source": .string(page.creator),
            "licence": .string(licence),
            "group": .string(""), "folder": .string(""),
            "favorite": .bool(false),
            "contentHash": .null,
            "geometryKey": .null,
            "printNextAt": .string(nowISO),
        ]
        writeSource(page, into: &record, at: nowISO)
        rows.insert(.object(record), at: 0)
        return Outcome(id: newId, created: true, wantsCover: true)
    }

    /// The page's own facts, which a later save always refreshes.
    static func writeSource(_ page: WebSave.Page, into record: inout [String: JSONValue], at: String) {
        record["sourceUrl"] = .string(page.url)
        record["sourceSite"] = .string(page.site.rawValue)
        func put(_ key: String, _ value: String) {
            if value.isEmpty { record.removeValue(forKey: key) } else { record[key] = .string(value) }
        }
        put("sourceLicenceText", page.licence)
        put("sourceNote", page.description)
        if page.files.isEmpty { record.removeValue(forKey: "sourceFiles") } else {
            record["sourceFiles"] = .array(page.files.map {
                .object(["url": .string($0.url), "name": .string($0.name)])
            })
        }
        record["savedFromWebAt"] = .string(at)
    }

    // MARK: - A download, attached

    /// The fields an import measures and a web record lacks: what the file
    /// is, where it went, and what it was read as.
    public static let fileFields: [String] = [
        "originalName", "sourceFile", "parsed", "externalPath", "colors", "swapCount",
        "thumbFile", "thumbSource", "contentHash", "geometryKey", "geometryReader", "printRisk",
    ]

    /// What attaching did: the record that now holds the file, and whether it
    /// is the saved page's own record or a new one beside it.
    public struct Attached: Equatable, Sendable {
        public let id: String
        public let intoSaved: Bool
        public init(id: String, intoSaved: Bool) { self.id = id; self.intoSaved = intoSaved }
    }

    /// Whether the saved record already has a file of its own.
    public static func hasFile(_ record: [String: JSONValue]) -> Bool {
        if case .object? = record["sourceFile"] { return true }
        return !text(record["externalPath"]).isEmpty
    }

    /// The record `id` in `rows`, if there is one.
    public static func record(_ id: String, in rows: [JSONValue]) -> [String: JSONValue]? {
        for case .object(let o) in rows { if case .string(id)? = o["id"] { return o } }
        return nil
    }

    /// Put an imported file (`imported`, the record `LibraryImport.prepare`
    /// made under `newId`) with the saved page `savedId`.
    ///
    /// While the saved record has no file yet, the file goes INTO it: the
    /// record keeps its id, title, creator, licence, tags, picture, Print next
    /// mark and everything it says about the page, and gains the file's own
    /// fields (`fileFields`) — the designer and licence the file names only
    /// where the page left them blank. Once it has a file (a second download
    /// from the same page), the import is a record of its own beside it,
    /// carrying the page's facts so it is found under Saved from web too.
    /// Nil when the saved record is gone.
    public static func attach(_ imported: [String: JSONValue], newId: String, to savedId: String,
                              in rows: inout [JSONValue]) -> Attached? {
        guard let i = rows.firstIndex(where: {
            if case .object(let o) = $0, case .string(savedId)? = o["id"] { true } else { false }
        }), case .object(var saved) = rows[i] else { return nil }

        if !hasFile(saved) {
            for key in fileFields {
                if let v = imported[key] { saved[key] = v } else { saved.removeValue(forKey: key) }
            }
            if text(saved["source"]).isEmpty, let v = imported["source"] { saved["source"] = v }
            if text(saved["licence"]).isEmpty, let v = imported["licence"] { saved["licence"] = v }
            if !hasPicture(saved), case .string(let p)? = imported["userPhoto"], p.hasPrefix("data:") {
                saved["userPhoto"] = .string(p)
            }
            StoreWriter.stamp(&saved)
            rows[i] = .object(saved)
            return Attached(id: savedId, intoSaved: true)
        }

        var record = imported
        record["id"] = .string(newId)
        for key in ["sourceUrl", "sourceSite", "sourceLicenceText", "sourceNote", "sourceFiles", "savedFromWebAt"] {
            if let v = saved[key] { record[key] = v }
        }
        if text(record["source"]).isEmpty, let v = saved["source"] { record["source"] = v }
        if text(record["licence"]).isEmpty, let v = saved["licence"] { record["licence"] = v }
        if case .array(let t)? = saved["tags"], !t.isEmpty, Tags.normalise(record["tags"]).isEmpty {
            record["tags"] = .array(t)
        }
        rows.insert(.object(record), at: 0)
        return Attached(id: newId, intoSaved: false)
    }

    /// Put the fetched cover on the record, unless it has a picture by now.
    public static func setCover(_ dataURI: String, id: String, in rows: inout [JSONValue]) -> Bool {
        guard dataURI.hasPrefix("data:image/") else { return false }
        for i in rows.indices {
            guard case .object(var record) = rows[i], case .string(id)? = record["id"],
                  !hasPicture(record) else { continue }
            record["userPhoto"] = .string(dataURI)
            StoreWriter.stamp(&record)
            rows[i] = .object(record)
            return true
        }
        return false
    }

    static func hasPicture(_ record: [String: JSONValue]) -> Bool {
        text(record["userPhoto"]).hasPrefix("data:") || !text(record["thumbFile"]).isEmpty
    }

    static func text(_ v: JSONValue?) -> String {
        if case .string(let s)? = v { s.trimmingCharacters(in: .whitespacesAndNewlines) } else { "" }
    }
}
