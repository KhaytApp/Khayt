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
    // macOS 26, and NOT for the sake of the machine this is built on.
    //
    // Khayt's Mac build has always been arm64 only, so every Mac that can run
    // it is Apple Silicon and every Apple Silicon Mac is supported by macOS 26.
    // The floor therefore excludes no hardware at all — only somebody who has
    // not updated. And the native app is unreleased, so there is nobody on an
    // older one to strand: this is free today and expensive after the first
    // shop installs it.
    //
    // It was .v14, inherited rather than chosen, and it was charging for that
    // reach in availability workarounds — a conditional `TableColumn` needs
    // 14.4, so a column that should have been three lines was written around.
    // A STRING, because `.v26` does not exist in swift-tools-version 6.0 —
    // the enum only knows the versions its own toolchain shipped with. The
    // string initializer takes any version and means the same thing.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "KhaytCore", targets: ["KhaytCore"]),
        .executable(name: "Khayt", targets: ["KhaytApp"]),
        // The Quick Look thumbnail extension. Its own product because it is its
        // own binary inside its own bundle — see `make-app.sh`, which assembles
        // the .appex the way it already assembles the .app.
        .executable(name: "KhaytThumbnail", targets: ["KhaytThumbnail"]),
        // What the SPACE BAR shows for a .3mf: the plate render, and what the
        // slicer was told to do with it. Its own bundle for the same reason the
        // thumbnail is — one extension point per .appex.
        .executable(name: "KhaytPreview", targets: ["KhaytPreview"]),
    ],
    // ── SPARKLE, AND WHY A DEPENDENCY AT ALL ─────────────────────────────
    //
    // This package has had no dependencies, deliberately: the business rules
    // run in JavaScriptCore, which is a system framework, and everything else
    // is Swift and AppKit. Sparkle is the first, and it is here because the
    // alternative is worse — an app that cannot update itself is an app whose
    // shops stay on whatever build they first installed, and the Electron app
    // they are moving from has had auto-update since it shipped.
    //
    // Pinned to a minor range rather than `branch:` or `exact:`. Sparkle's
    // update path runs privileged code on a shop's Mac; a floating branch is
    // not something to take on trust, and an exact pin means never taking its
    // security fixes either.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(name: "KhaytCore", resources: [.copy("JS")]),
        // The interface. It writes now — jobs, customers, payments, moves —
        // through `StoreWriter`, which reads the book from disk inside every
        // write and swaps the file atomically. `Resources` carries the sample
        // shop and the invoice's stylesheet, synced from the renderer.
        .executableTarget(name: "KhaytApp",
                          dependencies: ["KhaytCore",
                                         .product(name: "Sparkle", package: "Sparkle")],
                          resources: [
                              .process("Resources"),
                              // `.copy`, NOT `.process`, and in its own folder
                              // outside `Resources/` — because `.process`
                              // FLATTENS a directory tree into the bundle root,
                              // so `Help/en/jobs.md` and `Help/ar/jobs.md`
                              // become two resources both named `jobs.md` and
                              // the build refuses them as a collision. `.copy`
                              // keeps the folders, which is the whole point:
                              // the language IS the folder.
                              .copy("Help"),
                          ]),
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
        // The Quick Look PREVIEW. Same shape as the thumbnail extension and for
        // the same reasons — no Swift entry point, `NSExtensionMain` supplied by
        // `Entry.swift` — and it shows the facts through `PrintFactLines`, which
        // is the code the app's own inspector lays out with.
        .executableTarget(name: "KhaytPreview", dependencies: ["KhaytCore"],
                          swiftSettings: [
                              .unsafeFlags(["-parse-as-library"]),
                          ]),
        .testTarget(name: "KhaytPreviewTests",
                    dependencies: ["KhaytPreview", "KhaytCore"]),
        .testTarget(name: "KhaytCoreTests", dependencies: ["KhaytCore"]),
        .testTarget(name: "KhaytAppTests", dependencies: ["KhaytApp", "KhaytCore"]),
    ]
)
