import Foundation
import Testing
@testable import KhaytApp

/// One title bar, and no action lost taking the other one off.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// The shop's report was "jobs and board suddenly get a big header at top".
/// The new shell draws its own 40pt navy strip and the window went on drawing
/// the system's above it — two headers, and on those two screens the upper one
/// carried a stray "+", because a `.toolbar` has nowhere to go but the window's
/// own bar and declaring one brought that bar back.
///
/// Both halves are checked here, structurally, because neither shows in a
/// screenshot of a single screen: a bare `.toolbar` in a screen is the bar
/// coming back, and a screen whose toolbar was gated without its actions being
/// picked up in the strip is a button that has silently stopped existing.
@MainActor
struct ShellChromeTests {

    static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/KhaytApp")

    static func read(_ name: String) -> String {
        (try? String(contentsOf: sources.appending(path: name), encoding: .utf8)) ?? ""
    }

    /// Every file in the app, so a screen added later is covered without this
    /// test being edited.
    static let screens: [(String, String)] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sources.path())) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().map { ($0, read($0)) }
    }()

    @Test("no screen declares a toolbar the new shell cannot draw")
    func toolbarsAreGated() {
        #expect(!Self.screens.isEmpty, "the source directory moved — this test is reading nothing")
        for (name, text) in Self.screens {
            // `ScreenActions.swift` owns the one legitimate mention: the
            // modifier that applies a toolbar in the old shell only.
            if name == "ScreenActions.swift" { continue }
            // `ShopWindow.swift` carries the OLD shell's own toolbar — the book
            // source, the owed summary, the inspector toggle. That one is fine
            // because the old shell has a title bar; what is not fine is a
            // toolbar declared above it, where the shared screens are built.
            var text = text
            if name == "ShopWindow.swift" {
                guard let classic = text.range(of: "private var classic: some View") else {
                    Issue.record("ShopWindow's shells were renamed; this test is checking nothing")
                    continue
                }
                text = String(text[text.startIndex..<classic.lowerBound])
            }
            // `.toolbar(` and `.toolbar {` — not `.screenToolbar`, and not
            // `.windowToolbarStyle`, which is the scene's and stays.
            for spelling in [".toolbar {", ".toolbar("] {
                var from = text.startIndex
                while let hit = text.range(of: spelling, range: from..<text.endIndex) {
                    let before = text.index(hit.lowerBound, offsetBy: -6, limitedBy: text.startIndex)
                        .map { String(text[$0..<hit.lowerBound]) } ?? ""
                    if !before.hasSuffix("screen") {
                        Issue.record(Comment(rawValue: """
                            \(name) declares a bare `\(spelling)`. In the new shell the \
                            window has no title bar, so a toolbar brings the system's \
                            bar back above the navy strip — two headers. Use \
                            `.screenToolbar` and add the action to `ScreenActions`.
                            """))
                    }
                    from = hit.upperBound
                }
            }
        }
    }

    @Test("every gated screen's actions are in the strip")
    func actionsSurvivedTheMove() {
        let actions = Self.read("ScreenActions.swift")
        #expect(!actions.isEmpty, "ScreenActions.swift moved — this test is reading nothing")

        // The word key each screen's toolbar item carried. If a screen's
        // toolbar is gated and its key is not in the strip, the action is
        // unreachable in the shell that ships on by default.
        let moved = ["mac.new_job", "mac.new_product", "mac.view_list", "mac.view_grid",
                     "sched.suggest_btn", "mach.add", "mac.issue_gift_card",
                     "exp.add_title", "waste.add", "mac.import_models"]
        for key in moved {
            #expect(actions.contains("\"\(key)\""), Comment(rawValue: """
                \(key) is a toolbar action with no button in `ScreenActions`. \
                The new shell has no toolbar, so that action cannot be reached \
                at all — only from the menu bar, if it is there.
                """))
        }
        // The period menu is a control rather than a key.
        #expect(actions.contains("PeriodMenu"),
                "the spending and reports screens lost their period control")
    }

    @Test("both shells show a detail panel, and decide its contents in one place")
    func panelsReachBothShells() {
        let window = Self.read("ShopWindow.swift")
        let shell = Self.read("Shell.swift")

        // The old shell's `.inspector`, and the new shell's own column. They
        // are different holdings on purpose — see `InspectorPane` — but a shop
        // that selects a model must get a panel either way.
        #expect(window.contains("modifier(panels)"), """
            the old shell lost its `.inspector` chain
            """)
        #expect(shell.contains("InspectorPane(shop: shop)"), """
            the new shell draws no detail panel. That shipped once: selecting a \
            model highlighted the tile and opened nothing, because the inspector \
            was attached to the shell that was no longer being drawn.
            """)
        #expect(window.contains("struct InspectorPane"), """
            InspectorPane is gone, so each shell decides for itself which panel \
            a screen gets — which is how one of them ends up showing a job's \
            panel over the library.
            """)
        // And the switch that opens it, which the old toolbar carried.
        let actions = Self.read("ScreenActions.swift")
        #expect(actions.contains("mac.show_details"),
                "the new strip has no Details switch, so a closed panel cannot be reopened")
    }

    @Test("the switch and the window agree which shell is on")
    func oneDefaultForTheShell() {
        // `@AppStorage` takes its default per DECLARATION. Two declarations of
        // one key with two defaults read differently until the key is first
        // written, and this app shipped exactly that: the window opened in the
        // new shell while Settings showed the switch off, so turning it ON did
        // nothing and a shop wanting the old shell had to toggle it twice.
        for name in ["ShopWindow.swift", "SettingsWindow.swift"] {
            let text = Self.read(name)
            #expect(text.contains("@AppStorage(ShellChoice.key)"), Comment(rawValue: """
                \(name) names the shell key as a literal again. Both sides read \
                `ShellChoice`, or they drift.
                """))
            #expect(!text.contains("@AppStorage(\"ui.newShell\")"), Comment(rawValue:
                "\(name) still declares the key by hand"))
            #expect(text.contains("= ShellChoice.byDefault"), Comment(rawValue: """
                \(name) writes its own default for the shell. That is the bug: \
                a default is a value, and it is written down once.
                """))
        }
    }

    @Test("the shell takes the window's title bar off, and the old one puts it back")
    func chromeIsSwitched() {
        let window = Self.read("ShopWindow.swift")
        let shell = Self.read("Shell.swift")
        let app = Self.read("KhaytApp.swift")
        #expect(app.contains("windowStyle(.hiddenTitleBar)"), """
            the scene draws a title bar again. That is the two-headers bug: the \
            NSWindow properties alone do not take it off — measured — so this \
            modifier is the fix, not a belt-and-braces extra.
            """)
        #expect(shell.contains("windowTitleBar(hidden: true)"), """
            the new shell no longer hides the window's title bar, which is the \
            two-headers bug it was reported with
            """)
        #expect(shell.contains("ignoresSafeArea(.container, edges: .top)"), """
            the strip no longer escapes the title bar's safe area. On its own \
            `.hiddenTitleBar` leaves a 32pt inset the navy background fills and \
            the content does not: the strip renders 71pt tall with the traffic \
            lights a row above the title. Both lines, or the header is wrong.
            """)
        #expect(window.contains("windowTitleBar(hidden: false)"), """
            the old shell does not ask for the title bar back. Switching \
            Appearance would leave a NavigationSplitView with no toolbar and no \
            title, and no way to get either back short of relaunching.
            """)
        #expect(window.contains("classicShell, false") && window.contains("classicShell, true"),
                "the shells no longer say which they are, so `.screenToolbar` cannot tell")
    }
}

/// What the strip says you are looking at.
///
/// The old window had a subtitle and a group menu in its toolbar; the new one
/// has the strip, and the strip was naming the SCREEN. Open a library folder
/// and the title still read "All models" while the sidebar row still sat on
/// Library — nothing on screen named the folder, which is a place a shop can
/// be without being able to tell.
@MainActor
struct ShelfTitleTests {

    @Test("a library group is named by the group, not by the screen")
    func groupNamesItself() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        let all = shop.shelfTitle
        shop.shelf = .library("Pose 1")
        #expect(shop.shelfTitle == "Pose 1", """
            a folder is still titled "\(shop.shelfTitle)". Opening one left the \
            title on the screen's name and nothing anywhere saying which folder.
            """)
        #expect(all != shop.shelfTitle, "the folder and the whole library read the same")
    }

    @Test("a stage says which stage, and the whole book says the book")
    func stagesNameThemselves() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .jobs(nil)
        let all = shop.shelfTitle
        shop.shelf = .jobs(.printing)
        #expect(shop.shelfTitle != all, "a stage is titled the same as every job")
        #expect(!shop.shelfTitle.hasPrefix("queue."), """
            the title is a word KEY — a missing key is not blank, it IS the key, \
            so the strip would read "queue.printing"
            """)
    }

    @Test("every other screen still has a word")
    func nothingReadsAsAKey() async throws {
        let shop = Shop()
        await shop.load(.sample)
        for shelf in [Shop.Shelf.dashboard, .board, .customers, .machines, .inventory,
                      .expenses, .waste, .reports, .catalogue, .colour, .calculator,
                      .portfolio, .giftCards] {
            shop.shelf = shelf
            let title = shop.shelfTitle
            #expect(!title.contains("."), Comment(rawValue:
                "\(shelf) is titled \"\(title)\", which is a key rather than a word"))
        }
    }
}
