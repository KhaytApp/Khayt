import AppKit
import SwiftUI
import KhaytCore

/// ── RECALCULATE FROM PARTS ────────────────────────────────────────────────
///
/// `KHAYT_SNAPSHOT_RECALC=1`: Edit Job on a job whose price was typed, and the
/// Recalculate sheet over it showing old → new (Figma Qqxg4imtKVgC3TfNGcRGOk
/// 174:223 and 174:235). ALL IN MEMORY: one sample job's row is given a typed
/// price in `orderRows`, nothing is saved, and the sample is loaded again.
extension Snapshot {

    static func captureRecalculate(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        await settle()

        // An open job with parts, its price typed over the arithmetic.
        guard let index = shop.orderRows.firstIndex(where: { row in
            guard case .object(let o) = row, case .array(let parts)? = o["parts"], !parts.isEmpty,
                  case .string(let status)? = o["status"] else { return false }
            return !["completed", "delivered", "cancelled", "quote"].contains(status)
                && o["invoiceNumber"] == nil && o["paidAmount"].map { $0 == .number(0) } ?? true
        }), case .object(var job) = shop.orderRows[index], case .string(let id)? = job["id"] else {
            print("snapshot: no open sample job with parts")
            return
        }
        job["priceSource"] = .string("override")
        job["price"] = .number(250)
        shop.orderRows[index] = .object(job)
        let project: String = { if case .string(let p)? = job["project"] { return p }; return id }()

        // 1. Edit Job, with the kept price and its Recalculate button.
        let edit = NSWindow(contentRect: NSRect(x: 0, y: 0, width: JobSheet.width, height: 820),
                            styleMask: [.titled], backing: .buffered, defer: false)
        edit.isReleasedWhenClosed = false
        edit.contentView = NSHostingView(rootView:
            JobSheet(shop: shop, subject: .init(id: id, project: project))
                .modifier(ShopsLocale(words: shop.words))
                .frame(width: JobSheet.width, height: 820))
        edit.center()
        edit.makeKeyAndOrderFront(nil)
        await settle(); await settle(); await settle()
        capture(named: "rc-01-edit-job-kept-price" + tag, window: edit, into: dir)
        edit.close()

        // 2. The Recalculate sheet: old → new before anything is saved.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView:
            RecalculateSheet(shop: shop, jobId: id, currency: shop.currency) { _ in }
                .modifier(ShopsLocale(words: shop.words))
                .padding(20)
                .frame(width: 560))
        sheet.setContentSize(sheet.contentView?.fittingSize ?? NSSize(width: 560, height: 320))
        sheet.center()
        sheet.makeKeyAndOrderFront(nil)
        await settle(); await settle(); await settle()
        sheet.setContentSize(sheet.contentView?.fittingSize ?? NSSize(width: 560, height: 320))
        await settle()
        capture(named: "rc-02-recalculate" + tag, window: sheet, into: dir)
        sheet.close()

        await shop.load(.sample)
        await settle()
    }
}
