import SwiftUI
import AppKit
import KhaytCore

/// What to buy: every filament at or under its reorder point, grouped by
/// supplier, with what is on the shelf and how much to buy — the desktop's
/// Shopping List, from the same rule (`lib/reorder.js shoppingList`).
///
/// A planning aid, not a purchase: it copies and it prints, and it orders
/// nothing. Drafting a purchase order stays the shelf's own action.
struct ShoppingListSheet: View {
    @Bindable var shop: Shop
    let request: ShoppingListRequest
    @State private var copied = false

    var body: some View {
        let words = shop.words
        SheetFrame(width: 460) {
            Text(words.callIt("shop.title")).font(.headline)
            ForEach(request.list.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.supplier)
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase).tracking(0.6)
                        .foregroundStyle(.secondary)
                    ForEach(group.items) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(nsColor: NSColor(hex: item.color) ?? .tertiaryLabelColor))
                                .frame(width: 10, height: 10)
                            Text(item.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(verbatim: Self.amounts(item, grams: words.callIt("common.grams")))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .card(padding: 10)
            }
        } footer: {
            HStack {
                Button(words.callIt(copied ? "mac.copied" : "shop.copy")) {
                    shop.copyShoppingList(request.list)
                    copied = true
                }
                Button(words.callIt("common.print")) {
                    let html = ShoppingListPage.html(request, words: words)
                    shop.pendingShoppingList = nil
                    shop.pendingPrintedPage = PrintedPageRequest(title: request.title, html: html)
                }
                Spacer()
                Button(words.callIt("common.close")) { shop.pendingShoppingList = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    /// "120 g → 1000 g", the desktop's line, with the shop's word for grams.
    static func amounts(_ item: ShoppingList.Item, grams: String) -> String {
        let have: String = Money.quantity(item.have, decimals: 0)
        let buy: String = Money.quantity(item.buy, decimals: 0)
        return have + " " + grams + " \u{2192} " + buy + " " + grams
    }
}

/// The list as a page to print. Every value from the book is escaped.
@MainActor
enum ShoppingListPage {
    static func html(_ request: ShoppingListRequest, words w: Words) -> String {
        func e(_ s: String) -> String { Labels.escape(s) }
        let grams = w.callIt("common.grams")
        var body = ""
        for group in request.list.groups {
            body += "<h2>\(e(group.supplier))</h2><table>"
            for item in group.items {
                let amounts = ShoppingListSheet.amounts(item, grams: grams)
                body += "<tr><td>\(e(item.name))</td><td class=\"n\">\(e(amounts))</td></tr>"
            }
            body += "</table>"
        }
        let rtl = w.language == "ar"
        return """
        <!doctype html><html lang="\(e(w.language))" dir="\(rtl ? "rtl" : "ltr")"><head><meta charset="utf-8">
        <title>\(e(request.title))</title><style>
        @page { size: A4; margin: 16mm; }
        body { margin: 0; padding: 16px; background: #fff; color: #111;
               font: 12px -apple-system, system-ui, sans-serif; }
        h1 { font-size: 18px; margin: 0 0 14px; }
        h2 { font-size: 13px; margin: 18px 0 6px; }
        table { width: 100%; border-collapse: collapse; }
        td { border-bottom: 1px solid #eee; padding: 5px 4px; }
        td.n { text-align: end; font-variant-numeric: tabular-nums; white-space: nowrap; }
        </style></head><body>
        <h1>\(e(request.title))</h1>
        \(body)
        </body></html>
        """
    }
}
