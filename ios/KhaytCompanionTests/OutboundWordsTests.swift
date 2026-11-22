import XCTest
import SwiftUI
import KhaytCore
@testable import KhaytCompanion

/// The words for a call the shop's "Make no internet calls" switch refused
/// (signed off by Turki, Nov 22: iPhone Figma page "Internet switch · photos
/// · iPhone (Nov 22)"). They are the desktop's (#2633), in all nine languages.
@MainActor
final class OutboundWordsTests: XCTestCase {

    override func tearDown() { L10n.setLanguage(.system) }

    func testTheSignedOffSentences() {
        L10n.setLanguage(.en)
        XCTAssertEqual(PhoneOutbound.words(purpose: .cloud, reason: "offline"),
                       "Khayt is set to make no internet calls. This needs Khayt Cloud.")
        XCTAssertEqual(PhoneOutbound.words(purpose: .cloud, reason: "settings-unknown"),
                       "Khayt is starting. Try again in a moment.")
        XCTAssertEqual(L10n.tr("photos.blocked.nothing_sent"), "Nothing was sent.")
        XCTAssertEqual(L10n.tr("photos.blocked.detail"),
                       "Photos can’t be shown or added from this phone. The owner can keep Khayt Cloud in Internet use on the Mac.")
        XCTAssertEqual(PhoneOutbound.words(purpose: .lookups, reason: "offline"),
                       "Khayt is set to make no internet calls. This needs lookups.")
        // A purpose the phone does not name, or a reason the rule adds later,
        // never says "Khayt Cloud" by mistake (review of #2654).
        XCTAssertEqual(PhoneOutbound.words(purpose: .ai, reason: "offline"),
                       "Khayt is set to make no internet calls. This needs the internet.")
        XCTAssertEqual(PhoneOutbound.words(purpose: .cloud, reason: "some-new-reason"),
                       "Khayt is set to make no internet calls. This needs the internet.")
    }

    /// Every place that shows `error.localizedDescription` says why, never
    /// "network error" or the type's debug text.
    func testARefusalReadsAsItsWords() {
        L10n.setLanguage(.en)
        let gate = OutboundGate()
        gate.update(book: .settings(.object(["network": .object(["offline": .bool(true)])])))
        OutboundGate.$scoped.withValue(gate) {
            XCTAssertThrowsError(try OutboundGate.shared.require(.cloud)) { error in
                XCTAssertEqual(error.localizedDescription,
                               "Khayt is set to make no internet calls. This needs Khayt Cloud.")
            }
        }
        let starting = OutboundGate()
        starting.update(book: .unread)
        OutboundGate.$scoped.withValue(starting) {
            XCTAssertThrowsError(try OutboundGate.shared.require(.cloud)) { error in
                XCTAssertEqual(error.localizedDescription, "Khayt is starting. Try again in a moment.")
            }
        }
    }

    /// The desktop's Arabic, with the purpose filled in, so both apps say
    /// the same thing in the same language.
    func testArabicIsTheDesktopsSentence() {
        L10n.setLanguage(.ar)
        XCTAssertEqual(PhoneOutbound.words(purpose: .cloud, reason: "offline"),
                       "خيط مضبوط على عدم الاتصال بالإنترنت. هذا الإجراء يحتاج إلى سحابة خيط.")
        XCTAssertEqual(PhoneOutbound.words(purpose: .cloud, reason: "settings-unknown"),
                       "خيط قيد التشغيل. حاول مرة أخرى بعد لحظة.")
    }

    /// The eight keys are in all nine languages, and the sentence takes the
    /// purpose exactly once.
    func testEveryLanguageHasTheWords() throws {
        let keys = ["outbound.blocked.offline", "outbound.blocked.settings-unknown", "outbound.purpose.cloud",
                    "outbound.purpose.lookups", "outbound.purpose.webhooks", "outbound.purpose.internet", "photos.blocked.detail",
                    "photos.blocked.nothing_sent"]
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                                      inDirectory: nil, forLocalization: lang), lang)
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], lang)
            for key in keys {
                let value = try XCTUnwrap(table[key], "\(lang): \(key)")
                XCTAssertFalse(value.isEmpty, "\(lang): \(key)")
                XCTAssertNotEqual(value, key, "\(lang): \(key)")
            }
            XCTAssertEqual(table["outbound.blocked.offline"]?.components(separatedBy: "%@").count, 2,
                           "\(lang): one purpose")
        }
    }

    // ── The signed-off frames, drawn by the real card ───────────────────

    private func render(_ view: some View, dark: Bool, ar: Bool) throws -> UIImage {
        let framed = view
            .padding(16)
            .frame(width: 393)
            .background(KhaytDesign.ground)
            .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    /// Frames A (switch on), B (a tap refused, nothing sent) and C (Khayt
    /// starting), in English and Arabic, light and dark. With
    /// `TEST_RUNNER_KHAYT_SHOTS=<dir>` each is written there as a PNG, for
    /// the PR beside the frame.
    func testTheCardDrawsTheThreeSignedOffFrames() throws {
        let out = ProcessInfo.processInfo.environment["KHAYT_SHOTS"].map { URL(filePath: $0) }
        let api = KhaytAPIClient(settings: ConnectionSettings(), withBook: false)
        let offline = OutboundGate()
        offline.update(book: .settings(.object(["network": .object(["offline": .bool(true)])])))
        let starting = OutboundGate()
        starting.update(book: .unread)
        let photos = (1...3).map { KhaytAPIClient.OrderPhoto(id: "p\($0)", url: "/v1/p/t/photos/p\($0)",
                                                            mime: "image/jpeg", bytes: 1000, at: nil) }
        let refused = OutboundBlocked(purpose: .cloud, reason: "offline")
        for lang in [AppLanguage.en, .ar] {
            L10n.setLanguage(lang)
            for dark in [false, true] {
                let frames: [(String, OutboundGate, OrderPhotosCard)] = [
                    ("A", offline, OrderPhotosCard(access: .ready(token: "t"))),
                    ("B", offline, OrderPhotosCard(access: .ready(token: "t"), photos: photos, refusedTap: refused)),
                    ("C", starting, OrderPhotosCard(access: .ready(token: "t"))),
                ]
                for (name, gate, card) in frames {
                    let image = try OutboundGate.$scoped.withValue(gate) {
                        try render(card.environmentObject(api), dark: dark, ar: lang == .ar)
                    }
                    XCTAssertGreaterThan(image.size.height, 120, "\(name) \(lang) drew")
                    if let out, let png = image.pngData() {
                        try png.write(to: out.appending(path: "photos-refused-\(name)-\(lang.rawValue)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
