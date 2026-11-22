import Foundation
import Testing
@testable import KhaytApp

/// khayt-mcp ships inside the app, and Settings says where.
///
/// Settings ▸ Assistant had a switch for what `khayt-mcp` may share since the
/// program was written, but `make-app.sh` never built it, so no released Mac
/// carried it and the switch governed nothing a shop could run (found by the
/// website's review, Nov 2026, when the site advertised it).
@MainActor
struct McpBundledTests {

    static func makeApp() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "make-app.sh"), encoding: .utf8)
    }

    @Test("the release build makes it, puts it beside the app and signs it")
    func bundled() throws {
        let script = try Self.makeApp()
        #expect(script.contains(#"swift build -c release --product khayt-mcp --package-path "$PKG""#))
        #expect(script.contains(#"MCP_BIN="$APP/Contents/MacOS/khayt-mcp""#))
        #expect(script.contains("--identifier app.khayt.mac.mcp"))
        // Signed BEFORE the app, which seals it in.
        let signed = try #require(script.range(of: "--identifier app.khayt.mac.mcp"))
        let app = try #require(script.range(of: "# The app LAST"))
        #expect(signed.lowerBound < app.lowerBound)
    }

    @Test("the setup to paste is Claude Desktop's shape, with the path as written")
    func setup() throws {
        let text = Shop.mcpSetup(path: "/Applications/Khayt.app/Contents/MacOS/khayt-mcp")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: Any])
        let khayt = try #require(servers["khayt"] as? [String: Any])
        #expect(khayt["command"] as? String == "/Applications/Khayt.app/Contents/MacOS/khayt-mcp")
        #expect(!text.contains(#"\/"#), "slashes escaped — a pasted path would still work, but reads wrong")
    }

    @Test("Settings shows the path only when the program is there")
    func shownOnlyWhenPresent() {
        // A test process is not an app bundle with khayt-mcp in it.
        #expect(Shop.mcpExecutable == nil)
        #expect(MenuCoverageTests.source("SettingsWindow.swift").contains("if let mcp = Shop.mcpExecutable {"))
    }
}
