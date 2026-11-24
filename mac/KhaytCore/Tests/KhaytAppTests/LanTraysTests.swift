import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `GET /api/printer/{machineId}/trays` and
/// `POST /api/printer/{machineId}/trays/{head}/spool`: a paired phone reading
/// the spool tags on a printer's heads and saying which spool is in one
/// (iPhone frame 7a). Sample data only: the printer's answer is the recorded
/// `test/fixtures/u1-filament-detect.json`, and no printer is spoken to.
@MainActor
@Suite(.serialized)
struct LanTraysTests {
    static let engine = OperatorLockTests.sharedEngine
    static let link = Data(#"{"seen":"k","spoolId":"S1"}"#.utf8)

    // MARK: - The route and who may use it

    @Test("the paths name one machine, and one head from 1 to 16")
    func paths() {
        #expect(LanServer.trayReadPath("/api/printer/M1/trays") == "M1" && LanServer.trayLinkPath("/api/printer/M1/trays") == nil)
        #expect(LanServer.trayLinkPath("/api/printer/M1/trays/2/spool")?.head == 2 && LanServer.trayReadPath("/api/printer/M1/trays/2/spool") == nil)
        // A path that is not a tray path is neither: the read route must not answer for a printer's other routes.
        for other in ["/api/printer/M1/bed-clear", "/api/printer/M1/pause", "/api/printer/M1", "/api/machines", "/api/printer/M1/trays/x/spool"] {
            #expect(LanServer.trayReadPath(other) == nil && LanServer.trayLinkPath(other) == nil, Comment(rawValue: other))
        }
        #expect(LanServer.trayPath("/api/printer/M%201/trays/2/spool")?.id == "M 1")
        #expect(LanServer.trayPath("/api/printer/M1/trays/16/spool")?.head == 16)
        for bad in ["/api/printer//trays", "/api/printer/M1/trays/", "/api/printer/M1/trays/2", "/api/printer/M1/trays/0/spool",
                    "/api/printer/M1/trays/17/spool", "/api/printer/M1/trays/-1/spool", "/api/printer/M1/trays/+1/spool",
                    "/api/printer/M1/trays/1.0/spool", "/api/printer/M1/trays/١/spool", "/api/printer/M1/trays/001/spool",
                    "/api/printer/M1/trays/2/spool/x", "/api/printer/M1/trays/2/spools", "/api/printers/M1/trays", "api/printer/M1/trays"] {
            #expect(LanServer.trayPath(bad) == nil, "\(bad)")
        }
        // Not a printer command or a bed-clear, and they are not this.
        #expect(LanServer.printerPath("/api/printer/M1/trays") == nil && LanServer.bedClearPath("/api/printer/M1/trays") == nil)
        #expect(LanServer.trayPath("/api/printer/M1/pause") == nil)
    }

    @Test("the PIN alone, an API token, and nothing at all are refused; none reaches the printer or the book")
    func pinIsNotEnough() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let pin = ["x-khayt-pin": LanDeviceKeysTests.pin]
        let read = try await bench.get("/api/printer/M1/trays", headers: pin)
        #expect(read.status == 403 && read.text.contains("device-key-required"))
        let write = try await bench.post("/api/printer/M1/trays/1/spool", json: String(decoding: Self.link, as: UTF8.self), headers: pin)
        #expect(write.status == 403 && write.text.contains("device-key-required"))
        #expect(try await bench.get("/api/printer/M1/trays").status == 401)
        #expect(try await bench.post("/api/printer/M1/trays/1/spool", json: "{}").status == 401)
        #expect(bench.trayCalls.calls.isEmpty)
        // The printer's other routes are still theirs, and what is not a route is still not one.
        #expect(try await bench.get("/api/printer/M1/bed-clear", headers: pin).status == 404)
        #expect(try await bench.get("/api/printer/M1/trays/1/spool", headers: pin).status == 404)
        #expect(try await bench.post("/api/printer/M1/trays", json: "{}", headers: pin).status == 404)
    }

