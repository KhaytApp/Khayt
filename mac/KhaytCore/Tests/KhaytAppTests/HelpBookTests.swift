import Foundation
import Testing
@testable import KhaytApp

/// The help must exist, be reachable, and be the same book in every language.
///
/// Help rots more quietly than code: nothing fails when an article is renamed,
/// dropped from the order, or translated into eight of nine languages. These
/// are the checks that would otherwise be a person remembering.
@MainActor
struct HelpBookTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func helpDirectory(_ language: String) -> URL {
        repoRoot.appending(path: "mac/KhaytCore/Sources/KhaytApp/Help/\(language)")
    }

    static func ids(in language: String) throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(atPath: helpDirectory(language).path)
        return Set(files.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
    }

    /// The order is the book. A file nobody named is never shown; a name with
    /// no file is a gap in the contents.
    @Test("every article named is on disk, and every file on disk is named")
    func orderAndFilesAgree() throws {
        let onDisk = try Self.ids(in: "en")
        let named = Set(HelpBook.order)
        #expect(named.subtracting(onDisk).isEmpty,
                "named in HelpBook.order with no file: \(named.subtracting(onDisk).sorted())")
        #expect(onDisk.subtracting(named).isEmpty,
                "a file nobody reads: \(onDisk.subtracting(named).sorted())")
        #expect(HelpBook.order.count == Set(HelpBook.order).count, "an article is listed twice")
    }

    /// Every language the app speaks has the whole book. An article missing
    /// in one falls back to English at runtime rather than vanishing, which is
    /// right, and is also how a gap goes unnoticed. So it is named here.
    /// Arabic is not an afterthought — the app lays itself out right to left
    /// and a Riyadh shop reads it that way — and since Nov 2026 the other
    /// seven languages the interface speaks have the book too.
    @Test("the book is complete in every language the app speaks")
    func everyLanguageIsComplete() throws {
        let english = try Self.ids(in: "en")
        for language in Words.supported where language != "en" {
            let ids = try Self.ids(in: language)
            #expect(english.subtracting(ids).isEmpty,
                    "\(language): not translated: \(english.subtracting(ids).sorted())")
            #expect(ids.subtracting(english).isEmpty,
                    "\(language): translated but not in the English book: \(ids.subtracting(english).sorted())")
        }
    }

    /// The title is the first `# ` line, and it is what the contents list
    /// shows. A file without one is titled by its id, which reads as wrong on
    /// screen — deliberately, but it should never ship that way.
    @Test("every article has a title and something under it")
    func articlesAreWritten() throws {
        for language in Words.supported {
            for id in HelpBook.order {
                let url = Self.helpDirectory(language).appending(path: "\(id).md")
                let text = try String(contentsOf: url, encoding: .utf8)
                let article = HelpBook.parse(id: id, text)
                #expect(article.title != id, "\(language)/\(id).md has no `# ` heading")
                #expect(article.body.count > 200,
                        "\(language)/\(id).md is \(article.body.count) characters — a stub")
            }
        }
    }

    /// A translation that is still English is the failure
    /// `test/locale-quality.test.js` catches for the interface strings; the
    /// help files are markdown and that guard cannot see them. A translated
    /// article byte-identical to the English one has not been translated, and
    /// one whose headings are still the English headings is half done.
    @Test("a translated article is not the English one copied")
    func translationsAreNotCopies() throws {
        func headings(_ text: String) -> [String] {
            text.split(separator: "\n").filter { $0.hasPrefix("#") }.map(String.init)
        }
        for language in Words.supported where language != "en" {
            for id in HelpBook.order {
                let en = try String(contentsOf: Self.helpDirectory("en").appending(path: "\(id).md"),
                                    encoding: .utf8)
                let other = try String(contentsOf: Self.helpDirectory(language).appending(path: "\(id).md"),
                                       encoding: .utf8)
                #expect(en != other, "\(language)/\(id).md is the English file")
                // One shared heading is a word the languages share — French
                // "Secrets", Brazilian "Backups". Two is a file left half done.
                let same = Set(headings(en)).intersection(headings(other))
                #expect(same.count <= 1, "\(language)/\(id).md keeps English headings: \(same.sorted())")
            }
        }
        // Arabic script anywhere in it. A file of English prose with an
        // Arabic title is the shape a half-done translation takes.
        for id in HelpBook.order {
            let ar = try String(contentsOf: Self.helpDirectory("ar").appending(path: "\(id).md"),
                                encoding: .utf8)
            #expect(ar.unicodeScalars.contains { (0x0600...0x06FF).contains(Int($0.value)) },
                    "ar/\(id).md carries no Arabic")
        }
    }

    /// Every word must appear somewhere, not as a phrase — help is searched
    /// with half-remembered wording.
    @Test("search finds an article by words that are not adjacent")
    func searchIsWordwise() {
        let articles = [
            HelpBook.parse(id: "a", "# The shelf\n\nA spool that will run out soon is marked."),
            HelpBook.parse(id: "b", "# Jobs\n\nA job is one piece of work."),
        ]
        #expect(HelpBook.matching("spool marked", in: articles).map(\.id) == ["a"])
        #expect(HelpBook.matching("shelf", in: articles).map(\.id) == ["a"])
        #expect(HelpBook.matching("SPOOL", in: articles).map(\.id) == ["a"], "search is case-sensitive")
        #expect(HelpBook.matching("", in: articles).count == 2, "an empty search hid everything")
        #expect(HelpBook.matching("nothing here", in: articles).isEmpty)
    }

    /// Rendering is per block because `AttributedString(markdown:)` flattens a
    /// whole document into one run — headings stop being headings.
    @Test("markdown keeps its shape as headings, bullets and paragraphs")
    func blocksKeepShape() {
        let blocks = HelpWindow.blocks("""
        A paragraph that is
        soft wrapped.

        ## A heading

        - one
        - two
        """)
        #expect(blocks.count == 4)
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[0].text == "A paragraph that is soft wrapped.", "a soft wrap became a break")
        #expect(blocks[1].kind == .heading)
        #expect(blocks[2].kind == .bullet)
        #expect(blocks[2].text == "one")
        #expect(blocks[3].kind == .bullet)
    }

    /// The Help menu is supplied empty by macOS and stays empty unless
    /// something is put in it; the window and the menu must name the same id.
    /// The renderer joins soft-wrapped lines with a space; between Chinese or
    /// Japanese characters that space is a visible gap.
    @Test("soft-wrapped CJK joins without a space, Latin with one")
    func unwrapCJK() {
        #expect(HelpWindow.unwrap("打印机\n正在工作") == "打印机正在工作")
        #expect(HelpWindow.unwrap("ジョブを\n開きます") == "ジョブを開きます")
        #expect(HelpWindow.unwrap("a spool\nruns out") == "a spool runs out")
    }

    @Test("the help is reachable from the menu and the scene")
    func reachable() throws {
        let menus = try String(contentsOf: Self.repoRoot.appending(
            path: "mac/KhaytCore/Sources/KhaytApp/Menus.swift"), encoding: .utf8)
        let app = try String(contentsOf: Self.repoRoot.appending(
            path: "mac/KhaytCore/Sources/KhaytApp/KhaytApp.swift"), encoding: .utf8)
        #expect(menus.contains("CommandGroup(replacing: .help)"), "the Help menu is still empty")
        #expect(menus.contains("openWindow(id: HelpWindow.id)"), "the menu item opens nothing")
        #expect(app.contains("Window(Text(Words.upfront(\"mac.help_title\")), id: HelpWindow.id)"),
                "there is no help window scene")
    }
}

extension HelpWindow.Block.Kind: @retroactive Equatable {}
