import Foundation
import Testing
import SwiftUI
import AppKit
import KhaytCore
@testable import KhaytApp

/// The 4.0.0-alpha.67 pre-release review of "Sort linked folders" (#1839):
/// the once-per-book refile v3 runs over a shop's real book of 6,381 linked
/// records on first launch, so what it may change is held here.
struct Alpha67ReviewTests {

    // MARK: - A group's kind and picture, when its path loses a collection

    static func record(_ id: String, _ group: String) -> JSONValue {
        .object(["id": .string(id), "group": .string(group), "folder": .string(group)])
    }

    static func map(_ root: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(let s)? = root["settings"], case .object(let m)? = s["libraryGroups"] else { return [:] }
        return m
    }

    @Test("a print's old path keeps its kind and picture when its parts move under the print, not only a group that moves whole")
    @MainActor func entriesFollowThePrint() {
        let parts: JSONValue = .object(["kind": .string("parts"), "cover": .object(["image": .string("group-pictures/g.jpg")])])
        let large: JSONValue = .object(["cover": .object(["model": .string("a")])])
        let tier: JSONValue = .object(["kind": .string("collection")])
        var root: [String: JSONValue] = [
            "printFiles": .array([
                Self.record("a", "Aug26 Giga Tier/Life Size Gambit/Large Cuts"),
                Self.record("b", "Aug26 Giga Tier/Life Size Gambit/Large Cuts"),
                Self.record("c", "Aug26 Giga Tier/Life Size Gambit/Small Cuts"),
                Self.record("d", "Aug26 Giga Tier/Mumm-Ra"),
            ]),
            "settings": .object(["libraryGroups": .object([
                // On a group nobody is filed in directly: alpha.66's code never carried it.
                "Aug26 Giga Tier/Life Size Gambit": parts,
                "Aug26 Giga Tier/Life Size Gambit/Large Cuts": large,
                "Aug26 Giga Tier": tier,
            ])]),
        ]
        LinkedRegroup.apply([
            .init(id: "a", group: "Life Size Gambit/Large Cuts", name: nil),
            .init(id: "b", group: "Life Size Gambit/Large Cuts", name: nil),
            .init(id: "c", group: "Life Size Gambit/Small Cuts", name: nil),
            .init(id: "d", group: "Mumm-Ra", name: nil),
        ], to: &root)
        let m = Self.map(root)
        #expect(m["Life Size Gambit"] == parts, "the print's kind and picture are on the print")
        #expect(m["Life Size Gambit/Large Cuts"] == large, "a part that moved whole keeps its own")
        #expect(m["Aug26 Giga Tier/Life Size Gambit"] == nil && m["Aug26 Giga Tier/Life Size Gambit/Large Cuts"] == nil)
        // The tier's prints went their separate ways: nowhere to carry it, so
        // it is not put on any one of them.
        #expect(m["Mumm-Ra"] == nil)
        #expect(m["Aug26 Giga Tier"] == tier)
        // And the pictures' write that follows (which prunes) keeps them.
        GroupKinds.setCover(nil, for: "Nothing", into: &root)
        #expect(Self.map(root)["Life Size Gambit"] == parts)
    }

    @Test("a group of the shop's own at the destination keeps its own; the deeper of two arrivals wins")
    func entriesNeverOverwriteTheShops() {
        let mine: JSONValue = .object(["kind": .string("collection")])
        let wrapper: JSONValue = .object(["kind": .string("collection"), "cover": .object(["model": .string("w")])])
        let inner: JSONValue = .object(["kind": .string("parts")])
        var root: [String: JSONValue] = [
            "printFiles": .array([
                Self.record("a", "Old/Dragon"), Self.record("b", "Tier/Buzz/Buzz STLs"),
                Self.record("c", "Dragon"),
            ]),
            "settings": .object(["libraryGroups": .object([
                "Old/Dragon": .object(["kind": .string("parts")]), "Dragon": mine,
                "Tier": wrapper, "Tier/Buzz/Buzz STLs": inner,
            ])]),
        ]
        LinkedRegroup.apply([.init(id: "a", group: "Dragon", name: nil), .init(id: "b", group: "Buzz", name: nil)],
                            to: &root)
        let m = Self.map(root)
        #expect(m["Dragon"] == mine)
        // `Tier` held one print: both arrive at `Buzz`. The nearer one's kind,
        // the wrapper's picture (the inner had none).
        #expect(m["Buzz"] == .object(["kind": .string("parts"), "cover": .object(["model": .string("w")])]))
    }

