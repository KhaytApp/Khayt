import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A paired phone may fill a connector's own fields on a job or a customer,
/// and save a connector's reply there, through `POST /api/store/deltas`. It
/// may not invent a connector's values, change one whose signature does not
/// verify here, or wipe one an older phone build never knew about.
@MainActor
struct PhoneConnectorValuesTests {

    static func setup() async throws -> (engine: KhaytEngine, root: [String: JSONValue]) {
        let shop = await ConnectorInstallTests.shop()
        let engine = try #require(shop.engine)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: try ConnectorInstallTests.sample("lamha-shipping"))
        let entry = try await engine.pluginConsentedEntry(prev: .null, manifest: manifest)
        let root: [String: JSONValue] = [
            "settings": .object(["plugins": .array([entry])]),
            "printLog": .array([.object(["id": .string("J-1"), "rev": .number(3), "plugins": .object([
                "app.khayt.samples.lamha": .object(["lamhaOrderId": .string("OLD")]),
                "gone.connector": .object(["x": .number(1)]),
            ])])]),
        ]
        return (engine, root)
    }

    static func record(_ payload: [String: JSONValue], _ i: Int = 0) -> [String: JSONValue] {
        guard case .array(let ds)? = payload["deltas"], case .object(let d) = ds[i],
              case .object(let r)? = d["record"] else { return [:] }
        return r
    }

    @Test("a phone fills a running connector's field, and nothing it should not")
    func guarded() async throws {
        let (engine, root) = try await Self.setup()
        let sent = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"deltas":[
          {"collection":"printLog","record":{"id":"J-1","rev":4,"plugins":{
            "app.khayt.samples.lamha":{"lamhaOrderId":"LM-77","city":"Riyadh","injected":"x"},
            "made.up":{"a":1}}}},
          {"collection":"clients","record":{"id":"C-1","rev":1,"plugins":{
            "app.khayt.samples.lamha":{"city":"Jeddah","lamhaOrderId":"no"}}}},
          {"collection":"printLog","record":{"id":"J-1","rev":5,"name":"older phone"}},
          {"collection":"inventory","record":{"id":"S-1","rev":1,"plugins":{"x":{"y":1}}}}],
         "tombstones":[],"cursor":null}
        """#.utf8))
        guard case .object(let payload) = sent else { Issue.record("fixture"); return }
        let out = await Shop.phoneConnectorValues(payload, root: root, engine: engine)

        let job = Self.record(out, 0)
        guard case .object(let jp)? = job["plugins"] else { Issue.record("the job lost its plugins"); return }
        #expect(jp["app.khayt.samples.lamha"] == .object(["lamhaOrderId": .string("LM-77")]),
                "only the order field the connector declares lands on a job")
        #expect(jp["made.up"] == nil, "a phone invented a connector's values")
        #expect(jp["gone.connector"] == .object(["x": .number(1)]), "a removed connector's values were wiped")

        let customer = Self.record(out, 1)
        #expect(customer["plugins"] == .object(["app.khayt.samples.lamha": .object(["city": .string("Jeddah")])]))

        let older = Self.record(out, 2)
        #expect(older["plugins"] == root["printLog"].flatMap { if case .array(let a) = $0, case .object(let o) = a[0] { return o["plugins"] }; return nil },
                "a phone build that does not know plugins wiped them")

        // Not a job or a customer: untouched (the collection gate decides those).
        #expect(Self.record(out, 3)["plugins"] == .object(["x": .object(["y": .number(1)])]))
    }

    @Test("a connector whose signature does not verify here is not editable from a phone")
    func unreviewed() async throws {
        var (engine, root) = try await Self.setup()
        guard case .object(var st)? = root["settings"], case .array(var entries)? = st["plugins"],
              case .object(var e) = entries[0], case .object(var m)? = e["manifest"] else { Issue.record("fixture"); return }
        m["version"] = .string("9.9.9")          // signed bytes changed, signature kept
        e["manifest"] = .object(m); entries[0] = .object(e); st["plugins"] = .array(entries)
        root["settings"] = .object(st)
        let payload: [String: JSONValue] = ["deltas": .array([.object([
            "collection": .string("printLog"),
            "record": .object(["id": .string("J-1"), "rev": .number(4), "plugins": .object([
                "app.khayt.samples.lamha": .object(["lamhaOrderId": .string("FORGED")])])]),
        ])]), "tombstones": .array([])]
        let out = await Shop.phoneConnectorValues(payload, root: root, engine: engine)
        guard case .object(let p)? = Self.record(out)["plugins"] else { Issue.record("plugins gone"); return }
        #expect(p["app.khayt.samples.lamha"] == .object(["lamhaOrderId": .string("OLD")]))
    }
    @Test("the phone coerces a field value as the Mac does")
    func coerce() async throws {
        let (engine, _) = try await Self.setup()
        let number: JSONValue = .object(["key": .string("n"), "label": .object(["en": .string("N")]),
                                         "type": .string("number"), "attach": .string("order")])
        #expect(try await engine.pluginCoerceField(number, raw: .string("3")) == .number(3))
        #expect(try await engine.pluginCoerceField(number, raw: .string("")) == .null)
    }
}
