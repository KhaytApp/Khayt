import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's settings for a connector (manifest `settings[]`, stored as
/// `entry.config`): the form shows each with what is saved, and a save writes
/// declared keys only, checked by type, leaving the rest of the book alone.
@MainActor
struct ConnectorSettingsFormTests {

    @Test("the form lists Lamha's settings with their labels, saved values and what is required")
    func rows() async throws {
        let (_, entry, _) = try await ConnectorActionTests.lamha()
        let rows = Shop.settingRows(entry, lang: "ar")
        #expect(rows.map(\.key) == ["senderName", "senderPhone", "senderCity", "senderAddress", "carrierId"])
        #expect(rows.first?.label == "اسم المرسل")
        #expect(rows.first?.value == "Studio")
        #expect(rows.allSatisfy { $0.required })
    }

    @Test("a save changes only this connector's config, by declared key")
    func save() async throws {
        let (engine, entry, _) = try await ConnectorActionTests.lamha()
        let other: JSONValue = .object(["id": .string("other.connector"), "config": .object(["a": .string("b")])])
        let plugins: JSONValue = .array([entry, other])
        let next = try await engine.pluginWithConfig(entry, values: .object([
            "senderPhone": .string("0511111111"), "senderCity": .string(""), "invented": .string("x"),
        ]))
        let saved = try await engine.pluginWithEntry(plugins, entry: next)
        guard case .array(let rows) = saved, rows.count == 2 else { Issue.record("an entry was lost or added"); return }
        let cfg = Shop.object(Shop.object(rows[0])["config"])
        #expect(cfg["senderPhone"] == .string("0511111111"))
        #expect(cfg["senderCity"] == nil, "an emptied setting was kept")
        #expect(cfg["invented"] == nil, "a key the manifest never declared was saved")
        #expect(cfg["senderName"] == .string("Studio"), "an untouched setting was lost")
        #expect(Shop.object(rows[0])["manifest"] == Shop.object(entry)["manifest"])
        #expect(rows[1] == other, "another connector changed")
        // Still a valid entry, so still running.
        #expect(try await engine.pluginStateOf(next, reviewed: true) == "on")
    }
}
