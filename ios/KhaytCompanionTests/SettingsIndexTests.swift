import XCTest
@testable import KhaytCompanion

/// Settings in groups (S2): every row sits in a group, says something in
/// every language, and goes somewhere; the search finds rows by what they
/// say, whatever the case, accents or Arabic marks.
final class SettingsIndexTests: XCTestCase {
    private let languages: [AppLanguage] = [.en, .ar, .de, .es, .fr, .ja, .ptBR, .tr, .zhHans]

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    // MARK: Search

    private let rows: [(id: String, labels: [String])] = [
        ("notifications", ["Notifications", "Low filament"]),
        ("resume", ["Résumé"]),
        ("mac", ["Phones & Wi-Fi", "Owner LAN PIN"]),
        ("ar", ["الإشعارات", "المظهر واللغة"]),
    ]

    func testAnEmptyQueryKeepsEveryRowInOrder() {
        XCTAssertEqual(SettingsSearch.matches("", in: rows), ["notifications", "resume", "mac", "ar"])
        XCTAssertEqual(SettingsSearch.matches("   ", in: rows), ["notifications", "resume", "mac", "ar"])
    }

    func testCaseAndAccentsDoNotCount() {
        XCTAssertEqual(SettingsSearch.matches("NOTIF", in: rows), ["notifications"])
        XCTAssertEqual(SettingsSearch.matches("resume", in: rows), ["resume"])
        XCTAssertEqual(SettingsSearch.matches("RÉSU", in: rows), ["resume"])
    }

    func testAPageIsFoundByWhatItHolds() {
        XCTAssertEqual(SettingsSearch.matches("pin", in: rows), ["mac"])
        XCTAssertEqual(SettingsSearch.matches("filament", in: rows), ["notifications"])
    }

    func testArabicMarksDoNotCount() {
        // Hamza seat, harakat and tatweel left out or added.
        XCTAssertEqual(SettingsSearch.matches("الاشعارات", in: rows), ["ar"])
        XCTAssertEqual(SettingsSearch.matches("الإشْعَارات", in: rows), ["ar"])
        XCTAssertEqual(SettingsSearch.matches("اللـغة", in: rows), ["ar"])
    }

    func testNothingMatchesNothing() {
        XCTAssertEqual(SettingsSearch.matches("zzz", in: rows), [])
    }

    func testTheRealRowsAreFoundInEnglishAndArabic() {
        func search(_ q: String) -> [SettingsRoute] {
            SettingsSearch.matches(q, in: SettingsRoute.allCases.map { (id: $0, labels: $0.searchLabels()) })
        }
        L10n.setLanguage(.en)
        XCTAssertTrue(search("lock screen").contains(.notifications))
        XCTAssertTrue(search("pin").contains(.mac))
        XCTAssertTrue(search("mac").contains(.mac))
        XCTAssertEqual(search("diagnos"), [.diagnostics])
        L10n.setLanguage(.ar)
        XCTAssertTrue(search("الاشعارات").contains(.notifications), "\(search("الاشعارات"))")
    }

    // MARK: Rows

    func testEveryGroupHasRowsAndEveryRowAGroup() {
        for group in SettingsRoute.Group.allCases {
            XCTAssertFalse(SettingsRoute.rows(in: group, showsConnectors: true).isEmpty, group.rawValue)
        }
        let all = SettingsRoute.Group.allCases.flatMap { SettingsRoute.rows(in: $0, showsConnectors: true) }
        XCTAssertEqual(Set(all), Set(SettingsRoute.allCases))
        XCTAssertFalse(SettingsRoute.rows(in: .connected, showsConnectors: false).contains(.connectors))
    }

    func testTheDesignsOrder() {
        XCTAssertEqual(SettingsRoute.rows(in: .thisPhone, showsConnectors: true), [.appearance, .notifications, .privacy])
        XCTAssertEqual(SettingsRoute.rows(in: .shop, showsConnectors: true), [.shop])
        XCTAssertEqual(SettingsRoute.rows(in: .connected, showsConnectors: true), [.mac, .cloud, .connectors])
        XCTAssertEqual(SettingsRoute.rows(in: .about, showsConnectors: true), [.help, .diagnostics])
    }

