import Foundation
import Testing
@testable import KhaytApp

/// Errors shown to a shop are sentences, never NSError's debug dump.
struct ErrorTextTests {
    @Test("a cancelled Google token request reads as the system's one word, no userInfo")
    func urlError() {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        let e = URLError(.cancelled, userInfo: [NSURLErrorFailingURLErrorKey: url,
                                                NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        let said = ErrorText.plain(e)
        #expect(!said.contains("oauth2"), "\(said)")
        #expect(!said.contains("Domain="))
        #expect(said == (e as NSError).localizedDescription)
        // and the same error arriving as a plain NSError
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                         userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        #expect(!ErrorText.plain(ns).contains("oauth2"))
    }

    @Test("an error's own description wins; Khayt's own enums keep their case")
    func ownErrors() {
        struct Said: LocalizedError { var errorDescription: String? { "The bucket said no" } }
        #expect(ErrorText.plain(Said()) == "The bucket said no")
        enum Ours: Error { case bucketLostIt }
        #expect(ErrorText.plain(Ours.bucketLostIt).contains("bucketLostIt"))
    }
}
