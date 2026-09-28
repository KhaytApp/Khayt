import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

struct GoogleSignInTests {
    @Test("only GET /callback is the callback, and its query is read")
    func callback() {
        let q = GoogleSignIn.callbackQuery("GET /callback?code=4%2F0Ab&state=abc&scope=x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(q?["code"] == "4/0Ab" && q?["state"] == "abc")
        #expect(GoogleSignIn.callbackQuery("GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(GoogleSignIn.callbackQuery("POST /callback?code=x HTTP/1.1\r\n\r\n") == nil)
        #expect(GoogleSignIn.callbackQuery("") == nil)
    }

    @Test("the state is compared exactly")
    func state() {
        #expect(GoogleSignIn.constantTimeEqual("abc123", "abc123"))
        #expect(!GoogleSignIn.constantTimeEqual("abc123", "abc124"))
        #expect(!GoogleSignIn.constantTimeEqual("abc", "abc123"))
        #expect(!GoogleSignIn.constantTimeEqual("", "x"))
    }

    @Test("only a callback with this sign-in's state is taken — missing or wrong is refused, error included")
    func acceptsOnlyMatchingState() {
        #expect(GoogleSignIn.acceptsCallback(["state": "abc", "code": "c"], state: "abc"))
        #expect(GoogleSignIn.acceptsCallback(["state": "abc", "error": "access_denied"], state: "abc"))
        #expect(!GoogleSignIn.acceptsCallback(["error": "access_denied"], state: "abc"), "no state: an abort from anyone")
        #expect(!GoogleSignIn.acceptsCallback(["state": "zzz", "error": "access_denied"], state: "abc"))
        #expect(!GoogleSignIn.acceptsCallback(["state": "", "code": "c"], state: ""), "an empty state matches nothing")
    }

    // Off the main actor on purpose: the listener runs on its own queue, and
    // a full test run keeps the main actor busy enough to time a request out.
    @Test("a stray callback gets 400 and the listener keeps waiting for the real one")
    func strayCallbackDoesNotEndTheSignIn() async throws {
        let loop = try await GoogleSignIn.Loopback.start(state: "s3cr3t")
        defer { loop.stop() }
        let base = "http://127.0.0.1:\(loop.port)/callback"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        let session = URLSession(configuration: config)
        for stray in ["?error=access_denied", "?state=wrong&error=access_denied", "?state=wrong&code=x"] {
            let (_, r) = try await session.data(from: URL(string: base + stray)!)
            #expect((r as? HTTPURLResponse)?.statusCode == 400, "\(stray)")
        }
        async let real = session.data(from: URL(string: base + "?state=s3cr3t&code=good")!)
        let q = try await loop.nextCallback(timeout: 600)
        #expect(q["code"] == "good" && q["state"] == "s3cr3t")
        await loop.reply(title: "ok", body: "ok")
        let (_, r) = try await real
        #expect((r as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("the bucket wins when it is backing up; Drive is used when it is the one switched on")
    @MainActor
    func whichRemote() async {
        let bucket: JSONValue = .object(["enabled": .bool(true), "endpoint": .string("https://a.r2.cloudflarestorage.com"),
                                         "bucket": .string("b"), "accessKeyId": .string("k"), "secretAccessKey": .string("s")])
        let drive: JSONValue = .object(["enabled": .bool(true), "clientId": .string("c"), "refreshToken": .string("r")])
        let both = await CloudLibrary.config(settings: ["printLibrary": .object(["s3": bucket, "gdrive": drive])], build: nil)
        #expect(both?.isDrive == false)
        var off = bucket
        if case .object(var o) = off { o["enabled"] = .bool(false); off = .object(o) }
        let driveOnly = await CloudLibrary.config(settings: ["printLibrary": .object(["s3": off, "gdrive": drive])], build: nil)
        #expect(driveOnly?.isDrive == true && driveOnly?.backsUp == true)
        let none = await CloudLibrary.config(settings: ["printLibrary": .object(["gdrive": .object(["enabled": .bool(true)])])],
                                             build: nil)
        #expect(none == nil, "Drive with no sign-in is not a remote")
    }
}
