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

    private func resolve(_ e: [String: JSONValue], previous: JSONValue? = nil) async throws -> Connector? {
        let engine = try KhaytEngine()
        let keys = await ConnectorRules.signingKeys(engine)
        return await ConnectorRules.resolve(e, previous: previous, engine: engine, keys: keys)
    }

    func testTheBooksOwnVersionRunsWhenItReads() async throws {
        let e = try lamhaEntry()
        let c = try await resolve(e)
        XCTAssertEqual(c?.status, .active)
        XCTAssertNil(c?.unreadableVersion)
        XCTAssertEqual(c?.version, ConnectorRules.text(e["version"]))
    }

    func testAnUnreadableVersionRunsThePreviousOneFromTheEntry() async throws {
        let old = try lamhaEntry()
        var newer = try unreadable(old)
        newer["previous"] = previous(of: old)
        let c0 = try await resolve(newer)
        let c = try XCTUnwrap(c0)
        XCTAssertEqual(c.status, .active, "the readable previous version runs")
        XCTAssertEqual(c.version, ConnectorRules.text(old["version"]))
        XCTAssertEqual(c.unreadableVersion, "9.0.0")
        XCTAssertEqual(c.manifest, old["manifest"], "the signed older manifest, not the newer one")
    }

    func testThePreviousVersionCanComeFromTheUpdateRecordBesideTheEntry() async throws {
        let old = try lamhaEntry()
        let c0 = try await resolve(try unreadable(old), previous: previous(of: old))
        let c = try XCTUnwrap(c0)
        XCTAssertEqual(c.status, .active)
        XCTAssertEqual(c.unreadableVersion, "9.0.0")
    }

    func testWithNothingReadableTheConnectorIsInvalidAndSendsNothing() async throws {
        let c0 = try await resolve(try unreadable(try lamhaEntry()))
        let c = try XCTUnwrap(c0)
        XCTAssertEqual(c.status, .invalid)
        XCTAssertFalse(c.isActive)
        XCTAssertNil(c.unreadableVersion)
        // A previous that does not read either is no way out.
        var newer = try unreadable(try lamhaEntry())
        newer["previous"] = .object(["version": .string("0.1.0"), "manifest": .object(["id": .string(lamhaId)])])
        let d0 = try await resolve(newer)
        let d = try XCTUnwrap(d0)
        XCTAssertEqual(d.status, .invalid)
    }

    /// An update's bookkeeping in the entry does not make a build whose
    /// shared check predates it refuse a version it can read.
    func testUpdateBookkeepingDoesNotHideAReadableVersion() async throws {
        var e = try lamhaEntry()
        e["updatedAt"] = .number(1_762_000_000_000)
        e["updatedFrom"] = .string("1.0.0")
        e["previous"] = previous(of: try lamhaEntry())
        let c0 = try await resolve(e)
        let c = try XCTUnwrap(c0)
        XCTAssertEqual(c.status, .active)
        XCTAssertNil(c.unreadableVersion)
        XCTAssertNil(ConnectorRules.runnable(e)["previous"])
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
