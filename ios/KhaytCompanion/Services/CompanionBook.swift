import Foundation
import KhaytCore

/**
 * The shop's book, on the phone.
 *
 * `CompanionCache` beside this remembers the ANSWERS the desktop gave — one
 * file per endpoint, read-only by design, with writes refused rather than
 * queued. That was the right shape while the desktop was the only thing that
 * could compute anything. It is the wrong shape for a phone that has to work
 * when the desktop is not there: a screen fed by `/api/queue`'s reply can show
 * the queue and nothing else, and it cannot answer a question nobody thought
 * to cache.
 *
 * This is the other thing: the book itself, in the same shape the desktop keeps
 * it on disk — `khayt-store.json`, the collections named by
 * `KhaytStoreValidate.ARRAY_COLLECTIONS`. With the book here and `KhaytEngine`
 * linked, the phone can work a figure out instead of asking for it.
 *
 * ── IT WRITES THROUGH THE MAC'S WRITER, NOT ITS OWN ────────────────────────
 *
 * `StoreWriter` moved into KhaytCore for this. Every rule it carries is a
 * failure somebody already had: the read happens INSIDE the write, so a second
 * caller cannot put back the state it saw before the first change; the swap is
 * atomic with an fsync before it, so a crash cannot leave a half-written book;
 * the old copy rolls to `.prev` first, which is the one generation of rollback
 * a corrupt primary is recovered from; and the size ceiling is the one every
 * backup on the desktop is built to hold. A phone that wrote its book with
 * `data.write(to:)` would have none of that, and would have to learn each rule
 * again the same way.
 *
 * ── WHY OWNERSHIP IS SIMPLY TRUE HERE ──────────────────────────────────────
 *
 * `StoreWriter` asks `owns()` before the read and again before the swap. On a
 * Mac that question is real: Electron may be running on the same machine,
 * holding the same file, and taking it mid-edit. An iPhone's container is not
 * shared with a second Khayt — the widget reads a snapshot, never the book —
 * so the answer is always yes, and saying `{ true }` in one place is honest
 * where inventing a lock to satisfy the signature would not be.
 */
struct CompanionBook {

    /// The folder this book lives in.
    ///
    /// Injectable for one reason: a write path whose only trial run was on a
    /// shop's live book has not been tested, it has been risked — the same
    /// sentence `StoreWriter` carries. The tests hand it a temp directory; the
    /// app asks for `inSharedContainer()`.
    let directory: URL

    /// Shared with the widget, not private to the app.
    ///
    /// The queue widget currently draws from a snapshot written by the app,
    /// which means it can only show what the app last saw while it was
    /// running. Putting the book where the extension can also reach it is what
    /// eventually lets the widget answer from the book itself.
    static let appGroupID = WidgetSnapshotStore.appGroupID

    enum Failure: Error, CustomStringConvertible {
        case noContainer
        case notYetPulled

        var description: String {
            switch self {
            case .noContainer:
                return "This build cannot reach its shared container, so there is nowhere to keep "
                     + "the shop's book. Check the App Group on both targets."
            case .notYetPulled:
                return "This phone has not been given the shop's book yet. Pair with the Mac, "
                     + "which is what fills it the first time."
            }
        }
    }

    /// The real one, in the App Group container, creating the folder the
    /// first time.
    ///
    /// ── THE PROTECTION CLASS IS A REAL CHOICE, NOT A DEFAULT ──────────────
    ///
    /// `CompanionCache` uses `.complete`: unreadable whenever the phone is
    /// locked. For a cache that is free, because nothing reads it but a screen
    /// somebody is looking at.
    ///
    /// The book cannot have that. The whole point of it is that the phone keeps
    /// working on its own, and the two things that make that true — syncing
    /// with the Mac in the background, and a widget that is still right on the
    /// Home Screen — both run while the phone is locked in somebody's apron.
    /// `.complete` would fail those reads, and a sync that fails whenever the
    /// screen is off is not a sync.
    ///
    /// `.completeUntilFirstUserAuthentication` is the honest middle: the book
    /// is unreadable after a cold boot until the owner has unlocked the phone
    /// once, which is the case that matters for a device that is lost or taken.
    /// It is set on the DIRECTORY, so every file the writer's atomic swap
    /// creates inside it is born with the same class — including the `.prev`
    /// rollback copy, which holds exactly the same shop data as the book.
    static func inSharedContainer() throws -> CompanionBook {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw Failure.noContainer
        }
        let dir = container.appending(path: "Book", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return CompanionBook(directory: dir)
    }

    /// The book's path. Named as the desktop names it, so anybody who has seen
    /// one shop's data knows what this file is.
    var url: URL { directory.appending(path: "khayt-store.json") }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The whole book, as the engine wants it.
    func read() throws -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: url) else { throw Failure.notYetPulled }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    /// Replace the book wholesale — what a first pull from the Mac does.
    ///
    /// Deliberately routed through `StoreWriter.atomicWrite` rather than
    /// `Data.write`, so the very first book a phone receives lands the same way
    /// every later edit does: fsync, `.prev`, swap.
    func replace(with store: [String: JSONValue]) throws {
        let next = try JSONEncoder().encode(store)
        guard next.count <= StoreWriter.maxStoreBytes else {
            throw StoreWriter.Refusal.tooLarge(next.count)
        }
        try StoreWriter.atomicWrite(next, to: url)
    }

    /// Change the book in place, atomically.
    ///
    /// `owns` is `true` and `whoHasIt` is never consulted — see the note at the
    /// top about why that is honest on a phone rather than a stub.
    func update(_ mutate: (inout [String: JSONValue]) throws -> Void) throws {
        try StoreWriter.update(storeURL: url,
                               owns: { true },
                               whoHasIt: { nil },
                               mutate: mutate)
    }

    /// Change one record of one collection, stamping `rev` and `updatedAt`.
    ///
    /// The stamping is what makes an edit made on this phone syncable at all:
    /// `lib/sync.js` decides what to send by comparing revisions, so an edit
    /// that did not bump one is an edit the Mac will never hear about.
    func updateRecord(collection: String, id: String,
                      change: (inout [String: JSONValue]) -> Void) throws {
        try StoreWriter.updateRecord(storeURL: url,
                                     owns: { true }, whoHasIt: { nil },
                                     collection: collection, id: id, change: change)
    }

    /// Forget the shop entirely. Unpairing must not leave a client list behind.
    func forget() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("prev"))
    }
}
