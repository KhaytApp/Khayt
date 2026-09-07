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
                // The job's id, because that is the number the DOCUMENT states
                // under "No." — a header saying one thing over a paper saying
                // another is a header nobody can use.
                if let number = job?.id, !number.isEmpty {
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

    private func build() async {
        guard let job else { problem = shop.words.callIt("mac.move_gone"); return }
        guard let doc = await Invoice.html(for: job, shop: shop) else {
            problem = shop.words.callIt("mac.no_document"); return
        }
        paper = InvoicePaper(document: doc)
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
        panel.nameFieldStringValue = Self.filename(job, words: shop.words)
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

    /// What the file is called.
    ///
    /// The job's id, which is what Khayt's own PDF export uses and what the
    /// document prints as its number. Falling back to the project's name when
    /// there is somehow no id, and slashes taken out either way — a job called
    /// "lids 2/3" would otherwise be saved into a folder that is not there.
    static func filename(_ job: Order?, words: Words) -> String {
        let number = job?.id ?? ""
        let base = number.isEmpty ? (job?.project ?? words.callIt("doc.invoice")) : number
        let cleaned = base.replacingOccurrences(of: "/", with: "-")
                          .replacingOccurrences(of: ":", with: "-")
                          .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "invoice" : cleaned) + ".pdf"
    }
}
