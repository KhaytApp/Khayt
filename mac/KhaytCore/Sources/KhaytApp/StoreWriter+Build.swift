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
                       mutate: (inout [String: JSONValue]) throws -> Void) throws {
        try update(storeURL: build.storeURL,
                   owns: { StoreLock.weOwnIt(build) },
                   whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
                   mutate: mutate)
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
