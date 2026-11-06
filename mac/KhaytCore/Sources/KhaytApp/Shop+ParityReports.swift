import Foundation
import AppKit
import KhaytCore

/// The desktop's box-form VAT return, shopping list and test-print log, on
/// the Mac — each through the shared rule the desktop now calls too
/// (`lib/vat-return.js`, `lib/reorder.js shoppingList`, `lib/test-prints.js`),
/// so the two apps print one return, list one set of spools to buy and write
/// one shape of test-print row.
extension Shop {

    // MARK: - The box-form VAT return

    /// The return for one period (`from`…`to`, book days), shown before it
    /// is printed. The print panel's PDF menu is the Mac's Save as PDF.
    ///
    /// The document is the desktop's own, from the same module: English, as
    /// the desktop prints it — a working paper to transcribe onto the return
    /// the shop files, in the shop's own tax name.
    func askForVatReturn(title: String, from: String, to: String) async {
        // A report, read under the analytics permission like the P&L export;
        // `permitted` says why when it refuses.
        guard permitted("analytics", "view") else { return }
        guard let engine else { moveProblem = words.callIt("mac.move_sample"); return }
        do {
            let doc = try await engine.vatReturn(
                orders: orderRows, expenses: expenseRows, settings: settingsDict,
                clients: clientRows, currencies: Invoice.currencyTable(self),
                from: from, to: to, shopName: shopName, periodTitle: title)
            pendingPrintedPage = PrintedPageRequest(title: words.callIt("vatReturn"), html: doc.html)
        } catch {
            moveProblem = words.callIt("mac.export_failed") + " " + self.said(error)
        }
    }

    /// This book year, January to December — the desktop's "This Year".
    static func bookYear(_ now: Date = Date()) -> (from: String, to: String) {
        let year = Calendar.book.component(.year, from: now)
        return (String(format: "%04d-01-01", year), String(format: "%04d-12-31", year))
    }

    // MARK: - The shopping list

    /// Every filament at or under its reorder point, grouped by supplier.
    /// Nothing low says so rather than opening an empty list, as the desktop.
    func askForShoppingList() async {
        guard permitted("inventory", "view") else { return }
        guard let engine else { moveProblem = words.callIt("mac.move_sample"); return }
        let title = words.callIt("shop.title") + " \u{2014} " + (shopName.isEmpty ? "Khayt" : shopName)
        do {
            let list = try await engine.shoppingList(
                spools: inventoryRows, suppliers: supplierRows, settings: settingsDict,
                noSupplier: words.callIt("shop.no_supplier"), title: title)
            if list.isEmpty {
                importNote = words.callIt("shop.none")
                return
            }
            pendingShoppingList = ShoppingListRequest(list: list, title: title)
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Put the list on the clipboard, in the desktop's plain-text form.
    func copyShoppingList(_ list: ShoppingList) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list.text, forType: .string)
    }

    // MARK: - The test-print log

    /// One spool's test prints, newest first (`KhaytTestPrints.forSpool`'s
    /// order: by date, a row with none last).
    func testPrints(for spoolId: String) -> [SpoolLogRow] {
        let rows = testPrintRows.enumerated().compactMap { at, row -> SpoolLogRow? in
            guard case .object(let r) = row, Self.plainString(r["spoolId"]) == spoolId else { return nil }
            return SpoolLogRow(id: Self.plainString(r["id"]) ?? "testPrints-\(at)",
                               date: Self.plainString(r["date"]) ?? "", fields: r)
        }
        return rows.sorted { $0.date > $1.date }
    }

    /// Log a test print against a spool — the desktop's Test Prints form.
    /// `raw` carries the form's values; the rule normalises them exactly as
    /// the desktop's save does. Nil when written, else what went wrong.
    func addTestPrint(_ spoolId: String, raw: [String: JSONValue]) async -> String? {
        guard permitted("inventory", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else { return words.callIt("mac.read_only") }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        let words = self.words
        let id = Self.uid("TP")
        let today = Self.today()
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var shelf = Self.rows(root, "inventory")
                guard let at = shelf.firstIndex(where: { Self.recordId($0) == spoolId }) else {
                    throw MoveRefused(sentence: words.callIt("mac.move_gone"))
                }
                let made = try await engine.addTestPrint(Self.rows(root, "testPrints"), spool: shelf[at],
                                                         raw: raw, id: id, today: today)
                var log = made.testPrints
                if case .object(var entry)? = log.first {
                    StoreWriter.stamp(&entry)
                    log[0] = .object(entry)
                }
                root["testPrints"] = .array(log)
                if case .object(var spool)? = made.item, spool != Self.objectOf(shelf[at]) {
                    StoreWriter.stamp(&spool)
                    shelf[at] = .object(spool)
                    root["inventory"] = .array(shelf)
                }
            }
        } catch let refusal as MoveRefused {
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    /// Take a test print off the log; the grams it used go back on the spool.
    func deleteTestPrint(_ spoolId: String, id: String) async -> String? {
        guard permitted("inventory", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else { return words.callIt("mac.read_only") }
        guard let engine else { return words.callIt("mac.move_no_engine") }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var shelf = Self.rows(root, "inventory")
                let at = shelf.firstIndex(where: { Self.recordId($0) == spoolId })
                let made = try await engine.removeTestPrint(Self.rows(root, "testPrints"),
                                                            spool: at.map { shelf[$0] }, id: id)
                root["testPrints"] = .array(made.testPrints)
                if let at, case .object(var spool)? = made.item, spool != Self.objectOf(shelf[at]) {
                    StoreWriter.stamp(&spool)
                    shelf[at] = .object(spool)
                    root["inventory"] = .array(shelf)
                }
            }
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    /// A record's fields, or nil when it is not an object.
    nonisolated static func objectOf(_ value: JSONValue) -> [String: JSONValue]? {
        if case .object(let o) = value { return o }
        return nil
    }
}

/// A finished one-page document, waiting to be looked at and printed.
struct PrintedPageRequest: Identifiable {
    let id = UUID()
    let title: String
    let html: String
}

/// The shopping list as worked out, and the title it was copied under.
struct ShoppingListRequest: Identifiable {
    let id = UUID()
    let list: ShoppingList
    let title: String
}
