import Foundation

/// Where a SwiftPM resource bundle actually is, once the app has been assembled.
///
/// ── THE BUG THIS EXISTS TO PREVENT ────────────────────────────────────────
///
/// `Bundle.module` is not a search. SwiftPM generates it, per target, as
/// exactly two paths:
///
///     let mainPath  = Bundle.main.bundleURL.appendingPathComponent("KhaytCore_KhaytCore.bundle").path
///     let buildPath = "/Users/…/mac/KhaytCore/.build/arm64-apple-macosx/release/KhaytCore_KhaytCore.bundle"
///     guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { fatalError(…) }
///
/// `mainPath` is the bundle ROOT — `Khayt.app/KhaytCore_KhaytCore.bundle` —
/// and nothing may be put there: a loose file outside `Contents/` is unsealed
/// and codesign refuses the whole bundle. So `make-app.sh` puts the resources
/// in `Contents/Resources`, which is correct, and which `Bundle.module` does
/// not look in.
///
/// Which leaves `buildPath`: an ABSOLUTE path, baked in at compile time, to the
/// build directory on the machine that compiled it. On the developer's Mac that
/// directory is right there, so the app launched — by reaching outside itself,
/// into `.build`. On CI that path is `/Users/runner/work/Khayt/Khayt/…`, which
/// exists on no shop's Mac, so the SHIPPED app died on its first line:
///
///     KhaytCore/resource_bundle_accessor.swift:12: Fatal error: could not load
///     resource bundle: from /Applications/Khayt.app/KhaytCore_KhaytCore.bundle
///     or /Users/runner/work/Khayt/Khayt/mac/KhaytCore/.build/…
///
/// 4.0.0-alpha.1 and alpha.2 both shipped that way. Every local build worked and
/// every downloaded one crashed before it drew a window, which is the worst
/// shape a bug can have: invisible to the person who can fix it, total for
/// everybody else.
///
/// The Quick Look preview extension hit this first and fixed it for itself in
/// `KhaytPreview/Rules.swift`. Fixing it in one extension left the app, the
/// other extension and every future target still holding the loaded gun, so the
/// lookup is here now and `Bundle.module` is banned — see
/// `BundledLogicIsNotAForkTests.bundleModuleIsNeverUsedDirectly`.
public enum BundledResources {

    /// A target's resource bundle, looked for where an assembled app keeps it.
    ///
    /// The order is deliberate. `Contents/Resources` first, because that is
    /// where a real `.app` and a real `.appex` carry it and a shipped app must
    /// never depend on anything outside itself. The bundle root second, because
    /// that is the layout `swift run` produces. `fallback` last and lazily —
    /// callers pass their own `Bundle.module`, which is correct for `swift test`
    /// on the machine that built it, and which traps if it is ever reached in a
    /// shipped app. Reaching it there is a bug, and trapping is how it is heard.
    ///
    /// - Parameters:
    ///   - name: SwiftPM's name for it, `<Package>_<Target>` — e.g.
    ///     `KhaytCore_KhaytCore`. Without `.bundle`.
    ///   - fallback: what to use when it is not in the app. Autoclosure so a
    ///     trapping `Bundle.module` is not evaluated unless it is needed.
    public static func bundle(_ name: String,
                              fallback: @autoclosure () -> Bundle) -> Bundle {
        let file = "\(name).bundle"
        let main = Bundle.main
        for directory in [main.resourceURL, main.bundleURL] {
            guard let url = directory?.appending(path: file) else { continue }
            if let found = Bundle(url: url) { return found }
        }
        return fallback()
    }

    /// The shared JavaScript — `lib/`, copied in by `mac/sync-js.sh`.
    ///
    /// Every host that runs Khayt's rules goes through here, so an app, an
    /// extension and a test all read one copy from one place.
    public static var javaScript: Bundle { bundle("KhaytCore_KhaytCore", fallback: .module) }
}
