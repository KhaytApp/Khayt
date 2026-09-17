import Foundation
import Testing
@testable import KhaytApp

/// A message written for the shop is shown to the shop.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// `relocateNote` and `relocateProblem` were set in five places between them
/// and read in none. So "Find it on the network" either worked, and the row
/// changed — or it did nothing visible at all. No "nothing answered", no
/// "could not write that", not even "moved to .56". The feature succeeded
/// silently and failed silently, on the screen a shop reaches for when
/// something is already wrong.
///
/// Nothing caught it because nothing was wrong with either half: the message
/// was written correctly and the view was correct about what it drew. Only the
/// join was missing, which is the same shape as a rule with no caller — see
/// [[wiring-not-just-correctness]].
///
/// ── WHY THE NAME IS THE TEST ──────────────────────────────────────────────
///
/// A property called `somethingProblem` or `somethingNote` on `Shop` is a
/// sentence meant for a person, by the app's own convention — twenty-four of
/// them and every one a translated string. So the scan is: does any view read
/// it. It is a SOURCE scan and that is the right tool here, because this is a
/// wiring question and not a behaviour one: what is being asked is whether the
/// two halves are joined at all.
struct MessagesAreShownTests {

    /// Messages deliberately not put on screen. Each needs a reason, and the
    /// information has to reach somebody some other way.
    static let allowed: [String: String] = [
        "leadTimeProblem":
            "documented on the property as diagnostic-pane-only and never an alert — "
            + "a shop must not be interrupted about its storefront mid-job. The failure "
            + "still reaches stderr through `note()`, so it is recoverable.",
    ]

    private static var sources: (shop: String, views: [String: String]) {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // KhaytAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // KhaytCore
            .appending(path: "Sources/KhaytApp")
        var views: [String: String] = [:]
        var shop = ""
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if url.lastPathComponent == "Shop.swift" { shop = text } else { views[url.lastPathComponent] = text }
        }
        return (shop, views)
    }

    @Test("every message Shop writes is read by something that can draw it")
    func nothingIsWrittenIntoTheVoid() throws {
        let (shop, views) = Self.sources
        #expect(!shop.isEmpty, "could not read Shop.swift — this guard has rotted")
        #expect(views.count > 20, "could not read the views — this guard has rotted")

        var names: [String] = []
        for line in shop.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("var ") || t.hasPrefix("private(set) var ") else { continue }
            let after = t.replacingOccurrences(of: "private(set) ", with: "").dropFirst(4)
            let name = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            if name.hasSuffix("Problem") || name.hasSuffix("Note") { names.append(name) }
        }
        #expect(names.count > 15, Comment(rawValue: "found only \(names.count) — the scan has rotted"))

        var unread: [String] = []
        for name in Set(names).sorted() {
            if Self.allowed[name] != nil { continue }
            let read = views.values.contains { $0.contains(".\(name)") }
            if !read { unread.append(name) }
        }
        #expect(unread.isEmpty, Comment(rawValue:
            "written for the shop and shown to nobody: \(unread.joined(separator: ", ")). "
            + "Draw it, or add it to `allowed` with the reason and where the information "
            + "goes instead."))
    }

    @Test("the allow-list has no dead entries")
    func allowListStaysHonest() {
        // An excuse that outlives the property it excused quietly covers the
        // next one that happens to take the same name.
        let (shop, _) = Self.sources
        for name in Self.allowed.keys {
            #expect(shop.contains("var \(name)"),
                    Comment(rawValue: "`allowed` excuses \(name), which Shop no longer has"))
        }
    }

    @Test("every excuse gives a reason")
    func reasonsAreRealSentences() {
        for (name, why) in Self.allowed {
            #expect(why.count > 40, Comment(rawValue: "\(name)'s reason is too short to be one"))
        }
    }
}