    @Test("the deepest group a set of paths shares")
    func sharedGroup() {
        #expect(LinkedRegroup.sharedGroup(["A/B", "A/C"]) == "A")
        #expect(LinkedRegroup.sharedGroup(["A/B"]) == "A/B")
        #expect(LinkedRegroup.sharedGroup(["A/B", "AB/C"]) == nil)
        #expect(LinkedRegroup.sharedGroup(["A", ""]) == nil)
        #expect(LinkedRegroup.sharedGroup([]) == nil)
    }

    // MARK: - Tags the shop typed

    @Test("a collection tag is added to the tags there, never over them — an old comma-separated string included")
    func tagsAreAddedNotReplaced() {
        let drive = PrintSortTests.drive
        let m = PrintSortTests.buzzModels
        let p = PrintSortTests.plan(m, images: PrintSortTests.buzzImages)
        let path = { (rel: String) in drive.appending(path: rel).standardizedFileURL.path }
        var rows: [JSONValue] = [
            .object(["id": .string("s"), "name": .string("Wing_L_1"), "externalPath": .string(path(m[0])),
                     "group": .string("X"), "folder": .string("X"), "autoGroup": .string("X"),
                     "tags": .string("resin, for Ahmed")]),
            .object(["id": .string("t"), "name": .string("Wing_L_2"), "externalPath": .string(path(m[1])),
                     "group": .string("X"), "folder": .string("X"), "autoGroup": .string("X"),
                     "tags": .array([.string("PLA")])]),
            // Elsewhere in the book, the shop's own spelling of the collection.
            .object(["id": .string("u"), "name": .string("other"), "tags": .array([.string("AUG26 giga tier")])]),
        ]
        let changes = LinkedRegroup.changes(rows: rows, plan: p)
        #expect(changes.first { $0.id == "s" }?.tag == "AUG26 giga tier", "the spelling the book already uses")
        var root: [String: JSONValue] = ["printFiles": .array(rows)]
        LinkedRegroup.apply(changes, to: &root)
        if case .array(let r)? = root["printFiles"] { rows = r }
        func tags(_ i: Int) -> JSONValue? { if case .object(let o) = rows[i] { o["tags"] } else { nil } }
        #expect(tags(0) == .array([.string("resin"), .string("for Ahmed"), .string("AUG26 giga tier")]))
        #expect(tags(1) == .array([.string("PLA"), .string("AUG26 giga tier")]))
        #expect(LinkedRegroup.changes(rows: rows, plan: p).isEmpty, "settled: nothing to do the second time")
    }

    // MARK: - What the assistant may name a group

    @Test("an assistant's name is held to the group rule where it becomes a path, even read back from the book")
    func assistantNamesCannotInject() {
        #expect(PrintSort.assistantName("..") == nil)
        #expect(PrintSort.assistantName(" / ") == nil)
        #expect(PrintSort.assistantName("a/../b") == "a - .. - b")
        #expect(PrintSort.assistantName("Line\none") == "Line one")
        #expect(PrintSort.assistantName("درع") == "درع")
        let models = ["2026 World Cup/Can Opener/a.3mf", "2026 World Cup/Can Opener/b.3mf",
                      "2026 World Cup/Key Chain/c.3mf", "2026 World Cup/Key Chain/d.3mf"]
        var answers = PrintSort.Answers()
        answers.roles["2026 World Cup"] = .print
        answers.names["2026 World Cup"] = "../../etc"
        var p = PrintSortTests.plan(models, answers: answers)
        let g = p.placed[models[0]]?.group ?? ""
        let parts: [String] = g.split(separator: "/").map(String.init)
        let climbs = parts.contains("..") || parts.contains(".")
        #expect(!climbs, "\(g)")
        #expect(g.hasPrefix(".. - .. - etc/"))
        answers.names["2026 World Cup"] = ".."
        p = PrintSortTests.plan(models, answers: answers)
        #expect(p.placed[models[0]]?.group == "2026 World Cup/Can Opener", "nothing to read: the folder's own name")
    }

