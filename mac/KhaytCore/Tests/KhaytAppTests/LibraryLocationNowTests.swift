import Foundation
import Testing
@testable import KhaytApp

/// Settings › Preferences › "Where the library lives": the Now row always has
/// a value, and no row is drawn empty (Nov 11 2026 UI review, B11).
@MainActor struct LibraryLocationNowTests {

    @Test("a book with a library folder shows its path, home folder shortened")
    func path() {
        let home = NSHomeDirectory()
        #expect(LibraryLocationSettings.now(path: home + "/Khayt/library", isReal: true) == .path("~/Khayt/library"))
        #expect(LibraryLocationSettings.now(path: "/Volumes/NAS/prints", isReal: true) == .path("/Volumes/NAS/prints"))
    }

    @Test("with no folder to show it says where the book is, in words the app already had")
    func words() {
        // The sample shop keeps no files.
        #expect(LibraryLocationSettings.now(path: "", isReal: false) == .word("mac.sample"))
        #expect(LibraryLocationSettings.now(path: "  ", isReal: true) == .word("mac.on_this_mac"))
        // Both are words the app has, not keys that would be drawn raw.
        let words = Words()
        #expect(words.callIt("mac.sample") != "mac.sample")
        #expect(words.callIt("mac.on_this_mac") != "mac.on_this_mac")
    }

    @Test("the progress row is drawn only while something is moving")
    func noEmptyRow() {
        #expect(!LibraryLocationSettings.showsProgress(progress: false, busy: false, stoppable: false))
        #expect(LibraryLocationSettings.showsProgress(progress: true, busy: false, stoppable: false))
        #expect(LibraryLocationSettings.showsProgress(progress: false, busy: true, stoppable: false))
        #expect(LibraryLocationSettings.showsProgress(progress: false, busy: false, stoppable: true))
    }
}
