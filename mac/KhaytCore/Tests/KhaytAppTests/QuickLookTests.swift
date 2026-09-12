import Foundation
import Testing
@testable import KhaytApp

/// Looking at a second model.
///
/// ── WHAT THIS PINS, AND WHAT IT DELIBERATELY DOES NOT ─────────────────────
///
/// A second Quick Look took the whole app with it, silently: no crash report
/// from macOS, no `last-crash.txt`, nothing on stderr, and not even an orderly
/// `terminate:` in the unified log. The app was simply gone, which reads as a
/// crash and leaves nothing to look at. Three reproductions, all identical.
///
/// `.quickLookPreview` does not put its binding back to nil when the panel is
/// dismissed, so the next selection was a `url → url` change rather than a
/// fresh one, handed to a panel whose controller PlugInKit had already torn
/// down.
///
/// So what is asserted here is the TRANSITION — that the binding is never
/// handed url → url — and not the `QLPreviewPanel called while the panel has
/// no controller` warning. That warning is still logged after the fix:
/// nineteen times across the fifteen Quick Looks that proved it, with the app
/// up throughout. Pinning the warning would pin a symptom that was never the
/// cause.
///
/// The panel itself cannot be driven from a test — it is AppKit's, shared, and
/// wants a real window. The binding can, and the binding is where the bug was.
@MainActor
struct QuickLookTests {

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    /// Let the deferred set land. `quickLook` clears the binding and sets it on
    /// the next turn of the main loop, because both halves inside one update
    /// are coalesced into no change at all.
    static func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    static let a = URL(fileURLWithPath: "/tmp/khayt-test/a.stl")
    static let b = URL(fileURLWithPath: "/tmp/khayt-test/b.stl")

    @Test("the first look sets the file straight away")
    func firstLook() async {
        let shop = await Self.shop()
        #expect(shop.previewing == nil, "nothing is being previewed before anything is asked for")
        shop.quickLook(Self.a)
        // No deferral needed from nil: that transition is the one the modifier
        // is reliable for, so it is taken immediately.
        #expect(shop.previewing == Self.a)
    }

    @Test("a second look clears the binding before setting it")
    func secondLookClearsFirst() async {
        // THE FIX. Synchronously after asking for `b`, the binding must read
        // nil — never `a` and never `b`. A `url → url` change is what killed
        // the app, and it is invisible to anything that only checks the value
        // once the dust has settled.
        let shop = await Self.shop()
        shop.quickLook(Self.a)
        #expect(shop.previewing == Self.a)

        shop.quickLook(Self.b)
        #expect(shop.previewing == nil,
                "the second look went straight from one url to another")

        await Self.settle()
        #expect(shop.previewing == Self.b, "the deferred set never arrived")
    }

    @Test("looking at the same file twice is still a fresh look")
    func sameFileTwice() async {
        // Going through a library, a shop opens the same model again as often
        // as a different one. `a → a` is not a change the modifier would act
        // on at all, so the panel would simply not reopen.
        let shop = await Self.shop()
        shop.quickLook(Self.a)
        shop.quickLook(Self.a)
        #expect(shop.previewing == nil, "the same file twice was not cleared first")
        await Self.settle()
        #expect(shop.previewing == Self.a)
    }

    @Test("going through a whole library never hands it url to url")
    func manyInARow() async {
        // Fifteen in a row is what it took to be sure by hand; this does the
        // same thing to the binding without a panel.
        let shop = await Self.shop()
        for i in 0..<15 {
            let url = URL(fileURLWithPath: "/tmp/khayt-test/\(i).stl")
            let before = shop.previewing
            shop.quickLook(url)
            if before != nil {
                #expect(shop.previewing == nil,
                        Comment(rawValue: "look \(i) went \(before!.lastPathComponent) → \(url.lastPathComponent)"))
            }
            await Self.settle()
            #expect(shop.previewing == url, Comment(rawValue: "look \(i) did not arrive"))
        }
    }

    @Test("both ways in go through the same door")
    func oneFunnel() throws {
        // ⌘Y from the menu and the file row's context menu each used to assign
        // `previewing` themselves, so a fix in one would have left the other
        // still killing the app. Read out of the source because the context
        // menu is a SwiftUI `Button` action that cannot be invoked here.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir = dir.deletingLastPathComponent() }
        let sources = dir.appending(path: "Sources/KhaytApp")

        for file in ["Shop.swift", "FileActions.swift", "LibraryGrid.swift",
                     "Menus.swift", "LibraryInspector.swift"] {
            let text = (try? String(contentsOf: sources.appending(path: file), encoding: .utf8)) ?? ""
            // ONE line list for both the search and the bounds. Swift's
            // `split(separator:)` drops empty subsequences unless told not to,
            // so numbering the offenders from one split and the function from
            // another put them in different coordinate systems — every line
            // inside `quickLook` looked as though it were outside it.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let offenders = lines.enumerated().filter { _, line in
                line.contains("previewing =") && !line.contains("var previewing")
            }
            if file == "Shop.swift" {
                // Every assignment must live INSIDE `quickLook(_:)`. Counting
                // them would only encode today's number (three: the nil fast
                // path, the clear, and the deferred set); what matters is that
                // no other method in the file touches the binding.
                guard let opens = lines.firstIndex(where: { $0.contains("func quickLook(_ url: URL)") }),
                      let closes = lines.indices.first(where: { $0 > opens && lines[$0] == "    }" })
                else { Issue.record("Shop.quickLook(_:) is gone or renamed"); continue }
                #expect(!offenders.isEmpty, "nothing in Shop.swift previews anything any more")
                for (at, line) in offenders {
                    #expect(at > opens && at < closes,
                            Comment(rawValue: "Shop.swift:\(at + 1) assigns `previewing` outside quickLook: \(line.trimmingCharacters(in: .whitespaces))"))
                }
            } else {
                #expect(offenders.isEmpty,
                        Comment(rawValue: "\(file) assigns `previewing` directly, bypassing the funnel: line(s) \(offenders.map { $0.offset + 1 })"))
            }
        }
    }
}
