import Foundation
import Testing
@testable import KhaytApp

/// "One of these models has no copy in the vault yet. Back it up, then try
/// again." told the shop what to do and gave it no way to do it but Settings ▸
/// Back up the whole library now — hours, for a big library, to sell one model.
/// The refusal now carries the models it means, and the banner offers to send
/// just those up and ask again.
@MainActor
struct VaultBackupRetryTests {

    @Test("the refusal remembers which models the vault lacked, and the banner offers the retry")
    func reachable() {
        let products = MenuCoverageTests.source("Shop+VaultProducts.swift")
        #expect(products.contains("vaultMissing = VaultMissing(files: files, missing: missing)"))
        #expect(products.contains("await backUpModels(only: pending.missing)"))
        let banners = MenuCoverageTests.source("Banners.swift")
        #expect(banners.contains("shop.words.callIt(\"mac.vl_backup_retry\")"))
        #expect(banners.contains("await shop.backUpMissingAndRetry()"))
    }

    @Test("the whole-library backup and the retry are one upload, never two")
    func oneUpload() {
        let lib = MenuCoverageTests.source("CloudLibrary.swift")
        #expect(lib.contains("guard let (done, failed, total) = await backUpModels(only: nil)"))
        // Exactly one place uploads library models into the remote this way.
        #expect(lib.components(separatedBy: "try await CloudLibrary.ensureInBucket(config.remote, key: key, file: URL(fileURLWithPath: file.fullPath), engine: engine)").count == 2)
    }

    @Test("closing the banner forgets the pending retry")
    func closeForgets() {
        #expect(MenuCoverageTests.source("Banners.swift")
            .contains("shop.moveProblem = nil; shop.vaultMissing = nil"))
    }
}
