import Foundation
import Testing
@testable import KhaytCore

/// `encodeURIComponent`, exactly.
///
/// THE 404 THIS EXISTS FOR. Swift's `.alphanumerics` escapes `_`, every shop id
/// Khayt issues contains one, and khayt-cloud's route is
/// `^/v1/shops/([A-Za-z0-9_\-]+)/store$` — so `shop%5F282eb…` matched nothing
/// and *Check the cloud* answered 404 on its first real attempt.
///
/// The expected values below came out of Node's own `encodeURIComponent`, not
/// from reading the specification and hoping.
struct UriComponentTests {

    @Test("a shop id keeps its underscore")
    func shopId() {
        // The exact id in this shop's book.
        #expect("shop_282eb707c70c7f019f1e217f12ab5866".uriComponent
                == "shop_282eb707c70c7f019f1e217f12ab5866")
    }

    @Test("the marks JavaScript leaves alone are left alone")
    func unreserved() {
        #expect("extruder1".uriComponent == "extruder1")
        #expect("123456:AAH-abc_def.ghi".uriComponent == "123456%3AAAH-abc_def.ghi")
        #expect("x'y(z)!~*".uriComponent == "x'y(z)!~*")
    }

    @Test("what must be escaped still is")
    func reserved() {
        // A segment that could otherwise change the path it sits in.
        #expect("a b/c?d#e".uriComponent == "a%20b%2Fc%3Fd%23e")
        #expect("é".uriComponent == "%C3%A9")
    }

    @Test("it is not .alphanumerics, and the difference is the bug")
    func notAlphanumerics() {
        let id = "shop_282eb707"
        #expect(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) == "shop%5F282eb707")
        #expect(id.uriComponent == id)
    }

    @Test("URL.path cannot see this, and absoluteString can")
    func pathDecodes() {
        // WHY THE TEST THAT SHOULD HAVE CAUGHT IT DID NOT. `URL.path` decodes,
        // so an assertion that the path reads `/v1/shops/shop_282/store` passes
        // for a URL whose wire form carries `%5F`. Assert on `absoluteString`.
        let wrong = URL(string: "https://x/v1/shops/shop%5F282/store")!
        #expect(wrong.path == "/v1/shops/shop_282/store", "decoded, and therefore blind")
        #expect(wrong.absoluteString.contains("%5F"), "the wire still carries the escape")
    }
}
