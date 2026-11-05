import SwiftUI
import KhaytCore
import UniformTypeIdentifiers

/// A packing slip, delivery note, work order or account statement, on screen,
/// with a way to print it or keep it as a PDF.
///
/// The invoice sheet's shape, and its paper: the document is the shared
/// module's (`lib/shop-documents.js`) drawn by WebKit, so what this shows is
/// what the other app prints.
struct PaperSheet: View {
    let shop: Shop
    let request: PaperRequest

    @State private var paper: InvoicePaper?
    @State private var problem: String?
    @State private var saved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.headline)
                Text(request.subtitle)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(16)

            Divider()

            Group {
                if let paper {
                    InvoicePaperView(paper: paper)
                } else if let problem {
                    EmptyHere(title: problem)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 620, minHeight: 520)

            Divider()

            HStack {
                if let saved {
                    Text(saved).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.pendingPaper = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.print")) {
                    guard let paper else { return }
                    Task { await paper.printWithPanel(title: request.title, over: NSApp.keyWindow) }
                }
                .disabled(paper?.drawn != true)
                Button(shop.words.callIt("mac.save_pdf")) { save() }
                    .keyboardShortcut(.defaultAction)
                    // A PDF asked for before WebKit has laid the page out is blank.
                    .disabled(paper?.drawn != true)
            }
            .padding(16)
        }
        .task(id: request.id) { await build() }
    }

    private func build() async {
        switch await shop.paperDocument(request) {
        case .refused(let why):
            problem = why
        case .paper(let doc, _):
            paper = InvoicePaper(document: doc, wholePage: Shop.paperIsWholePage(request))
        }
    }

    /// Keep it, where the shop says — a paper is about to go to somebody.
    private func save() {
        guard let paper else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = request.filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await paper.pdf().write(to: url, options: .atomic)
                saved = shop.words.callIt("mac.saved_to") + " " + url.lastPathComponent
            } catch {
                saved = error.localizedDescription
            }
        }
    }
}

/// A quote's kept versions, newest first (`lib/quote-revision.js`): the
/// desktop's "Quote history" table — version, date, price, parts and notes.
struct QuoteRevisionsSheet: View {
    let shop: Shop
    let subject: Shop.PendingHold

    @State private var rows: [KhaytEngine.QuoteRevision]?

    private var job: Order? { shop.orders.first { $0.id == subject.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shop.words.callIt("ord.quote_revisions")).font(.headline)
                Text(subject.project + " · " + shop.words.callIt("ord.quote_version",
                                                                  ["n": .number(Double(shop.quoteVersion(subject.id)))]))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(16)
            Divider()
            Group {
                if let rows, rows.isEmpty {
                    EmptyHere(title: shop.words.callIt("ord.quote_rev_empty"))
                } else if let rows {
                    Table(rows) {
                        TableColumn(shop.words.callIt("mac.quote_version_col")) { r in
                            Text(shop.words.callIt("ord.quote_version", ["n": .number(Double(r.version))]))
                                .monospacedDigit()
                        }
                        TableColumn(shop.words.callIt("ord.quote_rev_date")) { r in
                            Text(Self.day(r.snapshotAt, shop.words)).monospacedDigit()
                        }
                        TableColumn(shop.words.callIt("ord.quote_rev_price")) { r in
                            Text(Money.text(r.price, job?.currency ?? shop.currency)).monospacedDigit()
                        }
                        TableColumn(shop.words.callIt("mac.parts")) { r in
                            Text(shop.words.numeral(r.partCount)).monospacedDigit()
                        }
                        TableColumn(shop.words.callIt("doc.notes")) { r in
                            Text(r.notes.isEmpty ? "—" : r.notes).lineLimit(1).truncationMode(.tail)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 560, minHeight: 280)
            Divider()
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.pendingRevisions = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .task(id: subject.id) { rows = await shop.quoteRevisions(subject.id) }
    }

    /// The day a version was kept, in the shop's language and the book's
    /// calendar; the raw stamp when it is not one.
    static func day(_ iso: String, _ words: Words) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        return words.say(date, Date.FormatStyle(date: .abbreviated, time: .omitted))
    }
}
