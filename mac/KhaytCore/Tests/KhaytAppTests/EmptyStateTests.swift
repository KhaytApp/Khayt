import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The empty states, and the one Apple component still allowed.
///
/// `ContentUnavailableView` is a good component and the single most generic
/// thing in a SwiftUI app: the same grey glyph and the same layout in every
/// app on the Mac. Twenty-nine of them were counted here once. Twenty-two were
/// replaced by `EmptyHere`, and the last seven — `.search`, on every screen
/// with a search box — by `NothingMatched`.
///
/// Source checks, for the reason `BannerTests` gives: a SwiftUI body cannot be
/// asked what it drew, and the defect being guarded is not "it renders wrongly"
/// but "this screen went back to the borrowed one" — which is what an eighth
/// searchable screen would do without noticing, because the borrowed one is
/// what autocomplete offers.
@MainActor
struct EmptyStateTests {

    static func source(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Every screen a search can empty, and the mark each one draws.
    static let searchable: [(file: String, mark: String)] = [
        ("OrdersTable.swift", ".jobs"),
        ("Kanban.swift", ".board"),
        ("ShopFloor.swift", ".filament"),
        ("LibraryGrid.swift", ".library"),
        ("CustomersTable.swift", ".clients"),
        ("GiftCards.swift", ".giftCards"),
        ("Portfolio.swift", ".portfolio"),
    ]

    @Test("no screen falls back to the system's search-empty view")
    func noBorrowedSearchEmpty() {
        for (file, _) in Self.searchable {
            let text = Self.source(file)
            #expect(!text.isEmpty, "\(file) moved")
            #expect(!text.contains("ContentUnavailableView.search"),
                    "\(file) went back to Apple's search-empty view")
        }
    }

    @Test("every screen a search can empty says so in the app's own hand")
    func allUseNothingMatched() {
        for (file, mark) in Self.searchable {
            let text = Self.source(file)
            #expect(text.contains("NothingMatched(shop: shop, mark: \(mark))"),
                    "\(file) does not draw its own mark when a search empties it")
        }
    }

    /// A screen that names its own mark is the point: an emptied shelf shows a
    /// spool, an emptied board shows lanes. Seven screens sharing one drawing
    /// is the state this replaced.
    @Test("no two searchable screens draw the same mark")
    func marksAreDistinct() {
        let marks = Self.searchable.map(\.mark)
        #expect(marks.count == Set(marks).count)
    }

    /// The two failure states keep the system's component ON PURPOSE, and this
    /// is here so that a later sweep for "the last ContentUnavailableView"
    /// finds the reason rather than the call.
    ///
    /// A book that will not open is a FAILURE, not an empty screen. The drawn
    /// mark that says "nothing here yet" would say the wrong thing cheerfully.
    @Test("a book that will not open keeps the system's warning")
    func failuresKeepTheWarning() {
        for file in ["OrdersTable.swift", "LibraryGrid.swift"] {
            let text = Self.source(file)
            #expect(text.contains("exclamationmark.octagon"),
                    "\(file) lost the warning octagon on the state that is a failure")
        }
    }

    /// The way out belongs on the screen that is in the way. Apple's component
    /// has nothing to press, so a shop that had narrowed itself into a blank
    /// screen had to go and find the search field again.
    @Test("the emptied screen offers a way out of both filters")
    func offersTheWayOut() {
        let craft = Self.source("Craft.swift")
        #expect(craft.contains("shop.search = \"\""), "nothing clears the search")
        #expect(craft.contains("shop.shelf = .jobs(nil)"), "nothing clears the stage")
    }

    /// The words exist in both languages the Mac app speaks — a missing one
    /// renders as its own key, which is what `queue.delivered` did in the first
    /// photograph of this screen.
    @Test("the words for an emptied screen are written in both languages")
    func wordsExist() {
        let words = Words()
        for key in ["mac.nothing_matches", "mac.and_only_stage",
                    "mac.clear_search", "mac.show_all_stages"] {
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) has no English")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) has no Arabic")
            #expect(words.callIt(key) != key, "\(key) renders as its own key")
        }
    }

    /// The term goes into the sentence, in both languages. A placeholder that
    /// is spelt differently in one of them silently drops the word the shop
    /// typed — leaving "Nothing matches “”".
    @Test("the search term reaches the sentence in both languages")
    func termIsSubstituted() async throws {
        for language in ["en", "ar"] {
            let words = Words()
            await words.load(language, engine: try KhaytEngine())
            let line = words.callIt("mac.nothing_matches", ["q": .string("petg")])
            #expect(line.contains("petg"), "\(language): the term was dropped")
            #expect(!line.contains("{q}"), "\(language): the placeholder was left in")
        }
    }
}

/// The board asks the rules BEFORE the card lands.
///
/// Source checks, for the reason `BannerTests` gives: a SwiftUI body cannot be
/// asked what it drew, and the defect guarded here is not "the column is the
/// wrong grey" — it is "nothing asks", which is the state this app was in for
/// as long as the board has existed. `KhaytEngine.statusGate` was written for
/// exactly this and documented as "what greys out a drop target before anything
/// is dragged onto it", and no screen called it.
@MainActor
struct DragFeedbackTests {

    static func source(_ name: String) -> String { EmptyStateTests.source(name) }

    @Test("picking a card up asks every column")
    func theBoardAsks() {
        let board = Self.source("Kanban.swift")
        #expect(!board.isEmpty, "Kanban.swift moved")
        #expect(board.contains("shop.beganDragging(id)"),
                "nothing tells the shop a card was picked up")
        #expect(board.contains("shop.dragRefusal(stage)"),
                "the column never asks whether it would take the card")
    }

    /// The drop is refused here too. The engine refuses it again inside
    /// `moveJob` — this does not replace that, it stops a drop the board has
    /// already drawn as barred from looking accepted.
    @Test("a barred column does not accept the drop")
    func theDropIsRefused() {
        #expect(Self.source("Kanban.swift").contains("guard shop.dragRefusal(stage) == nil"),
                "a column drawn as barred still takes the card")
    }

    /// A drag that is abandoned tells nobody, so the state that dims the board
    /// has to be cleared by something other than a successful drop.
    @Test("an abandoned drag cannot leave the board greyed out")
    func theDragAlwaysEnds() {
        let shop = Self.source("Shop.swift")
        #expect(shop.contains("addLocalMonitorForEvents"), "a release inside the app ends nothing")
        #expect(shop.contains("addGlobalMonitorForEvents"), "a release outside the app ends nothing")
        #expect(shop.contains("NSEvent.removeMonitor"), "the watchers are never taken down")
        // NOT `isTargeted`: it goes false every time the pointer crosses from
        // one column to the next, so clearing on it would end the drag halfway
        // across the board.
        #expect(!shop.contains("isTargeted") || !shop.contains("stoppedDragging()\n        }"),
                "the drag looks like it ends on a column change")
    }
}
