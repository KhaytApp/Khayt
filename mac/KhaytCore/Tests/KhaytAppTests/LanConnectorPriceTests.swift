import Foundation
import Testing
import CryptoKit
import KhaytCore
@testable import KhaytApp

/// The shop's price for a plate sliced in OrcaSlicer (`POST
/// /api/connectors/price`): the shared vectors through the Mac's engine, and
/// the route on the bench — off by default, a device sees only what its grant
/// allows, and nothing is stored.
@MainActor
@Suite(.serialized)
struct LanConnectorPriceTests {

    static let path = "/api/connectors/price"

    static func vectors() throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test/fixtures/connector-price-vectors.json")
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    static func obj(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    /// `{...shop, ...case.ctx, settings: {...shop.settings, ...case.ctx.settings}}`,
    /// as `test/connector-price.test.js` builds it.
    static func context(_ shop: [String: JSONValue], _ c: [String: JSONValue]) -> JSONValue {
        var ctx = shop
        let own = obj(c["ctx"])
        for (k, v) in own { ctx[k] = v }
        var settings = obj(shop["settings"])
        for (k, v) in obj(own["settings"]) { settings[k] = v }
        ctx["settings"] = .object(settings)
        return .object(ctx)
    }

    @Test("the shared vectors, through the Mac's engine")
    func vectorsAgree() async throws {
        let v = Self.obj(try Self.vectors())
        guard case .array(let cases)? = v["cases"] else { Issue.record("no cases"); return }
        #expect(cases.count >= 15)
        let shop = Self.obj(v["shop"])
        let engine = try KhaytEngine()
        for value in cases {
            let c = Self.obj(value)
            let why: String = { if case .string(let s)? = c["why"] { return s }; return "?" }()
            let got = try await engine.connectorPrice(facts: c["facts"] ?? .null, context: Self.context(shop, c))
            #expect(got == c["want"], Comment(rawValue: why))
        }
    }

    // MARK: - The route

    /// The first vector's facts and the vectors' shop, so the route's figures
    /// are the vector's figures.
    static func fixture() throws -> (facts: Data, context: JSONValue, want: [String: JSONValue]) {
        let v = Self.obj(try Self.vectors())
        guard case .array(let cases)? = v["cases"] else { throw CocoaError(.fileReadCorruptFile) }
        let first = Self.obj(cases[0])
        let facts = try JSONEncoder().encode(first["facts"] ?? .null)
        return (facts, Self.context(Self.obj(v["shop"]), first), Self.obj(first["want"]))
    }

    static func bench(prices: Bool, context: JSONValue?) async throws -> (LanServerTests.Bench, URL) {
        let root = LanConnectorRoutesTests.scratch()
        let bench = try await LanServerTests.Bench(pin: LanConnectorRoutesTests.pin, slicerRoot: root,
                                                   connectorsEnabled: true,
                                                   connectorPrices: prices, priceContext: context)
        return (bench, root)
    }

    /// Ask for the price; the opened answer.
    static func ask(_ bench: LanServerTests.Bench, _ peer: LanConnectorRoutesTests.Peer,
                    _ facts: Data) async throws -> (LanServerTests.Bench.Reply, [String: JSONValue]) {
        let body = LanConnectorRoutesTests.sealed(facts, for: peer, path: path)
        let reply = try await LanConnectorRoutesTests.call(bench, peer, "POST", path, body: body)
        let opened = LanServer.unseal(reply.body, key: LanServer.sealKey(peer.key, connectorId: peer.id),
                                      aad: LanServer.sealAad(method: "POST", path: path))
        let answer = opened.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return (reply, Self.obj(answer))
    }

    static func scopes(_ bench: LanServerTests.Bench, _ peer: LanConnectorRoutesTests.Peer) async throws -> [String] {
        let reply = try await LanConnectorRoutesTests.call(bench, peer, "GET", "/api/connectors/self")
        return (reply.json["scopes"] as? [String]) ?? []
    }

    @Test("off by default: a granted device is answered prices:off, a 200, and holds no price scope")
    func offByDefault() async throws {
        let f = try Self.fixture()
        let (bench, root) = try await Self.bench(prices: false, context: f.context)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        bench.devices.setPriceGrant(peer.id, "cost")
        let (reply, answer) = try await Self.ask(bench, peer, f.facts)
        #expect(reply.status == 200)
        #expect(answer == ["prices": .string("off")])
        #expect(try await Self.scopes(bench, peer) == ["slices:send", "queue:read"])
    }

    @Test("on, but no grant for this device: prices:off")
    func noGrant() async throws {
        let f = try Self.fixture()
        let (bench, root) = try await Self.bench(prices: true, context: f.context)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        let (reply, answer) = try await Self.ask(bench, peer, f.facts)
        #expect(reply.status == 200)
        #expect(answer == ["prices": .string("off")])
        #expect(!(try await Self.scopes(bench, peer)).contains("price:read"))
    }

    @Test("grant Price: the price, never the cost or the margin")
    func priceOnly() async throws {
        let f = try Self.fixture()
        let (bench, root) = try await Self.bench(prices: true, context: f.context)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        bench.devices.setPriceGrant(peer.id, "price")
        let (reply, answer) = try await Self.ask(bench, peer, f.facts)
        #expect(reply.status == 200)
        #expect(answer["prices"] == .string("on"))
        for key in LanServer.priceKeys { #expect(answer[key] == f.want[key], Comment(rawValue: key)) }
        #expect(answer["cost"] == nil && answer["margin"] == nil, "a price-only device saw the cost")
        #expect(Set(answer.keys) == Set(["prices"] + LanServer.priceKeys))
        #expect(try await Self.scopes(bench, peer) == ["slices:send", "queue:read", "price:read"])
    }

    @Test("grant Price and cost: the price, the cost and the margin")
    func priceAndCost() async throws {
        let f = try Self.fixture()
        let (bench, root) = try await Self.bench(prices: true, context: f.context)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        bench.devices.setPriceGrant(peer.id, "cost")
        let (_, answer) = try await Self.ask(bench, peer, f.facts)
        #expect(answer["prices"] == .string("on"))
        #expect(answer["total"] == f.want["total"])
        #expect(answer["cost"] == f.want["cost"])
        #expect(answer["margin"] == f.want["margin"])
        #expect(try await Self.scopes(bench, peer) == ["slices:send", "queue:read", "price:read", "cost:read"])
    }

    /// The vector the shop rounds: the first with `rounded: true`.
    static func roundedFixture() throws -> (facts: Data, context: JSONValue, want: [String: JSONValue]) {
        let v = Self.obj(try Self.vectors())
        guard case .array(let cases)? = v["cases"],
              let hit = cases.map(Self.obj).first(where: { Self.obj($0["want"])["rounded"] == .bool(true) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let facts = try JSONEncoder().encode(hit["facts"] ?? .null)
        return (facts, Self.context(Self.obj(v["shop"]), hit), Self.obj(hit["want"]))
    }

    @Test("the margin three ways for Price and cost; never for Price")
    func marginFields() async throws {
        let f = try Self.fixture()
        #expect(Self.obj(f.want["margin"]).keys.sorted() == ["amount", "pct", "pctOnCost"], "the vectors carry the three")
        let (bench, root) = try await Self.bench(prices: true, context: f.context)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        bench.devices.setPriceGrant(peer.id, "cost")
        let (_, cost) = try await Self.ask(bench, peer, f.facts)
        #expect(cost["margin"] == f.want["margin"])
        #expect(cost["round"] == nil, "an unrounded price names no step")
        bench.devices.setPriceGrant(peer.id, "price")
        let (_, price) = try await Self.ask(bench, peer, f.facts)
        #expect(price["margin"] == nil && price["cost"] == nil)
    }

    @Test("a rounded price names its step, for either grant")
    func roundStep() async throws {
        let f = try Self.roundedFixture()
        let step = try #require(Self.obj(f.want["round"])["step"])
        let (bench, root) = try await Self.bench(prices: true, context: f.context)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        for grant in ["price", "cost"] {
            bench.devices.setPriceGrant(peer.id, grant)
            let (_, answer) = try await Self.ask(bench, peer, f.facts)
            #expect(answer["rounded"] == .bool(true))
            #expect(answer["round"] == .object(["step": step]), Comment(rawValue: grant))
        }
    }

    @Test("the allow-list is nested: a key the rule adds inside margin, cost or round is not passed on")
    func nestedAllowList() {
        let priced: [String: JSONValue] = [
            "currency": .string("SAR"), "qty": .number(1), "unit": .number(10), "total": .number(10),
            "rounded": .bool(true), "basis": .string("measured"),
            "cost": .object(["unit": .number(7), "total": .number(7), "spool": .string("S2")]),
            "margin": .object(["pct": .number(30), "pctOnCost": .number(42.86), "amount": .number(3),
                               "default": .number(30), "note": .string("x")]),
            "round": .object(["step": .number(5), "mode": .string("up")]),
            "preset": .string("U1")]
        let cost = LanServer.priceAnswer(priced, grant: "cost")
        #expect(cost["margin"] == .object(["pct": .number(30), "pctOnCost": .number(42.86), "amount": .number(3)]))
        #expect(cost["cost"] == .object(["unit": .number(7), "total": .number(7)]))
        #expect(cost["round"] == .object(["step": .number(5)]))
        #expect(cost["preset"] == nil)
        let price = LanServer.priceAnswer(priced, grant: "price")
        #expect(Set(price.keys) == Set(["prices", "round"] + LanServer.priceKeys))
        // A step with no rounding, a zero step or a text step is not passed on.
        var plain = priced; plain["rounded"] = .bool(false)
        #expect(LanServer.priceAnswer(plain, grant: "cost")["round"] == nil)
        for bad in [JSONValue.object(["step": .number(0)]), .object(["step": .string("5")]), .number(5)] {
            var p = priced; p["round"] = bad
            #expect(LanServer.priceAnswer(p, grant: "cost")["round"] == nil)
        }
    }

    @Test("a slice the shop cannot price says why, inside prices:on")
    func unpriced() async throws {
        let f = try Self.fixture()
        var context = Self.obj(f.context)
        var settings = Self.obj(context["settings"]); settings["currency"] = .string("")
        context["settings"] = .object(settings)
        let (bench, root) = try await Self.bench(prices: true, context: .object(context))
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        bench.devices.setPriceGrant(peer.id, "cost")
        let (_, answer) = try await Self.ask(bench, peer, f.facts)
        #expect(answer == ["prices": .string("on"), "unpriced": .string("no-currency")])
    }

    @Test("nothing is stored: the book and the inbox are as they were")
    func storesNothing() async throws {
        let f = try Self.fixture()
        let (bench, root) = try await Self.bench(prices: true, context: f.context)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        bench.devices.setPriceGrant(peer.id, "cost")
        let before = bench.book.value
        _ = try await Self.ask(bench, peer, f.facts)
        #expect(bench.book.value == before)
        #expect(SlicerInbox.list(root: root).isEmpty)
    }

    @Test("POST only; a phone's key is refused; an unsealed body is a 400")
    func refusals() async throws {
        let f = try Self.fixture()
        let (bench, root) = try await Self.bench(prices: true, context: f.context)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try LanConnectorRoutesTests.enrol(bench)
        bench.devices.setPriceGrant(peer.id, "price")
        let get = try await LanConnectorRoutesTests.call(bench, peer, "GET", Self.path)
        #expect(get.status == 405)
        let phone = try LanConnectorRoutesTests.enrol(bench, kind: nil, name: "Phone")
        let refused = try await LanConnectorRoutesTests.call(
            bench, phone, "POST", Self.path, body: LanConnectorRoutesTests.sealed(f.facts, for: phone, path: Self.path))
        #expect(refused.status == 403)
        let plain = try await LanConnectorRoutesTests.call(bench, peer, "POST", Self.path, body: f.facts)
        #expect(plain.status == 400)
        // Over the sealed cap: refused before anything is decrypted.
        let big = Data(repeating: 0x20, count: LanServer.connectorPriceMaxSealedBytes + 1)
        let tooBig = try await LanConnectorRoutesTests.call(bench, peer, "POST", Self.path, body: big)
        #expect(tooBig.status == 413)
        // The largest facts the rule takes still fit once sealed.
        let most = Data(repeating: 0x20, count: LanServer.connectorPriceMaxBytes)
        #expect(LanConnectorRoutesTests.sealed(most, for: peer, path: Self.path).count <= LanServer.connectorPriceMaxSealedBytes)
    }

    @Test("a grant is stored per connector, and only a known grant")
    func grants() throws {
        let devices = LanDevices.inMemory()
        let c = try LanConnectorScopeTests.enrol(devices, kind: LanDevices.kindConnector, name: "Orca")
        let phone = try LanConnectorScopeTests.enrol(devices, kind: nil, name: "Phone")
        #expect(devices.priceGrant(c.id) == nil)
        devices.setPriceGrant(c.id, "cost")
        #expect(devices.priceGrant(c.id) == "cost")
        devices.setPriceGrant(c.id, "everything")
        #expect(devices.priceGrant(c.id) == nil)
        devices.setPriceGrant(phone.id, "price")
        #expect(devices.priceGrant(phone.id) == nil, "a phone holds no price grant")
    }
}
