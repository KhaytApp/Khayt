import Foundation
import Testing
@testable import KhaytApp

/// What the window says when something is wrong.
///
/// Every one of these is a source check, because a SwiftUI view's body cannot
/// be asked what it drew. That is a weak kind of test and it is the right kind
/// here: the defect being guarded is not "the banner renders wrongly", it is
/// "the banner is not on this screen at all" — which is what happened to the
/// engine failure for as long as it was a caption at the foot of the sidebar.
@MainActor
struct BannerTests {

    /// A source file — and a recorded failure when there isn't one.
    ///
    /// It returned `""` for a file it could not find, which is how a dozen
    /// structural tests came to have a silent third outcome: not pass, not
    /// fail, but assert against the empty string. Half of them pass on it
    /// (`!source.contains("bad thing")`) and half fail with a sentence about
    /// entirely the wrong thing — moving `Money.swift` to another module
    /// produced "the riyal mark moved off U+20C1" when what moved was the file.
    ///
    /// A test that reads nothing must say so.
    static func source(_ name: String, file: StaticString = #filePath,
                       line: UInt = #line) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/\(name)")
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        Issue.record("\(name) is not in Sources/KhaytApp — this test is reading nothing",
                     sourceLocation: SourceLocation(fileID: #fileID, filePath: "\(file)",
                                                    line: Int(line), column: 1))
        return ""
    }

    /// The three the window has to carry, above whatever screen is showing.
    @Test("every window-level banner is on the window, not on one screen")
    func bannersAreOnTheWindow() {
        let window = Self.source("ShopWindow.swift")
        #expect(!window.isEmpty, "ShopWindow moved")
        for banner in ["EngineBanner(shop: shop)", "MoveBanners(shop: shop)", "SpendBanner(shop: shop)"] {
            #expect(window.contains(banner), "\(banner) is not shown by the window")
        }
    }

    /// If the shared rules did not load, every figure in the app is absent or
    /// zero — and an empty dashboard looks exactly like a quiet shop. It must
    /// be said where the figures are, not only where the provenance is.
    @Test("a shop whose rules did not load is told twice, and one of them is not the sidebar")
    func engineFailureIsSaidWhereTheFiguresAre() {
        #expect(Self.source("Banners.swift").contains("shop.engineProblem"),
                "the banner does not read the engine's problem")
        #expect(Self.source("Sidebar.swift").contains("shop.engineProblem"),
                "the sidebar dropped its record of it")
    }

    /// The HIG's reason for the banner existing, kept where somebody deleting
    /// it would read it.
    @Test("the window has a floor")
    func theWindowCannotBeShrunkIntoNonsense() {
        let app = Self.source("KhaytApp.swift")
        #expect(app.contains("minWidth: 900"), "no minimum width — the columns can be crushed")
        #expect(app.contains("minHeight:"))
    }

    /// `Banner` was private to the board. It is three screens' worth of
    /// messages now, and a fourth caller having to reach into `Kanban.swift`
    /// for it is how it would end up copied instead.
    @Test("the banner belongs to the window, not to the board")
    func bannerIsShared() {
        // Matched loosely on purpose: it grew a generic accessory for the Stop
        // button on a running import, and what this guards is where it lives.
        #expect(Self.source("Banners.swift").contains("struct Banner"))
        #expect(!Self.source("Kanban.swift").contains("struct Banner"),
                "there are two Banners again")
    }
}

/// A photographed run says which appearance it is, BOTH ways.
///
/// The light run used to set none at all, so it followed whatever the Mac was
/// set to — and a Mac that switches itself at dusk then writes dark pictures
/// under light names. There is no cheap way to assert a colour without running
/// the app, so this asserts the line that decides it instead.
@MainActor
struct SnapshotAppearanceTests {
    @Test("the runner chooses an appearance either way, and only once")
    func choosesBothWays() {
        let source = BannerTests.source("KhaytApp.swift")
        #expect(source.contains("dark ? .darkAqua : .aqua"),
                "the light run no longer forces an appearance, so it follows the system")
        // Once. Changing it part way through a run is the abort this runner was
        // fixed to stop doing, and the fix holds only while nothing switches.
        #expect(source.components(separatedBy: "NSApp.appearance =").count - 1 == 1,
                "the appearance is set more than once — one of them is a switch")
    }
}

/// A column of dashes is not a column — but hiding one is a decision, and a
/// decision made twice is a decision taken away from the person who made it.
@MainActor
struct EmptyColumnTests {
    @Test("the jobs table hides an unused column once, and remembers that it did")
    func hiddenOnceAndRemembered() {
        let source = BannerTests.source("OrdersTable.swift")
        // The two columns a book can leave entirely empty, each addressable.
        #expect(source.contains("\"client\""), "the client column lost its customization id")
        #expect(source.contains("\"due\""), "the due column lost its customization id")

        // THE PART THAT MATTERS. As `@State` this reset on every launch, so the
        // hiding ran again each time and un-did a column the shop had put back.
        #expect(source.contains("@SceneStorage(\"jobs.columnsChosen\")"),
                "the decision is view state again — it will re-hide on every launch")
        #expect(!source.contains("@State private var decided"),
                "the decision is back in view state")
    }

    /// "Signed in", "Email sent": news, pinned over every screen until the next
    /// job moved, with no way to clear it. Turki read three of them as stuck
    /// warnings after signing in to the cloud.
    @Test("a notice can be closed, and goes on its own")
    func noticesCanBeCleared() {
        let shop = Shop()
        shop.moveNotices = ["one", "two", "three"]
        shop.dismissNotice(at: 1)
        #expect(shop.moveNotices == ["one", "three"])
        shop.dismissNotice(at: 9)          // out of range: nothing, no trap
        #expect(shop.moveNotices == ["one", "three"])

        let banners = BannerTests.source("Banners.swift")
        #expect(banners.contains("shop.dismissNotice(at: index)"),
                "the notice banner lost its Close button")
        #expect(banners.contains(".task(id: shop.moveNotices)")
                && banners.contains("Shop.noticeLifetime"),
                "the notices no longer clear themselves")
        #expect(Shop.noticeLifetime >= .seconds(10), "too short to read three sentences")
    }

    /// Every banner that tells a shop something can be put away: the four
    /// refusals by hand, the two green ticks by hand or on their own.
    @Test("every warning and every tick on the window has a Close button")
    func everyBannerCloses() {
        let banners = BannerTests.source("Banners.swift")
        for field in ["moveProblem", "importProblem", "convertProblem", "slicerProblem",
                      "importNote", "convertNote"] {
            #expect(banners.contains("BannerClose(words: shop.words) { shop.\(field) = nil }"),
                    "\(field) is on the window with no way to close it")
        }
        for note in ["importNote", "convertNote"] {
            #expect(banners.contains("if !Task.isCancelled, shop.\(note) == note { shop.\(note) = nil }"),
                    "\(note) is a tick that stays until the next gesture")
        }
    }
}
