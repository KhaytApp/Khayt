import Foundation
import AppKit
import KhaytCore

/// The papers that travel with a product.
///
/// Assembly instructions, a safety sheet, a drawing. They are filed against the
/// PRODUCT rather than against an order, because that is what they describe: a
/// safety sheet belongs to the thing being made, and filing it against one
/// order's line item means re-attaching the same PDF every time somebody orders
/// the same product. `lib/product-docs.js` owns what they MEAN — which of them
/// go on the work order the floor reads, and which go on the delivery note in
/// the box. What is here is the part no pure module can do: copy a file the
/// shop picked and put it where both apps look.
///
/// ── THE FOLDER AND THE NAME ARE `main.js`'s, DELIBERATELY ─────────────────
///
/// `product-docs` beside the book, and `<productId>-<base-36 ms>.<ext>` with
/// everything outside `[A-Za-z0-9_-]` replaced. Both apps read the same store,
/// so a document attached on this Mac has to be one the other app can open, and
/// a record naming a file in a folder it does not look in is a document the
/// shop believes it has attached.
///
/// Their own folder rather than the order files': these outlive any single
/// order, and deleting an order's files must never take a product's documents
/// with it.
enum ProductDocs {

    /// What the shop may attach — `main.js`'s list, and then everything, the
    /// same way its dialog offers both.
    static let kinds = ["pdf", "png", "jpg", "jpeg", "txt", "md", "doc", "docx"]

    static func folder(_ build: StoreReader.Build) -> URL {
        build.storeURL.deletingLastPathComponent().appending(path: "product-docs")
    }

    /// One attached document, as the store records it.
    struct Attached: Identifiable, Sendable, Hashable {
        /// The name on disk. Also the id: it is unique by construction and it
        /// is what every other screen resolves a document by.
        var id: String { filename }
        let filename: String
        /// What the shop called it. Shown, because the name on disk is a
        /// timestamp and tells nobody which sheet this is.
        let originalName: String
        let size: Int
        /// Absent means YES. A document attached before this flag existed was
        /// attached to travel, and defaulting it to "no" would silently stop
        /// shipping papers that used to go out.
        var packWithOrder: Bool

        var record: JSONValue {
            .object(["filename": .string(filename),
                     "originalName": .string(originalName),
                     "size": .number(Double(size)),
                     "packWithOrder": .bool(packWithOrder)])
        }

        @MainActor static func from(_ value: JSONValue) -> Attached? {
            guard case .object(let o) = value,
                  let filename = Shop.plainString(o["filename"]), !filename.isEmpty
            else { return nil }
            let original = Shop.plainString(o["originalName"]) ?? filename
            var packs = true
            if case .bool(let said)? = o["packWithOrder"] { packs = said }
            return Attached(filename: filename,
                            originalName: original.isEmpty ? filename : original,
                            size: Int(Shop.plainNumber(o["size"]) ?? 0),
                            packWithOrder: packs)
        }
    }

    /// Copy a file in and return the record for it.
    ///
    /// A COPY, not a reference. The shop's own file stays where it is and can
    /// be moved, renamed or deleted without the product losing its papers —
    /// which is what a path into somebody's Downloads folder would mean.
    static func attach(_ source: URL, productId: String,
                       in build: StoreReader.Build) throws -> Attached {
        let dir = folder(build)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = source.lastPathComponent
        let name = filename(productId: productId, ext: source.pathExtension)
        let into = dir.appending(path: name)
        if FileManager.default.fileExists(atPath: into.path) {
            try FileManager.default.removeItem(at: into)
        }
        try FileManager.default.copyItem(at: source, to: into)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Attached(filename: name, originalName: original, size: size, packWithOrder: true)
    }

    /// `main.js`'s name, spelled the same way: the product, a base-36
    /// millisecond stamp, and the original extension lower-cased.
    static func filename(productId: String, ext: String) -> String {
        let kind = ext.lowercased().isEmpty ? "bin" : ext.lowercased()
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        return "\(safe(productId))-\(stamp).\(kind)"
    }

    /// Everything outside `[A-Za-z0-9_-]` becomes `_`, after taking the last
    /// path component — the same two steps in the same order as
    /// `path.basename(...).replace(/[^a-zA-Z0-9_-]/g, '_')`.
    static func safe(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent
        return String(leaf.map { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-") ? c : "_"
        })
    }

    /// Show it to the shop, in whatever it normally opens that kind with.
    @MainActor static func open(_ name: String, in build: StoreReader.Build) {
        guard let at = resolve(name, in: build) else { return }
        NSWorkspace.shared.open(at)
    }

    /// Unlink one nobody references any more.
    static func delete(_ name: String, in build: StoreReader.Build) {
        guard let at = resolve(name, in: build) else { return }
        // The Trash, not deleted, like the product photos beside it.
        try? FileManager.default.trashItem(at: at, resultingItemURL: nil)
    }

    /// The file a record names, or nothing.
    ///
    /// `lastPathComponent` because this both opens and deletes: the name comes
    /// off a store record, and a record can arrive from a sync with anything in
    /// it. A `../../` in there would otherwise reach outside the folder.
    static func resolve(_ name: String, in build: StoreReader.Build) -> URL? {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return nil }
        let at = folder(build).appending(path: leaf)
        return FileManager.default.fileExists(atPath: at.path) ? at : nil
    }
}
