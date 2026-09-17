import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// The shop's print library, in Spotlight.
///
/// ── WHY THIS IS THE FEATURE A MAC APP OWES A LIBRARY OF THIS SIZE ─────────
///
/// This shop has 209 models filed in 13 projects. Finding one means opening
/// Khayt, going to the library, and typing — which is fine when Khayt is
/// already open and is three steps too many when it is not. A Mac already has
/// a search box that is one keystroke away from anywhere, and an app that
/// keeps hundreds of things and puts none of them in it is asking to be opened
/// before it can be useful.
///
/// So every model is a Spotlight result: its name, its project, its material,
/// its tags, and its thumbnail. Choosing one opens Khayt on that model with it
/// selected — see `Shop.reveal`, which clears every filter that could hide it,
/// because a search result that opens an empty grid is worse than no result.
///
/// ── WHAT IS NOT INDEXED, AND WHY ──────────────────────────────────────────
///
/// **The sample book.** Khayt opens on invented data when a shop has none, and
/// putting "Benchy" and "Calibration cube" into someone's Mac-wide search
/// because they once looked at the demo would be a mess they did not ask for
/// and could not explain. Only a real book is indexed.
///
/// **Anything but the library.** Jobs carry customer names and prices. Putting
/// those into a system-wide index is a decision for a shop to make rather than
/// one to be surprised by, and a model name is not that: it is the name of a
/// file already sitting on the disk. So this is the library, and the toggle is
/// on by default; the rest of the book stays out until it is asked for.
///
/// The whole thing can be switched off in Settings, which also empties what has
/// already been indexed — switching a thing off has to undo it, or the switch
/// is decoration.
@MainActor
final class Spotlight {
    static let shared = Spotlight()
    private init() {}

    /// Everything this app indexes lives under one domain, so it can all be
    /// withdrawn in one call.
    static let domain = "app.khayt.mac.library"
    /// Prefixed so a Spotlight identifier cannot be mistaken for a record id
    /// anywhere it is passed around.
    static let prefix = "khayt.library."
    static let defaultsKey = "mac.spotlight"

    /// Mac-local, like the menu bar item and for the same reason: whether this
    /// Mac's search knows about the library is not the shop's business and must
    /// not follow the book to another machine.
    static var wanted: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The record a Spotlight result names, or nil if it names something else.
    static func recordId(forItem identifier: String) -> String? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    static func itemId(for recordId: String) -> String { prefix + recordId }

    /// What one model looks like as a search result, as plain values.
    ///
    /// Separated from `CSSearchableItem` so the wording can be tested without
    /// an index: what a person reads under the name is the whole point, and
    /// `CSSearchableItemAttributeSet` is not something a test can assert about
    /// comfortably.
    struct Card: Equatable, Sendable {
        var itemId: String
        var title: String
        /// The line under the title. Empty when there is nothing true to say.
        var subtitle: String
        /// What a search has to match to find it, beyond the title.
        var keywords: [String]
    }

    /// One model's card.
    ///
    /// The subtitle answers "which one is this" and nothing else: the project
    /// it belongs to, what it is made of, and whether it has been printed. Not
    /// the file size, not the triangle count — a search result is read at a
    /// glance, and a figure nobody is looking for crowds out the two they are.
    static func card(for file: LibraryFile, printedTimes: String? = nil) -> Card {
        var parts: [String] = []
        if let group = file.groupName, !group.isEmpty { parts.append(group) }
        if let material = file.material, !material.isEmpty { parts.append(material) }
        if let category = file.category, !category.isEmpty { parts.append(category) }
        if let printedTimes, !printedTimes.isEmpty { parts.append(printedTimes) }

        // Keywords are matched, not read, so they can hold what the subtitle
        // has no room for — including the name the file had when it arrived,
        // which is often what somebody remembers it as.
        var keywords: [String] = ["Khayt"]
        keywords += file.tags ?? []
        for value in [file.material, file.category, file.groupName, file.originalName] {
            if let value, !value.isEmpty { keywords.append(value) }
        }
        // The extension, because "the stl one" is a thing people search for.
        if let ext = (file.sourceFile?.filename).map({ ($0 as NSString).pathExtension }),
           !ext.isEmpty {
            keywords.append(ext.lowercased())
        }
        // Distinct, order preserved: Spotlight does not care, and a duplicated
        // keyword in a test failure is noise that hides the real difference.
        var seen = Set<String>()
        keywords = keywords.filter { seen.insert($0.lowercased()).inserted }

        return Card(itemId: itemId(for: file.id),
                    title: file.title,
                    subtitle: parts.joined(separator: " · "),
                    keywords: keywords)
    }

    // MARK: - Keeping the index up to date

