import Foundation

// ── THE ENTRY POINT ───────────────────────────────────────────────────────────
//
// The Safari web extension's native half, started the way every app extension
// here is: the system calls `NSExtensionMain`, which finds the principal class
// (`SafariWebExtensionHandler`) and hands it each message. Shaped exactly like
// `KhaytThumbnail/Entry.swift` and for its reasons — no `main.swift`, no
// `@main`, so the binary carries no `__swift5_entry` section for the extension
// runtime to run instead of the principal class (`ThumbnailExtensionTests`
// checks the built binary), and the entry symbol named out loud in
// `Package.swift` because the default build engine links `_main`.

@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32

@_cdecl("KhaytSafari_main")
func khaytSafariMain(_ argc: Int32,
                     _ argv: UnsafePointer<UnsafePointer<CChar>?>) -> Int32 {
    NSExtensionMain(argc, argv)
}
