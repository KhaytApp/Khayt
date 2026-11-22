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

    func testAShopsDocumentNeverReachesTheNetwork() async throws {
        let server = try Listener()
        let port = try await server.start()
        defer { server.listener.cancel() }

        // The listener hears a plain request: a silent count below is the
        // paper's doing, not a deaf listener.
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/probe")!)
        probe.timeoutInterval = 2
        _ = try? await URLSession.shared.data(for: probe)
        await waitUntil(3) { server.count > 0 }
        XCTAssertGreaterThan(server.count, 0, "the listener hears a request")
        let before = server.count

        let base = "http://127.0.0.1:\(port)"
        let html = """
        <p>INV-1</p>
        <img src="\(base)/pixel.png" alt="">
        <div style="background-image:url('\(base)/bg.png')">x</div>
        <style>@import url("\(base)/more.css");</style>
        <link rel="stylesheet" href="\(base)/sheet.css">
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" alt="local">
        """
        for whole in [false, true] {
            let paper = InvoicePaper()
            await waitUntil(5) { paper.rulesInstalled }
            XCTAssertTrue(paper.rulesInstalled)
            paper.show(InvoiceDocument(html: html, arabicNumerals: false, selector: "p"), filename: "x.pdf", wholePage: whole)
            await waitUntil(10) { paper.drawn }
            XCTAssertTrue(paper.drawn, "the paper is drawn")
            try? await Task.sleep(for: .seconds(1))
            XCTAssertEqual(server.count, before, "nothing left the phone (whole page: \(whole))")
        }
    }
}
