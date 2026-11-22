import Foundation
import Testing

/// Every screen's name is drawn in the toolbar by the app, not left to the
/// system title, which collapsed on six of thirteen screens in beta.19
/// (Library, Catalogue, Customers, Expenses, Calculator, Gift cards).
struct ToolbarTitleTests {
    @Test("the window removes the system title and draws its own on every screen")
    func titleIsDrawn() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/ShopWindow.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        #expect(s.contains(".toolbar(removing: .title)"))
        let nav = try #require(s.range(of: "ToolbarItem(placement: .navigation) {"))
        let tail = String(s[nav.upperBound...].prefix(400))
        #expect(tail.contains("Text(shop.shelfTitle)") && tail.contains("Text(subtitle)"))
    }
}
