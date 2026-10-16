import SwiftUI
import KhaytCore
import UniformTypeIdentifiers

/// The invoice, on screen, with a way to keep it.
///
/// The document is built by the shared module and drawn by WebKit, so what this
/// sheet shows is the paper the customer gets — not a summary of it. There is
/// no second layout here to drift from Khayt's.
///
/// Building it needs the runtime, so it happens once the sheet is on screen and
/// the sheet says so while it waits. A shop with no ZATCA registration, or one
/// missing a field the QR requires, still gets a document: the refusal prints on
/// it in words rather than as an empty box.
struct InvoiceSheet: View {
    let shop: Shop
    let subject: Shop.PendingHold

    @State private var paper: InvoicePaper?
    @State private var problem: String?
    @State private var saved: String?
    /// The number the document prints, as `KhaytInvoiceDocument.documentNumber`
    /// answered it once the job was numbered (if it was owed one).
    @State private var number: String?

    private var job: Order? { shop.orders.first { $0.id == subject.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shop.words.callIt(job.flatMap(Stage.of) == .quote ? "doc.quotation" : "doc.invoice"))
                        .font(.headline)
                    Text(subject.project)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                // The number the DOCUMENT states under "No." — a header saying
                // one thing over a paper saying another is a header nobody can
                // use. Asked of the shared rule (`documentNumber`), not kept
                // here: the invoice number for a job that began as a quote,
                // the id for a quote and for every other job.
                if let number, !number.isEmpty {
                    Text(number).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
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
                Button(shop.words.callIt("common.close")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.save_pdf")) { save() }
                    .keyboardShortcut(.defaultAction)
                    // Asking WebKit for a PDF before it has laid the document
                    // out returns a blank page, so the button waits for it.
                    .disabled(paper?.drawn != true)
            }
            .padding(16)
        }
        .task(id: subject.id) { await build() }
    }

    /// The paper, through `Shop.invoiceDocument` — the one path File ▸ Print…
    /// and File ▸ Share… take as well, so the three cannot disagree about
    /// which number a document carries or when it may not be drawn.
    private func build() async {
        switch await shop.invoiceDocument(for: subject.id) {
        case .refused(let why):
            problem = why
        case .paper(let doc, let n):
            number = n
            paper = InvoicePaper(document: doc)
        }
    }

    /// Keep it, where the shop says.
    ///
    /// A save panel rather than a fixed folder: this is a document a person is
    /// about to send someone, and an app that decides where it went is an app
    /// they have to go looking through.
    private func save() {
        guard let paper else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Self.filename(job, words: shop.words, number: number)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await paper.pdf().write(to: url, options: .atomic)
                Telemetry.feature(.invoiceExported, in: shop)
                saved = shop.words.callIt("mac.saved_to") + " " + url.lastPathComponent
            } catch {
                saved = error.localizedDescription
            }
        }
    }

    /// What the file is called.
    ///
    /// The number the document prints (`number`, from `documentNumber`; the
    /// job's id when none was given). Falling back to the
    /// project's name when there is somehow none, and slashes taken out either
    /// way — a job called "lids 2/3" would otherwise be saved into a folder
    /// that is not there.
    static func filename(_ job: Order?, words: Words, number: String? = nil) -> String {
        let number = number ?? job?.id ?? ""
        let base = number.isEmpty ? (job?.project ?? words.callIt("doc.invoice")) : number
        let cleaned = base.replacingOccurrences(of: "/", with: "-")
                          .replacingOccurrences(of: ":", with: "-")
                          .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "invoice" : cleaned) + ".pdf"
    }
}