    // MARK: - A request that keeps failing

    @Test("a failing request is not re-sent the same day, and stops after three until its folders change")
    func failuresAreHeld() {
        var marks: [String: SortFailures.Mark] = [:]
        // Day 1: fails. Held for the rest of the day.
        marks = SortFailures.after(marks, asked: ["s"], failed: ["s"], pending: ["s"], today: "2026-10-12")
        #expect(marks["s"] == SortFailures.Mark(count: 1, last: "2026-10-12"))
        #expect(SortFailures.held("s", in: marks, today: "2026-10-12"))
        #expect(!SortFailures.held("s", in: marks, today: "2026-10-13"), "tried again the next day")
        // Days 2 and 3: fails again. Three: held on any day after.
        marks = SortFailures.after(marks, asked: ["s"], failed: ["s"], pending: ["s"], today: "2026-10-13")
        marks = SortFailures.after(marks, asked: ["s"], failed: ["s"], pending: ["s"], today: "2026-10-14")
        #expect(marks["s"]?.count == 3)
        #expect(SortFailures.held("s", in: marks, today: "2026-11-30"))
        // A held request not asked keeps its mark; one the pass no longer
        // makes (its folders changed: a new signature) is forgotten.
        #expect(SortFailures.after(marks, asked: [], failed: [], pending: ["s"], today: "2026-10-15") == marks)
        let changed = SortFailures.after(marks, asked: ["t"], failed: [], pending: ["t"], today: "2026-10-15")
        #expect(changed.isEmpty)
        #expect(!SortFailures.held("t", in: changed, today: "2026-10-15"))
        // Pressed by hand and it worked: forgotten.
        #expect(SortFailures.after(marks, asked: ["s"], failed: [], pending: ["s"], today: "2026-10-15").isEmpty)
        // Round trip through the book.
        var root: [String: JSONValue] = ["settings": .object([:])]
        SortFailures.write(marks, into: &root)
        guard case .object(let s)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(SortFailures.read(s) == marks)
        SortFailures.write([:], into: &root)
        guard case .object(let s2)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(SortFailures.read(s2).isEmpty)
    }

