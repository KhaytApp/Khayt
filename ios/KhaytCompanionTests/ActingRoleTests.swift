import XCTest
@testable import KhaytCompanion

/// The role this phone acts on for the owner's switches and the scopes it
/// offers (`DeviceRole.acting`, Dev Hub Nov 22, from the review of #2656): a
/// Khayt Cloud member never paired with a Mac is NOT the owner by default, and
/// an unknown role fails closed to viewer.
final class ActingRoleTests: XCTestCase {

    private func acting(role: String? = nil, byCode: Bool = false, mac: Bool = false,
                        cloud: Bool = false, cloudRole: String? = nil, sample: Bool = false) -> String {
        DeviceRole.acting(role: role, pairedByCode: byCode, heldByMac: mac,
                          cloudSignedIn: cloud, cloudRole: cloudRole, sampleShop: sample)
    }

    func testAMacGivenRoleWins() {
        for r in DeviceRole.ladder { XCTAssertEqual(acting(role: r, byCode: true, mac: true, cloud: true, cloudRole: "owner"), r) }
        XCTAssertEqual(acting(role: "admin", mac: true), "viewer", "a role this build does not know")
    }

    func testCodePairedWithNoRoleIsAViewer() {
        XCTAssertEqual(acting(byCode: true, mac: true), "viewer")
        XCTAssertEqual(acting(byCode: true, cloud: true, cloudRole: "owner"), "viewer", "the cloud never raises a code-paired phone")
    }

    func testAPrePairingOwnerHoldingTheMacsCredentialIsTheOwner() {
        XCTAssertEqual(acting(mac: true), "owner")
        XCTAssertEqual(acting(mac: true, cloud: true, cloudRole: "viewer"), "owner", "the PIN holder is the owner")
    }

    func testACloudMemberNeverPairedWithAMacActsOnTheirCloudRole() {
        XCTAssertEqual(acting(cloud: true, cloudRole: "viewer"), "viewer")
        XCTAssertEqual(acting(cloud: true, cloudRole: "operator"), "operator")
        XCTAssertEqual(acting(cloud: true, cloudRole: "manager"), "manager")
        XCTAssertEqual(acting(cloud: true, cloudRole: "owner"), "owner")
        XCTAssertEqual(acting(cloud: true, cloudRole: "editor"), "viewer", "unknown: fail closed")
        XCTAssertEqual(acting(cloud: true, cloudRole: nil), "viewer", "no role saved: fail closed")
    }

    func testACredentialDroppedWithTheShopKeptFollowsTheCloud() {
        // forgetMac(keepShop: true): the PIN and device key are gone.
        XCTAssertEqual(acting(cloud: true, cloudRole: "viewer"), "viewer")
        XCTAssertEqual(acting(), "viewer", "no Mac, no cloud: fail closed")
    }

    func testTheSampleShopIsTheOwnersDemo() {
        XCTAssertEqual(acting(sample: true), "owner")
        XCTAssertEqual(acting(cloud: true, cloudRole: "viewer", sample: true), "viewer", "a real cloud role wins")
    }

    /// The owner-only switches follow the acting role.
    func testAViewerCloudPhoneMayNotTurnTheInstallCountOn() {
        let role = acting(cloud: true, cloudRole: "viewer")
        XCTAssertFalse(SettingsPrivacyPage.mayTurn(on: true, role: role))
        XCTAssertTrue(SettingsPrivacyPage.mayTurn(on: false, role: role))
    }

    func testTheSavedCloudRoleIsReadFromDefaults() throws {
        let name = "acting-role-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertFalse(CloudSession.savedRole(defaults: d).signedIn)
        d.set("https://cloud.example", forKey: "khayt.cloud.url")
        d.set("shop-1", forKey: "khayt.cloud.shopId")
        XCTAssertTrue(CloudSession.savedRole(defaults: d).signedIn)
        XCTAssertNil(CloudSession.savedRole(defaults: d).role)
        d.set("viewer", forKey: "khayt.cloud.role")
        XCTAssertEqual(CloudSession.savedRole(defaults: d).role, "viewer")
    }
}
