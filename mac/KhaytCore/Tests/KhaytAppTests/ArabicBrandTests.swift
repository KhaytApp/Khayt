import Foundation
import Testing
@testable import KhaytApp

/// Turki's ruling of Nov 10: in Arabic the app's name is written in Arabic
/// letters, خيط, and Khayt Cloud is سحابة خيط. Where خيط alone could read as
/// "filament", the words say تطبيق خيط. Two of the Mac's own Arabic lines still
/// said "Khayt Cloud" in Latin letters, and sixteen called it خيط السحابي;
/// this keeps both from coming back.
/// (The shared renderer strings are the desktop's to sweep.)
struct ArabicBrandTests {
    @Test("no Arabic word the Mac owns spells Khayt in Latin letters, or calls the cloud anything but سحابة خيط")
    func noLatinKhayt() {
        let latin = Words.own.compactMap { key, forms -> String? in
            guard let ar = forms["ar"],
                  ar.contains("Khayt") || ar.contains("خيط السحابي") || ar.contains("كلاود") else { return nil }
            return key
        }.sorted()
        #expect(latin.isEmpty, "Arabic still says Khayt in: \(latin.joined(separator: ", "))")
    }
}
