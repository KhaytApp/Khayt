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
    nonisolated static let domain = "app.khayt.mac.library"
    /// Prefixed so a Spotlight identifier cannot be mistaken for a record id
    /// anywhere it is passed around.
    nonisolated static let prefix = "khayt.library."
    nonisolated static let defaultsKey = "mac.spotlight"

    /// Mac-local, like the menu bar item and for the same reason: whether this
    /// Mac's search knows about the library is not the shop's business and must
    /// not follow the book to another machine.
    nonisolated static var wanted: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The record a Spotlight result names, or nil if it names something else.
    static func recordId(forItem identifier: String) -> String? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    nonisolated static func itemId(for recordId: String) -> String { prefix + recordId }

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
    nonisolated static func card(for file: LibraryFile, printedTimes: String? = nil) -> Card {
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

    /// What was last handed to Spotlight, record by record: each item's
    /// identifier and the signature of the record it was made from. A book
    /// that reloads unchanged — which is most reloads — does no work at all,
    /// and one that changed re-describes only what changed. Nil when the index
    /// is in an unknown state (never filled, emptied, or a write failed), and
    /// then the next pass withdraws everything and starts again.
    ///
    /// Read and written ONLY on `queue`, where the passes run in order — so
    /// the diff is always against what the pass before it handed over.
    private final class Ledger: @unchecked Sendable {
        var indexed: [String: String]?
    }
    private nonisolated static let ledger = Ledger()

    /// One pass's worth of work, decided on `queue` from plain values.
    struct Plan: Equatable, Sendable {
        /// Every record now in the index, by item identifier.
        var now: [String: String]
        /// The records to (re)describe — new, or changed in a way a card shows.
        var changed: [LibraryFile]
        /// Item identifiers to withdraw: records no longer in the book.
        var removed: [String]
        /// Withdraw the whole domain first: nothing is known about what is there.
        var everything: Bool
        var isEmpty: Bool { changed.isEmpty && removed.isEmpty && !everything }
    }

    /// What has to change in the index to go from `before` to `files`.
    ///
    /// ONLY WHAT CHANGED, because this ran after every library write and
    /// re-described all ten thousand of one shop's models each time, on the
    /// main actor — 127 ms of frozen window per edit on a local disk, base64
    /// photo decoding included, and more on a NAS (measured Oct 2026). A
    /// deleted record is withdrawn BY IDENTIFIER, so the index still loses
    /// what the book lost.
    nonisolated static func plan(before: [String: String]?, files: [LibraryFile]) -> Plan {
        var now: [String: String] = [:]
        now.reserveCapacity(files.count)
        var changed: [LibraryFile] = []
        for file in files {
            let id = itemId(for: file.id)
            let signature = recordSignature(file)
            // Two records with one id are both handed over, and the later
            // replaces the earlier in the index — as when the whole list went.
            if before?[id] != signature { changed.append(file) }
            now[id] = signature
        }
        guard let before else {
            return Plan(now: now, changed: changed, removed: [], everything: true)
        }
        let removed = before.keys.filter { now[$0] == nil }.sorted()
        return Plan(now: now, changed: changed, removed: removed, everything: false)
    }

    /// Re-describe the library to Spotlight.
    ///
    /// Safe to call on every load: it compares first, off the main actor, and
    /// an unchanged library costs one signature per record there.
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
    ///
    /// AND NOTHING WHILE THE STAFF LOCK IS ON: Spotlight answers anybody at
    /// the Mac, signed in or not, so the library's names in it were the book
    /// behind the lock. nil also EMPTIES the index, so switching the lock on
    /// takes out what was there (alpha.62 re-check, round 3).
    nonisolated static func indexable(source: Shop.Source, files: [LibraryFile],
                          wanted: Bool = Spotlight.wanted,
                          lockOn: Bool = false) -> [LibraryFile]? {
        guard wanted, source.isReal, !lockOn else { return nil }
        return files.filter { !$0.isArchived }
    }


    /// Where the index is written. One SERIAL queue, so passes reach
    /// Spotlight in the order they were decided — an incremental pass must
    /// never land before the full rebuild it was diffed against — and a
    /// dispatch queue rather than a task, because what runs on it blocks
    /// (thumbnail stats, photo decoding, waiting on the index): blocking work
    /// on the cooperative pool starves it (see `PinWork`).
    private nonisolated static let queue = DispatchQueue(label: "app.khayt.mac.spotlight",
                                                         qos: .utility)

    func reindex(shop: Shop) {
        // Only plain values are read here. Choosing what is indexable walks
        // the whole library, so even that is done on the queue.
        let gate = (source: shop.source, lockOn: shop.lockSwitchedOn, wanted: Self.wanted)
        let all = shop.files
        // The same phrase the tile in the library prints under the same
        // model, so a result and the thing it opens agree. Worded here, once
        // per distinct count, because `Words` lives on the main actor.
        var printed: [Int: String] = [:]
        if gate.wanted, gate.source.isReal {
            for file in all where file.printCount > 0 && printed[file.printCount] == nil {
                printed[file.printCount] = shop.words.counting(file.printCount, "mac.printed_n")
            }
        }
        let roots = shop.libraryRoots?.roots
        let wording = printed
        Self.queue.async {
            guard let files = Self.indexable(source: gate.source, files: all,
                                             wanted: gate.wanted, lockOn: gate.lockOn) else {
                // Not an early return with nothing done: a book that WAS
                // indexed and is now the sample must stop being findable, or
                // a shop that closed its book still has it in Spotlight.
                Self.withdrawAll()
                return
            }
            let plan = Self.plan(before: Self.ledger.indexed, files: files)
            guard !plan.isEmpty else { return }
            Self.ledger.indexed = plan.now
            let failed = Self.write(plan, printed: wording, roots: roots)
            guard let failed else { return }
            // Spotlight declining is not worth a banner — nobody asked for
            // this, it happens in the background, and the app is entirely
            // usable without it. But what was indexed must be forgotten, or
            // the failure is remembered as a success and the library stays
            // out of search until something else changes.
            Self.ledger.indexed = nil
            Task { @MainActor in
                Spotlight.shared.problem = failed
            }
        }
    }

    /// The plan, handed to the index, on `queue`. Returns why it failed, or
    /// nil.
    ///
    /// Everything here touches the disk or the index, which is why it is not
    /// on the main actor: a thumbnail on a NAS is a round trip, and an inline
    /// photo is a base64 decode of up to a few hundred kilobytes.
    private nonisolated static func write(_ plan: Plan, printed: [Int: String],
                                          roots: [String]?) -> String? {
        let items = plan.changed.map {
            item(for: $0, printedTimes: printed[$0.printCount], roots: roots)
        }
        let index = CSSearchableIndex.default()
        let outcome = Outcome()
        func wait(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) {
            guard outcome.error == nil else { return }
            let done = DispatchSemaphore(value: 0)
            call { error in
                if let error { outcome.error = String(describing: error) }
                done.signal()
            }
            done.wait()
        }
        // Withdraw first, so a model deleted from the book leaves the index.
        if plan.everything {
            wait { index.deleteSearchableItems(withDomainIdentifiers: [domain], completionHandler: $0) }
        } else if !plan.removed.isEmpty {
            let removed = plan.removed
            wait { index.deleteSearchableItems(withIdentifiers: removed, completionHandler: $0) }
        }
        if !items.isEmpty {
            wait { index.indexSearchableItems(items, completionHandler: $0) }
        }
        return outcome.error
    }

    /// Where a completion handler leaves its error for the queue that is
    /// waiting on it. Written before the semaphore is signalled and read after
    /// it is waited on, so the semaphore orders every access.
    private final class Outcome: @unchecked Sendable {
        var error: String?
    }

    nonisolated static func item(for file: LibraryFile, printedTimes: String?,
                                 roots: [String]?) -> CSSearchableItem {
        let card = card(for: file, printedTimes: printedTimes)
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
        // The same choice `Shop.thumbnail(for:)` makes, read without its
        // main-actor memo.
        if let photo = file.userPhoto, photo.hasPrefix("data:") {
            attributes.thumbnailData = bytes(ofDataURI: photo)
        } else if case .file(let url)? = Shop.thumbnailOnDisk(file, roots: roots) {
            attributes.thumbnailURL = url
        }
        return CSSearchableItem(uniqueIdentifier: card.itemId,
                                domainIdentifier: domain,
                                attributeSet: attributes)
    }

    /// Why the last attempt did not work, for the one place that asks: nothing
    /// on screen, but a test can tell "did nothing because it matched" from
    /// "did nothing because it failed".
    private(set) var problem: String?

    /// Take the library out of Spotlight — switched off, or the book closed.
    /// On the same queue as the writes, so it lands after any still waiting.
    func forget() {
        Self.queue.async { Self.withdrawAll() }
    }

    /// Everything out, on `queue`.
    private nonisolated static func withdrawAll() {
        ledger.indexed = nil
        let done = DispatchSemaphore(value: 0)
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in done.signal() }
        done.wait()
    }

    /// Everything that would change what a result says, and nothing else.
    ///
    /// Not the whole record: a field the card does not read cannot change the
    /// card, and including it would re-index the library every time a print
    /// finished.
    static func signature(of files: [LibraryFile]) -> String {
        files.map(recordSignature).joined(separator: "\u{1E}")
    }

    /// One record's part of `signature(of:)`.
    nonisolated static func recordSignature(_ file: LibraryFile) -> String {
        [file.id, file.title, file.groupName ?? "", file.material ?? "",
         file.category ?? "", (file.tags ?? []).joined(separator: ","),
         file.originalName ?? "", file.thumbFile ?? "",
         String(file.printCount), file.updatedAt ?? ""].joined(separator: "\u{1F}")
    }

    /// The bytes inside a `data:` URI, or nil if it is not one.
    nonisolated static func bytes(ofDataURI uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.startIndex..<comma]
        let body = String(uri[uri.index(after: comma)...])
        guard header.contains(";base64") else { return nil }
        return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
    }
}
