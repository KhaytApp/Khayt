import XCTest
import CryptoKit
import SwiftUI
import KhaytCore
@testable import KhaytCompanion

/// The U1 run (Nov 27): around opening Baby U1's care page, the phone opened
/// 317 connections to the Mac in 65 s. That was the library picture prefetch
/// (paced since), not this page, and this test is what showed it: it opens
/// the printers tab in a real window against a stand-in Mac (a U1 printing,
/// two tagged heads, every answer signed), opens Care through the machine
/// row's own link the way a person does, and counts what the page asks for
/// while it stays open. A page shown once asks once.
@MainActor
final class CarePageLoadsOnceTests: XCTestCase {

    private static let key = Data(repeating: 7, count: 32)
    private static let identity = "care-loop-identity"
    private var dir: URL!
    private var window: UIWindow?
    private var saved: (String, Int, String, Bool, Bool, DeviceKey.Credential?, String)?
    private var settings: ConnectionSettings?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "care-loop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CountingMac.reset()
        L10n.setLanguage(.en)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        if let saved, let s = settings {
            (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.device, s.macIdentityKey) = saved
        }
        L10n.setLanguage(.system)
        try? FileManager.default.removeItem(at: dir)
    }

    private func shop() -> [String: JSONValue] {
        [
            "settings": .object([:]),
            "printLog": .array([]),
            "inventory": .array([]),
            "consumables": .array([]),
            "machines": .array([
                .object(["id": .string("u1"), "name": .string("Baby U1"), "rev": .number(1)]),
            ]),
        ]
    }

    func testTheCarePageAsksOnceWhileItStaysOpen() async throws {
        let book = CompanionBook(directory: dir)
        try book.replace(with: shop(), scope: nil)
        let s = ConnectionSettings()
        settings = s
        saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop, s.device, s.macIdentityKey)
        s.host = CountingMac.host; s.port = 3219; s.pin = "12345678"; s.isPaired = true; s.isSampleShop = false
        s.macIdentityKey = Self.identity
        s.device = .init(deviceId: "dev_careloop01", key: Self.key.base64EncodedString(), identityKey: Self.identity)

        let api = KhaytAPIClient(settings: s, protocols: [CountingMac.self], book: book)
        let health = ConnectionHealth(api: api, settings: s)
        await health.refresh()
        XCTAssertTrue(health.macInReach, "the stand-in Mac answers")
        let live = LivePrinters { try await api.fetchLivePrinters() }
        // The tab's own poll, as the app runs it.
        live.watch()

        let root = MachinesView()
            .environmentObject(AppLock())
            .environmentObject(LockScreenNames())
            .environmentObject(s)
            .environmentObject(api)
            .environmentObject(health)
            .environmentObject(NFCReader())
            .environmentObject(OrdersNavigationState())
            .environmentObject(live)
        // SwiftUI builds its accessibility elements only once accessibility
        // is on in the process; the test host starts with it off.
        if let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
           let on = dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") {
            unsafeBitCast(on, to: (@convention(c) (Bool) -> Void).self)(true)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window = window

        // The machine row's "Care" link, once the tab has read the book.
        var link: NSObject?
        for _ in 0..<50 where link == nil {
            try await Task.sleep(for: .milliseconds(100))
            link = Self.find(window) { $0.hasPrefix(L10n.tr("care.title")) }
        }
        let care = try XCTUnwrap(link, "the machine row's Care link")
        try await Task.sleep(for: .seconds(1))
        CountingMac.reset()
        XCTAssertTrue(care.accessibilityActivate(), "the link opens")

        try await Task.sleep(for: .seconds(20))
        let counts = CountingMac.counts()
        print("CARE-LOOP counts over 20 s: \(counts.sorted { $0.key < $1.key })")
        let trays = counts.filter { $0.key.hasPrefix("/api/printer/") }.values.reduce(0, +)
        let all = counts.filter { !$0.key.hasPrefix("/api/machines/live") && !$0.key.hasPrefix("/api/status") }
            .values.reduce(0, +)
        XCTAssertLessThanOrEqual(trays, 2, "the spool tags are asked for once, not on every redraw")
        XCTAssertLessThanOrEqual(all, 6, "a page shown once asks once: \(counts)")
    }

    /// The first accessibility element under `root` whose label matches.
    static func find(_ root: NSObject, depth: Int = 0, _ match: (String) -> Bool) -> NSObject? {
        guard depth < 60 else { return nil }
        if root !== UIApplication.shared, let label = root.accessibilityLabel, match(label),
           root.accessibilityTraits.contains(.button) || root.accessibilityTraits.contains(.link) {
            return root
        }
        var kids: [NSObject] = []
        if let elements = root.accessibilityElements as? [NSObject] { kids += elements }
        let n = root.accessibilityElementCount()
        if n != NSNotFound, n > 0 {
            for i in 0..<n { if let k = root.accessibilityElement(at: i) as? NSObject { kids.append(k) } }
        }
        if let view = root as? UIView { kids += view.subviews }
        for k in kids { if let found = find(k, depth: depth + 1, match) { return found } }
        return nil
    }
}

/// A Mac that answers anything and counts what it was asked, per path.
final class CountingMac: URLProtocol, @unchecked Sendable {
    static let host = "khayt-careloop.invalid"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: [String: Int] = [:]
    static func reset() { lock.withLock { asked = [:] } }
    static func counts() -> [String: Int] { lock.withLock { asked } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.asked[path, default: 0] += 1 }
        let tick = Self.lock.withLock { Self.asked[path, default: 0] }
        let (status, body): (Int, String) = switch path {
        case "/api/status": (200, #"{"ok":true,"queued":0}"#)
        // A U1 printing, its reading moving on every poll, as on the bench.
        case "/api/machines/live":
            (200, #"[{"id":"u1","name":"Baby U1","hasPrinterApi":true,"state":"printing","progress":\#(min(tick, 99)),"filename":"Bracket.gcode","timeRemaining":\#(3600 - tick * 4),"tempNozzle":220,"tempBed":60}]"#)
        case let p where p.hasSuffix("/trays"):
            (200, ##"{"ok":true,"trays":[{"head":1,"tag":{"manufacturer":"Polymaker","material":"PLA","sub":"SnapSpeed","colours":["#080A0D"],"weightG":500},"key":"k-1","match":{"kind":"new"},"linked":null},{"head":2,"tag":{"material":"PLA","colours":["#E2DEDB"]},"key":"k-2","match":{"kind":"new"},"linked":null}]}"##)
        case let p where p.hasSuffix("/timelapse"): (200, #"{"ok":true}"#)
        default: (404, #"{"error":"Not found"}"#)
        }
        let data = Data(body.utf8)
        var headers = ["Content-Type": "application/json"]
        // Signed as the paired Mac signs: the phone believes these answers.
        if request.value(forHTTPHeaderField: "x-khayt-device") != nil, let nonce = request.value(forHTTPHeaderField: "x-khayt-nonce") {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let text = "khayt-reply-v1\n\(nonce)\n\(status)\n\(hash)"
            headers["x-khayt-reply-mac"] = Data(HMAC<SHA256>.authenticationCode(
                for: Data(text.utf8), using: SymmetricKey(data: Data(repeating: 7, count: 32)))).base64EncodedString()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
