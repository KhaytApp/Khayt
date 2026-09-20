import Foundation
import Testing
@testable import KhaytApp

/// What a folder full of models is filed under.
///
/// This is a rule made of judgement about how strangers name folders, so it is
/// pinned against the shapes real packs actually come in rather than against
/// the ones that make the rule look good.
struct ImportGroupingTests {

    private func folder(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test("a model in a named folder is filed under it")
    func plain() {
        let group = ImportGrouping.group(for: folder("/Downloads/Saudi Kings/crown.stl"),
                                         chosen: folder("/Downloads/Saudi Kings"))
        #expect(group == "Saudi Kings")
    }

    /// The case the whole rule exists for.
    @Test("format and state folders are walked through, not filed under")
    func skipsPackaging() {
        // `presupported` is not a group, it is a statement about the file.
        #expect(ImportGrouping.group(
            for: folder("/Downloads/Saudi Kings/STL/presupported/crown.stl"),
            chosen: folder("/Downloads/Saudi Kings")) == "Saudi Kings")
        #expect(ImportGrouping.group(
            for: folder("/Downloads/Dragon/files/3mf/body.3mf"),
            chosen: folder("/Downloads/Dragon")) == "Dragon")
    }

    @Test("every level that names something is kept, in order")
    func theWholePath() {
        // Seven kings in one download: each is its own folder INSIDE Kings,
        // rather than seven siblings with the download's name lost. `STL` is
        // walked through as before.
        #expect(ImportGrouping.group(
            for: folder("/Downloads/Kings/King Abdulaziz/STL/head.stl"),
            chosen: folder("/Downloads/Kings")) == "Kings/King Abdulaziz")
    }

    @Test("a project with levels keeps them, and its loose files stay at the top")
    func theReportedCase() {
        // The library showed "only the files in the first folder, all sub
        // folders skipped": every file WAS imported, and the ones below the
        // top level landed in sibling folders instead of inside the project.
        let root = folder("/Downloads/MyProject")
        #expect(ImportGrouping.group(for: folder("/Downloads/MyProject/base.stl"),
                                     chosen: root) == "MyProject")
        #expect(ImportGrouping.group(for: folder("/Downloads/MyProject/pose 1/Blue/a.stl"),
                                     chosen: root) == "MyProject/pose 1/Blue")
        #expect(ImportGrouping.group(for: folder("/Downloads/MyProject/pose 2/Grey/b.stl"),
                                     chosen: root) == "MyProject/pose 2/Grey")
    }

    @Test("a path too long to be written down keeps the two levels that say most")
    func withinTheLimit() {
        // `LibraryFile.normalise` cuts a group at 60 UTF-16 units, the same as
        // the other app, so a longer path would be sliced mid-segment and read
        // as a folder nobody made. The project and the folder the file sat in
        // are what survive; the levels between them go first.
        let long = ["Saudi Kings Collection 2026",
                    "Commissioned Reproductions",
                    "King Abdulaziz Al Saud",
                    "Head and Shoulders"]
        let fitted = ImportGrouping.fitting(long)
        #expect(fitted.utf16.count <= 60, Comment(rawValue: "\(fitted.utf16.count): \(fitted)"))
        #expect(fitted.hasSuffix("Head and Shoulders"),
                "the folder it actually sat in was dropped")
        #expect(fitted.hasPrefix("Saudi Kings Collection 2026"),
                "the project it belongs to was dropped before the levels between")
        #expect(fitted == "Saudi Kings Collection 2026/Head and Shoulders",
                Comment(rawValue: fitted))

        // Three levels that DO fit are all kept — the trim only bites when the
        // limit is actually reached.
        #expect(ImportGrouping.fitting(["Saudi Kings Collection 2026",
                                        "Commissioned Reproductions", "Head"])
                == "Saudi Kings Collection 2026/Commissioned Reproductions/Head")

        // Short paths are untouched.
        #expect(ImportGrouping.fitting(["MyProject", "pose 1", "Blue"])
                == "MyProject/pose 1/Blue")
        // And one level that cannot fit is handed over as it is, to be cut by
        // the rule that owns the limit rather than by a second one here.
        let huge = String(repeating: "A", count: 80)
        #expect(ImportGrouping.fitting([huge]) == huge)
    }

    /// A file picked on its own is one thing the shop chose, not a set.
    @Test("a file chosen directly is never grouped")
    func chosenAlone() {
        let file = folder("/Downloads/crown.stl")
        #expect(ImportGrouping.group(for: file, chosen: file) == nil)
    }

    @Test("a numbered folder is an ordering, not a name")
    func numbering() {
        #expect(ImportGrouping.meaningful("01") == nil)
        #expect(ImportGrouping.meaningful("2") == nil)
        // But the number in front of a name is decoration on a real name.
        #expect(ImportGrouping.meaningful("01 - Dragon") == "01 - Dragon")
    }

    /// Returned as the shop wrote it. Stripping is for COMPARING only — this
    /// app does not get to rename somebody's folders.
    @Test("decoration is compared away and then handed back untouched")
    func decoration() {
        #expect(ImportGrouping.strip("[FDM] Dragon") == "dragon")
        #expect(ImportGrouping.strip("03_supported") == "supported")
        #expect(ImportGrouping.meaningful("[FDM] Dragon") == "[FDM] Dragon")
        // …which means a decorated packaging folder is still refused.
        #expect(ImportGrouping.meaningful("03_supported") == nil)
        #expect(ImportGrouping.meaningful("(STL)") == nil)
    }

    @Test("a folder of nothing but packaging still groups under what was chosen")
    func allPackaging() {
        #expect(ImportGrouping.group(
            for: folder("/Downloads/Vase/stl/supported/vase.stl"),
            chosen: folder("/Downloads/Vase")) == "Vase")
    }

    /// A shop that picks a container folder gets no group rather than a wrong
    /// one. "Downloads" is not what anything is called.
    @Test("a chosen folder that is itself packaging groups nothing")
    func chosenIsPackaging() {
        #expect(ImportGrouping.group(
            for: folder("/Users/x/Downloads/vase.stl"),
            chosen: folder("/Users/x/Downloads")) == nil)
    }

    @Test("a file outside what was chosen is not grouped by it")
    func unrelated() {
        #expect(ImportGrouping.group(for: folder("/Elsewhere/a.stl"),
                                     chosen: folder("/Downloads/Kings")) == nil)
    }
}