    /// One test per role, as the Mac's own write is checked per role.
    func role(_ role: String, reads: Bool, writes: Bool) async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let phone = try PhoneRolesTests.codePaired(bench.devices, role: role, name: role)
        let (got, readJson) = try await PhoneRolesTests.status(bench, phone, "GET", "/api/printer/M1/trays")
        #expect(got == (reads ? 200 : 403), Comment(rawValue: role))
        if !reads { #expect(readJson["required"] as? String == "inventory:read") }
        let (sent, json) = try await PhoneRolesTests.status(bench, phone, "POST", "/api/printer/M1/trays/2/spool", body: Self.link)
        #expect(sent == (writes ? 200 : 403), Comment(rawValue: role))
        if !writes {
            #expect(json["reason"] as? String == "role-scope" && json["required"] as? String == "inventory:write", Comment(rawValue: role))
        }
        var want: [String] = []
        if reads { want.append("read M1") }
        if writes { want.append("link M1 2 " + String(decoding: Self.link, as: UTF8.self)) }
        #expect(bench.trayCalls.calls == want, Comment(rawValue: role))
        // And the phone is told the Mac serves it, when its role may read it.
        let (_, me) = try await PhoneRolesTests.status(bench, phone, "GET", "/api/devices/self")
        #expect(((me["can"] as? [String]) ?? []).contains("trays") == reads, Comment(rawValue: role))
    }

    @Test("a viewer's phone may read the tags and is refused the link, with the scope it lacked")
    func viewer() async throws { try await role("viewer", reads: true, writes: false) }
    @Test("an operator's phone may read and link") func `operator`() async throws { try await role("operator", reads: true, writes: true) }
    @Test("a manager's phone may read and link") func manager() async throws { try await role("manager", reads: true, writes: true) }
    @Test("the owner's phone may read and link") func owner() async throws { try await role("owner", reads: true, writes: true) }