    @Test("the launch pass skips held requests; only Sort linked folders… by hand tries them")
    func onlyByHandTriesAHeldRequest() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop+LinkedSort.swift"), encoding: .utf8)
        #expect(source.contains("if !byHand, SortFailures.held(sig, in: marks, today: today)"))
        #expect(source.contains("askAssistantToSort(sorted, stop: stop, byHand: true)"), "the preview is by hand")
        let rescan = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/LinkedFolders.swift"), encoding: .utf8)
        #expect(rescan.contains("askAssistantToSort(plans, stop: stop)"), "the launch pass is not")
    }

    @Test("the note says how many folders the assistant could not sort")
    @MainActor func heldIsSaid() async {
        let shop = Shop()
        await shop.load(.sample)
        let line = SortAsk(sorted: 12, problem: nil, held: 40).line(shop.words) ?? ""
        #expect(line.contains("12") && line.contains("40"))
        #expect(SortAsk(held: 5).line(shop.words)?.contains("5") == true)
        #expect(SortAsk().line(shop.words) == nil)
    }

    // MARK: - What leaves this Mac

    /// The prompt the request carries, wherever the provider puts it.
    static func prompt(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s.contains("Folders (path") ? s : nil
        case .array(let a): return a.lazy.compactMap(prompt).first
        case .object(let o): return o.values.lazy.compactMap(prompt).first
        default: return nil
        }
    }

    @Test("the request holds paths below the linked folder only, and the published limits: 5 samples, 30 sub-folders, 150 folders")
    func requestIsNamesBelowTheLinkedFolder() async throws {
        let engine = try KhaytEngine()
        let on: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(true),
                                                      "features": .object(["library": .bool(true)])])]
        // The real shape: a Google Drive under the person's home, by e-mail.
        let root = URL(fileURLWithPath: "/Users/turki/Library/CloudStorage/GoogleDrive-shop@example.com/My Drive/Linked Root")
        var models: [URL] = []
        for s in 1...40 { for f in 1...7 { models.append(root.appending(path: "Pack/Sub \(s)/part \(f).stl")) } }
        for f in 1...9 { models.append(root.appending(path: "Pack/loose \(f).stl")) }
        for t in 1...200 { models.append(root.appending(path: "Top \(t)/m.stl")) }
        let plan = PrintSort.plan(root: root, models: models, images: [])
        let entries = SortCache.units(plan).flatMap(\.entries)
        for batch in SortCache.batches(SortCache.units(plan)) {
            #expect(batch.count <= 150)
            let request = try await engine.aiLibraryRequest(settings: on, entries: batch.map(\.json), apiKey: "k")
            let text = try #require(Self.prompt(request.body))
            for leak in ["/Users", "turki", "CloudStorage", "GoogleDrive", "example.com", "My Drive", "Linked Root"] {
                #expect(!text.contains(leak), "\(leak) left this Mac")
            }
            let lines = text.split(separator: "\n").dropFirst()
            #expect(lines.count <= 150)
            if let pack = lines.first(where: { $0.hasPrefix("Pack | ") }) {
                let cols = pack.components(separatedBy: " | ")
                #expect(cols[2].components(separatedBy: "; ").count == 30, "sub-folders capped at 30")
                #expect(cols[3].components(separatedBy: "; ").count == 5, "samples capped at 5")
            }
        }
        #expect(entries.contains { $0.path == "Pack" })
        // Off — the feature, or the master switch — and nothing is built to send.
        let masterOff: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(false),
                                                             "features": .object(["library": .bool(true)])])]
        await #expect(throws: (any Error).self) {
            _ = try await engine.aiLibraryRequest(settings: masterOff, entries: entries.prefix(3).map(\.json), apiKey: "k")
        }
        let features = try await engine.aiFeatures(settings: masterOff)
        #expect(features.first { $0.id == "library" }?.enabled == false)
    }
}

// MARK: - Pictures of the screens

/// "Sort linked folders" in Settings and its preview sheet, in a real window
/// (`ImageRenderer` draws a List and a button as nothing). Writes only when
/// KHAYT_SNAPSHOT_DIR is set; run once per language with KHAYT_LANG.
@Suite(.serialized) @MainActor
struct Alpha67SnapshotTests {

    private func hosted(_ view: some View, _ name: String, _ size: CGSize, dark: Bool, wait: Double = 1.2) async {
        guard let dir = SnapshotTests.outputDir else { return }
        let rtl = Direction.rtlLanguages.contains(Direction.shopLanguage())
        let host = NSHostingView(rootView: view
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .frame(width: size.width, height: size.height)
            .background(Khayt.surface))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Suspended, not a blocked run loop: a pane that loads in `.task`
        // (the assistant pane asks the engine) needs the main actor free.
        try? await Task.sleep(for: .seconds(wait))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?
            .write(to: dir.appending(path: name + (dark ? "-dark" : "-light") + ".png"))
    }

