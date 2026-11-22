import Foundation

/// Khayt's own help, bundled.
///
/// ── WHY NOT AN APPLE HELP BOOK ────────────────────────────────────────────
///
/// A `.help` bundle is the platform's answer and it is the wrong one here. It
/// is indexed at build time by `hiutil`, served by Help Viewer — a separate
/// application, in its own window, in the system's language rather than the
/// shop's — and it cannot be read while the app it describes is being used
/// beside it. Khayt's interface follows `settings.lang`, not the Mac's, because
/// a Riyadh shop on an English Mac keeps its book in Arabic; help that ignored
/// that would be help in the wrong language for the people most likely to need
/// it.
///
/// So it is a window of this app's own, in the shop's language, opening beside
/// the screen being asked about.
///
/// ── THE PROSE IS NOT IN SWIFT ─────────────────────────────────────────────
///
/// Markdown files under `Resources/Help/<language>/`. Help is long, it is
/// edited far more often than code, and a paragraph inside a string literal is
/// a paragraph nobody rewrites. Keeping it as files also means a translation is
/// a file somebody can be handed.
///
/// The ORDER is here rather than in the files, because reading order is a
/// decision about teaching and a directory listing is alphabetical. An article
/// named here with no file is a gap `HelpBookTests` reports; a file nobody
/// named is dead weight it also reports.
enum HelpBook {

    /// One article, loaded.
    struct Article: Identifiable, Hashable, Sendable {
        let id: String
        /// The first `# ` heading in the file — written once, in the prose,
        /// rather than a second time in a list here that could disagree with it.
        let title: String
        /// Everything after that heading.
        let body: String

        /// Title and body together, folded, for searching. Built once per
        /// article rather than per keystroke.
        let haystack: String
    }

    /// Reading order. Grouped the way somebody learns the app: what it is and
    /// where the book lives, then the day's work, then the shelf and the floor,
    /// then money, then the things that are occasionally needed.
    static let order: [String] = [
        "welcome",
        "the-book",
        "jobs",
        "board",
        "customers",
        "library",
        "catalogue",
        "inventory",
        "machines",
        "money",
        "reports",
        "cloud",
        "backups",
        "settings",
        "shortcuts",
        "when-something-is-wrong",
    ]

    /// Every article, in reading order, for a language.
    ///
    /// Falls back to English per ARTICLE rather than per book: a shop reading
    /// Arabic should not lose the whole help because one article has not been
    /// translated yet, and should not be shown an English book because of it
    /// either.
    static func articles(language: String, bundle: Bundle) -> [Article] {
        order.compactMap { id in
            load(id, language: language, bundle: bundle)
                ?? (language == "en" ? nil : load(id, language: "en", bundle: bundle))
        }
    }

    static func load(_ id: String, language: String, bundle: Bundle) -> Article? {
        guard let url = bundle.url(forResource: id, withExtension: "md",
                                   subdirectory: "Help/\(language)"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(id: id, text)
    }

    /// Split the title off the body.
    ///
    /// A file with no `# ` heading is a drafting mistake, and titling it by its
    /// filename would hide that on screen — so it is titled by its id, which
    /// reads as wrong, which is the point.
    static func parse(id: String, _ text: String) -> Article {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var title = id
        var start = 0
        if let first = lines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            start = 1
        }
        let body = lines.dropFirst(start).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Article(id: id, title: title, body: body,
                       haystack: (title + "\n" + body).lowercased())
    }

    /// The articles matching what was typed.
    ///
    /// Every word has to appear SOMEWHERE in the article, not as a phrase: help
    /// is searched with half-remembered wording — "spool empty when" — and
    /// phrase matching answers nothing for it.
    static func matching(_ term: String, in articles: [Article]) -> [Article] {
        let words = term.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return articles }
        return articles.filter { article in
            words.allSatisfy { article.haystack.contains($0) }
        }
    }
}
