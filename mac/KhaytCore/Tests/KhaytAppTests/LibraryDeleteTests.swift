import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Taking a model out of the library.
///
/// Reported from the running app: *"I can't delete something from the
/// library?"* — and nothing in the Mac app could. The Electron app has had
/// this since the library existed; the rule here is that one's.
@MainActor
struct LibraryDeleteTests {

    static func book() -> [String: JSONValue] {
        ["printFiles": .array([
            .object(["id": .string("PF-a"), "name": .string("hand"),
                     "sourceFile": .object(["filename": .string("hand.stl"), "ext": .string("stl")])]),
            .object(["id": .string("PF-b"), "name": .string("torso"),
                     "sourceFile": .object(["filename": .string("torso.stl"), "ext": .string("stl")])]),
        ])]
    }

    static func tempStore(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-libdel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    @Test("deleting a model takes its record out and leaves the rest")
    func recordGoes() throws {
        let url = try Self.tempStore(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The same write `Shop.deleteLibraryFile` makes.
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            var rows = Shop.rows(root, "printFiles")
            rows.removeAll { Shop.recordId($0) == "PF-a" }
            root["printFiles"] = .array(rows)
        }
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        let left = Shop.rows(root, "printFiles").compactMap(Shop.recordId)
        #expect(left == ["PF-b"], "left \(left)")
    }

    @Test("the sample shop's library cannot be changed, and it says why")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        guard let any = shop.files.first else { return }
        shop.pendingLibraryDelete = any
        await shop.deleteLibraryFile(any)
        #expect(shop.importProblem == shop.words.callIt("mac.move_sample"))
        #expect(shop.pendingLibraryDelete == nil, "the question is closed either way")
        #expect(shop.files.contains { $0.id == any.id }, "the sample lost a model")
    }

    /// ── THE QUESTION IS ASKED WHERE BOTH SHELLS CAN ASK IT ─────────────────
    ///
    /// Every sheet the window raises lives in `WindowSheets` so that a shell
    /// switch cannot leave one attached to a view no longer drawn — the bug
    /// that shipped with every editor unreachable. A confirmation is a sheet
    /// by another name, and this one goes the same way.
    @Test("the delete confirmation lives in WindowSheets, and the menu offers it")
    func wiredInBothShells() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let window = (try? String(contentsOf: root.appending(path: "ShopWindow.swift"), encoding: .utf8)) ?? ""
        let actions = (try? String(contentsOf: root.appending(path: "FileActions.swift"), encoding: .utf8)) ?? ""
        #expect(!window.isEmpty && !actions.isEmpty, "the sources moved; this test is reading nothing")
        guard let sheets = window.range(of: "struct WindowSheets: ViewModifier") else {
            Issue.record("WindowSheets is gone"); return
        }
        let after = window[sheets.upperBound...]
        #expect(after.contains("pendingLibraryDelete"), """
            the delete confirmation is not in WindowSheets — attached to one \
            shell, it is a Delete that does nothing in the other
            """)
        #expect(actions.contains("pendingLibraryDelete") && actions.contains("role: .destructive"),
                "the model's menu no longer offers Delete, or offers it unmarked")
        // And the words are the Electron app's own, in both languages.
        for key in ["plib.delete_title", "plib.delete_confirm", "plib.deleted", "plib.delete_partial"] {
            #expect(window.contains(key) || actions.contains(key)
                    || ((try? String(contentsOf: root.appending(path: "Shop.swift"), encoding: .utf8)) ?? "").contains(key),
                    "\(key) is not used — the two apps say this differently")
        }
    }
}
