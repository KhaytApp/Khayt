import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Connector updates (design connector-updates §4): the phone never checks
/// for updates, it reads what the Mac wrote. When the book holds a version
/// this build cannot read, the phone runs the version before it, never a
/// manifest that fails the shared check, and never nothing when an older
/// readable one is there.
final class ConnectorPreviousTests: XCTestCase {

    private let lamhaId = "app.khayt.samples.lamha"

    /// The signed Lamha sample entry, as the sample shop stores it.
    private func lamhaEntry() throws -> [String: JSONValue] {
        guard case .array(let rows) = SampleShop.sampleConnectors,
              let e = rows.compactMap({ r -> [String: JSONValue]? in
                  if case .object(let o) = r, o["id"] == .string(lamhaId) { return o }; return nil }).first
        else { throw XCTSkip("no Lamha sample") }
        return e
    }

    /// A newer version this build cannot read: its manifest carries a key the
    /// shared validator refuses (as beta.32's refused 1.1.1's path list).
    private func unreadable(_ e: [String: JSONValue], version: String = "9.0.0") throws -> [String: JSONValue] {
        guard case .object(var m)? = e["manifest"] else { throw XCTSkip("no manifest") }
        m["version"] = .string(version)
        m["fromTheFuture"] = .bool(true)
        var newer = e
        newer["manifest"] = .object(m)
        newer["version"] = .string(version)
        return newer
    }

    private func previous(of e: [String: JSONValue]) -> JSONValue {
        .object(["version": e["version"] ?? .null, "manifest": e["manifest"] ?? .null, "granted": e["granted"] ?? .null])
    }

    /// A book's settings holding `entry`, with the Mac's update record for it.
    private func settings(_ entry: [String: JSONValue], state: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var s: [String: JSONValue] = ["plugins": .array([.object(entry)])]
        if !state.isEmpty {
            s["connectorUpdates"] = .object(["serial": .number(7), "connectors": .object([lamhaId: .object(state)])])
        }
        return s
    }

    private func resolve(_ e: [String: JSONValue], state: [String: JSONValue] = [:]) async throws -> Connector? {
        let engine = try KhaytEngine()
        let keys = await ConnectorRules.signingKeys(engine)
        return await ConnectorRules.resolve(e, settings: settings(e, state: state), engine: engine, keys: keys)
    }

    func testTheBooksOwnVersionRunsWhenItReads() async throws {
        let e = try lamhaEntry()
        let c = try await resolve(e)
        XCTAssertEqual(c?.status, .active)
        XCTAssertNil(c?.unreadableVersion)
        XCTAssertEqual(c?.version, ConnectorRules.text(e["version"]))
        XCTAssertEqual(ConnectorRules.updateNotes(try XCTUnwrap(c), showUpdated: true), [])
    }

    func testAnUnreadableVersionRunsThePreviousOneTheMacKept() async throws {
        let old = try lamhaEntry()
        let c0 = try await resolve(try unreadable(old), state: ["previous": previous(of: old)])
        let c = try XCTUnwrap(c0)
        XCTAssertEqual(c.status, .active, "the readable previous version runs")
        XCTAssertEqual(c.version, ConnectorRules.text(old["version"]))
        XCTAssertEqual(c.unreadableVersion, "9.0.0")
        XCTAssertEqual(c.manifest, old["manifest"], "the signed older manifest, not the newer one")
        let notes = ConnectorRules.updateNotes(c, showUpdated: true)
        XCTAssertEqual(notes, [L10n.format("plg.update_needs_app", c.name, "9.0.0")])
    }

    func testWithNothingReadableTheConnectorIsInvalidAndSendsNothing() async throws {
        let c0 = try await resolve(try unreadable(try lamhaEntry()))
        let c = try XCTUnwrap(c0)
        XCTAssertEqual(c.status, .invalid)
        XCTAssertFalse(c.isActive)
        XCTAssertNil(c.unreadableVersion)
        // A previous that does not read either is no way out.
        let d0 = try await resolve(try unreadable(try lamhaEntry()),
                                   state: ["previous": .object(["version": .string("0.1.0"), "manifest": .object(["id": .string(lamhaId)])])])
        XCTAssertEqual(try XCTUnwrap(d0).status, .invalid)
    }

