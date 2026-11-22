import Foundation
import Testing
@testable import KhaytCore

/// The `URL` the bundled rules get, which JavaScriptCore does not supply.
///
/// `URL` is a host object rather than part of ECMAScript, so a plain
/// `JSContext` has none — Node and every browser do, which is why nothing
/// noticed until a module that uses it was bundled here. `JSRuntime` installs a
/// shim over Foundation's `URLComponents`, and the shim exposes only the fields
/// something reads.
///
/// THAT LAST PART IS WHY THIS FILE EXISTS. A missing field does not fail
/// loudly: it reads as `undefined`, so a guard on it passes everything and a
/// value built from it becomes the literal string "undefined". Both happened —
/// bundling `lib/base-url.js` added three readers the shim did not have, its
/// credentials check silently accepted every `https://user:pass@host`, and the
/// address it returned was "undefined" with a path glued on.
///
/// So: every field the shim promises is asserted here, on the real runtime.
@Suite struct UrlPolyfillTests {

    /// One field of `new URL(input)`, as the bundled rules would read it.
    static func field(_ input: String, _ name: String) async throws -> String {
        let engine = try KhaytEngine()
        return try await engine.urlField(input, name)
    }

    @Test("the shim exists at all")
    func exists() async throws {
        #expect(try await Self.field("https://example.com/x", "hostname") == "example.com")
    }

    @Test("every field the shim promises is actually there")
    func everyField() async throws {
        // A field that is absent comes back as the string "undefined" rather
        // than as an error, which is exactly how this went wrong.
        let input = "https://user:secret@Example.COM:8443/v1/messages"
        let want: [String: String] = [
            "protocol": "https:",
            "hostname": "example.com",          // lowercased, as a browser does
            "port": "8443",
            "pathname": "/v1/messages",
            "host": "example.com:8443",
            "username": "user",
            "password": "secret",
            "origin": "https://example.com:8443",
            "href": input,
        ]
        for (name, expected) in want.sorted(by: { $0.key < $1.key }) {
            let got = try await Self.field(input, name)
            #expect(got == expected,
                    Comment(rawValue: "\(name): got \(got), wanted \(expected)"))
            #expect(got != "undefined", Comment(rawValue: "\(name) is not on the shim"))
        }
    }

    @Test("an address with no credentials reports empty, not undefined")
    func noCredentials() async throws {
        // `base-url.js` tests `u.username || u.password`, so these must be
        // falsy for an ordinary address and must not be the word "undefined".
        for name in ["username", "password"] {
            let got = try await Self.field("https://api.anthropic.com/v1/messages", name)
            #expect(got.isEmpty, Comment(rawValue: "\(name): got \(got)"))
        }
    }

    @Test("origin is built without the port when there is none")
    func originWithoutPort() async throws {
        #expect(try await Self.field("https://example.com/x/y", "origin") == "https://example.com")
        #expect(try await Self.field("http://localhost:11434/v1", "origin") == "http://localhost:11434")
    }

    @Test("the parsing is Foundation's, so a userinfo host resolves like a browser's")
    func userinfoHost() async throws {
        // `http://evil.com@192.168.1.50/` has a HOST of 192.168.1.50 and a
        // username of evil.com. Getting that backwards inside the SSRF guard
        // `lib/webcam.js` runs would be worse than having no guard, which is
        // why the shim does not parse anything itself.
        #expect(try await Self.field("http://evil.com@192.168.1.50/", "hostname") == "192.168.1.50")
        #expect(try await Self.field("http://evil.com@192.168.1.50/", "username") == "evil.com")
    }

    @Test("something that is not an address throws, rather than returning blanks")
    func notAnAddress() async throws {
        // Failing closed is the point: `webcam.js` wraps this in a try/catch and
        // refuses the host, and `base-url.js` turns it into "Not a valid
        // address". A shim that returned empty strings instead would have both
        // of them accepting nonsense.
        for bad in ["", "   ", "not a url", "/just/a/path"] {
            var threw = false
            do { _ = try await Self.field(bad, "hostname") } catch { threw = true }
            #expect(threw, Comment(rawValue: "\(bad.debugDescription) was accepted as an address"))
        }
    }
}