    @Test("a phone paired with the owner PIN before roles is the owner; a paired slicer is refused both")
    func legacyAndSlicer() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let phone = try LanConnectorRoutesTests.enrol(bench, kind: nil, name: "Legacy")
        #expect(try await PhoneRolesTests.status(bench, phone, "POST", "/api/printer/M1/trays/1/spool", body: Self.link).0 == 200)
        let slicer = try LanConnectorRoutesTests.enrol(bench)
        let before = bench.trayCalls.calls
        for (method, path) in [("GET", "/api/printer/M1/trays"), ("POST", "/api/printer/M1/trays/1/spool")] {
            let (status, _) = try await PhoneRolesTests.status(bench, slicer, method, path, body: method == "POST" ? Self.link : Data())
            #expect(status == 401 || status == 403, "\(method) \(status)")
        }
        #expect(bench.trayCalls.calls == before)
    }

    @Test("the rule names the scopes, in the bundled copy the server asks; the wrong direction is the owner's")
    func rule() async throws {
        func ask(_ role: String, _ method: String, _ path: String) async throws -> (Bool, String?) {
            let a = try await Self.engine.deviceAllows(.object(["role": .string(role), "rolesVersion": .number(1)]), path: path, method: method)
            return (a.ok, a.required)
        }
        for (role, write) in [("viewer", false), ("operator", true), ("manager", true), ("owner", true)] {
            #expect(try await ask(role, "GET", "/api/printer/m1/trays") == (true, "inventory:read"), Comment(rawValue: role))
            #expect(try await ask(role, "POST", "/api/printer/m1/trays/2/spool") == (write, "inventory:write"), Comment(rawValue: role))
        }
        #expect(try await ask("manager", "POST", "/api/printer/m1/trays") == (false, "owner"))
        #expect(try await ask("manager", "DELETE", "/api/printer/m1/trays/2/spool") == (true, "inventory:write"), "every write verb is one direction")
        #expect(try await ask("manager", "GET", "/api/printer/m1/trays/2/spool") == (false, "owner"))
    }

    // MARK: - What the Mac does with it

    /// The U1's recorded answer: heads 1 and 2 tagged (Polymaker PLA SnapSpeed, black and off-white), 3 and 4 empty.
    static let recorded: String = {
        try! String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test/fixtures/u1-filament-detect.json"), encoding: .utf8)
    }()

    static func book(spools: [JSONValue], headSpools: JSONValue? = nil, type: String = "moonraker") -> [String: JSONValue] {
        var machine: [String: JSONValue] = ["id": .string("U1"), "name": .string("Baby U1"),
                                            "printerApi": .object(["type": .string(type), "host": .string("192.168.68.56")])]
        if let headSpools { machine["headSpools"] = headSpools }
        return ["machines": .array([.object(machine), .object(["id": .string("plain"), "name": .string("No printer API")])]),
                "inventory": .array(spools), "settings": .object([:])]
    }
    static func spool(_ id: String, _ material: String, _ color: String, brand: String? = nil, weight: Double = 800) -> JSONValue {
        var s: [String: JSONValue] = ["id": .string(id), "material": .string(material), "color": .string(color), "weight": .number(weight), "cost": .number(90)]
        if let brand { s["brand"] = .string(brand) }
        return .object(s)
    }

    @MainActor final class Asked { var paths: [String] = []; var answer: String? }

    static func shop(_ book: [String: JSONValue], answer: String? = recorded) -> (Shop, Asked) {
        let shop = Shop()
        shop.useEngine(engine)
        shop.trayBookForTests = book
        shop.trayBaseForTests = PrinterRunoutTests.base
        let asked = Asked()
        asked.answer = answer
        shop.trayFetchForTests = { request in
            let path = (request.url?.path ?? "") + (request.url?.query(percentEncoded: true).map { "?" + $0 } ?? "")
            let (body, method) = await MainActor.run { asked.paths.append((request.httpMethod ?? "GET") + " " + path); return (asked.answer, request.httpMethod) }
            _ = method
            guard let body else { throw URLError(.cannotConnectToHost) }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (shop, asked)
    }
    static func json(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:] }
    static func rows(_ text: String) -> [[String: Any]] { (json(text)["trays"] as? [[String: Any]]) ?? [] }

    @Test("the tags are read with one read-only GET and matched against the shelf: link, new, and no tag")
    func reads() async throws {
        let (shop, asked) = Self.shop(Self.book(spools: [
            Self.spool("S1", "PLA", "#080A0D", brand: "Polymaker"),      // head 1's spool, to the colour
            Self.spool("S2", "PETG", "#E2DEDB"),                          // head 2's colour, the wrong material
            .object(["id": .string("gone"), "material": .string("PLA"), "color": .string("#E2DEDB"), "weight": .number(500), "deleted": .bool(true)]),
        ], headSpools: .object(["1": .string("S2"), "0": .string("gone"), "3": .string("nobody")])))
        let (status, body) = await shop.phoneTrays("U1")
        #expect(status == 200)
        let rows = Self.rows(body)
        #expect(rows.count == 4 && rows.map { $0["head"] as? Int } == [1, 2, 3, 4])
        // Head 1: one strong match.
        #expect((rows[0]["match"] as? [String: Any])?["kind"] as? String == "link")
        #expect((rows[0]["match"] as? [String: Any])?["spoolId"] as? String == "S1")
        let tag = try #require(rows[0]["tag"] as? [String: Any])
        #expect(tag["material"] as? String == "PLA" && tag["sub"] as? String == "SnapSpeed" && tag["manufacturer"] as? String == "Polymaker")
        #expect(tag["colours"] as? [String] == ["#080A0D"] && tag["weightG"] as? Int == 500 && tag["official"] as? Bool == true)
        #expect(tag["sku"] == nil && tag["lengthM"] == nil, "more of the tag than the phone was promised")
        // Head 2: nothing like it (the PETG is not PLA, and a deleted spool is nobody's): add from the tag.
        #expect((rows[1]["match"] as? [String: Any])?["kind"] as? String == "new")
        let prefill = try #require(rows[1]["prefill"] as? [String: Any])
        #expect(prefill["material"] as? String == "PLA SnapSpeed" && prefill["color"] as? String == "#E2DEDB"
                && prefill["brand"] as? String == "Polymaker" && prefill["weight"] as? Int == 500)
        // What is already recorded: head 2's link stands; head 1's was to a deleted spool, head 4's to nobody.
        #expect(rows[1]["linked"] as? String == "S2" && rows[0]["linked"] is NSNull && rows[3]["linked"] is NSNull)
        // Heads 3 and 4 read no tag.
        #expect(rows[2]["tag"] is NSNull && rows[2]["key"] as? String == "" && (rows[2]["match"] as? [String: Any])?["kind"] as? String == "none")
        #expect(rows[2]["prefill"] is NSNull)
        // Two tags, two keys.
        #expect((rows[0]["key"] as? String ?? "").count > 10 && rows[0]["key"] as? String != rows[1]["key"] as? String)
        // The printer was asked exactly one thing, and it was a read.
        #expect(asked.paths == ["GET /printer/objects/query?filament_detect"])
        // Two spools like it: the shop chooses, best first.
        let (two, _) = Self.shop(Self.book(spools: [Self.spool("B", "PLA", "#080A0D"), Self.spool("A", "PLA", "#080A0D")]))
        let ask = try #require(Self.rows(await two.phoneTrays("U1").1).first?["match"] as? [String: Any])
        #expect(ask["kind"] as? String == "ask" && ask["candidates"] as? [String] == ["A", "B"])
    }

    @Test("a printer with no tags to read answers ok with no trays, and is not asked when it could not have any")
    func none() async throws {
        // Not a Moonraker printer: nothing is sent to it.
        let (bambu, askedBambu) = Self.shop(Self.book(spools: [], type: "bambu"))
        let (s1, b1) = await bambu.phoneTrays("U1")
        #expect(s1 == 200 && Self.json(b1)["ok"] as? Bool == true && Self.json(b1)["trays"] == nil && askedBambu.paths.isEmpty)
        // No connection at all.
        let (s2, b2) = await bambu.phoneTrays("plain")
        #expect(s2 == 200 && Self.json(b2)["trays"] == nil && askedBambu.paths.isEmpty)
        // A Moonraker printer whose firmware has no filament_detect.
        let (klipper, _) = Self.shop(Self.book(spools: []), answer: #"{"result":{"status":{}}}"#)
        let (s3, b3) = await klipper.phoneTrays("U1")
        #expect(s3 == 200 && Self.json(b3)["trays"] == nil)
        // Asked and silent: said, not "no trays".
        let (off, _) = Self.shop(Self.book(spools: []), answer: nil)
        let (s4, b4) = await off.phoneTrays("U1")
        #expect(s4 == 502 && Self.json(b4)["reason"] as? String == "printer-unreachable")
        // No such machine; and before the app has an engine.
        #expect(await off.phoneTrays("nobody").0 == 404)
        let starting = Shop()
        if starting.engine == nil { #expect(await starting.phoneTrays("U1").0 == 503) }
    }

    static func body(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }

    @Test("linking writes the machine's record as the other app does, and changes no spool")
    func links() async throws {
        let s1 = Self.spool("S1", "PLA", "#080A0D", brand: "Polymaker"), s9 = Self.spool("S9", "ABS", "#FF0000")
        let (shop, asked) = Self.shop(Self.book(spools: [s1, s9], headSpools: .object(["3": .string("S9")])))
        let rows = Self.rows(await shop.phoneTrays("U1").1)
        let key1 = try #require(rows[0]["key"] as? String), key2 = try #require(rows[1]["key"] as? String)
        asked.paths = []
        // The suggested spool, into head 1.
        let (status, text) = await shop.phoneLinkTray("U1", head: 1, body: Self.body(["seen": key1, "spoolId": "S1"]))
        #expect(status == 200, Comment(rawValue: text))
        let said = Self.json(text)
        #expect(said["ok"] as? Bool == true && said["spoolId"] as? String == "S1" && said["created"] as? Bool == false && said["head"] as? Int == 1)
        #expect((said["spool"] as? [String: Any])?["material"] as? String == "PLA")
        var book = try #require(shop.trayBookForTests)
        guard case .object(let machine)? = Shop.rows(book, "machines").first, case .object(let held)? = machine["headSpools"] else { Issue.record("shape"); return }
        // Keyed from zero, as the other app keys it; the link that was there on head 4 stays.
        #expect(held == ["0": .string("S1"), "3": .string("S9")])
        #expect(machine["rev"] == .number(1) && machine["updatedAt"] != nil)
        // The shelf is exactly as it was: no spool was touched.
        #expect(Shop.rows(book, "inventory") == [s1, s9])
        // The Mac read the tags again before writing, and only read.
        #expect(asked.paths == ["GET /printer/objects/query?filament_detect"])
        // "Choose another": any spool on the shelf, whatever the tag says. Same link twice: the same link.
        for _ in 0..<2 {
            #expect(await shop.phoneLinkTray("U1", head: 2, body: Self.body(["seen": key2, "spoolId": "S9"])).0 == 200)
        }
        book = try #require(shop.trayBookForTests)
        guard case .object(let after)? = Shop.rows(book, "machines").first else { Issue.record("shape"); return }
        #expect(after["headSpools"] == .object(["0": .string("S1"), "1": .string("S9"), "3": .string("S9")]))
        #expect(Shop.rows(book, "inventory") == [s1, s9])
        // And the next read says so.
        #expect(Self.rows(await shop.phoneTrays("U1").1).map { $0["linked"] as? String } == ["S1", "S9", nil, "S9"])
    }

    @Test("\"Add spool from the tag\" adds one spool, with no price, and links it")
    func creates() async throws {
        let s1 = Self.spool("S1", "PLA", "#080A0D", brand: "Polymaker")
        let (shop, _) = Self.shop(Self.book(spools: [s1]))
        let key2 = try #require(Self.rows(await shop.phoneTrays("U1").1)[1]["key"] as? String)
        let (status, text) = await shop.phoneLinkTray("U1", head: 2, body: Self.body(["seen": key2, "create": true]))
        #expect(status == 201, Comment(rawValue: text))
        let said = Self.json(text)
        let id = try #require(said["spoolId"] as? String)
        #expect(said["created"] as? Bool == true && id.hasPrefix("INV"))
        let book = try #require(shop.trayBookForTests)
        let shelf = Shop.rows(book, "inventory")
        #expect(shelf.count == 2 && shelf[0] == s1, "an existing spool was changed")
        guard case .object(let made) = shelf[1] else { Issue.record("shape"); return }
        #expect(made["id"] == .string(id) && made["material"] == .string("PLA SnapSpeed") && made["color"] == .string("#E2DEDB"))
        #expect(made["brand"] == .string("Polymaker") && made["weight"] == .number(500))
        // No price was made up for it.
        if case .number(let cost)? = made["cost"] { #expect(cost == 0) }
        guard case .object(let machine)? = Shop.rows(book, "machines").first else { Issue.record("shape"); return }
        #expect(machine["headSpools"] == .object(["1": .string(id)]))
        // Reading again: the head is linked to it, and it is now the one strong match.
        let again = Self.rows(await shop.phoneTrays("U1").1)[1]
        #expect(again["linked"] as? String == id && (again["match"] as? [String: Any])?["spoolId"] as? String == id)
    }

    @Test("nothing is written when the head's spool changed since the phone looked, or the request is not exactly one choice")
    func refusals() async throws {
        let original = Self.book(spools: [Self.spool("S1", "PLA", "#080A0D", brand: "Polymaker")])
        let (shop, asked) = Self.shop(original)
        let rows = Self.rows(await shop.phoneTrays("U1").1)
        let key1 = try #require(rows[0]["key"] as? String), key2 = try #require(rows[1]["key"] as? String)
        func send(_ head: Int, _ fields: [String: Any]) async -> (Int, [String: Any]) {
            let (s, t) = await shop.phoneLinkTray("U1", head: head, body: Self.body(fields)); return (s, Self.json(t))
        }
        // The phone was showing head 2's tag and sends it for head 1 (as after a swap): told, with what is there now.
        let stale = await send(1, ["seen": key2, "spoolId": "S1"])
        #expect(stale.0 == 409 && stale.1["reason"] as? String == "changed" && (stale.1["trays"] as? [[String: Any]])?.count == 4)
        // A head that reads no tag has nothing to be linked from, whatever is sent as seen.
        #expect(await send(3, ["seen": key1, "spoolId": "S1"]).1["reason"] as? String == "changed")
        // A head the printer does not have.
        #expect(await send(9, ["seen": key1, "spoolId": "S1"]) .1["reason"] as? String == "no-head")
        // A spool that is not on the shelf.
        let missing = await send(1, ["seen": key1, "spoolId": "nobody"])
        #expect(missing.0 == 404 && missing.1["reason"] as? String == "no-spool")
        // Not exactly one choice, no `seen`, or anything else in the body: refused before the printer is asked.
        asked.paths = []
        for bad: [String: Any] in [["seen": key1], ["spoolId": "S1"], ["seen": key1, "spoolId": "S1", "create": true], ["seen": key1, "create": false],
                                    ["seen": key1, "spoolId": ""], ["seen": "", "spoolId": "S1"], ["seen": key1, "spoolId": 7],
                                    ["seen": key1, "spoolId": "S1", "weight": 5], ["seen": key1, "create": "true"]] {
            #expect(await send(1, bad).0 == 400, Comment(rawValue: "\(bad)"))
        }
        #expect(await shop.phoneLinkTray("U1", head: 1, body: Data("[1]".utf8)).0 == 400)
        #expect(await shop.phoneLinkTray("U1", head: 1, body: Data(repeating: 0x20, count: 5000)).0 == 400)
        #expect(asked.paths.isEmpty)
        // The printer does not answer; a printer with no tags; no such machine.
        asked.answer = nil
        #expect(await send(1, ["seen": key1, "spoolId": "S1"]).0 == 502)
        asked.answer = #"{"result":{"status":{}}}"#
        #expect(await send(1, ["seen": key1, "spoolId": "S1"]).1["reason"] as? String == "no-trays")
        #expect(await shop.phoneLinkTray("nobody", head: 1, body: Self.body(["seen": key1, "spoolId": "S1"])).0 == 404)
        // Through all of that the book did not move.
        #expect(shop.trayBookForTests == original)
        // The sample book has nowhere to write.
        let sample = Shop()
        sample.useEngine(Self.engine)
        await sample.load(.sample)
        if let machine = sample.machinesInUse.first {
            let (s, t) = await sample.phoneLinkTray(machine.id, head: 1, body: Self.body(["seen": key1, "spoolId": "S1"]))
            #expect(s == 409 && t.contains("read-only") || s == 404, Comment(rawValue: t))
        }
    }

    @Test("the write itself: a machine or spool gone from the book on disk is refused and nothing is half-written")
    func writeOnABook() async throws {
        var root = Self.book(spools: [Self.spool("S1", "PLA", "#080A0D")])
        let before = root
        func tried(_ machine: String, _ head: Int, _ choice: Shop.TrayChoice, prefill: [String: JSONValue] = [:]) async -> String? {
            do {
                _ = try await Shop.linkTray(into: &root, machineId: machine, head: head, choice: choice, prefill: prefill,
                                            engine: Self.engine, newId: "INV-new", today: "2026-11-24")
                return nil
            } catch let refused as Shop.TrayRefused { return refused.reason } catch { return "threw" }
        }
        #expect(await tried("removed", 1, .link("S1")) == "not-found")
        #expect(await tried("U1", 1, .link("removed")) == "no-spool")
        #expect(await tried("U1", 0, .link("S1")) == "not-found")
        #expect(await tried("U1", 17, .link("S1")) == "not-found")
        // A tag with no material is not a spool: nothing added, nothing linked.
        #expect(await tried("U1", 1, .create, prefill: ["weight": .number(500)]) == "tag-unusable")
        #expect(root == before)
        // And one that is: added once, linked.
        #expect(await tried("U1", 2, .create, prefill: ["material": .string("PETG"), "weight": .number(1000), "color": .string("#112233")]) == nil)
        #expect(Shop.rows(root, "inventory").count == 2)
        guard case .object(let machine)? = Shop.rows(root, "machines").first else { Issue.record("shape"); return }
        #expect(machine["headSpools"] == .object(["1": .string("INV-new")]))
    }

    @Test("the routes in the real server are these functions, and the reference says what they do")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try String(contentsOf: root.appending(path: "Sources/KhaytApp/LanServer.swift"), encoding: .utf8)
        #expect(server.contains("await self?.phoneTrays(id)") && server.contains("await self?.phoneLinkTray(id, head: head, body: body)"))
        // The only thing either function sends a printer is the one read.
        let mine = try String(contentsOf: root.appending(path: "Sources/KhaytApp/Shop+PhoneTrays.swift"), encoding: .utf8)
        #expect(mine.components(separatedBy: "PrinterWatch.get(").count == 2 && mine.contains(#"path: "/printer/objects/query?filament_detect""#))
        for never in ["PrinterControl", "gcode", "PrinterWatch.post", "printers.commanding", "httpMethod"] { #expect(!mine.contains(never), Comment(rawValue: never)) }
        let docs = try String(contentsOf: root.deletingLastPathComponent().deletingLastPathComponent().appending(path: "docs/LAN_API.md"), encoding: .utf8)
        #expect(docs.contains("### `GET /api/printer/{machineId}/trays`") && docs.contains("### `POST /api/printer/{machineId}/trays/{head}/spool`"))
    }
}