    /// A picture file to stand for a print's render.
    private static func swatch(_ name: String, _ color: NSColor) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "a67-\(name).png")
        let image = NSImage(size: NSSize(width: 80, height: 80))
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 80, height: 80), xRadius: 10, yRadius: 10).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        return url
    }

    private static func preview(_ assistant: SortAsk?, off: Bool) -> SortPreview {
        let rows = [
            SortPreview.Row(id: "Life Size Buzz Lightyear", name: "Life Size Buzz Lightyear", models: 42,
                            picture: .file(swatch("buzz", .systemGreen)), from: "Aug26 Giga Tier"),
            SortPreview.Row(id: "Life Size Gambit", name: "Life Size Gambit", models: 18,
                            picture: .file(swatch("gambit", .systemPurple)), from: "Aug26 Giga Tier"),
            SortPreview.Row(id: "Guilmon Card", name: "Guilmon Card", models: 103, picture: nil, from: "Oct26 Giga Tier"),
            SortPreview.Row(id: "Gridcube", name: "Gridcube", models: 27,
                            picture: .file(swatch("grid", .systemOrange)), from: "GridCube File Delivery"),
            SortPreview.Row(id: "Mumm Ra", name: "Mumm Ra", models: 9, picture: nil, from: nil),
            SortPreview.Row(id: "Iron Spiderman", name: "Iron Spiderman", models: 1, picture: nil, from: "Yosh Free Files"),
        ]
        return SortPreview(plans: [], rows: rows, collections: 4, moved: 186, renamed: 12, tagged: 194, kept: 7,
                           assistant: assistant, assistantOff: off)
    }

    static func shop(linked: URL) async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        var settings = shop.settingsDict
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        library["linked"] = .array([.string(linked.path)])
        settings["printLibrary"] = .object(library)
        settings["ai"] = .object(["enabled": .bool(true), "provider": .string("anthropic"),
                                  "features": .object(["library": .bool(true), "quote": .bool(true)])])
        shop.settingsValue = .object(settings)
        return shop
    }

    @Test("the Sort linked folders sheet, its Settings row, the asking state and the note, in light and dark")
    func linkedSortScreens() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let linked = FileManager.default.temporaryDirectory.appending(path: "a67-My Drive")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let shop = await Self.shop(linked: linked)
        let sheet = CGSize(width: 560, height: 600)
        for dark in [false, true] {
            await hosted(LinkedSortSheet(shop: shop, preview: Self.preview(nil, off: true)), "a67-sort-sheet-assistant-off",
                   sheet, dark: dark)
            await hosted(LinkedSortSheet(shop: shop, preview: Self.preview(SortAsk(sorted: 37, problem: nil, held: 12), off: false)),
                   "a67-sort-sheet-assistant-used", sheet, dark: dark)
            await hosted(LinkedSortSheet(shop: shop, preview: Self.preview(SortAsk(sorted: 0, problem: "The provider is busy (HTTP 529). Try again in a minute."), off: false)),
                   "a67-sort-sheet-assistant-failed", sheet, dark: dark)
            let settings = CGSize(width: 680, height: 820)
            shop.libraryMoveNote = nil
            await hosted(Form { LibraryLocationSettings(shop: shop) }.formStyle(.grouped), "a67-library-location",
                   settings, dark: dark)
            shop.libraryMoveBusy = true
            shop.libraryScanStop = ScanStop()
            shop.librarySortAsking = true
            await hosted(Form { LibraryLocationSettings(shop: shop) }.formStyle(.grouped), "a67-library-asking",
                   settings, dark: dark)
            shop.librarySortAsking = false
            shop.libraryScanStop = nil
            shop.libraryMoveBusy = false
            shop.libraryMoveNote = [shop.words.callIt("mac.linked_regrouped", ["n": .number(186)]),
                                    shop.words.callIt("mac.sort_pictures_added", ["n": .number(31)]),
                                    SortAsk(sorted: 37).line(shop.words) ?? ""].joined(separator: " ")
            await hosted(Form { LibraryLocationSettings(shop: shop) }.formStyle(.grouped), "a67-library-done",
                   settings, dark: dark)
            shop.libraryMoveNote = nil
            await hosted(AssistantPane(shop: shop), "a67-assistant-pane", CGSize(width: 680, height: 1500), dark: dark,
                   wait: 2.5)
        }
    }
}
