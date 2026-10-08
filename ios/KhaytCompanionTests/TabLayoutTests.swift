import XCTest
@testable import KhaytCompanion

/// The tab bar is the system's TabView (iPhone Duo moves only system bars to
/// the side). An iPhone tab bar holds five; a sixth put Clients and Settings
/// behind "More". So compact width shows five, and regular width — iPad,
/// iPhone Duo's inner display — adds Settings as a sidebar-only tab.
final class TabLayoutTests: XCTestCase {
    private let six = (0...5).map { KhaytTabItem(id: $0, title: "t\($0)", icon: "circle") }

    func testCompactWidthFitsTheBarWithoutMore() {
        let shown = MainTabView.shown(six, regularWidth: false)
        XCTAssertEqual(shown.count, 5)
        XCTAssertFalse(shown.contains { $0.id == MainTabView.settingsTab })
        XCTAssertTrue(shown.contains { $0.id == 4 }, "Clients stays in the bar")
    }

    func testRegularWidthHasSettingsInTheSidebar() {
        XCTAssertEqual(MainTabView.shown(six, regularWidth: true).count, 6)
    }
}
