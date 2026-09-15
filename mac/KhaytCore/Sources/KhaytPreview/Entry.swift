import Foundation

// The entry point, and it must not be a Swift one — see the long note in
// `Package.swift` and `KhaytThumbnail/Entry.swift`. ExtensionKit looks for a
// Swift entry point before it looks for `NSExtensionPrincipalClass`, so a
// `main.swift` here would be run instead of the preview controller and the
// process would be gone before Quick Look got a panel.

@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32

@_cdecl("KhaytPreview_main")
func khaytPreviewMain(_ argc: Int32,
                      _ argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32 {
    NSExtensionMain(argc, argv)
}

// ── AND WHY THERE ARE TWO NAMES ──────────────────────────────────────────────
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
