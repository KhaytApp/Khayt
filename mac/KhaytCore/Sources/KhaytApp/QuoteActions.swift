import SwiftUI
import KhaytCore

/// The packing slip, delivery note and work order for a job, as links beside
/// its invoice (`Shop+Papers.swift`). Showing one writes nothing, so they are
/// offered as the invoice is.
struct JobPaperButtons: View {
    let shop: Shop
    let job: Order

    var body: some View {
        ForEach(KhaytEngine.ShopPaper.allCases, id: \.self) { kind in
            Button(shop.words.callIt(Shop.paperTitleKey(kind))) { shop.showPaper(kind, for: job.id) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

/// The same three, as menu items (the Job menu, a job's right-click).
/// `upfront` in the menu bar, whose titles are baked when it is built
/// (`Words.upfront`).
struct JobPaperItems: View {
    let shop: Shop
    let job: Order?
    var upfront = false

    private func say(_ key: String) -> String { upfront ? Words.upfront(key) : shop.words.callIt(key) }

    var body: some View {
        ForEach(KhaytEngine.ShopPaper.allCases, id: \.self) { kind in
            Button(say(Shop.paperTitleKey(kind)) + "\u{2026}") {
                if let job { shop.showPaper(kind, for: job.id) }
            }
            .disabled(job == nil || job?.status == "quote")
        }
    }
}

/// A quote's Follow up, Revise, history and Reject (`Shop+Quotes.swift`).
/// Each writes the job, so each needs a book this app holds and somebody the
/// staff lock lets edit jobs — Reject also the lock's leave to delete.
struct QuoteActions: View {
    let shop: Shop
    let job: Order

    var body: some View {
        let sent = shop.followUpCount(job.id)
        HStack(spacing: 6) {
            Button(shop.words.callIt("quote.followup_btn")) {
                Task { await shop.sendQuoteFollowUp(job.id) }
            }
            .buttonStyle(.link)
            .disabled(!shop.canMoveJobs)
            if sent > 0 {
                Text(shop.words.callIt("quote.followup_count", ["n": .number(Double(sent))]))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        Button(shop.words.callIt("ord.revise_quote") + "\u{2026}") {
            Task { await shop.reviseQuote(job.id) }
        }
        .buttonStyle(.link)
        .font(.callout)
        .disabled(!shop.canMoveJobs)
        if shop.hasQuoteRevisions(job.id) {
            Button(QuoteActions.historyTitle(shop, job.id)) { shop.showQuoteRevisions(job.id) }
                .buttonStyle(.link)
                .font(.callout)
        }
        Button(shop.words.callIt("quote.reject") + "\u{2026}", role: .destructive) {
            shop.rejectQuote(job.id)
        }
        .buttonStyle(.link)
        .font(.callout)
        .disabled(!shop.canMoveJobs || !shop.lockAllows("orders", "delete"))
    }

    /// "Quote history v3", as the other app's menu names it.
    static func historyTitle(_ shop: Shop, _ id: Order.ID) -> String {
        shop.words.callIt("ord.quote_revisions") + " "
            + shop.words.callIt("ord.quote_version", ["n": .number(Double(shop.quoteVersion(id)))])
    }
}

/// The same answers as menu items, for a quote picked in the Job menu or
/// right-clicked in the jobs list.
struct QuoteItems: View {
    let shop: Shop
    let job: Order?
    var upfront = false

    private func say(_ key: String) -> String { upfront ? Words.upfront(key) : shop.words.callIt(key) }

    var body: some View {
        let quote = job?.status == "quote" ? job : nil
        Button(say("quote.followup_btn")) {
            if let quote { Task { await shop.sendQuoteFollowUp(quote.id) } }
        }
        .disabled(quote == nil || !shop.canMoveJobs)
        Button(say("ord.revise_quote") + "\u{2026}") {
            if let quote { Task { await shop.reviseQuote(quote.id) } }
        }
        .disabled(quote == nil || !shop.canMoveJobs)
        Button(say("ord.quote_revisions") + "\u{2026}") {
            if let quote { shop.showQuoteRevisions(quote.id) }
        }
        .disabled(quote.map { !shop.hasQuoteRevisions($0.id) } ?? true)
        Button(say("quote.reject") + "\u{2026}", role: .destructive) {
            if let quote { shop.rejectQuote(quote.id) }
        }
        .disabled(quote == nil || !shop.canMoveJobs || !shop.lockAllows("orders", "delete"))
    }
}

/// A customer's statement and their invoices, as menu items or links.
struct CustomerPaperItems: View {
    let shop: Shop
    let person: Customer

    var body: some View {
        if person.record != nil {
            Button(shop.words.callIt("cl.statement_title") + "\u{2026}") { shop.showStatement(for: person) }
            Button(shop.words.callIt("cl.export_all_invoices") + "\u{2026}") {
                Task { await shop.exportInvoices(for: person) }
            }
        }
    }
}
