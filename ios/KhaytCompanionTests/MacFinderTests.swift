import XCTest
@testable import KhaytCompanion

/// Which name the phone looks its Mac up by when the address stops answering.
@MainActor
final class MacFinderTests: XCTestCase {
    override func setUp() {
        for k in ["khayt.serviceName", "khayt.shopLabel", "khayt.host"] { UserDefaults.standard.removeObject(forKey: k) }
    }
    override func tearDown() { setUp() }

    func testThePairedNameIsTheOneLookedUp() {
        let s = ConnectionSettings()
        s.host = "192.168.68.75"
        s.shopLabel = "Front desk"          // renamed by the person
        s.serviceName = "Turki’s Mac"
        XCTAssertEqual(s.bonjourName, "Turki’s Mac", "a renamed label is not the Mac's name")
    }

    func testAPhonePairedBeforeTheNameWasKeptFallsBackToTheLabel() {
        let s = ConnectionSettings()
        s.host = "192.168.68.75"
        s.shopLabel = "Turki’s Mac"         // what pairing set it to from Bonjour
        XCTAssertEqual(s.bonjourName, "Turki’s Mac")
    }

    func testATypedInAddressHasNoNameToLookUp() {
        let s = ConnectionSettings()
        s.host = "192.168.68.75"
        s.shopLabel = "192.168.68.75"       // what manual pairing sets
        XCTAssertNil(s.bonjourName, "the phone must never go looking for some other Mac")
        s.shopLabel = "My Shop"
        XCTAssertNil(s.bonjourName)
    }
}
