import AppKit
import SwiftUI
import KhaytCore

/// ── A PRODUCT'S LINE OF N ────────────────────────────────────────────────
///
/// `KHAYT_SNAPSHOT_PRODUCTLINE=1`: the product sheet on a product with its own
/// rates, 4 to a box, showing labour by the line, Pieces per box and "For N
/// pieces" (Figma Qqxg4imtKVgC3TfNGcRGOk 180:223). ALL IN MEMORY: one sample
/// product's row is given rates and a box size, nothing is saved, and the
/// sample is loaded again at the end.
extension Snapshot {

    static func captureProductLine(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        await settle()
        guard let index = shop.productRows.firstIndex(where: { row in
            guard case .object(let o) = row, case .array(let parts)? = o["parts"] else { return false }
            return !parts.isEmpty
        }), case .object(var row) = shop.productRows[index], case .string(let id)? = row["id"] else {
            print("snapshot: no sample product with parts")
            return
        }
        row["rates"] = .object(["laborRate": .number(90), "prepTime": .number(0.25), "postTime": .number(0.5)])
        row["labourPerPart"] = .bool(false)
        row["perBox"] = .number(4)
        var rows = shop.productRows
        rows[index] = .object(row)
        shop.pretendProducts(rows)
        guard let product = await shop.productForEditing(id) else { return }

        // Laid flat (`photographFlat`): the sheet scrolls, and a scroll view
        // photographs only what is in view.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ProductSheet.width, height: 2600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            ProductSheet(shop: shop, existing: product)
                .modifier(ShopsLocale(words: shop.words))
                .environment(\.photographFlat, true)
                .frame(width: ProductSheet.width, height: 2600))
        window.center()
        window.makeKeyAndOrderFront(nil)
        await settle(); await settle(); await settle(); await settle()
        capture(named: "pl-01-product-line" + tag, window: window, into: dir)
        window.close()

        await shop.load(.sample)
        await settle()
    }
}
