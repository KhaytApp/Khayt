import Foundation
import Testing
@testable import KhaytApp

/// Motion in this app comes from `Motion.swift` and nowhere else.
///
/// Two faults this catches, both found in the tree rather than imagined:
///
/// `Kanban.swift` animated its drop target with a hand-written
/// `.easeOut(duration: 0.12)` — the same number `Motion.hover` holds — on the
/// line directly ABOVE one that asked for the token properly. The literal did
/// not go to zero under Reduce Motion and the token did: one question, two
/// answers, two lines apart. `LibraryGrid.swift` had the same literal around
/// the scroll that follows the keyboard.
///
/// A duration written by hand is not a style preference here. `Motion.of`
/// returning nil under Reduce Motion is the whole accessibility story of this
/// app — `Motion.swift` argues it as "this app is for a workshop, motion
/// sensitivity is common, and a pulsing dot on a screen somebody has to look
/// at all day is the exact thing the setting exists for" — and a literal
/// silently opts out of it.
@MainActor
struct MotionIsOneVocabularyTests {

    static func appSources() -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Motion.swift").path),
                "the source directory was not found — these tests would pass vacuously")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                     includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "swift" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.lastPathComponent, text)
            }
    }

    /// `Motion.swift` is where the durations live; everywhere else asks it.
    @Test("no screen writes its own duration")
    func noBareDurations() {
        let sources = Self.appSources()
        #expect(sources.count > 50, "only \(sources.count) sources — the scan is wrong")

        let banned = ["easeOut(duration:", "easeInOut(duration:", "easeIn(duration:",
                      "linear(duration:"]
        var found: [String] = []
        for (name, text) in sources where name != "Motion.swift" {
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                for token in banned where line.contains(token) {
                    found.append("\(name):\(n + 1)  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(found.isEmpty,
                Comment(rawValue: "durations written by hand — use a Motion token, which is "
                        + "what goes to zero under Reduce Motion:\n  "
                        + found.joined(separator: "\n  ")))
    }

    /// The doctrine's own list of what this app does not do.
    ///
    /// `Motion.swift`: "Nothing loops for decoration, nothing bounces, and
    /// nothing draws the eye to a thing that is not news." A spring overshoots,
    /// which on a shop tool reads as a toy; `repeatForever` is the breath, and
    /// the breath belongs to `Alive` alone.
    @Test("nothing bounces, and only the breath repeats")
    func noSpringsAndOneRepeat() {
        let sources = Self.appSources()
        var springs: [String] = []
        var repeats: [String] = []
        for (name, text) in sources {
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                if line.contains(".spring(") || line.contains(".bouncy") || line.contains(".snappy") {
                    springs.append("\(name):\(n + 1)")
                }
                // `Motion.swift` owns the one repeating animation there is.
                if line.contains("repeatForever"), name != "Motion.swift" {
                    repeats.append("\(name):\(n + 1)")
                }
            }
        }
        #expect(springs.isEmpty,
                Comment(rawValue: "a spring overshoots, and a shop tool that overshoots reads "
                        + "as a toy: " + springs.joined(separator: ", ")))
        #expect(repeats.isEmpty,
                Comment(rawValue: "the only thing that repeats in this app is Alive's breath, "
                        + "on a print running right now: " + repeats.joined(separator: ", ")))
    }
}
