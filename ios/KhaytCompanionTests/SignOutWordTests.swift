import XCTest
@testable import KhaytCompanion

/// Turki (Nov 22): "Sign out" is the one word for taking a phone off, on
/// every app, and the install count is the owner's to change.
@MainActor
final class SignOutWordTests: XCTestCase {

    private func table(_ lang: String) throws -> [String: String] {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                                  inDirectory: nil, forLocalization: lang), lang)
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], lang)
    }

    /// The desktop's word (`lan.phones_sign_out`) in each language, and no
    /// "Unpair" left in any phone string.
    func testSignOutIsTheDesktopsWordEverywhere() throws {
        let word = ["en": "Sign out", "ar": "تسجيل الخروج", "de": "Abmelden", "es": "Cerrar sesión", "fr": "Déconnecter",
                    "ja": "サインアウト", "pt-BR": "Desconectar", "tr": "Oturumu kapat", "zh-Hans": "退出登录"]
        let old = ["en": "unpair", "ar": "الربط", "de": "kopplung", "es": "desempareja", "fr": "dissocier",
                   "ja": "ペアリング解除", "pt-BR": "despare", "tr": "eşleme", "zh-Hans": "配对"]
        for (lang, sayIt) in word {
            let t = try table(lang)
            XCTAssertEqual(t["settings.unpair"], sayIt, lang)
            XCTAssertTrue(t["connectors.key.footer"]?.localizedCaseInsensitiveContains(sayIt) == true, "\(lang): the footer names Sign out")
            for key in ["settings.unpair", "connectors.key.footer"] {
                XCTAssertFalse(t[key]?.lowercased().contains(old[lang]!) == true, "\(lang): \(key) still says the old word")
            }
            XCTAssertFalse((t["settings.count_install.owner_only"] ?? "").isEmpty, "\(lang): owner-only footer")
            // The dialog says what is signed out of, and that Khayt Cloud goes too (review of #2656).
            XCTAssertTrue(t["settings.unpair.title"]?.localizedCaseInsensitiveContains(sayIt) == true, "\(lang): title")
            XCTAssertTrue(t["settings.unpair.footer"]?.contains("Khayt Cloud") == true || t["settings.unpair.footer"]?.contains("سحابة خيط") == true,
                          "\(lang): the footer says Khayt Cloud is signed out too")
        }
        XCTAssertEqual(try table("en")["settings.count_install.owner_only"], "Only the owner can change this.")
    }

    func testOnlyTheOwnerChangesTheInstallCount() {
        XCTAssertTrue(SettingsPrivacyPage.ownerMayChange("owner"))
        for role in ["manager", "operator", "viewer", "", "admin"] {
            XCTAssertFalse(SettingsPrivacyPage.ownerMayChange(role), role)
        }
        // A phone paired with the PIN before roles is the owner, as it always was.
        XCTAssertTrue(SettingsPrivacyPage.ownerMayChange(DeviceRole.effective(role: nil, pairedByCode: false)))
        XCTAssertFalse(SettingsPrivacyPage.ownerMayChange(DeviceRole.effective(role: nil, pairedByCode: true)))
    }
}
