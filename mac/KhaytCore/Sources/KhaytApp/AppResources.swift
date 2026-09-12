import Foundation
import KhaytCore

/// This app's own resource bundle — the sample shop and the invoice stylesheet.
///
/// Not `Bundle.module`, for the reason `BundledResources` sets out at length:
/// SwiftPM compiles that accessor down to the app bundle's ROOT (where nothing
/// may be put, because codesign seals only what is inside `Contents/`) and,
/// failing that, the absolute path of the build directory on the machine that
/// compiled it. Both shipped 4.0 alphas therefore died on launch on every Mac
/// except the one that built them.
///
/// The app's own two resources fail more quietly than the JavaScript does, which
/// is why they are worth naming: a missing `sample-shop.json` is a sample book
/// that will not open, and a missing `invoice.css` is an invoice that prints
/// with no styling at all — a shop's own document, sent to a customer, as
/// unstyled HTML.
enum AppResources {
    static var bundle: Bundle { BundledResources.bundle("KhaytCore_KhaytApp", fallback: .module) }

    /// The filament catalogue, as text for the engine to parse.
    ///
    /// Nil when the resource is missing, which is a build fault rather than a
    /// shop's: `Khayt --check-resources` names it, and the search simply finds
    /// nothing without it.
    static var filamentCatalogJSON: String? {
        guard let url = bundle.url(forResource: "filament-catalog", withExtension: "json")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
