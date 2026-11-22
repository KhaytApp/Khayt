import Foundation
import Testing
@testable import KhaytCore

/// KhaytCore ships inside the iPhone app, and a Mac session cannot tell.
///
/// ── WHAT THIS IS DEFENDING ────────────────────────────────────────────────
///
/// `ios/KhaytCompanion` links the `KhaytCore` product and works the shop's money
/// out with it. That is the whole reason there is no second tax engine written
/// in Swift for the phone, and it is not obvious from the outside: a package
/// filed under `mac/` is shipping inside an iPhone.
///
/// So the failure this guards against is somebody improving the Mac. Adding
/// `import AppKit` to a file in this target is a completely ordinary thing to do
/// on macOS; `swift build` stays green, `swift test` stays green, every Mac
/// screen keeps working, and the iOS app stops compiling. Nobody finds out until
/// somebody opens Xcode, which may be days later and will look like the phone's
/// fault rather than the commit's.
///
/// ── WHAT IT CANNOT DO ─────────────────────────────────────────────────────
///
/// It reads source text. A macOS-only API reached through a framework that
/// exists on both — `NSAttributedString` doing something AppKit-shaped, a
/// `FileManager` constant that is macOS-only — passes this and still fails the
/// real build. Only a compiler holding the iOS SDK settles that, which is what
/// `.github/workflows/ios-contract.yml` is for. This is the fast half: it costs
/// nothing, runs in the suite a Mac session was already running, and catches the
/// mistake that is actually likely.
@Suite struct KhaytCoreIsPortableTests {

    /// This file is `Tests/KhaytCoreTests/…`; the sources are two levels up.
    static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // KhaytCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // KhaytCore
            .appending(path: "Sources/KhaytCore")
    }

    /// Frameworks that do not exist on iOS, or exist and mean something else.
    ///
    /// `Cocoa` and `AppKit` are the ones somebody reaches for by habit.
    /// `ServiceManagement`, `IOKit` and `CoreServices` are the ones somebody
    /// reaches for when they are doing something clever with a Mac.
    static let notOnThePhone: Set<String> = [
        "AppKit", "Cocoa", "Carbon", "IOKit", "CoreServices", "ServiceManagement",
        "ScreenCaptureKit", "OSAKit", "DiskArbitration", "SystemConfiguration",
    ]

    @Test("nothing in KhaytCore imports a framework the iPhone does not have")
    func noMacOnlyImports() throws {
        var offences: [String] = []
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let framework = String(trimmed.dropFirst("import ".count))
                    .split(separator: ".").first.map(String.init) ?? ""
                if Self.notOnThePhone.contains(framework) {
                    offences.append("\(url.lastPathComponent):\(n + 1)  import \(framework)")
                }
            }
        }
        #expect(offences.isEmpty, """
            KhaytCore is linked by ios/KhaytCompanion, and these imports do not exist on iOS:

            \(offences.joined(separator: "\n"))

            The Mac build will not complain and the iOS build will stop dead. If the code
            genuinely needs AppKit it belongs in Sources/KhaytApp — but check what it costs
            the phone first: a rule that lands in KhaytApp is a rule the phone has to ask
            the Mac for, over the network, when it may not be able to reach it.
            """)
    }

    @Test("the package still says it builds for the phone")
    func manifestStillDeclaresIOS() throws {
        // One line, deleted in passing, and the companion cannot resolve the
        // package at all — with an error that names SwiftPM and not whoever
        // removed it.
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Package.swift")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        #expect(text.contains(".iOS("), """
            Package.swift no longer declares an iOS platform. ios/KhaytCompanion links this
            package and cannot resolve it without one. See the KhaytCore section in CLAUDE.md.
            """)
    }

    @Test("the writer the phone keeps its book with is still in the shared half")
    func storeWriterIsStillShared() {
        // Not a style rule. `CompanionBook` on the phone writes through
        // `StoreWriter` so that there is one atomic swap, one `.prev` rollback
        // and one size ceiling rather than two. Moved back into KhaytApp, it
        // stops existing for the phone — and the iOS error will be
        // "cannot find 'StoreWriter' in scope", which names neither this rule
        // nor the commit that broke it.
        #expect(FileManager.default.fileExists(
            atPath: Self.sources.appending(path: "StoreWriter.swift").path),
            "StoreWriter left Sources/KhaytCore — the phone writes its book with it")
        #expect(FileManager.default.fileExists(
            atPath: Self.sources.appending(path: "BookScope.swift").path),
            "BookScope left Sources/KhaytCore — both ends read it to agree on how much of the book a phone carries")
    }
}
