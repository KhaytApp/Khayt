// swift-tools-version: 6.0
import PackageDescription

/// KhaytCore — the shared heart of Khayt, on macOS.
///
/// Khayt's business logic is 29,121 lines of dependency-free JavaScript in
/// `lib/`: the tax engine, pricing, payment plans, split-order money, loyalty,
/// the estimator. It carries the corrections from twenty-two review passes and
/// is pinned by 3,598 tests.
///
/// This package does NOT reimplement any of it. macOS ships JavaScriptCore as a
/// system framework, so that code runs here unchanged, with nothing bundled and
/// no Node — and a differential test suite proves Swift and Node agree to the
/// byte. Reimplementing `computeTax` in Swift would earn the right to be wrong
/// in a second, different way, and every future fix would have to be made twice.
///
/// What IS written in Swift: the store, the platform layer, and the interface.
let package = Package(
    name: "KhaytCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KhaytCore", targets: ["KhaytCore"]),
        .executable(name: "Khayt", targets: ["KhaytApp"]),
        // The Quick Look thumbnail extension. Its own product because it is its
        // own binary inside its own bundle — see `make-app.sh`, which assembles
        // the .appex the way it already assembles the .app.
        .executable(name: "KhaytThumbnail", targets: ["KhaytThumbnail"]),
    ],
    targets: [
        .target(name: "KhaytCore", resources: [.copy("JS")]),
        // The interface. It writes now — jobs, customers, payments, moves —
        // through `StoreWriter`, which reads the book from disk inside every
        // write and swaps the file atomically. `Resources` carries the sample
        // shop and the invoice's stylesheet, synced from the renderer.
        .executableTarget(name: "KhaytApp", dependencies: ["KhaytCore"],
                          resources: [.process("Resources")]),
        // What Finder shows for a .3mf. Depends on KhaytCore for the zip
        // reader and the rule about which member of a 3MF is the picture —
        // both moved there so the app and the extension read one copy.
        //
        // THE ENTRY POINT IS NOT `main`, AND THERE MUST NOT BE ONE.
        //
        // An app extension is started by the system calling `NSExtensionMain`,
        // so the linker is pointed at that symbol. That alone is not enough:
        // ExtensionKit, which is what actually launches a Quick Look thumbnail
        // extension on macOS 14+, looks for a Swift entry point in the binary
        // FIRST and only falls back to the principal class when it finds none.
        // A `main.swift` — even one whose only job is to refuse to run — emits
        // a `__swift5_entry` section, so ExtensionKit found it, ran it, and the
        // process exited before the provider was ever instantiated. The symptom
        // was a thumbnail request that came back QLThumbnailErrorDomain 102
        // with the extension having launched and quit in 38 ms.
        //
        // `-parse-as-library` with no `@main` type is how the section stays out
        // of the binary. `Entry.swift` supplies the entry SwiftPM links against
        // and hands straight to `NSExtensionMain`. Apple's own thumbnail
        // extensions have no `__swift5_entry` either — that is the check if this
        // ever regresses, and `EntryPointTests` makes it.
        .executableTarget(name: "KhaytThumbnail", dependencies: ["KhaytCore"],
                          swiftSettings: [
                              .unsafeFlags(["-parse-as-library"]),
                          ]),
        .testTarget(name: "KhaytCoreTests", dependencies: ["KhaytCore"]),
        .testTarget(name: "KhaytAppTests", dependencies: ["KhaytApp", "KhaytCore"]),
    ]
)
