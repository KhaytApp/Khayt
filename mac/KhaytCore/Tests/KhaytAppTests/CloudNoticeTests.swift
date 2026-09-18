import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Saying that this app does not sync.
///
/// It writes to the book on this Mac and stamps every record, so the Electron
/// app's next sync picks the change up. That is the whole mechanism, and it
/// only runs when that app runs — so a shop keeping its book on two machines
/// and no longer opening Khayt would have the two drift apart with nothing
/// said. That is the one failure worth putting on screen BEFORE the feature
/// exists, because it is silent and it costs the most.
///
/// This shop's own book is connected: `enabled`, `verified`, a `shopId` and
/// `lastServerRev: 12`.
@MainActor
struct CloudNoticeTests {

    static func shop(_ cloud: [String: JSONValue]?) -> Bool {
        Shop.cloudConnected(cloud.map { ["cloud": .object($0)] } ?? [:])
    }

    @Test("a connected book is told")
    func connected() {
        #expect(Self.shop([
            "enabled": .bool(true), "verified": .bool(true), "shopId": .string("shop_282eb"),
        ]))
    }

    @Test("a book that never connected is not nagged")
    func neverConnected() {
        // A line saying "this does not sync" to a shop with nothing to sync to
        // is a line people stop reading, and then they stop reading the one
        // that matters.
        #expect(!Self.shop(nil))
        #expect(!Self.shop([:]))
    }

    @Test("a book that switched the cloud off is not nagged either")
    func switchedOff() {
        #expect(!Self.shop([
            "enabled": .bool(false), "verified": .bool(true), "shopId": .string("shop_282eb"),
        ]))
    }

    @Test("a half-finished connection is not a stranded one")
    func notYetVerified() {
        // Started connecting and never finished: there is no other device
        // waiting, so telling it its changes are stranded is a false alarm.
        #expect(!Self.shop([
            "enabled": .bool(true), "verified": .bool(false), "shopId": .string("shop_282eb"),
        ]))
        #expect(!Self.shop([
            "enabled": .bool(true), "shopId": .string("shop_282eb"),
        ]), "no answer about verification is not a yes")
    }

    @Test("a connection with no shop is not a connection")
    func noShopId() {
        #expect(!Self.shop([
            "enabled": .bool(true), "verified": .bool(true), "shopId": .string(""),
        ]))
    }

    /// ── THIS TEST WAS PINNED TO THE WRONG WINDOW ──────────────────────────
    ///
    /// It asserted that `Sidebar.swift` carries the sync line and calls
    /// `Self.syncLine(shop)` — and passed for months while the SHIPPING window
    /// showed no sync state at all, because `Sidebar.swift` is the shell the
    /// app stopped opening with in 4.0.0-alpha.12.
    ///
    /// A test naming one shell is how the app came to have things that ship in
    /// no window. It asks about both now, and about the one place the sentence
    /// is written.
    @Test("both windows carry it, and only when connected")
    func theWindowsSayIt() throws {
        func source(_ file: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/\(file)"), encoding: .utf8)
        }
        // The window that ships.
        let shell = try source("Shell.swift")
        #expect(shell.contains("if shop.cloudConnected {"),
                "the shipping window shows no sync state")
        #expect(shell.contains("shop.syncLine"))

        // And the one being retired, while it is still here.
        let sidebar = try source("Sidebar.swift")
        #expect(sidebar.contains("if shop.cloudConnected {"))
        #expect(sidebar.contains("shop.syncLine"))

        // It says what sync is DOING now rather than one standing sentence,
        // and it says it from ONE place so the two cannot drift.
        let shop = try source("Shop.swift")
        #expect(shop.contains("var syncLine:"))
        #expect(shop.contains("case .failing:"), "the states are no longer enumerated here")
    }
}
