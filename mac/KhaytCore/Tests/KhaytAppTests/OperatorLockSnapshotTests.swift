import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// The operator lock's screens, photographed. Writes only when
/// KHAYT_SNAPSHOT_DIR is set (see `SnapshotTests`); read the PNGs.
@Suite @MainActor struct OperatorLockSnapshotTests {

    @Test("sign-in, not allowed, the Settings section and the PIN sheet")
    func pictures() async throws {
        let snap = SnapshotTests()
        let shop = await OperatorLockTests.shop()
        try snap.render(LockScreen(shop: shop), "lock-screen", size: CGSize(width: 900, height: 600))
        try snap.renderDark(LockScreen(shop: shop), "lock-screen-dark", size: CGSize(width: 900, height: 600))

        // Signed in as an operator, on a screen above their level.
        _ = await shop.signIn("OP-x", pin: "3333")
        try snap.render(NotAllowed(shop: shop), "lock-not-allowed", size: CGSize(width: 700, height: 420))

        // An owner, in Settings: one PIN not readable here, one set elsewhere.
        shop.lockNow()
        let mixed = await OperatorLockTests.shop(OperatorLockTests.staff() + [
            OperatorLockTests.op("OP-e", "Majed", roleKey: "operator", pinHash: "__KHAYT_MASKED__"),
            OperatorLockTests.op("OP-u", "Huda", roleKey: "operator", pinHash: "MTIzNA=="),
            OperatorLockTests.op("OP-n", "Lina", roleKey: "viewer"),
        ])
        _ = await mixed.signIn("OP-o", pin: "1111")
        _ = await shop.signIn("OP-o", pin: "1111")
        try snap.render(LockSection(shop: mixed).padding(20).frame(width: 600).background(Khayt.ground),
                        "lock-settings-mixed", size: CGSize(width: 600, height: 620))
        try snap.render(LockSection(shop: shop).padding(20).frame(width: 600).background(Khayt.ground),
                        "lock-settings", size: CGSize(width: 600, height: 520))
        try snap.renderDark(LockSection(shop: shop).padding(20).frame(width: 600),
                            "lock-settings-dark", size: CGSize(width: 600, height: 520))
        try snap.render(SetPinSheet(shop: shop, person: try #require(shop.signedIn)).background(Khayt.ground),
                        "lock-set-pin", size: CGSize(width: 360, height: 260))
        try snap.render(RecoveryCodeSheet(shop: shop, code: "KHAYT-7K2P-QX9M-4HTA").background(Khayt.ground),
                        "lock-recovery-code", size: CGSize(width: 380, height: 220))

        // Switched on without an owner who can sign in: Settings says so.
        let stranded = await OperatorLockTests.shop([OperatorLockTests.op("OP-o", "Noura", roleKey: "owner")])
        try snap.render(LockSection(shop: stranded).padding(20).frame(width: 600).background(Khayt.ground),
                        "lock-settings-not-in-force", size: CGSize(width: 600, height: 300))
        OperatorLockTests.clearThrottle()
    }
}
