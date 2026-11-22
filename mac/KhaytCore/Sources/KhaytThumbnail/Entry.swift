import Foundation

// ── THE ENTRY POINT, AND WHY IT LOOKS LIKE THIS ───────────────────────────────
//
// An app extension is started by the system calling `NSExtensionMain`, which
// stands the plug-in up, finds `NSExtensionPrincipalClass` and hands it XPC
// connections. So this file is the whole program: a C-callable function that
// hands straight over.
//
// It is written this way — rather than as a `main.swift` — because of what
// ExtensionKit does on the way in. A Quick Look thumbnail extension on macOS 14
// and later is launched by ExtensionKit, which looks for a SWIFT ENTRY POINT in
// the binary first and only falls back to the principal class when it finds
// none. Top-level code in a `main.swift` emits a `__swift5_entry` section, and
// ExtensionKit ran that instead: the process launched, executed the top-level
// code, exited in 38 ms, and the thumbnail request came back with
// QLThumbnailErrorDomain 102 having never instantiated the provider. Apple's own
// thumbnail extensions have no `__swift5_entry` section at all. Neither does
// this one, and `EntryPointTests` fails the build if that ever changes.
//
// ── AND WHY THERE ARE TWO NAMES ──────────────────────────────────────────────
//
// That comment used to end "if a future SwiftPM renames it the link fails
// outright and says which symbol it wanted, which is the right way to find
// out." It did, and it was.
//
// SwiftPM's `native` engine links an executable with `-e _<TargetName>_main`,
// so the entry symbol is the target's name. Xcode 26.x makes `swiftbuild` the
// default engine — `native` is now marked deprecated — and that one links with
// the ordinary `_main`, so the build died with `"_main", referenced from:
// <initial-undefines>` on both extensions. Not a Khayt change: `main` at the
// time failed the same way.
//
// Defining a second `@_cdecl("main")` alongside it links the product and then
// breaks the TEST bundle: an XCTest runner brings its own `_main`, and the
// testable object is linked into it, so the two collide. So the entry symbol
// stays the one name, and `Package.swift` tells the linker to use it — which
// is what `native` was doing implicitly all along.

@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32

@_cdecl("KhaytThumbnail_main")
func khaytThumbnailMain(_ argc: Int32,
                        _ argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32 {
    NSExtensionMain(argc, argv)
}
