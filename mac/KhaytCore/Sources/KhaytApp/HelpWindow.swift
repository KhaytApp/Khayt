import SwiftUI
import KhaytCore

/// Khayt's help, in a window of its own.
///
/// Beside the app rather than on top of it: somebody reading "how do I drop one
/// object from a plate" wants the plate on screen while they read. So it is a
/// `Window` scene, not a sheet.
struct HelpWindow: View {
    /// Named once, because the scene and the menu item must agree.
    static let id = "help"

    let shop: Shop
    @State private var chosen: String?
    @State private var term = ""

    private var articles: [HelpBook.Article] {
        HelpBook.articles(language: shop.words.language, bundle: AppResources.bundle)
    }

    private var shown: [HelpBook.Article] {
        HelpBook.matching(term.trimmingCharacters(in: .whitespaces), in: articles)
    }

    var body: some View {
        NavigationSplitView {
            List(shown, selection: $chosen) { article in
                Text(article.title).tag(article.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .searchable(text: $term, placement: .sidebar,
                        prompt: shop.words.callIt("mac.help_search"))
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: term)
                }
            }
        } detail: {
            if let article = shown.first(where: { $0.id == chosen }) ?? shown.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(article.title).font(.largeTitle.bold())
                        // `AttributedString(markdown:)` with `.full` so the
                        // headings, lists and emphasis in the files survive.
                        // Per-article rather than per-paragraph: the whole body
                        // is one document, and splitting it would lose the
                        // blank lines that separate its parts.
                        ForEach(Array(Self.blocks(article.body).enumerated()), id: \.offset) { _, block in
                            block.view
                        }
                    }
                    .textSelection(.enabled)
                    .padding(28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Khayt.ground)
            } else {
                ContentUnavailableView(shop.words.callIt("mac.help_none"),
                                       systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        // The shop's language, not the Mac's — the same rule the main window
        // follows. An Arabic book reads right to left here too.
        .environment(\.layoutDirection, shop.words.isRTL ? .rightToLeft : .leftToRight)
    }

    /// One piece of an article.
    ///
    /// Markdown is rendered a BLOCK AT A TIME because SwiftUI's
    /// `AttributedString(markdown:)` flattens a whole document into one run of
    /// text: headings stop being headings and every list item joins the
    /// paragraph above it. Splitting on blank lines first keeps the shape.
    struct Block: Identifiable {
        let id = UUID()
        let kind: Kind
        let text: String

        enum Kind { case heading, bullet, paragraph }

        @ViewBuilder var view: some View {
            switch kind {
            case .heading:
                Text(Self.inline(text)).font(.title3.bold()).padding(.top, 8)
            case .bullet:
                // The dot is drawn rather than left in the text, so a wrapped
                // line lines up under the words instead of under the marker.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                }
            case .paragraph:
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        }

        /// Bold, italics and `code`, kept. A failure falls back to the raw
        /// text: help that shows its own asterisks is worse than none, and help
        /// that shows nothing is worse still.
        static func inline(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text,
                                   options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
    }

    static func blocks(_ body: String) -> [Block] {
        var out: [Block] = []
        for chunk in body.components(separatedBy: "\n\n") {
            let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if piece.hasPrefix("## ") {
                out.append(Block(kind: .heading, text: String(piece.dropFirst(3))))
            } else if piece.hasPrefix("- ") {
                // A run of bullets arrives as one chunk; each line is its own.
                for line in piece.split(separator: "\n") {
                    let item = line.trimmingCharacters(in: .whitespaces)
                    out.append(Block(kind: .bullet,
                                     text: item.hasPrefix("- ") ? String(item.dropFirst(2)) : item))
                }
            } else {
                // Soft-wrapped prose is one paragraph, so the newlines inside a
                // chunk become spaces rather than breaks.
                out.append(Block(kind: .paragraph,
                                 text: piece.replacingOccurrences(of: "\n", with: " ")))
            }
        }
        return out
    }
}
