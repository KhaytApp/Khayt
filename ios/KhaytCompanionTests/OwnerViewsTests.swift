import XCTest
@testable import KhaytCompanion

/// The owner's two read-only views (signed frames 268:7 and 268:28, Turki,
/// Nov 24; the Mac's routes, #2707). Sample data only.
@MainActor
final class OwnerViewsTests: XCTestCase {

    private let devices = #"""
    {"ok":true,"devices":[
      {"deviceId":"dev_a","name":"Sample iPhone","role":"owner","pairedBy":"pin","lastSeenAt":"2026-11-24T09:00:00.000Z","self":true},
      {"deviceId":"dev_b","name":"Floor iPhone","role":"operator","pairedBy":"code","lastSeenAt":"2026-11-24T06:12:00.000Z"},
      {"deviceId":"dev_c","name":"","role":"captain","pairedBy":"code","lastSeenAt":"2026-11-23T10:00:00.000Z"},
      {"name":"no id"}
    ]}
    """#

    private func phones(_ status: Int = 200, signed: Bool = true, body: String? = nil) -> [PairedPhone]? {
        OwnerViews.phones(status: status, body: Data((body ?? devices).utf8), signed: signed)
    }

    func testThePairedPhonesAreReadAsTheMacOrderedThem() throws {
        let rows = try XCTUnwrap(phones())
        XCTAssertEqual(rows.map(\.deviceId), ["dev_a", "dev_b", "dev_c"], "a row without an id is dropped, never the list")
        XCTAssertTrue(rows[0].isSelf)
        XCTAssertFalse(rows[1].isSelf)
        XCTAssertEqual(rows[1].pairedBy, "code")
    }

    /// Nothing is shown on anything less than a signed 200 that says ok.
    func testOnlyASignedAnswerIsShown() {
        XCTAssertNil(phones(signed: false), "anything on the Wi-Fi can answer for the Mac")
        XCTAssertNil(phones(403, body: #"{"reason":"role-scope","required":"owner"}"#), "not the owner")
        XCTAssertNil(phones(404, body: "Not found"), "a computer without the route")
        XCTAssertNil(phones(200, body: #"{"ok":false,"devices":[]}"#))
        XCTAssertNil(phones(200, body: "junk"))
        XCTAssertEqual(phones(200, body: #"{"ok":true,"devices":[]}"#), [])
        let prices = #"{"ok":true,"slicerPrices":true,"connectors":[]}"#
        XCTAssertNil(OwnerViews.prices(status: 200, body: Data(prices.utf8), signed: false))
        XCTAssertNil(OwnerViews.prices(status: 403, body: Data(prices.utf8), signed: true))
        XCTAssertNotNil(OwnerViews.prices(status: 200, body: Data(prices.utf8), signed: true))
    }

    func testWhatEachPhonesRowSays() throws {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let rows = try XCTUnwrap(phones())
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-24T09:05:00Z"))
        XCTAssertEqual(OwnerViews.detail(rows[0], now: now), "Paired with the PIN · last seen now")
        XCTAssertTrue(OwnerViews.detail(rows[1], now: now).hasPrefix("Paired by number · last seen "))
        XCTAssertEqual(OwnerViews.roleWords("owner"), "Owner")
        XCTAssertEqual(OwnerViews.roleWords("operator"), "Operator")
        XCTAssertEqual(OwnerViews.roleWords("captain"), "", "a role this build does not know is not guessed at")
        XCTAssertEqual(OwnerViews.roleWords(nil), "")
        XCTAssertEqual(L10n.format("owner.phones.this", "Sample iPhone"), "Sample iPhone (this phone)")
    }

    func testLastSeenIsNowATimeYesterdayOrADate() throws {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z"))
        XCTAssertEqual(OwnerViews.lastSeen("2026-11-24T11:55:00.000Z", now: now, calendar: utc), "now")
        XCTAssertEqual(OwnerViews.lastSeen("2026-11-23T20:00:00.000Z", now: now, calendar: utc), "yesterday")
        let today = try XCTUnwrap(OwnerViews.lastSeen("2026-11-24T06:12:00Z", now: now, calendar: utc))
        XCTAssertFalse(today == "now" || today == "yesterday" || today.isEmpty, today)
        let older = try XCTUnwrap(OwnerViews.lastSeen("2026-11-10T06:12:00.000Z", now: now, calendar: utc))
        XCTAssertTrue(older.contains("10"), older)
        XCTAssertNil(OwnerViews.lastSeen(nil, now: now))
        // The book's calendar, whatever the phone's region uses: a Saudi
        // phone (Umm al-Qura) still reads Nov 10, never 1448 AH.
        XCTAssertEqual(OwnerViews.bookCalendar.identifier, .gregorian)
        XCTAssertFalse(older.contains("AH") || older.contains("1448"), older)
        XCTAssertTrue(older.contains("Nov"), older)
        XCTAssertNil(OwnerViews.lastSeen("", now: now))
        XCTAssertNil(OwnerViews.lastSeen("last Tuesday", now: now))
    }

    /// The frame's two states only: a grant is a plain `true`, anything else
    /// is hidden. How much a granted slicer sees (`grant`) is not shown.
    func testEachSlicerIsAllowedOrHidden() throws {
        let body = #"""
        {"ok":true,"slicerPrices":true,"connectors":[
          {"deviceId":"con_a","name":"Sample Orca on the studio Mac","priceGrant":true,"grant":"cost","lastSeenAt":"2026-11-24T09:00:00.000Z"},
          {"deviceId":"con_b","name":"Sample Orca on the laptop","priceGrant":false,"grant":null,"lastSeenAt":"2026-11-20T09:00:00.000Z"},
          {"deviceId":"con_c","name":"Odd","priceGrant":"yes"},
          {"deviceId":"con_d","name":"No word"}
        ]}
        """#
        let prices = try XCTUnwrap(OwnerViews.prices(status: 200, body: Data(body.utf8), signed: true))
        XCTAssertTrue(prices.shown)
        XCTAssertEqual(prices.slicers.map(\.priceGrant), [true, false, false, false], "never a grant by mistake")
        let off = try XCTUnwrap(OwnerViews.prices(status: 200, body: Data(#"{"ok":true,"connectors":[]}"#.utf8), signed: true))
        XCTAssertFalse(off.shown, "no switch in the answer reads as off")
    }

    func testOnlyTheOwnerInReachOfTheMacAsks() {
        XCTAssertTrue(OwnerViews.asks(role: "owner", macInReach: true, sampleShop: false))
        for role in ["manager", "operator", "viewer", ""] {
            XCTAssertFalse(OwnerViews.asks(role: role, macInReach: true, sampleShop: false), role)
        }
        XCTAssertFalse(OwnerViews.asks(role: "owner", macInReach: false, sampleShop: false))
        XCTAssertFalse(OwnerViews.asks(role: "owner", macInReach: true, sampleShop: true))
    }

    func testTheWordsAreInAllNineLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let en = try XCTUnwrap(NSDictionary(contentsOf: root.appending(path: "KhaytCompanion/Resources/en.lproj/Localizable.strings")) as? [String: String])
        let keys = en.keys.filter { $0.hasPrefix("owner.") }
        XCTAssertEqual(keys.count, 22)
        for lang in ["ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let url = root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys { XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang): \(key)") }
        }
    }
}
