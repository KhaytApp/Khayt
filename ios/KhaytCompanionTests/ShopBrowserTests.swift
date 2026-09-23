import XCTest
import Network
@testable import KhaytCompanion

/**
 * Turning a shop the phone found into an address it can actually open.
 *
 * The browsing itself needs a network and a Mac, so it is not what these test.
 * What they test is the part that is pure and wrong by default: how a resolved
 * endpoint is written down, and what the TXT record is taken to mean.
 */
final class ShopBrowserTests: XCTestCase {

    func testAnOrdinaryAddressIsWrittenPlainly() {
        let (host, port) = ShopBrowser.address(host: .ipv4(IPv4Address("192.168.1.42")!),
                                               port: NWEndpoint.Port(rawValue: 3219)!)
        XCTAssertEqual(host, "192.168.1.42")
        XCTAssertEqual(port, 3219)
        // The thing that matters downstream: it has to survive URL building,
        // because the API client puts it straight into one.
        XCTAssertNotNil(URL(string: "http://\(host):\(port)/api/status"))
    }

    func testALinkLocalIPv6AddressSurvivesBeingPutInAURL() {
        // The failure this exists for. A Mac can resolve to a link-local IPv6
        // address, which arrives with a zone on the end — `fe80::1%en0`. Put
        // that in a URL as it stands and `URL` refuses the whole string, so the
        // shop is told it cannot connect to an address that is perfectly good.
        let raw = IPv6Address("fe80::1c3d:ff:fe12:3456%en0")
        XCTAssertNotNil(raw, "the test's own address is malformed")
        let (host, port) = ShopBrowser.address(host: .ipv6(raw!),
                                               port: NWEndpoint.Port(rawValue: 3219)!)

        // Bracketed, because a bare IPv6 address has colons in it and a URL
        // reads the first one as the start of the port.
        XCTAssertTrue(host.hasPrefix("["), "an IPv6 address must be bracketed in a URL")
        XCTAssertTrue(host.hasSuffix("]"))
        // And the zone's `%` percent-encoded, which is the half everybody
        // forgets.
        XCTAssertFalse(host.contains("%en0"), "the raw zone separator would be refused")
        XCTAssertTrue(host.contains("%25en0"), "the zone must be percent-encoded")

        XCTAssertNotNil(URL(string: "http://\(host):\(port)/api/status"),
                        "the formatted address does not survive URL building, which is the whole job")
    }

    func testAResolvedHostnameIsUsedAsItIs() {
        let (host, _) = ShopBrowser.address(host: .name("ward.local", nil),
                                            port: NWEndpoint.Port(rawValue: 3219)!)
        XCTAssertEqual(host, "ward.local")
    }

    func testWhetherTheShopCanBeWorkedOffline() {
        // `store=1` is what separates a Mac that can hand over the book from an
        // Electron desktop that cannot, and the pairing screen says which before
        // anybody commits to it. Anything other than "1" means no — including
        // the record being absent, which is what an older Mac sends.
        XCTAssertTrue(ShopBrowser.servesBook(["store": "1"]))
        XCTAssertFalse(ShopBrowser.servesBook(["store": "0"]))
        XCTAssertFalse(ShopBrowser.servesBook([:]))
        XCTAssertFalse(ShopBrowser.servesBook(["v": "1"]))
    }

    // MARK: - What the resolver writes, the settings must accept

    /// The two halves met on Turki's phone and not in any test: the resolver
    /// wrote `[fe80::…%25en0]`, the settings refused the zone, the Mac counted
    /// as not configured, and pairing could not continue. Each half had its
    /// own passing test.
    func testAScopedIPv6AddressFromTheResolverIsAnAddressTheSettingsTake() throws {
        let raw = try XCTUnwrap(IPv6Address("fe80::1c3d:ff:fe12:3456%en0"))
        let (host, port) = ShopBrowser.address(host: .ipv6(raw), port: NWEndpoint.Port(rawValue: 3219)!)
        let url = try XCTUnwrap(ConnectionSettings.baseURL(host: host, port: Int(port)),
                                "the settings refused the address the resolver just found")
        XCTAssertEqual(url.absoluteString, "http://[fe80::1c3d:ff:fe12:3456%25en0]:3219")
        XCTAssertNotNil(URL(string: "/api/status", relativeTo: url))
    }

    func testAPlainIPv6AndAnIPv4AddressStillWork() throws {
        XCTAssertEqual(ConnectionSettings.baseURL(host: "[fe80::1]", port: 3219)?.absoluteString, "http://[fe80::1]:3219")
        XCTAssertEqual(ConnectionSettings.baseURL(host: "192.168.68.75", port: 3219)?.absoluteString, "http://192.168.68.75:3219")
    }

    func testAResolversTrailingDotIsTheSameHost() throws {
        let (host, port) = ShopBrowser.address(host: .name("Turkis-MacBook-Air.local.", nil),
                                               port: NWEndpoint.Port(rawValue: 3219)!)
        XCTAssertEqual(host, "Turkis-MacBook-Air.local")
        XCTAssertEqual(ConnectionSettings.baseURL(host: host, port: Int(port))?.absoluteString,
                       "http://Turkis-MacBook-Air.local:3219")
        // Typed with the dot, it is accepted too.
        XCTAssertNotNil(ConnectionSettings.baseURL(host: "Turkis-MacBook-Air.local.", port: 3219))
    }

    func testAZoneIsAnInterfaceNameAndNothingElse() {
        // Still a guard: a "zone" is where an injected path or userinfo would go.
        XCTAssertNil(ConnectionSettings.baseURL(host: "[fe80::1%25en0/evil]", port: 3219))
        XCTAssertNil(ConnectionSettings.baseURL(host: "[fe80::1%25]", port: 3219))
        XCTAssertNil(ConnectionSettings.baseURL(host: "[fe80::1%25en0@x.com]", port: 3219))
        XCTAssertNil(ConnectionSettings.baseURL(host: "[fe80::zz]", port: 3219))
    }
}
