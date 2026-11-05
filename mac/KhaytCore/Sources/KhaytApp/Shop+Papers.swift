import Foundation
import AppKit
import KhaytCore

/// One of the shop's papers, asked for and waiting to be drawn.
///
/// Frozen when asked, like every question this window holds: the title and
/// the file name are the ones the shop clicked, whatever reloads underneath.
struct PaperRequest: Identifiable, Equatable {
    enum Subject: Equatable {
        /// A packing slip, delivery note or work order for one job.
        case job(KhaytEngine.ShopPaper, Order.ID)
        /// A customer's account statement.
        case statement(clientId: String)
    }
    let id = UUID()
    let subject: Subject
    /// What the sheet is headed with.
    let title: String
    /// Under the title: the job or the customer.
    let subtitle: String
    /// What Save as PDF offers to call the file.
    let filename: String
}

/// The packing slip, delivery note, work order and a customer's account
/// statement — the papers besides the invoice.
///
/// ── WHAT DECIDES WHAT ─────────────────────────────────────────────────────
///
/// `lib/shop-documents.js`, shared with the other app: the desktop's own four
/// handlers were lifted into it unchanged, so a packing slip printed here is
/// the one printed there. This gathers what the paper needs from the book and
/// draws it in the invoice's WebKit paper (`InvoicePaper`), which saves the
/// same A4 PDF the invoice does.
///
/// Showing a paper writes nothing, so it is not behind `canMoveJobs`, as the
/// invoice is not: the sample shop is where most people look first.
extension Shop {

    /// The words a paper is headed with — the shop's own catalogue.
    static func paperTitleKey(_ kind: KhaytEngine.ShopPaper) -> String {
        switch kind {
        case .packingSlip: return "ps.title"
        case .deliveryNote: return "doc.delivery_note"
        case .workOrder: return "doc.work_order"
        }
    }

    /// The file name a paper is saved under: what it is, and whose.
    static func paperFilename(_ kind: KhaytEngine.ShopPaper, reference: String) -> String {
        let lead: String
        switch kind {
        case .packingSlip: lead = "packing-slip"
        case .deliveryNote: lead = "delivery-note"
        case .workOrder: lead = "work-order"
        }
        return lead + "-" + Self.safeFilePart(reference) + ".pdf"
    }

    /// A name with the characters a file name cannot hold taken out.
    static func safeFilePart(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-")
                       .replacingOccurrences(of: ":", with: "-")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "khayt" : cleaned
    }

    /// Show one job's packing slip, delivery note or work order.
    func showPaper(_ kind: KhaytEngine.ShopPaper, for id: Order.ID) {
        guard let job = orders.first(where: { $0.id == id }) else { return }
        pendingPaper = PaperRequest(subject: .job(kind, id),
                                    title: words.callIt(Self.paperTitleKey(kind)),
                                    subtitle: shownTitle(of: job),
                                    filename: Self.paperFilename(kind, reference: job.reference))
    }

    /// Show a customer's account statement. Only for somebody written down:
    /// the statement lists the jobs filed under their record.
    func showStatement(for person: Customer) {
        guard let record = person.record else { return }
        pendingPaper = PaperRequest(subject: .statement(clientId: record.id),
                                    title: words.callIt("cl.statement_title"),
                                    subtitle: person.name,
                                    filename: "statement-" + Self.safeFilePart(person.name) + ".pdf")
    }

    /// What every paper is drawn with, from the book as loaded.
    func paperInputs(docs: [JSONValue] = []) -> KhaytEngine.PaperInputs {
        KhaytEngine.PaperInputs(
            settings: settingsDict, clients: clientRows, machines: machineRows,
            inventory: inventoryRows, currencies: Invoice.currencyTable(self),
            language: words.language, shopName: shopName,
            today: Calendar.book.dayString(Date()), docs: docs)
    }

    /// The paper itself, or why there is none.
    func paperDocument(_ request: PaperRequest) async -> InvoiceBuild {
        guard let engine else { return .refused(words.callIt("mac.move_no_engine")) }
        switch request.subject {
        case .job(let kind, let id):
            guard let job = orders.first(where: { $0.id == id }), let row = orderRow(id) else {
                return .refused(words.callIt("mac.move_gone"))
            }
            let docs: [JSONValue] = await documents(for: job).map {
                .object(["name": .string($0.name), "packWithOrder": .bool($0.packWithOrder)])
            }
            guard let html = try? await engine.shopPaperHtml(kind, order: row, paperInputs(docs: docs)) else {
                return .refused(words.callIt("mac.no_document"))
            }
            return .paper(InvoiceDocument(html: html, arabicNumerals: false, selector: ""), number: job.reference)
        case .statement(let clientId):
            guard let client = clientRows.first(where: { Self.recordId($0) == clientId }) else {
                return .refused(words.callIt("mac.move_gone"))
            }
            guard let html = try? await engine.statementHtml(client: client, orders: orderRows, paperInputs()) else {
                return .refused(words.callIt("mac.no_document"))
            }
            return .paper(InvoiceDocument(html: html, arabicNumerals: false, selector: ""), number: nil)
        }
    }

    /// Whether a paper is a whole page of its own (the packing slip) rather
    /// than a document for the invoice's stylesheet.
    static func paperIsWholePage(_ request: PaperRequest) -> Bool {
        if case .job(.packingSlip, _) = request.subject { return true }
        return false
    }

    // MARK: - Export all invoices

    /// The jobs "Export all invoices" would write for this customer: their
    /// finished work, oldest first, by the shared rule.
    func invoicesToExport(for person: Customer) async -> [Order.ID] {
        guard let record = person.record, let engine else { return [] }
        return (try? await engine.invoicesToExport(clientId: record.id, orders: orderRows)) ?? []
    }

    /// Every finished job's invoice for this customer, one PDF each, into a
    /// folder the shop picks. The same paper the invoice sheet saves —
    /// `invoiceDocument`, so a job owed its invoice number is given it first,
    /// and one that cannot be numbered here is left out and named.
    func exportInvoices(for person: Customer) async {
        moveProblem = nil
        moveNotices = []
        let ids = await invoicesToExport(for: person)
        guard !ids.isEmpty else { moveProblem = words.callIt("cl.no_invoices"); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = words.callIt("cl.export_all_invoices")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var failed: [String] = []
        var written = 0
        for id in ids {
            switch await invoiceDocument(for: id) {
            case .refused:
                failed.append(orders.first { $0.id == id }?.reference ?? id)
            case .paper(let doc, let number):
                let paper = InvoicePaper(document: doc)
                // WebKit lays the page out before a PDF is anything but blank.
                for _ in 0..<600 where !paper.drawn { try? await Task.sleep(for: .milliseconds(50)) }
                let name = InvoiceSheet.filename(orders.first { $0.id == id }, words: words, number: number)
                do {
                    guard paper.drawn else { throw InvoicePaper.Failure.printFailed }
                    try await paper.pdf().write(to: folder.appending(path: name), options: .atomic)
                    written += 1
                } catch {
                    failed.append(orders.first { $0.id == id }?.reference ?? id)
                }
            }
        }
        if failed.isEmpty {
            moveNotices = [words.callIt("cl.invoices_exported", ["n": .number(Double(written))])]
        } else {
            moveProblem = words.callIt("cl.invoices_exported_partial", [
                "n": .string(String(written)), "total": .string(String(ids.count)),
                "ids": .string(failed.joined(separator: ", ")),
            ])
        }
    }
}