    /// What was last handed to Spotlight. A book that reloads unchanged — which
    /// is most reloads — does no work at all.
    private var lastSignature: String?

    /// Re-describe the library to Spotlight.
    ///
    /// Safe to call on every load: it compares first, and an unchanged library
    /// costs one string comparison.
    /// What belongs in the index for this book, or nil for "nothing, and take
    /// out whatever is there".
    ///
    /// Pure, and separate from the indexing, because the two decisions it makes
    /// are the ones that matter and neither can be checked by looking at a
    /// Spotlight index: the sample book is never indexed, and switching the
    /// feature off is an instruction to EMPTY rather than to stop adding.
    ///
    /// Archived models are left out. A superseded model is still in the book
    /// and still on disk, but it is not one of the things the shop is choosing
    /// between — and `Shop.reveal` can still show one, for the case where
    /// somebody finds it another way.
    static func indexable(source: Shop.Source, files: [LibraryFile],
                          wanted: Bool = Spotlight.wanted) -> [LibraryFile]? {
        guard wanted, source.isReal else { return nil }
        return files.filter { !$0.isArchived }
    }

    func reindex(shop: Shop) {
        guard let files = Self.indexable(source: shop.source, files: shop.files) else {
            // Not an early return with nothing done: a book that WAS indexed
            // and is now the sample must stop being findable, or a shop that
            // closed its book still has it in Spotlight.
            forget()
            return
        }
        let signature = Self.signature(of: files)
        guard signature != lastSignature else { return }
        lastSignature = signature

        let items = files.map { file -> CSSearchableItem in
            // The same phrase the tile in the library prints under the same
            // model, so a result and the thing it opens agree.
            let printed = file.printCount > 0
                ? shop.words.callIt("cat.printed_n", ["n": .number(Double(file.printCount))])
                : nil
            let card = Self.card(for: file, printedTimes: printed)
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = card.title
            attributes.displayName = card.title
            attributes.contentDescription = card.subtitle
            attributes.keywords = card.keywords
            attributes.contentModificationDate = file.updatedAtDate
            // A picture, because a library is recognised by sight. Given as a
            // URL wherever the thumbnail is a file on disk — handing over 209
            // decoded images would be megabytes held for no reason — and as
            // data only for the inline `data:` photographs a shop took itself.
            switch shop.thumbnail(for: file) {
            case .file(let url): attributes.thumbnailURL = url
            case .inlineData(let uri): attributes.thumbnailData = Self.bytes(ofDataURI: uri)
            case nil: break
            }
            let item = CSSearchableItem(uniqueIdentifier: card.itemId,
                                        domainIdentifier: Self.domain,
                                        attributeSet: attributes)
            return item
        }

        // `await` on the main actor rather than completion handlers, so
        // nothing non-`Sendable` crosses an actor boundary — `CSSearchableItem`
        // and the index itself are both AppKit-era classes that do not conform.
        Task { @MainActor [items] in
            let index = CSSearchableIndex.default()
            do {
                // Withdraw first. A model deleted from the book has to leave
                // the index, and comparing identifiers to work out which would
                // be more machinery than re-describing two hundred rows is
                // worth.
                try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
                if !items.isEmpty { try await index.indexSearchableItems(items) }
            } catch {
                // Spotlight declining is not worth a banner — nobody asked for
                // this, it happens in the background, and the app is entirely
                // usable without it. But the signature must go back, or the
                // failure is remembered as a success and the library stays out
                // of search until something else changes.
                lastSignature = nil
                problem = String(describing: error)
            }
        }
    }

    /// Why the last attempt did not work, for the one place that asks: nothing
    /// on screen, but a test can tell "did nothing because it matched" from
    /// "did nothing because it failed".
    private(set) var problem: String?

    /// Take the library out of Spotlight — switched off, or the book closed.
    func forget() {
        lastSignature = nil
        Task { @MainActor in
            try? await CSSearchableIndex.default()
                .deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        }
    }

    /// Everything that would change what a result says, and nothing else.
    ///
    /// Not the whole record: a field the card does not read cannot change the
    /// card, and including it would re-index the library every time a print
    /// finished.
    static func signature(of files: [LibraryFile]) -> String {
        files.map { file in
            [file.id, file.title, file.groupName ?? "", file.material ?? "",
             file.category ?? "", (file.tags ?? []).joined(separator: ","),
             file.originalName ?? "", file.thumbFile ?? "",
             String(file.printCount), file.updatedAt ?? ""].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }

    /// The bytes inside a `data:` URI, or nil if it is not one.
    static func bytes(ofDataURI uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.startIndex..<comma]
        let body = String(uri[uri.index(after: comma)...])
        guard header.contains(";base64") else { return nil }
        return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
    }
}
