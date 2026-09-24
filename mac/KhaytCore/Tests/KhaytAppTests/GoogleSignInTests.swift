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
