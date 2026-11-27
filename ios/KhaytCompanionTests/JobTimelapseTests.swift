import XCTest
@testable import KhaytCompanion

/// The print's time-lapse as proof (signed frame 7b; the Mac's routes, #2700).
/// Sample data only: what the phone reads, what it says, and who may keep.
@MainActor
final class JobTimelapseTests: XCTestCase {

    private func read(_ status: Int, _ body: String, signed: Bool = true) -> JobTimelapse {
        JobTimelapse.read(status: status, body: Data(body.utf8), signed: signed)
    }
    private func kept(_ status: Int, _ body: String) -> JobTimelapse.Kept { JobTimelapse.kept(status: status, body: Data(body.utf8)) }

    func testEachStateTheMacReports() {
        XCTAssertEqual(read(200, #"{"ok":true,"state":"none"}"#), .nothing)
        let available = read(200, #"{"ok":true,"state":"available","bytes":35651584,"url":"http://192.168.1.60/server/files/timelapse/a.mp4"}"#)
        XCTAssertEqual(available.state, .available)
        XCTAssertEqual(available.bytes, 35_651_584)
        XCTAssertEqual(available.url?.host, "192.168.1.60")
        XCTAssertFalse(available.copying)
        XCTAssertTrue(read(200, #"{"ok":true,"state":"available","bytes":1,"copying":true}"#).copying)
        XCTAssertEqual(read(200, #"{"ok":true,"state":"kept","bytes":33900000}"#).state, .kept)
        let link = read(200, #"{"ok":true,"state":"link","reason":"over-budget","bytes":188743680,"maxBytes":157286400}"#)
        XCTAssertEqual([link.reason, "\(link.maxBytes ?? 0)"], ["over-budget", "157286400.0"])
    }

    /// No card on anything but a 200-family answer with a state this build
    /// knows: never a guess.
    func testNoCardWithoutAClearAnswer() {
        for (status, body) in [(404, "Not found"), (403, #"{"reason":"role-scope","required":"orders:read"}"#),
                               (503, #"{"ok":false,"reason":"busy"}"#), (200, #"{"ok":true,"state":"something-new"}"#),
                               (200, #"{"ok":false,"state":"available"}"#), (200, "junk"), (500, #"{"ok":true,"state":"kept"}"#)] {
            XCTAssertEqual(read(status, body), .nothing, "\(status) \(body)")
            XCTAssertFalse(read(status, body).shows)
        }
    }

    /// "Open on the printer" opens only a plain web address on the shop's own
    /// network, and only from an answer the Mac signed: anything on the Wi-Fi
    /// can answer for the Mac (review of #2701).
    func testOnlyASignedAddressOnTheShopsNetworkIsOpened() {
        for good in ["http://192.168.1.60:7125/server/files/timelapse/a.mp4", "https://u1.local/a.mp4", "http://10.0.0.5/a.mp4",
                     "http://172.20.1.9/a.mp4", "http://169.254.3.4/a.mp4", "http://[fe80::1]/a.mp4"] {
            XCTAssertNotNil(JobTimelapse.lanURL(good), good)
        }
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "khayt://job/1", "tel:123", "http://user:pass@192.168.1.60/a.mp4",
                    "http:///a.mp4", "", "not a url", "https://example.com/login", "http://8.8.8.8/a.mp4", "http://172.32.0.1/a.mp4",
                    "http://192.169.1.1/a.mp4", "http://192.168.1.60.example.com/a.mp4", "http://local/a.mp4", "http://999.168.1.1/a.mp4"] {
            XCTAssertNil(JobTimelapse.lanURL(bad), bad)
        }
        let body = #"{"ok":true,"state":"link","reason":"over-budget","url":"http://192.168.1.60/a.mp4"}"#
        XCTAssertNotNil(read(200, body, signed: true).url)
        XCTAssertNil(read(200, body, signed: false).url, "an unsigned answer's address is never offered")
        XCTAssertEqual(read(200, body, signed: false).state, .link, "the card still shows; only the button goes")
        XCTAssertNil(read(200, #"{"ok":true,"state":"link","url":"javascript:alert(1)"}"#).url)
    }

    /// The Mac's megabytes: its 150 MB limit is 157,286,400 bytes.
    func testTheLimitReadsAsTheMacsOwnFigure() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertEqual(JobTimelapse.megabytes(157_286_400), "150 MB")
        XCTAssertEqual(JobTimelapse.megabytes(150 * 1_048_576 + 1), "150 MB")
        XCTAssertGreaterThanOrEqual(JobTimelapse.watchEvery * JobTimelapse.watchRounds, 300, "a copy is watched for minutes, not one request")
    }

    func testTheCardsWords() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let available = read(200, #"{"ok":true,"state":"available","bytes":35651584}"#)
        XCTAssertEqual(available.title, "Time-lapse on the printer")
        XCTAssertEqual(available.sub, "Recorded by the printer for this print")
        XCTAssertEqual(JobTimelapse.megabytes(available.bytes), "34 MB")
        XCTAssertEqual(JobTimelapse.megabytes(2_411_725), "2.3 MB")
        XCTAssertNil(JobTimelapse.megabytes(nil))
        XCTAssertNil(JobTimelapse.megabytes(0))
        let link = read(200, #"{"ok":true,"state":"link","reason":"over-budget","bytes":188743680,"maxBytes":157286400}"#)
        XCTAssertEqual(link.title, "Too large to keep here")
        XCTAssertEqual(link.sub, "Over the 150 MB limit: kept as a link to the printer")
        XCTAssertEqual(JobTimelapse.megabytes(link.bytes), "180 MB")
        XCTAssertEqual(read(200, #"{"ok":true,"state":"link","reason":"size-unknown"}"#).sub,
                       "The printer did not say its size: kept as a link to the printer")
        XCTAssertEqual(read(200, #"{"ok":true,"state":"kept"}"#).title, "Time-lapse kept as proof")
        XCTAssertEqual(read(200, #"{"ok":true,"state":"available","copying":true}"#).sub, "The Mac is copying it now")
        XCTAssertEqual(L10n.format("lapse.title", "Coffee dallah"), "Coffee dallah · time-lapse")
    }

    func testEachAnswerToKeepAsProof() {
        XCTAssertEqual(kept(201, #"{"ok":true,"state":"kept","bytes":33900000,"filename":"J-1-timelapse.mp4"}"#),
                       .done(JobTimelapse(state: .kept, bytes: 33_900_000, maxBytes: nil, reason: nil, url: nil, copying: false)))
        if case .done(let already) = kept(200, #"{"ok":true,"state":"kept"}"#) { XCTAssertEqual(already.state, .kept) } else { XCTFail("already kept") }
        if case .done(let link) = kept(200, #"{"ok":true,"state":"link","reason":"over-budget","maxBytes":157286400}"#) {
            XCTAssertEqual(link.state, .link)
        } else { XCTFail("kept as a link") }
        for reason in ["no-timelapse", "no-machine", "copying", "read-only", "cancelled"] {
            XCTAssertEqual(kept(409, #"{"ok":false,"reason":"\#(reason)"}"#), .refused(reason))
        }
        XCTAssertEqual(kept(500, #"{"ok":false,"reason":"not-saved"}"#), .refused("not-saved"))
        XCTAssertEqual(kept(502, #"{"ok":false,"reason":"printer-unreachable"}"#), .refused("printer-unreachable"))
        XCTAssertEqual(kept(403, #"{"reason":"role-scope","required":"orders:write"}"#), .refused("role-scope"))
        XCTAssertEqual(kept(404, "Not found"), .refused("not-offered"), "a computer from before the route")
        XCTAssertEqual(kept(404, #"{"ok":false,"reason":"not-found"}"#), .refused("not-found"))
        XCTAssertEqual(kept(200, #"{"ok":true,"state":"available"}"#), .refused("unreachable"), "not kept is not done")
    }

    /// The keep's answer is believed only when the Mac signed it (#2700).
    func testAnUnsignedKeepAnswerIsNotBelieved() {
        func unsigned(_ status: Int, _ body: String) -> JobTimelapse.Kept { JobTimelapse.kept(status: status, body: Data(body.utf8), signed: false) }
        XCTAssertEqual(unsigned(201, #"{"ok":true,"state":"kept","bytes":1}"#), .noAnswer, "never 'kept'")
        XCTAssertEqual(unsigned(409, #"{"ok":false,"reason":"no-timelapse"}"#), .noAnswer, "nor a forged refusal")
        XCTAssertEqual(unsigned(404, "Not found"), .refused("not-offered"))
    }

    func testEveryRefusalHasWords() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        for reason in ["no-timelapse", "no-machine", "copying", "read-only", "cancelled", "not-saved", "printer-unreachable", "busy",
                       "role-scope", "device-key-required", "not-offered", "not-found", "something-new"] {
            let words = JobTimelapse.words(reason)
            // A sentence, never the key or the bare code ("copying" is a word its own sentence uses).
            XCTAssertFalse(words.isEmpty || words.hasPrefix("lapse.") || words == reason || !words.contains(" "), reason)
        }
        XCTAssertEqual(JobTimelapse.words("cancelled"), "Someone at the Mac stopped the copy. Nothing was kept.")
    }

    func testWhoMayKeepAndWhenItIsAsked() {
        for (role, may) in [("owner", true), ("manager", true), ("operator", true), ("viewer", false)] {
            XCTAssertEqual(JobTimelapse.mayKeep(role: role), may, role)
        }
        XCTAssertTrue(JobTimelapse.asks(macInReach: true, sampleShop: false))
        XCTAssertFalse(JobTimelapse.asks(macInReach: false, sampleShop: false), "the Mac copies; away from it there is nobody to ask")
        XCTAssertFalse(JobTimelapse.asks(macInReach: true, sampleShop: true))
    }

    func testTheWordsAreInAllNineLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let en = try XCTUnwrap(NSDictionary(contentsOf: root.appending(path: "KhaytCompanion/Resources/en.lproj/Localizable.strings")) as? [String: String])
        let keys = en.keys.filter { $0.hasPrefix("lapse.") }
        XCTAssertEqual(keys.count, 27)
        for lang in ["ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let url = root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys { XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang): \(key)") }
        }
    }
}
