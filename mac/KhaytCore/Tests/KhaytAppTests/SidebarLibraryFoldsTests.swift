import Foundation
import Testing

/// Library's saved searches and groups sit inside a disclosure that starts shut.
///
/// beta.18 drew them as plain rows straight under Library. On a Drive library,
/// where every folder is a group, that was several hundred rows that could not
/// be closed — the shop's own sidebar, Nov 3 2026. A source check, because
/// there is no way to drive a sidebar List from a test.
struct SidebarLibraryFoldsTests {
    static var sidebar: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Sidebar.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("the groups are inside Library's disclosure, and it starts closed")
    func groupsFold() throws {
        let s = Self.sidebar
        #expect(s.contains(#"@SceneStorage("sidebar.library") private var showLibrary = false"#))
        let open = try #require(s.range(of: "DisclosureGroup(isExpanded: libraryOpen)"))
        let groups = try #require(s.range(of: "ForEach(shop.groups, id: \\.self)"))
        let smart = try #require(s.range(of: "ClassicSmartFolderRows(shop: shop)"))
        #expect(open.lowerBound < smart.lowerBound && smart.lowerBound < groups.lowerBound)
        #expect(s.components(separatedBy: "ForEach(shop.groups").count == 2)
    }
}
