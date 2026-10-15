import Foundation
import UniformTypeIdentifiers
import AppKit
import KhaytCore

/// The profit and loss over the period the shop chose, and the files it is
/// exported as.
///
/// ── ONE QUESTION, ASKED THE SAME WAY TWICE ────────────────────────────────
///
/// The Reports page draws the P&L and the File menu exports it, and both go
/// through `pnlInputs` — the same book, the same grain, the same span. A file
/// that disagreed with the screen it was exported from would be worse than no
/// file: the shop would send its accountant one number and read another.
extension Shop {
    /// What the P&L is asked with, as of `now`; nil when the engine is not up
    /// or the custom range cannot be read.
    func pnlInputs(now: Date = Date()) -> PnlInputs? {
        let resolved = pnlRange.resolve(now: now)
        if resolved == .invalid { return nil }
        let bounds = resolved.bounds
        return PnlInputs(
            orders: orderRows, expenses: expenseRows, settings: settingsDict,
            clients: clientRows, currencies: Invoice.currencyTable(self), now: now,
            granularity: pnlByMonth ? "month" : "quarter",
            wasteLog: wasteRows, inventory: inventoryRows, machines: machineRows,
            recentMonthlyHours: recentMonthlyHours, timeEntries: timeEntryRows,
            from: bounds?.from, to: bounds?.to)
    }

    /// The rows and the VAT for the chosen period — nil for an unreadable
    /// custom range, which the page says rather than showing the whole book.
    func pnlStatement(now: Date = Date()) async -> PnlStatement? {
        guard let engine, let input = pnlInputs(now: now) else { return nil }
        return try? await engine.pnlStatement(input)
    }

    /// The chosen period's name: "This month", or a custom range's own days.
    func pnlPeriodTitle(now: Date = Date()) -> String {
        Self.pnlPeriodTitle(pnlRange, words: words, now: now)
    }

    static func pnlPeriodTitle(_ range: PnlRange, words: Words, now: Date = Date()) -> String {
        guard range.kind == .custom else { return words.callIt(range.kind.key) }
        let from = range.from.trimmingCharacters(in: .whitespaces)
        let to = range.to.trimmingCharacters(in: .whitespaces)
        if from.isEmpty && to.isEmpty { return words.callIt(range.kind.key) }
        // Isolated, so an Arabic line does not reorder the two dates.
        return Figure.isolated(from.isEmpty ? "…" : from) + " – " + Figure.isolated(to.isEmpty ? "…" : to)
    }

    /// The shop's words for every line of the exported statement, keyed the
    /// way `lib/pnl-report.js` `STATEMENT_LABELS` keys them.
    func pnlLabels(_ vat: VatSummary?) -> [String: String] {
        var labels: [String: String] = [
            "title": words.callIt("mac.pnl_title"),
            "period": words.callIt("an.pnl_period"),
            "from": words.callIt("rb.from"),
            "to": words.callIt("rb.to"),
            "currency": words.callIt("pnl.currency"),
            "orders": words.callIt("an.pnl_orders"),
            "revenue": words.callIt("an.revenue"),
            "cogs": words.callIt("pnl.cogs"),
            "waste": words.callIt("pnl.waste"),
            "depreciation": words.callIt("pnl.depreciation"),
            "labour": words.callIt("pnl.labour"),
            "expenses": words.callIt("an.pnl_expenses"),
            "fixed": words.callIt("pnl.fixed"),
            "costs": words.callIt("pnl.costs"),
            "net": words.callIt("an.pnl_net"),
            "margin": words.callIt("pnl.gross_margin"),
            "vatCollected": words.callIt("pnl.vat_output"),
            "vatReclaimable": words.callIt("exp.vat_reclaimed"),
            "vatDue": words.callIt("exp.vat_due"),
            "total": words.callIt("common.total"),
            "inventory": words.callIt("pnl.inventory"),
            "vatTitle": words.callIt("pnl.vat_title"),
            "vatSales": words.callIt("pnl.vat_sales"),
            "vatOutput": words.callIt("pnl.vat_output"),
            "vatInput": words.callIt("pnl.vat_input"),
        ]
        if let vat, vat.applies {
            labels["vatNet"] = words.callIt(vat.net < 0 ? "pnl.vat_refund" : "pnl.vat_net")
            labels["vatMode"] = words.callIt(vat.mode == "exclusive" ? "pnl.vat_exclusive" : "pnl.vat_inclusive")
            if vat.expensesWithoutVat > 0 {
                labels["vatMissing"] = words.callIt("pnl.vat_missing",
                                                    ["n": .number(Double(vat.expensesWithoutVat))])
            }
        }
        return labels
    }

    enum PnlExportFormat { case csv, pdf }

    /// The file's name: the period in book days, so "this month" exported in
    /// October and again in November are two files that say which is which.
    func pnlFilename(_ format: PnlExportFormat, now: Date = Date()) -> String {
        "khayt-pnl-" + pnlRange.fileStem(now: now) + (format == .csv ? ".csv" : ".pdf")
    }

    /// Write the chosen period's P&L where the shop says.
    ///
    /// A save panel, as the invoice's PDF and the shop's own export use: this
    /// is a document somebody is about to send on, and an app that decides
    /// where it went is an app they have to go looking through.
    func exportPnl(_ format: PnlExportFormat) async {
        spendProblem = nil
        spendNote = nil
        // The P&L is a report; reading it is the analytics permission, the
        // one the Ask-the-book item asks for.
        guard permitted("analytics", "view") else { spendProblem = moveProblem; return }
        let now = Date()
        guard let engine, let input = pnlInputs(now: now) else {
            spendProblem = words.callIt(engine == nil ? "mac.move_sample" : "pnl.custom_invalid"); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .pdf]
        panel.nameFieldStringValue = pnlFilename(format, now: now)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let vat = (try? await engine.pnlStatement(input))?.vat
            let docs = try await engine.pnlDocuments(
                input, labels: pnlLabels(vat), periodLabel: pnlPeriodTitle(now: now)
                    .replacingOccurrences(of: "\u{2068}", with: "")
                    .replacingOccurrences(of: "\u{2069}", with: ""),
                currency: currency, rightToLeft: words.isRTL, language: words.language,
                shopName: shopName)
            switch format {
            case .csv:
                // The rule puts the BOM on; written as UTF-8 so it survives.
                try Data(docs.csv.utf8).write(to: url, options: .atomic)
            case .pdf:
                let paper = InvoicePaper(document: InvoiceDocument(html: docs.html, arabicNumerals: false,
                                                                   selector: ""))
                // A hang guard, not a speed limit: WebKit lays the page out in
                // its own process, and a PDF asked for before it has is blank.
                for _ in 0..<600 where !paper.drawn { try await Task.sleep(for: .milliseconds(100)) }
                try await paper.pdf().write(to: url, options: .atomic)
            }
            spendNote = words.callIt("pnl.exported_as") + " " + url.lastPathComponent
        } catch {
            spendProblem = words.callIt("mac.export_failed") + " " + String(describing: error)
        }
    }
}
