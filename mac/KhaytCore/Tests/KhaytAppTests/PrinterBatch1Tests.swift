import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Printer batch 1 on the Mac (Figma Mac file, page 23): printers as their own
/// area in the role rules (P5), the seven state chips (C2), and the checks a
/// file gets against its printer before it goes (C8).
@Suite(.serialized) @MainActor
struct PrinterBatch1Tests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/KhaytApp")

    static func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }

    // MARK: - P5: who may do what to a printer

    static let limitsCases: [JSONValue?] = [
        nil,
        .object(["operator": .object(["printers": .object(["control": .bool(false)])])]),
        .object(["manager": .object(["printers": .object(["send": .bool(false), "connection": .bool(false)])])]),
        // A limit can never take a right from the owner, nor give the viewer one.
        .object(["owner": .object(["printers": .object(["send": .bool(false)])]),
                 "viewer": .object(["printers": .object(["send": .bool(true)])])]),
        .object(["operator": .string("junk")]),
        .string("junk"),
    ]

    @Test("canPrinter in Swift is the module's, over every role, verb, lock state and limit")
    func canPrinterParity() async throws {
        let engine = OperatorLockTests.sharedEngine
        let rbac = try await engine.rbac()
        #expect(rbac.printerVerbs == ["send": "create", "control": "edit", "connection": "edit", "unlink": "delete"])
        for role in rbac.roles + ["Admin", "", "nobody"] {
            for verb in ["send", "control", "connection", "unlink", "format", ""] {
                for lock in [true, false] {
                    for limits in Self.limitsCases {
                        let want = try await engine.rbacCanPrinter(role: role, verb: verb, lockEnabled: lock, limits: limits)
                        #expect(rbac.canPrinter(role: role, verb: verb, lockEnabled: lock, limits: limits) == want,
                                Comment(rawValue: "\(role)/\(verb)/lock \(lock)/\(String(describing: limits))"))
                    }
                }
            }
        }
    }

    @Test("defaults are what each role could do under edit orders: nothing changes until a shop tightens")
    func defaultsAreTodays() async throws {
        let shop = await OperatorLockTests.shop()
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333"), ("OP-m", "2222"), ("OP-o", "1111")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            for verb in Shop.printerRoleVerbs {
                #expect(shop.printerAllows(verb) == shop.lockAllows("orders", "edit"),
                        Comment(rawValue: "\(who?.0 ?? "nobody") / \(verb)"))
            }
        }
    }

    @Test("a shop's limit takes one verb from one role, and the refusal is said")
    func limitsTighten() async throws {
        let limits: JSONValue = .object(["operator": .object(["printers": .object(["control": .bool(false)])])])
        let shop = await OperatorLockTests.shop(extra: ["roleLimits": limits])
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        #expect(shop.printerAllows("send"))
        #expect(!shop.printerAllows("control"))
        #expect(shop.lockAllows("orders", "edit"), "the limit changes only printers")
        shop.moveProblem = nil
        #expect(!shop.permittedPrinter("control"))
        #expect(LockReviewTests.refused(shop))
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(shop.printerAllows("control"), "a manager is not the operator")
        shop.lockNow()
        #expect(!shop.printerAllows("send"), "nobody signed in")
    }

    @Test("every printer action asks the printers rule, none asks edit orders")
    func gatesAskThePrinterRule() throws {
        let printers = try String(contentsOf: Self.sources.appending(path: "Shop+Printers.swift"), encoding: .utf8)
        for (anchor, verb) in [("func applyRelocation(", "connection"), ("func tell(", "control"), ("func control(", "control"),
                               ("func sendToPrinter(", "send"), ("func drop(", "control"), ("func switchPlug(", "control")] {
            let at = try #require(printers.range(of: anchor), Comment(rawValue: anchor))
            let body = printers[at.upperBound...].prefix(1200)
            #expect(body.contains("permittedPrinter(\"\(verb)\")"), Comment(rawValue: anchor))
        }
        #expect(!printers.contains(#"permitted("orders", "edit")"#))
        let prep = try String(contentsOf: Self.sources.appending(path: "Shop+PrintPrep.swift"), encoding: .utf8)
        #expect(prep.contains(#"permittedPrinter("send")"#) && !prep.contains(#"permitted("orders", "edit")"#))
        let light = try String(contentsOf: Self.sources.appending(path: "U1Camera.swift"), encoding: .utf8)
        #expect(light.contains(#"shop.permittedPrinter("control")"#) && !light.contains(#"permitted("orders", "edit")"#))
        for file in ["ChamberLight.swift", "ShopFloor.swift"] {
            let text = try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
            #expect(!text.contains(#"lockAllows("orders", "edit")"#), Comment(rawValue: file))
        }
    }

    @Test("a machine save asks the connection right only when the connection changed")
    func connectionChanged() {
        let api: JSONValue = .object(["type": .string("moonraker"), "host": .string("192.168.1.20"), "port": .number(80)])
        let opened: [String: JSONValue] = ["name": .string("U1"), "printerApi": api,
                                           "webcam": .object(["enabled": .bool(false)]),
                                           "smartPlug": .object(["type": .string("none")])]
        var renamed = opened; renamed["name"] = .string("Workshop U1"); renamed["powerDraw"] = .number(200)
        #expect(!Shop.connectionChanged(renamed, opened: opened))
        var moved = opened
        moved["printerApi"] = .object(["type": .string("moonraker"), "host": .string("192.168.1.21"), "port": .number(80)])
        #expect(Shop.connectionChanged(moved, opened: opened))
        var keyed = opened
        keyed["printerApi"] = .object(["type": .string("moonraker"), "host": .string("192.168.1.20"), "port": .number(80),
                                       "apiKey": .string("sealed")])
        #expect(Shop.connectionChanged(keyed, opened: opened), "a new key is a connection change")
        var cam = opened; cam["webcam"] = .object(["enabled": .bool(true)])
        #expect(Shop.connectionChanged(cam, opened: opened))
        // A new machine: only when a connection was typed.
        #expect(!Shop.connectionChanged(["name": .string("New"), "printerApi": .object(["type": .string("none"), "host": .string("")]),
                                         "webcam": .object(["enabled": .bool(false)]),
                                         "smartPlug": .object(["type": .string("none")])], opened: nil))
        #expect(Shop.connectionChanged(["name": .string("New"), "printerApi": api], opened: nil))
        #expect(Shop.connectionChanged(["smartPlug": .object(["type": .string("tasmota")])], opened: nil))
    }

    // MARK: - The Roles sheet

    @Test("a tick: allowing removes the limit and its empty objects, refusing writes false")
    func roleLimitsTransform() {
        let off = Shop.roleLimits(nil, role: "operator", verb: "control", allowed: false)
        #expect(off == .object(["operator": .object(["printers": .object(["control": .bool(false)])])]))
        let two = Shop.roleLimits(off, role: "operator", verb: "send", allowed: false)
        #expect(Self.obj(Self.obj(Self.obj(two)["operator"])["printers"]).count == 2)
        let one = Shop.roleLimits(two, role: "operator", verb: "control", allowed: true)
        #expect(one == .object(["operator": .object(["printers": .object(["send": .bool(false)])])]))
        #expect(Shop.roleLimits(one, role: "operator", verb: "send", allowed: true) == .object([:]))
        // Another role's limits, and another area's, are left alone.
        let other: JSONValue = .object(["manager": .object(["printers": .object(["send": .bool(false)]),
                                                            "orders": .object(["edit": .bool(false)])])])
        let kept = Shop.roleLimits(other, role: "operator", verb: "send", allowed: false)
        #expect(Self.obj(kept)["manager"] == Self.obj(other)["manager"])
        let cleared = Shop.roleLimits(other, role: "manager", verb: "send", allowed: true)
        #expect(cleared == .object(["manager": .object(["orders": .object(["edit": .bool(false)])])]))
    }

    @Test("the owner's column and the viewer's are fixed; only the owner changes a tick")
    func rolesSheetRules() async throws {
        let shop = await OperatorLockTests.shop()
        for verb in Shop.printerRoleVerbs {
            #expect(!shop.printerRoleCanChange("owner", verb))
            #expect(!shop.printerRoleCanChange("viewer", verb), "the rules give a viewer nothing to take away")
            #expect(shop.printerRoleCanChange("manager", verb) && shop.printerRoleCanChange("operator", verb))
            #expect(shop.printerRoleHas("owner", verb) && !shop.printerRoleHas("viewer", verb))
        }
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333"), ("OP-m", "2222")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            await shop.setPrinterRole("operator", "control", allowed: false)
            #expect(LockReviewTests.refused(shop), Comment(rawValue: who?.0 ?? "nobody"))
            #expect(shop.printerRoleHas("operator", "control"))
        }
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        await shop.setPrinterRole("operator", "control", allowed: false)
        // The owner passes the gate; the sample book has nowhere to write.
        #expect(!LockReviewTests.refused(shop))
        #expect(shop.moveProblem == shop.words.callIt("mac.move_sample"))
        shop.moveProblem = nil
        await shop.setPrinterRole("owner", "send", allowed: false)
        #expect(shop.moveProblem == nil, "the owner's column is not written at all")
    }

    // MARK: - C2: the seven chips

    @Test("the chips: paused is its own state and busy; one miss reconnects, three is offline; never asked is not known yet")
    func chips() async throws {
        let engine = OperatorLockTests.sharedEngine
        func m(_ id: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "printerApi": .object(["type": .string("moonraker")])]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        func e(_ state: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = ["state": .string(state), "progress": .number(40)]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        let miss: [String: JSONValue] = ["error": .string("no answer"), "consecutiveFailures": .number(1)]
        let gone: [String: JSONValue] = ["error": .string("no answer"), "consecutiveFailures": .number(3)]
        let machines = [m("print"), m("pause"), m("idle"), m("miss"), m("gone"), m("never"), m("err"),
                        m("manual", ["isOffline": .bool(true)]),
                        .object(["id": .string("unlinked")])]
        let cache: [String: JSONValue] = ["print": e("printing"), "pause": e("paused"), "idle": e("standby", ["progress": .number(0)]),
                                          "miss": e("offline", miss), "gone": e("offline", gone), "err": e("error"),
                                          "manual": e("printing")]
        let chips = try await engine.machineChips(machines: machines, cache: cache)
        #expect(chips["print"] == .printing && chips["pause"] == .paused && chips["idle"] == .idle)
        #expect(chips["miss"] == .reconnecting && chips["gone"] == .offline)
        #expect(chips["never"] == .unknown && chips["err"] == .error && chips["manual"] == .offline)
        #expect(chips["unlinked"] == nil, "a machine Khayt does not poll has no chip")
        #expect(KhaytEngine.MachineChip.paused.busy && KhaytEngine.MachineChip.printing.busy)
        #expect(!KhaytEngine.MachineChip.idle.busy && !KhaytEngine.MachineChip.reconnecting.busy)
        #expect(KhaytEngine.MachineChip.allCases.count == 7)
    }

    @Test("every chip has its word, in every language the Mac speaks")
    func chipWords() async {
        let shop = await OperatorLockTests.shop(on: false)
        var said: Set<String> = []
        for chip in KhaytEngine.MachineChip.allCases {
            let word = MachineStateChip.word(chip, shop.words)
            #expect(!word.isEmpty && !word.hasPrefix("mac."), Comment(rawValue: chip.rawValue))
            said.insert(word)
        }
        #expect(said.count == 7, "seven states, seven different words")
    }

    // MARK: - C8: the checks before a send

    @Test("the shared send-check vectors, through the Mac's engine")
    func sendCheckVectors() async throws {
        let url = Self.root.appending(path: "test/fixtures/send-checks-vectors.json")
        let v = Self.obj(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)))
        guard case .array(let cases)? = v["cases"] else { Issue.record("no cases"); return }
        #expect(cases.count >= 24)
        let engine = OperatorLockTests.sharedEngine
        for value in cases {
            let c = Self.obj(value)
            let why: String = { if case .string(let s)? = c["why"] { return s }; return "?" }()
            let got = try await engine.sendChecksVector(file: c["file"] ?? .null, machine: c["machine"] ?? .null, loaded: c["loaded"])
            #expect(got == c["want"], Comment(rawValue: why))
        }
    }

    static let gcode = """
        ; printer_model = Voron 2.4
        ; printable_area = 0x0,350x0,350x350,0x350
        ; printable_height = 340
        G28
        ; filament used [g] = 12.5, 3.0
        ; filament_type = PLA;PETG
        ; filament_colour = #1E1E1E;#FFFFFF
        """

    static let u1: JSONValue = .object([
        "id": .string("m1"), "model": .string("Snapmaker U1"), "toolheads": .number(4),
        "bed": .object(["x": .number(270), "y": .number(270), "z": .number(270)]),
        "printerApi": .object(["type": .string("moonraker")])])

    @Test("a real file's text: sliced for another printer, a material that is not what is loaded, a head not reported")
    func sendChecksFromText() async throws {
        let engine = OperatorLockTests.sharedEngine
        let loaded: JSONValue = .array([
            .object(["slot": .number(0), "hex": .string("#1E1E1E"), "material": .string("PETG")]),
            .object(["slot": .number(1), "material": .string("NONE")])])
        let found = try await engine.sendChecks(fileName: "plate.gcode", gcodeText: Self.gcode, bounds: nil,
                                                machine: Self.u1, loaded: loaded)
        #expect(found.map(\.code) == ["sliced-for-other", "material-mismatch", "head-not-reported"])
        #expect(!SendChecks.holds(found) && SendChecks.asksAnyway(found))
        #expect(found[1].slot == 1 && found[1].want?.type == "PLA" && found[1].have?.material == "PETG")
        #expect(found[0].model == "Voron 2.4")
        // Nothing read, nothing loaded: nothing is invented.
        #expect(try await engine.sendChecks(fileName: "plate.gcode", gcodeText: nil, bounds: nil, machine: Self.u1, loaded: nil).isEmpty)
        // A measured model too big for the bed holds the send.
        let big: JSONValue = .object(["x": .number(300), "y": .number(300), "z": .number(50), "source": .string("placed-extents")])
        let held = try await engine.sendChecks(fileName: "plate.gcode", gcodeText: nil, bounds: big, machine: Self.u1, loaded: nil)
        #expect(held.first?.code == "bed-footprint" && SendChecks.holds(held) && !SendChecks.asksAnyway(held))
    }

    @Test("each finding is said in words, with what to do; the button says Send anyway only for a warning")
    func sendCheckWords() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        func finding(_ json: String) throws -> KhaytEngine.SendFinding {
            try JSONDecoder().decode(KhaytEngine.SendFinding.self, from: Data(json.utf8))
        }
        let bed = KhaytEngine.SendFinding.Size(x: 270, y: 270, z: 270)
        let bounds = KhaytEngine.SendFinding.Size(x: 300, y: 210, z: 40)
        let stop = try finding(#"{"code":"bed-footprint","severity":"block","over":{"x":30,"y":0,"z":0}}"#)
        let line = try #require(SendChecks.line(stop, printer: "Workshop U1", bounds: bounds, bed: bed, words: w))
        #expect(line.title == "Too big for this bed: 300 × 210 mm on 270 × 270 mm")
        #expect(line.hint == "Slice it again for Workshop U1, or send it to a larger printer.")
        let material = try finding(##"{"code":"material-mismatch","severity":"warn","slot":2,"want":{"type":"PLA","colour":"#000000"},"have":{"material":"PETG","colour":"#FFFFFF"}}"##)
        let said = try #require(SendChecks.line(material, printer: "Workshop U1", bounds: nil, bed: bed, words: w))
        #expect(said.title == "Tool 2 has PETG #FFFFFF loaded; the file asks for PLA #000000")
        #expect(said.hint?.hasPrefix("Load PLA #000000 in tool 2") == true)
        let quiet = try finding(#"{"code":"head-not-reported","severity":"info","slot":4}"#)
        let q = try #require(SendChecks.line(quiet, printer: "Workshop U1", bounds: nil, bed: bed, words: w))
        #expect(q.title == "Tool 4: the printer didn't say what is loaded" && q.hint == "Not checked. Nothing is assumed.")
        // A code this build does not know says nothing, and holds nothing.
        let later = try finding(#"{"code":"something-new","severity":"warn"}"#)
        #expect(SendChecks.line(later, printer: "U1", bounds: nil, bed: bed, words: w) == nil)
        for code in ["bed-height", "bed-rotate", "sliced-for-other", "colour-far"] {
            let f = try finding(#"{"code":"\#(code)","severity":"warn","slot":1}"#)
            let l = try #require(SendChecks.line(f, printer: "U1", bounds: bounds, bed: bed, words: w), Comment(rawValue: code))
            #expect(!l.title.isEmpty && !l.title.contains("mac.sc_") && !l.title.contains("{"), Comment(rawValue: l.title))
        }
        #expect(SendToPrinterSheet.sendKey(slicesFirst: false, start: true, findings: [material]) == "mac.send_anyway")
        #expect(SendToPrinterSheet.sendKey(slicesFirst: false, start: true, findings: [quiet]) == "mac.send_and_start")
        #expect(SendToPrinterSheet.sendKey(slicesFirst: false, start: false, findings: []) == "mac.send_only")
        #expect(SendToPrinterSheet.sendKey(slicesFirst: false, start: true, findings: [stop, material]) == "mac.send_and_start",
                "a held send is not offered as Send anyway; the button is off")
        #expect(SendToPrinterSheet.sendKey(slicesFirst: true, start: true, findings: [material]) == "slicer.send_title")
    }

    @Test("a long G-code file is read at both ends, where slicers write their comments")
    func readsBothEnds() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "khayt-sendcheck-\(UUID().uuidString).gcode")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data("; printer_model = Voron 2.4\n".utf8)
        data.append(Data(repeating: UInt8(ascii: "G"), count: SendChecks.headBytes + SendChecks.tailBytes + 4096))
        data.append(Data("\n; filament_type = PLA\n".utf8))
        try data.write(to: url)
        let text = try #require(SendChecks.read(url))
        #expect(text.hasPrefix("; printer_model = Voron 2.4"))
        #expect(text.hasSuffix("; filament_type = PLA\n"))
        #expect(text.utf8.count <= SendChecks.headBytes + SendChecks.tailBytes + 1)
    }
}
