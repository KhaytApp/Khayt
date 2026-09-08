import Testing
import Foundation
import CoreGraphics
import KhaytCore

/// The Quick Look extension, in the two places it went wrong.
///
/// Both failures looked identical from outside — Finder showed the blank
/// document icon and a thumbnail request came back QLThumbnailErrorDomain 102 —
/// and neither could be caught by reading the Swift. They are checked here
/// against the built binary and against the arithmetic, because that is where
/// they live.
struct ThumbnailExtensionTests {

    /// The package root. COUNTED, not guessed: four of these lands on `mac/`
    /// and the check below then found no binary and passed without looking at
    /// anything, which is how it sat green while proving nothing.
    static var package: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }   // …/Tests/KhaytAppTests/<file>
        return root                                        // → mac/KhaytCore
    }

    /// A built extension binary, or nil when this product has not been built.
    static func binary(_ name: String) -> URL? {
        #expect(FileManager.default.fileExists(atPath: package.appending(path: "Package.swift").path),
                "the package root is wrong, so every check against a build is vacuous")
        for build in ["release", "debug"] {
            let url = package.appending(path: ".build/\(build)/\(name)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// EVERY extension bundle, not just the first one written. The rule below
    /// is a property of app extensions, not of thumbnails, and the second
    /// extension is exactly where it would be forgotten.
    static let extensions = ["KhaytThumbnail", "KhaytPreview"]

    /// THE ONE THAT COST A DAY.
    ///
    /// ExtensionKit launches a thumbnail extension by looking for a Swift entry
    /// point in the binary and only falls back to `NSExtensionPrincipalClass`
    /// when there is none. A `main.swift` — even one whose whole body was a
    /// refusal to run — emits a `__swift5_entry` section, so ExtensionKit ran
    /// that and the process was gone in 38 ms without ever building the
    /// provider. Apple's own thumbnail extensions have no such section either.
    ///
    /// `Package.swift` keeps it out with `-parse-as-library` and an `@_cdecl`
    /// entry. Anyone who adds a `main.swift` or an `@main` back gets this.
    @Test(arguments: ThumbnailExtensionTests.extensions)
    func hasNoSwiftEntryPoint(_ name: String) throws {
        guard let binary = Self.binary(name) else { return }
        let otool = Process()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        otool.arguments = ["otool", "-l", binary.path]
        let pipe = Pipe()
        otool.standardOutput = pipe
        otool.standardError = FileHandle.nullDevice
        try otool.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        otool.waitUntilExit()
        // `segname __TEXT`, capitals — `sectname` is lowercase (`__text`) and
        // looking for the wrong one made this sanity check itself vacuous.
        #expect(out.contains("segname __TEXT"),
                "otool told us nothing; the check below would pass vacuously")
        #expect(!out.contains("__swift5_entry"), """
            \(name) has a Swift entry point again. ExtensionKit will run it \
            instead of the extension's principal class, the process will be gone \
            in 38 ms, and every .3mf will fall back to the blank document icon \
            with no error anywhere. See the note in Package.swift.
            """)
    }

    /// The reply is measured in points and the picture in pixels, which is how
    /// a 256×256 plate render ended up drawn into the corner of a 1024×1024
    /// thumbnail on the first try.
    @Test func replyIsTheRenderAtItsOwnResolution() {
        let size = ThreeMF.thumbnailSize(
            for: CGSize(width: 256, height: 256),
            maximum: CGSize(width: 512, height: 512), scale: 2)
        // 256 pixels of picture, asked for at scale 2, is 128 points.
        #expect(size == CGSize(width: 128, height: 128))
    }

    @Test func replyKeepsTheRendersShape() {
        let size = ThreeMF.thumbnailSize(
            for: CGSize(width: 512, height: 384),
            maximum: CGSize(width: 100, height: 100), scale: 1)
        #expect(size == CGSize(width: 100, height: 75))
    }

    /// A render bigger than the request is shrunk; one smaller is left alone.
    /// Enlarging it would hand Finder a soft picture where it could have made
    /// its own, and cost bytes to do it.
    @Test func replyNeverEnlarges() {
        let small = ThreeMF.thumbnailSize(
            for: CGSize(width: 64, height: 64),
            maximum: CGSize(width: 512, height: 512), scale: 2)
        #expect(small == CGSize(width: 32, height: 32))
    }

    @Test func replySurvivesNonsense() {
        let max = CGSize(width: 40, height: 40)
        #expect(ThreeMF.thumbnailSize(for: .zero, maximum: max, scale: 2) == max)
        #expect(ThreeMF.thumbnailSize(
            for: CGSize(width: 10, height: 10), maximum: max, scale: 0) == max)
    }
}

/// What the built .app carries inside its extensions.
///
/// Checked against `dist/Khayt.app` when one has been built, because these are
/// properties of the BUNDLE and nothing in the Swift can express them. Skipped
/// when there is no build to look at, so `swift test` alone stays green.
struct ExtensionBundleTests {

    /// The built app, when there is one. `mac/` is FOUR levels up — five is the
    /// repository root and `dist/Khayt.app` is not there, so every check in this
    /// suite would skip and report success.
    static var app: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }      // → mac/
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "make-app.sh").path),
                "\(root.path) is not mac/, so these checks are looking at nothing")
        let url = root.appending(path: "dist/Khayt.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// THE PREVIEW NEEDS ITS OWN COPY OF THE RULES.
    ///
    /// It reads print settings through the shared engine, and `Bundle.module`
    /// resolves against the bundle it runs in — for an extension, the .appex and
    /// not the app around it. Without this the extension launched, found its
    /// extension point, and died on `could not load resource bundle` the instant
    /// a preview was asked for. Quick Look then fell back to scaling the
    /// thumbnail, so what a person saw was a preview that looked nearly right
    /// and simply had no facts under it — which is why this is a test and not a
    /// comment.
    @Test func thePreviewCarriesTheRules() throws {
        guard let app = Self.app else { return }
        let rules = app.appending(
            path: "Contents/PlugIns/KhaytPreview.appex/Contents/Resources/KhaytCore_KhaytCore.bundle")
        #expect(FileManager.default.fileExists(atPath: rules.path),
                "KhaytPreview has no copy of the JavaScript; every preview will be blank")
        let one = rules.appending(path: "JS/print-facts.js")
        #expect(FileManager.default.fileExists(atPath: one.path),
                "the resource bundle is there and the rule is not")
    }

    /// The thumbnail extension does NOT get one, and that is deliberate: it
    /// reads the zip and picks a member and never builds an engine. 1.4 MB is
    /// worth carrying once, not twice.
    @Test func theThumbnailDoesNotCarryWhatItDoesNotUse() throws {
        guard let app = Self.app else { return }
        let rules = app.appending(
            path: "Contents/PlugIns/KhaytThumbnail.appex/Contents/Resources/KhaytCore_KhaytCore.bundle")
        #expect(!FileManager.default.fileExists(atPath: rules.path))
    }

    /// Nothing may sit in an .appex's root: it is outside `Contents/` and so
    /// outside what is sealed, and codesign refuses the whole bundle with
    /// "unsealed contents present in the bundle root". An entitlements file put
    /// there once already cost a build.
    @Test(arguments: ["KhaytThumbnail", "KhaytPreview"])
    func nothingLooseInTheBundleRoot(_ name: String) throws {
        guard let app = Self.app else { return }
        let appex = app.appending(path: "Contents/PlugIns/\(name).appex")
        let inRoot = try FileManager.default.contentsOfDirectory(
            at: appex, includingPropertiesForKeys: nil)
        #expect(inRoot.map(\.lastPathComponent) == ["Contents"],
                "\(name).appex has \(inRoot.map(\.lastPathComponent)) in its root")
    }
}
