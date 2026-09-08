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
// The name is SwiftPM's: it links an executable target with
// `-e _<TargetName>_main`. If a future SwiftPM renames it the link fails
// outright and says which symbol it wanted, which is the right way to find out.

@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32

@_cdecl("KhaytThumbnail_main")
func khaytThumbnailMain(_ argc: Int32,
                        _ argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32 {
    NSExtensionMain(argc, argv)
}
