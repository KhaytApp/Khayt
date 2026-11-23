import XCTest
import Network
import WebKit
import KhaytCore
@testable import KhaytCompanion

/// The invoice web view loads nothing that is not on the phone (follow-up to
/// #2638): an `<img src="http://…">`, a CSS `url()` or an `@import` in a
/// shop's document never leaves the phone, online or not, as the desktop's
/// CSP (`img-src 'self' data: blob:`). Proved against a listener on this
/// machine: it hears a plain request, and hears nothing from the paper.
@MainActor
final class InvoiceLocalOnlyTests: XCTestCase {

    /// A TCP listener on localhost that counts the connections it is offered.
    private final class Listener: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                self.lock.lock(); self._count += 1; self.lock.unlock()
                c.start(queue: .global())
                c.cancel()
            }
        }

        func start() async throws -> UInt16 {
            let ready = AsyncStream<UInt16?> { cont in
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: cont.yield(self?.listener.port?.rawValue); cont.finish()
                    case .failed, .cancelled: cont.yield(nil); cont.finish()
                    default: break
                    }
                }
            }
            listener.start(queue: .global())
            for await port in ready { if let port { return port } }
            throw URLError(.cannotConnectToHost)
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func testTheRulesCompileAndThePagesCarryThePolicy() async throws {
        let list = await InvoicePaper.localOnlyList()
        XCTAssertNotNil(list, "the content blocker compiles")
        let page = InvoicePaper.page(InvoiceDocument(html: "<p>INV-1</p>", arabicNumerals: false, selector: "p"))
        let csp = try XCTUnwrap(page.range(of: "Content-Security-Policy"))
        let style = try XCTUnwrap(page.range(of: "<style>"))
        XCTAssertLessThan(csp.lowerBound, style.lowerBound, "the policy holds before anything is named")
        XCTAssertTrue(InvoicePaper.localOnlyCSP.contains("img-src data: blob:"))
        XCTAssertTrue(InvoicePaper.localOnlyCSP.contains("default-src 'none'"))

        let whole = InvoicePaper.withPolicy("<!doctype html><html><HEAD><title>Slip</title></HEAD><body>x</body></html>")
        XCTAssertTrue(whole.contains("<HEAD><meta http-equiv=\"Content-Security-Policy\""), "first in its own head")
        let bare = InvoicePaper.withPolicy("<p>slip</p>")
        XCTAssertTrue(bare.hasPrefix("<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\""))
    }

    /// A document full of remote loads: an image, a CSS `url()`, an
    /// `@import`, a stylesheet link, a preconnect and a DNS prefetch.
    private func remote(_ base: String) -> String {
        """
        <link rel="preconnect" href="\(base)/">
        <link rel="dns-prefetch" href="\(base)/">
        <p>INV-1</p>
        <img src="\(base)/pixel.png" alt="">
        <div style="background-image:url('\(base)/bg.png')">x</div>
        <style>@import url("\(base)/more.css");</style>
        <link rel="stylesheet" href="\(base)/sheet.css">
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" alt="local">
        """
    }

    /// A web view sized like the sheet's and in a window, so WebKit lays the
    /// page out and fetches what it names.
    private func host(_ view: WKWebView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        return window
    }

    func testAShopsDocumentNeverReachesTheNetwork() async throws {
        let server = try Listener()
        let port = try await server.start()
        defer { server.listener.cancel() }
        let base = "http://127.0.0.1:\(port)"
        let html = remote(base)

        // Positive control: the same document in a plain web view, with no
        // blocker and no policy, IS heard. A silent count below is then the
        // paper's doing, not a WebKit that fetched nothing.
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let plain = WKWebView(frame: .zero, configuration: config)
        let w0 = host(plain)
        plain.loadHTMLString(html, baseURL: nil)
        await waitUntil(10) { server.count > 0 }
        XCTAssertGreaterThan(server.count, 0, "an unguarded web view fetches the remote parts")
        _ = w0
        try? await Task.sleep(for: .seconds(1))
        var before = server.count

        // The blocker alone: the html loaded straight into the paper's web
        // view, with no CSP, is silent.
        let bare = InvoicePaper()
        let w1 = host(bare.webView)
        await waitUntil(5) { bare.rulesSettled }
        XCTAssertTrue(bare.rulesInstalled, "the content blocker is attached")
        bare.webView.loadHTMLString(html, baseURL: nil)
        try? await Task.sleep(for: .seconds(2))
        XCTAssertEqual(server.count, before, "the content blocker alone blocks every remote load")
        _ = w1

        // The paper as the app uses it: wrapped, and as a whole page with a head of its own.
        before = server.count
        let wholePage = "<!doctype html><html><head lang=\"en\"><title>Slip</title></head><body>" + html + "</body></html>"
        for (doc, whole) in [(html, false), (wholePage, true)] {
            let paper = InvoicePaper()
            let w = host(paper.webView)
            paper.show(InvoiceDocument(html: doc, arabicNumerals: false, selector: "p"), filename: "x.pdf", wholePage: whole)
            await waitUntil(10) { paper.drawn }
            XCTAssertTrue(paper.drawn, "the paper is drawn")
            try? await Task.sleep(for: .seconds(1))
            XCTAssertEqual(server.count, before, "nothing left the phone (whole page: \(whole))")
            _ = w
        }
        XCTAssertTrue(InvoicePaper.withPolicy(wholePage).contains("<head lang=\"en\"><meta http-equiv=\"Content-Security-Policy\""))
    }
}
