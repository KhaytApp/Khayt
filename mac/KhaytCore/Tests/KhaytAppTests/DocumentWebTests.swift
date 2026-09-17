import Foundation
import WebKit
import Testing
@testable import KhaytApp

/// The only web views in this app do nothing but draw a document.
///
/// An invoice and a sheet of labels are html — the same html the other app
/// prints — so the document is shared on purpose and only the window around it
/// is native. It is still a browser handed a page built out of a shop's own
/// data, and it had neither of the two locks the other app puts on its own
/// window: scripts were enabled and any navigation was allowed.
///
/// The content IS escaped, so neither was a live hole. These are the second and
/// third lines, and they cost a printed document nothing.
@MainActor
struct DocumentWebTests {

    @Test("a document web view runs no scripts")
    func scriptsAreOff() {
        let view = DocumentWeb.view()
        #expect(view.configuration.defaultWebpagePreferences.allowsContentJavaScript == false,
                "an invoice can run scripts — an escaping slip would then execute")
    }

    @Test("the document goes in; nothing else gets to load")
    func onlyTheDocumentLoads() {
        // `loadHTMLString` arrives as about:blank, once.
        #expect(DocumentWeb.allows(URL(string: "about:blank"), alreadyLoaded: false))
        #expect(DocumentWeb.allows(nil, alreadyLoaded: false))

        // Everything a page might try afterwards.
        #expect(!DocumentWeb.allows(URL(string: "https://evil.example/x"), alreadyLoaded: false),
                "a remote page could load inside the app's own window")
        #expect(!DocumentWeb.allows(URL(string: "http://192.168.1.1/"), alreadyLoaded: false))
        #expect(!DocumentWeb.allows(URL(string: "file:///etc/passwd"), alreadyLoaded: false),
                "a local file could be read into the document")
        #expect(!DocumentWeb.allows(URL(string: "javascript:alert(1)"), alreadyLoaded: false))

        // And once it is drawn, not even another about: load.
        #expect(!DocumentWeb.allows(URL(string: "about:blank"), alreadyLoaded: true),
                "a second document could replace the one on screen")
    }

    @Test("both papers use the locked view, not a bare one")
    func bothPapersAreLocked() {
        // The labels sheet says in its own comment that it is "deliberately the
        // same machinery as InvoicePaper". This is that claim, checked — one of
        // them being hardened and the other not is exactly how the pair drifts.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        for name in ["Invoice.swift", "ShelfLabels.swift"] {
            let text = (try? String(contentsOf: dir.appending(path: name), encoding: .utf8)) ?? ""
            #expect(!text.isEmpty, Comment(rawValue: "could not read \(name)"))
            #expect(text.contains("DocumentWeb.view()"),
                    Comment(rawValue: "\(name) makes its own unlocked WKWebView"))
            #expect(text.contains("decidePolicyFor"),
                    Comment(rawValue: "\(name) allows any navigation"))
        }
    }
}
