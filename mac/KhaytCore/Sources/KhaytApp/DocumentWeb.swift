import Foundation
import WebKit

/// The web view a printed document is laid out in, with everything it does not
/// need switched off.
///
/// ── WHY THERE IS A WEB VIEW IN A NATIVE APP AT ALL ────────────────────────
///
/// An invoice and a sheet of labels ARE html — the same html the other app
/// prints, from `lib/invoice-document.js` and the stylesheet beside it. Laying
/// them out any other way would mean a second layout engine and a second answer
/// to what an invoice looks like, which is the thing this codebase spends most
/// of its effort preventing. The document is shared on purpose; only the window
/// around it is native.
///
/// ── AND WHY IT IS LOCKED ──────────────────────────────────────────────────
///
/// It is still a browser, handed a page built out of a shop's own data:
/// customer names, part names, invoice notes, whatever somebody typed. That
/// content is escaped — `KhaytEngine` passes a real `escapeHtml` into the
/// document rule, all five characters — so nothing here is a live hole. These
/// are the second and third lines:
///
///   NO SCRIPTS. A document has none. With `allowsContentJavaScript` off, an
///   escaping slip in some future field is a visible `<script>` on the paper
///   rather than code running.
///
///   NO NAVIGATION. Nothing but the one `loadHTMLString` is allowed to load.
///   Without this, an absolute link, a `<meta refresh>` or a redirect could
///   put a remote page inside the app's own window — the same thing the other
///   app's `will-navigate` handler refuses, which this had no equivalent of.
///
/// Neither costs the document anything: it is a page that is drawn once and
/// printed.
@MainActor
enum DocumentWeb {

    /// A web view that renders a document and does nothing else.
    static func view() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // An invoice runs no scripts. Neither does a sheet of labels.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// Whether a navigation is the document being put in, or something else.
    ///
    /// Static and separate from the delegate so it can be tested without a
    /// window: the whole rule is "the first load, and nothing after it".
    static func allows(_ url: URL?, alreadyLoaded: Bool) -> Bool {
        // `loadHTMLString` arrives as `about:blank`, and only ever once.
        guard !alreadyLoaded else { return false }
        guard let url else { return true }
        return url.scheme == "about"
    }
}