    func testEveryRowGoesSomewhere() {
        for route in SettingsRoute.allCases {
            switch route.destination {
            case .page: XCTAssertNotEqual(route, .help)
            case .link(let url): XCTAssertEqual(url.host, "khaytapp.com", route.rawValue)
            }
        }
        XCTAssertEqual(SettingsRoute.diagnostics.destination, .page, "Diagnostics is a visible row with a page")
    }

    func testEveryLabelIsTranslatedInEveryLanguage() {
        let keys = SettingsRoute.allCases.flatMap { [$0.titleKey] + $0.searchKeys }
            + SettingsRoute.Group.allCases.map(\.titleKey)
            + ["settings.search", "settings.search.none", "settings.diag.syncs"]
        let states: [SettingsState] = [.paired, .away, .notPaired, .sampleShop, .signedIn, .needsSignIn, .on, .off]
        for lang in languages {
            L10n.setLanguage(lang)
            for key in keys {
                XCTAssertNotEqual(L10n.tr(key), key, "\(lang.rawValue): \(key)")
            }
            for state in states {
                XCTAssertFalse(state.label.hasPrefix("state."), "\(lang.rawValue): \(state)")
            }
        }
    }

    /// A row that is also a shared Settings pane (Mac 91:435) has its name.
    func testSharedPanesKeepTheirNames() {
        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.tr(SettingsRoute.shop.titleKey), "Shop details")
        XCTAssertEqual(L10n.tr(SettingsRoute.mac.titleKey), "Phones & Wi-Fi")
        XCTAssertEqual(L10n.tr(SettingsRoute.cloud.titleKey), "Khayt Cloud")
        XCTAssertEqual(L10n.tr(SettingsRoute.connectors.titleKey), "Connectors")
        XCTAssertEqual(L10n.tr(SettingsRoute.notifications.titleKey), "Notifications", "the phone's own pushes, not Messages & alerts")
    }

    /// The sample shop has no Mac: never a green "Paired", whatever else is set.
    func testTheSampleShopIsNeverPaired() {
        for paired in [true, false] {
            for inReach in [true, false] {
                XCTAssertEqual(SettingsState.mac(paired: paired, inReach: inReach, sampleShop: true), .sampleShop)
            }
        }
        XCTAssertEqual(SettingsState.sampleShop.tone, .neutral)
        for lang in languages {
            L10n.setLanguage(lang)
            XCTAssertNotEqual(SettingsState.sampleShop.label, "sample.banner", lang.rawValue)
        }
    }

    /// The phone pairs with Khayt on a Mac or a PC: the address field says so.
    func testTheAddressSaysMacOrPC() {
        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.tr("settings.host"), "Mac or PC address")
    }

    func testTheLANReferenceIsGone() {
        XCTAssertFalse(SettingsRoute.allCases.flatMap(\.searchKeys).contains("settings.docs"))
        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.tr("settings.docs"), "settings.docs")
    }

    // MARK: States

    func testStatesSayTheSameEverywhere() {
        XCTAssertEqual(SettingsState.mac(paired: true, inReach: true), .paired)
        XCTAssertEqual(SettingsState.mac(paired: true, inReach: false), .away)
        XCTAssertEqual(SettingsState.mac(paired: false, inReach: true), .notPaired)
        XCTAssertEqual(SettingsState.away.tone, .neutral)
        XCTAssertEqual(SettingsState.cloud(signedIn: true, needsSignIn: false), .signedIn)
        XCTAssertEqual(SettingsState.cloud(signedIn: true, needsSignIn: true), .needsSignIn)
        XCTAssertEqual(SettingsState.cloud(signedIn: false, needsSignIn: false), .off)
        XCTAssertEqual(SettingsState.paired.tone, .good)
        XCTAssertEqual(SettingsState.signedIn.tone, .good)
        XCTAssertEqual(SettingsState.on.tone, .good)
        XCTAssertEqual(SettingsState.needsSignIn.tone, .waiting)
        XCTAssertEqual(SettingsState.off.tone, .neutral)
        XCTAssertEqual(SettingsState.away.tone, .neutral)
    }
}
