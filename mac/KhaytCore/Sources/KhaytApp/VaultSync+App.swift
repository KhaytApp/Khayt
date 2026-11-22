import Foundation
import KhaytCore

extension StoreReader.Build {
    /// Where this Mac keeps the vault's per-device state for the library at
    /// `libraryRoot`: the book's own folder, never the library or its parent
    /// (`VaultSyncState`). `supportFolderForTests` moves it with the book.
    func vaultStateFolder() -> URL { storeURL.deletingLastPathComponent() }
}
