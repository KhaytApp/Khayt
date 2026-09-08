import Foundation
import KhaytCore

/// Where this extension finds the shared rules.
///
/// `KhaytEngine()` defaults to SwiftPM's `Bundle.module`, which resolves against
/// the bundle it is compiled into — and inside an `.appex` that lookup does not
/// land where the resources are. It reported
///
///     could not load resource bundle: from …/KhaytPreview.appex/KhaytCore_KhaytCore.bundle
///
/// which is the appex ROOT, and nothing may be put there: a loose file outside
/// `Contents/` is unsealed and codesign refuses the whole bundle. So the
/// resources go in `Contents/Resources` like everything else and this finds them
/// by asking, rather than by hoping CFBundle agrees.
///
/// The failure it replaces is a bad one to debug: the extension launches, finds
/// its extension point, and dies on a `Fatal error` the instant a preview is
/// asked for. Quick Look then falls back to scaling the thumbnail, so what a
/// person sees is a preview that looks nearly right and simply has no facts
/// under it.
enum Rules {

    /// An engine reading this extension's own copy of the JavaScript.
    static func engine() throws -> KhaytEngine {
        try KhaytEngine(bundle: resources ?? .main)
    }

    /// SwiftPM's resource bundle inside this extension, if it is there.
    ///
    /// Named the way SwiftPM names it — `<Package>_<Target>.bundle` — and looked
    /// for beside the other resources. `nil` falls back to the main bundle,
    /// which is what a `swift run` wants and what the tests get.
    static var resources: Bundle? {
        guard let dir = Bundle.main.resourceURL else { return nil }
        return Bundle(url: dir.appending(path: "KhaytCore_KhaytCore.bundle"))
    }
}
