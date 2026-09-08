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

    /// The built extension binary, or nil when only the app was built.
    static var binary: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }   // → KhaytCore
        for build in ["release", "debug"] {
            let url = root.appending(path: ".build/\(build)/KhaytThumbnail")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

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
    @Test func hasNoSwiftEntryPoint() throws {
        guard let binary = Self.binary else { return }
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
        #expect(out.contains("sectname __TEXT"),
                "otool told us nothing; the check would pass vacuously")
        #expect(!out.contains("__swift5_entry"), """
            KhaytThumbnail has a Swift entry point again. ExtensionKit will run \
            it instead of KhaytThumbnailProvider and every .3mf will show the \
            blank document icon. See the note in Package.swift.
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
