import Foundation
import Testing
@testable import KhaytApp

/// Every "+" the navy strip offers (`ScreenActions`) is also in the default
/// window, whose buttons come from each screen's own `screenToolbar`.
///
/// Nov 10: Customers and Inventory had their add button only on the strip, and
/// the strip is off by default since the redesign — so a shop could not add a
/// customer once it had one, nor ever add a spool.
struct AddActionParityTests {
    static func source(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(file)"), encoding: .utf8)
    }

    /// The action, and the files whose `screenToolbar` must offer it.
    static let actions: [(act: String, files: [String])] = [
        ("takingAJob = true", ["OrdersTable.swift"]),
        ("editingProduct = shop.newProduct()", ["Catalogue.swift"]),
        ("addingMachine = true", ["ShopFloor.swift"]),
        ("addingSpool = true", ["ShopFloor.swift"]),
        ("importingSpoolman = true", ["ShopFloor.swift"]),
        ("addingExpense = true", ["Spending.swift"]),
        ("loggingWaste = true", ["Spending.swift"]),
        ("issuingGiftCard = true", ["GiftCards.swift"]),
        ("editingCustomer = Shop.newCustomer()", ["CustomersTable.swift"]),
    ]

    @Test("each add action on the strip is on its screen in the default window too")
    func parity() throws {
        let strip = try Self.source("ScreenActions.swift")
        for (act, files) in Self.actions {
            #expect(strip.contains(act), "\(act) left the strip — this list is stale")
            for file in files {
                let src = try Self.source(file)
                let toolbar = src.components(separatedBy: ".screenToolbar").dropFirst().map { String($0.prefix(4000)) }
                // Jobs draws its button through `NewJobButton`, which sets it.
                let viaComponent = toolbar.contains { $0.contains("NewJobButton(shop: shop)") }
                    && src.components(separatedBy: "struct NewJobButton").dropFirst().first?.prefix(1500).contains(act) == true
                #expect(toolbar.contains { $0.contains(act) } || viaComponent, "\(file) has no \(act) in its toolbar")
            }
        }
    }

    @Test("New Customer has a shortcut, and it is not one New Job or New Product uses")
    func shortcut() throws {
        let menus = try Self.source("Menus.swift")
        let at = try #require(menus.range(of: #"Button(Words.upfront("mac.new_customer"))"#))
        #expect(menus[at.upperBound...].prefix(400).contains(#".keyboardShortcut("n", modifiers: [.command, .option])"#))
    }
}
