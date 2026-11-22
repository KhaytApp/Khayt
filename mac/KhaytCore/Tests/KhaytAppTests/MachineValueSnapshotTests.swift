import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// The machine sheet's Value tab, on the sample machine that carries
/// depreciation. Its own serialized suite because it opens the sheet on that
/// tab through `MachineSheet.opensOn`, a static. Writes only when
/// KHAYT_SNAPSHOT_DIR is set, like `SnapshotTests`.
///
/// No `.task` runs under `ImageRenderer`, so the hourly line is drawn in its
/// "working it out" state — which is the state the review asked to see.
@Suite(.serialized) @MainActor
struct MachineValueSnapshotTests {

    @Test("the Value tab renders, with its words")
    func valueTab() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let valued = try #require(shop.machines.first { $0.depreciation != nil },
                                  "the sample shop has no machine with depreciation to draw")
        MachineSheet.opensOn = "value"
        defer { MachineSheet.opensOn = "printer" }
        try SnapshotTests().render(MachineSheet(shop: shop, existing: valued),
                                   "29b-machine-value-words",
                                   size: CGSize(width: MachineSheet.width, height: 640))
    }
}
