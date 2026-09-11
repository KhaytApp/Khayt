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

    @Test("a subfolder that names a model wins over the folder chosen")
    func deepestName() {
        // Seven kings in one download: each is its own group, not all "Kings".
        #expect(ImportGrouping.group(
            for: folder("/Downloads/Kings/King Abdulaziz/STL/head.stl"),
            chosen: folder("/Downloads/Kings")) == "King Abdulaziz")
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
