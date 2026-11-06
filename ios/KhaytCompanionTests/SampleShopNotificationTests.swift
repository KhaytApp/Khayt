import XCTest
@testable import KhaytCompanion

/// The sample shop has no Mac and nothing in it really happens, so it must
/// never post a shop notification (or a feed item) to a real phone.
@MainActor
final class SampleShopNotificationTests: XCTestCase {
    func testTheSampleShopNeverSaysTheShopWentAway() {
        let settings = ConnectionSettings()
        let was = (settings.isSampleShop, settings.notifyConnection)
        defer { settings.isSampleShop = was.0; settings.notifyConnection = was.1 }
        settings.notifyConnection = true

        settings.isSampleShop = true
        let sample = CompanionNotifications()
        sample.handleHealthUpdate(state: .connected, status: nil, settings: settings)
        sample.handleHealthUpdate(state: .unreachable, status: nil, settings: settings)
        XCTAssertEqual(sample.posted, [], "the sample shop posted Khayt disconnected")

        // A real shop that goes away still says so.
        settings.isSampleShop = false
        let real = CompanionNotifications()
        real.handleHealthUpdate(state: .connected, status: nil, settings: settings)
        real.handleHealthUpdate(state: .unreachable, status: nil, settings: settings)
        XCTAssertEqual(real.posted, ["khayt.offline"])
    }
}