    /// Khayt withdrew this version: it never runs, says why, and the
    /// version before it is not run in its place.
    func testARevokedVersionIsPausedByKhaytWithTheReason() async throws {
        let e = try lamhaEntry()
        let version = try XCTUnwrap(ConnectorRules.text(e["version"]))
        let c0 = try await resolve(e, state: ["revoked": .object(["version": .string(version), "reason": .string("Reports a refused order as sent."),
                                                                  "at": .string("2026-11-12T09:00:00.000Z"), "wasEnabled": .bool(true)]),
                                              "previous": previous(of: e)])
        let c = try XCTUnwrap(c0)
        XCTAssertEqual(c.status, .revoked)
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(c.revokedReason, "Reports a refused order as sent.")
        let why = try XCTUnwrap(ConnectorRules.disabledReason(c))
        XCTAssertTrue(why.contains("Reports a refused order as sent."), why)
        XCTAssertEqual(why, L10n.format("plg.update_revoked", "Reports a refused order as sent."))
        // A revocation of another version leaves this one alone.
        let other0 = try await resolve(e, state: ["revoked": .object(["version": .string("0.0.1"), "reason": .string("x")])])
        XCTAssertEqual(try XCTUnwrap(other0).status, .active)
    }

    func testAPendingVersionAndTheQuietNote() async throws {
        let e = try lamhaEntry()
        let c0 = try await resolve(e, state: ["pending": .object(["version": .string("1.2.0")]),
                                              "updatedAt": .string("2026-11-12T09:00:00.000Z"), "updatedFrom": .string("1.0.0")])
        let c = try XCTUnwrap(c0)
        XCTAssertEqual(c.status, .active)
        XCTAssertEqual(c.pendingVersion, "1.2.0")
        XCTAssertEqual(c.updatedFrom, "1.0.0")
        XCTAssertEqual(ConnectorRules.updateNotes(c, showUpdated: true),
                       [L10n.format("plg.update_pending", c.name, "1.2.0"), L10n.format("plg.update_updated", c.name, c.version)])
        XCTAssertEqual(ConnectorRules.updateNotes(c, showUpdated: false), [L10n.format("plg.update_pending", c.name, "1.2.0")])
    }

    func testTheUpdatedNoteShowsOncePerUpdate() throws {
        let suite = "connector-updates-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var c = ConnectorsTests.connector(granted: nil)
        XCTAssertFalse(ConnectorUpdateSeen.firstSight(c, defaults: defaults), "no update, no note")
        c.updatedAt = "2026-11-12T09:00:00.000Z"
        XCTAssertTrue(ConnectorUpdateSeen.firstSight(c, defaults: defaults))
        XCTAssertFalse(ConnectorUpdateSeen.firstSight(c, defaults: defaults))
        c.updatedAt = "2026-12-01T09:00:00.000Z"
        XCTAssertTrue(ConnectorUpdateSeen.firstSight(c, defaults: defaults), "the next update shows again")
        XCTAssertEqual(defaults.stringArray(forKey: ConnectorUpdateSeen.key)?.count, 1)
    }

    /// The older version gets only the settings it has, its own grant, and
    /// the shop's switch: a shop that switched the connector off keeps it off.
    func testThePreviousEntryKeepsTheSwitchAndDropsSettingsItDoesNotHave() throws {
        let old = try lamhaEntry()
        var newer = try unreadable(old)
        newer["enabled"] = .bool(false)
        var config: [String: JSONValue] = [:]
        if case .object(let c)? = old["config"] { config = c }
        config["onlyInNine"] = .string("x")
        newer["config"] = .object(config)
        let p = try XCTUnwrap(ConnectorRules.previousEntry(newer, previous: previous(of: old)))
        XCTAssertEqual(p["enabled"], .bool(false))
        XCTAssertEqual(p["granted"], old["granted"])
        guard case .object(let kept)? = p["config"] else { return XCTFail("no config") }
        XCTAssertNil(kept["onlyInNine"])
        XCTAssertEqual(p["version"], old["version"])
    }
}
