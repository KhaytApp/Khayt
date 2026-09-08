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
