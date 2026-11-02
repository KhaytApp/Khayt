import SwiftUI
import KhaytCore

/// Book ▸ End of Day Report… — the day's figures on one A4 page, to print or,
/// from the print panel's PDF menu, to save.
///
/// The other app has had this since its batch-2 operations features; the Mac
/// did not (Oct 31 2026 gap audit). The figures are `EndOfDay.report` (see
/// there for the three desktop sums it corrects); the page is printed by the
/// same WebKit machinery as the shelf labels (`LabelPaper`), so it comes out
/// at the paper's size rather than as a picture of the window.
struct DayReportRequest: Identifiable {
    let id = UUID()
    let report: EndOfDay
    let html: String
}

extension Shop {
    /// Today's report, built once when the shop asks.
    func askForEndOfDay(now: Date = Date()) async {
        guard let engine else { return }
        let rows = orderRows
        guard let facts = try? await engine.endOfDayFacts(orders: rows, settings: settingsDict,
                                                         clients: clientRows) else { return }
        let day = Calendar.book.dayString(now)
        let report = EndOfDay.report(day: day, orders: rows, facts: facts,
                                     waste: wasteRows, time: timeEntryRows,
                                     dayOf: { Calendar.localDay(ofInstant: $0) })
        let shown = words.say(now, .dateTime.weekday(.wide).day().month(.wide).year())
        pendingDayReport = DayReportRequest(
            report: report,
            html: EndOfDayPage.html(report, shown: shown, words: words, currency: currency))
    }
}

/// The page. Every value from the book goes through `Labels.escape`.
@MainActor
enum EndOfDayPage {
    static func html(_ r: EndOfDay, shown: String, words w: Words, currency: String) -> String {
        func e(_ s: String) -> String { Labels.escape(s) }
        func money(_ n: Double) -> String { e(Money.quantity(n, decimals: 2) + " " + currency) }
        let rtl = w.language == "ar"
        let tiles: [(String, String)] = [
            (w.callIt("mac.eod_finished"), e(Money.quantity(Double(r.finished.count), decimals: 0))),
            (w.callIt("mac.eod_revenue"), money(r.revenue)),
            (w.callIt("mac.eod_open"), e(Money.quantity(Double(r.inProgress), decimals: 0))),
            (w.callIt("mac.eod_overdue"), e(Money.quantity(Double(r.overdue), decimals: 0))),
            (w.callIt("mac.eod_waste"), e(Money.quantity(r.wasteGrams, decimals: 0) + " g")),
            (w.callIt("mac.eod_hours"), e(Money.quantity(r.hoursLogged, decimals: 1))),
        ]
        let tileHTML = tiles.map { label, value in
            "<div class=\"tile\"><div class=\"k\">\(e(label))</div><div class=\"v\">\(value)</div></div>"
        }.joined()
        var lists = ""
        if r.finished.isEmpty {
            lists += "<p class=\"none\">\(e(w.callIt("mac.eod_nothing")))</p>"
        } else {
            lists += "<h2>\(e(w.callIt("mac.eod_finished_list")))</h2><table>"
            for job in r.finished {
                lists += "<tr><td>\(e(job.title))</td><td class=\"id\">\(e(job.id))</td>"
                    + "<td class=\"n\">\(money(job.revenue))</td></tr>"
            }
            lists += "</table>"
        }
        if !r.dueNotDone.isEmpty {
            lists += "<h2 class=\"warn\">\(e(w.callIt("mac.eod_due_today")))</h2><table>"
            for job in r.dueNotDone {
                lists += "<tr><td>\(e(job.title))</td><td class=\"id\">\(e(job.id))</td></tr>"
            }
            lists += "</table>"
        }
        let title = w.callIt("mac.eod_title", ["day": .string(shown)])
        return """
        <!doctype html><html lang="\(e(w.language))" dir="\(rtl ? "rtl" : "ltr")"><head><meta charset="utf-8">
        <title>\(e(title))</title><style>
        @page { size: A4; margin: 16mm; }
        body { margin: 0; padding: 16px; background: #fff; color: #111;
               font: 12px -apple-system, system-ui, sans-serif; }
        h1 { font-size: 18px; margin: 0 0 14px; }
        h2 { font-size: 13px; margin: 18px 0 6px; }
        h2.warn { color: #9a5b00; }
        .tiles { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
        .tile { border: 1px solid #ddd; border-radius: 6px; padding: 8px 10px; }
        .k { font-size: 10px; color: #666; }
        .v { font-size: 18px; font-weight: 600; margin-top: 2px; font-variant-numeric: tabular-nums; }
        table { width: 100%; border-collapse: collapse; }
        td { border-bottom: 1px solid #eee; padding: 5px 4px; }
        td.id { color: #777; font-size: 10px; }
        td.n { text-align: end; font-variant-numeric: tabular-nums; white-space: nowrap; }
        .none { color: #666; margin-top: 18px; }
        </style></head><body>
        <h1>\(e(title))</h1>
        <div class="tiles">\(tileHTML)</div>
        \(lists)
        </body></html>
        """
    }
}

/// The page, shown before it is printed.
struct DayReportSheet: View {
    @Bindable var shop: Shop
    let request: DayReportRequest
    @StateObject private var paper: LabelPaper

    init(shop: Shop, request: DayReportRequest) {
        self.shop = shop
        self.request = request
        _paper = StateObject(wrappedValue: LabelPaper(html: request.html, wholePage: true))
    }

    var body: some View {
        VStack(spacing: 0) {
            LabelPaperView(paper: paper)
                .frame(minWidth: 520, minHeight: 560)
            Divider()
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.pendingDayReport = nil }
                    .keyboardShortcut(.cancelAction)
                // The print panel's PDF menu is the Mac's own Save as PDF.
                Button(shop.words.callIt("mac.print")) { paper.printSheet() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!paper.drawn)
            }
            .padding(12)
        }
    }
}
