import XCTest
@testable import KhaytCompanion

/// The tab bar is the system's TabView (iPhone Duo moves only system bars to
/// the side). An iPhone tab bar holds five; a sixth put Clients and Settings
/// behind "More". So compact width shows five, and regular width — iPad,
/// iPhone Duo's inner display — adds Settings as a sidebar-only tab.
final class TabLayoutTests: XCTestCase {
    private let six = (0...6).map { KhaytTabItem(id: $0, title: "t\($0)", icon: "circle") }

    func testCompactWidthFitsTheBarWithoutMore() {
        let shown = MainTabView.shown(six, regularWidth: false)
        XCTAssertEqual(shown.count, 5)
        XCTAssertFalse(shown.contains { $0.id == MainTabView.settingsTab })
        XCTAssertFalse(shown.contains { $0.id == MainTabView.calculatorTab }, "Home's header opens it")
        XCTAssertTrue(shown.contains { $0.id == 4 }, "Clients stays in the bar")
    }

    func testRegularWidthHasSettingsInTheSidebar() {
        let shown = MainTabView.shown(six, regularWidth: true)
        XCTAssertEqual(shown.count, 7)
        XCTAssertTrue(shown.contains { $0.id == MainTabView.calculatorTab }, "the calculator is a tab where there is room")
    }
}
