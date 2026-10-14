import Foundation
import KhaytCore

/// The two writes that are addressed by a *build* rather than by a path.
///
/// `StoreWriter` itself moved to KhaytCore, because the phone has a book to
/// write too and there must not be a second implementation of an atomic swap.
/// What could not move is this: `StoreReader.Build` is how the Mac finds which
/// Khayt wrote the store it is opening, and `StoreLock` is how it answers "may
/// I write to it" — a question that exists because Electron may be running on
/// the same Mac, holding the same file.
///
/// Neither idea means anything on a phone. An iPhone's book is inside its own
/// container, where there is no second app to take ownership, so the phone
/// passes ownership checks that are simply true. Keeping these two here is what
/// lets the shared half stay free of both types.
extension StoreWriter {

    /// Read-modify-write the whole store, atomically, while we own it.
    static func update(_ build: StoreReader.Build,
                       recordingDeletes: Bool = true,
                       mutate: (inout [String: JSONValue]) throws -> Void) throws {
        try update(storeURL: build.storeURL,
                   owns: { StoreLock.weOwnIt(build) },
                   whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
                   recordingDeletes: recordingDeletes,
                   mutate: mutate)
    }

    /// The ASYNC update, by a name no synchronous closure can fall into.
    ///
    /// For a change that needs the main actor (a sheet's own rules, the
    /// app's words): the book is read, decoded, encoded and swapped off the
    /// main thread and only `mutate` runs here. `try await update(...)` with a
    /// closure that never awaits compiles to the SYNCHRONOUS update — this
    /// cannot.
    ///
    /// `mutate` may run MORE THAN ONCE: when the book moved while the change
    /// was being worked out, it is worked out again on the book as it is now.
    /// Whatever it collects must start empty inside it.
    @MainActor
    static func updateAsync(_ build: StoreReader.Build,
                            recordingDeletes: Bool = true,
                            mutate: (inout [String: JSONValue]) async throws -> Void) async throws {
        try await update(storeURL: build.storeURL,
                         owns: { StoreLock.weOwnIt(build) },
                         whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
                         recordingDeletes: recordingDeletes,
                         mutate: mutate)
    }

    /// The same, on the write chain, without holding the main thread.
    ///
    /// The store's path is taken HERE, on the caller's thread, so the write
    /// addresses the book the caller meant even if a test points the app at
    /// another folder before the queue gets to it.
    static func updateOffMain<T: Sendable>(_ build: StoreReader.Build,
                                           recordingDeletes: Bool = true,
                                           mutate: @escaping @Sendable (inout [String: JSONValue]) throws -> T)
        async throws -> T {
        try await updateOffMain(storeURL: build.storeURL,
                                owns: { StoreLock.weOwnIt(build) },
                                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
                                recordingDeletes: recordingDeletes,
                                mutate: mutate)
    }

    /// `updateRecord`, on the write chain without holding the main thread.
    /// Returns what `change` returned, or nil when the record is not in the
    /// book (and nothing was changed).
    @discardableResult
    static func updateRecordOffMain<T: Sendable>(_ build: StoreReader.Build, collection: String, id: String,
                                                 change: @escaping @Sendable (inout [String: JSONValue]) -> T)
        async throws -> T? {
        try await updateOffMain(build) { root -> T? in
            guard case .array(var rows)? = root[collection],
                  let index = rows.firstIndex(where: { Shop.recordId($0) == id }),
                  case .object(var record) = rows[index] else { return nil }
            let out = change(&record)
            stamp(&record)
            rows[index] = .object(record)
            root[collection] = .array(rows)
            return out
        }
    }

    /// Change one record of one collection in place, stamping it.
    static func updateRecord(_ build: StoreReader.Build, collection: String, id: String,
                             change: (inout [String: JSONValue]) -> Void) throws {
        try updateRecord(storeURL: build.storeURL,
                         owns: { StoreLock.weOwnIt(build) },
                         whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
                         collection: collection, id: id, change: change)
    }
}
