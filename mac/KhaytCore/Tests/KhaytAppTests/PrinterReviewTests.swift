import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The October 2026 printer review: ten reviewer-verified faults in the
/// machine sheet, the machine card and the printer watch, each pinned here.
@MainActor
struct PrinterReviewTests {

    // MARK: - 1. The Test button asks the way the poller asks

    /// A Bambu with no serial is refused by the BAMBU branch, before any
    /// connection — which is how a test can tell, from outside, that the button
    /// took that branch rather than asking `/printer/objects/query` over HTTP.
    @Test("a Bambu draft is asked over MQTT, not as a Moonraker")
    func bambuTakesItsOwnBranch() async throws {
        let engine = try KhaytEngine()
        let draft = try #require(MachineSheet.draft(id: nil, name: "X1C", type: "bambu",
                                                    host: "192.168.1.50", port: 0,
                                                    serial: "", slug: ""))
        var asked = 0
        await #expect(throws: PrinterWatch.Refusal.needsSerial) {
            _ = try await PrinterWatch.ask(draft, engine: engine, key: "", accessCode: "") { _ in
                asked += 1
                return (Data(), URLResponse())
            }
        }
        #expect(asked == 0, "a Bambu was sent an HTTP request")
    }

    @Test("an Elegoo draft is asked over SDCP, not as a Moonraker")
    func sdcpTakesItsOwnBranch() async throws {
        let engine = try KhaytEngine()
        let draft = try #require(MachineSheet.draft(id: nil, name: "Saturn", type: "sdcp",
                                                    host: "192.168.1.51", port: 0,
                                                    serial: "", slug: ""))
        var asked = 0
        await #expect(throws: PrinterWatch.Refusal.needsMainboardId) {
            _ = try await PrinterWatch.ask(draft, engine: engine, key: "", accessCode: "") { _ in
                asked += 1
                return (Data(), URLResponse())
            }
        }
        #expect(asked == 0)
    }

    /// And the HTTP protocols still go through `read`, with the key handed in.
    @Test("a Moonraker draft is asked over HTTP, with the key")
    func httpStillReads() async throws {
        let engine = try KhaytEngine()
        let draft = try #require(MachineSheet.draft(id: nil, name: "U1", type: "octoprint",
                                                    host: "192.168.1.52", port: 80,
                                                    serial: "", slug: ""))
        var keys: [String?] = []
        _ = try? await PrinterWatch.ask(draft, engine: engine, key: "k-123", accessCode: "") { request in
            keys.append(request.value(forHTTPHeaderField: "X-Api-Key"))
            throw URLError(.cannotConnectToHost)
        }
        #expect(!keys.isEmpty, "an HTTP printer was not asked over HTTP")
        #expect(keys.first == "k-123")
    }

    /// The draft carries what each transport addresses a machine by.
    @Test("the draft carries the serial and the Repetier slug")
    func draftCarriesIdentifiers() throws {
        let bambu = try #require(MachineSheet.draft(id: "M1", name: "P1S", type: "bambu",
                                                    host: " 192.168.1.50 ", port: 8883,
                                                    serial: " 01P00A000000001 ", slug: ""))
        #expect(bambu.printerApi?.serial == "01P00A000000001")
        #expect(bambu.printerApi?.host == "192.168.1.50")
        #expect(bambu.id == "M1")
        let repetier = try #require(MachineSheet.draft(id: nil, name: "R", type: "repetier",
                                                       host: "10.0.0.4", port: 3344,
                                                       serial: "", slug: "left_printer"))
        #expect(repetier.printerApi?.printerSlug == "left_printer")
        #expect(repetier.id == "MACH-draft")
    }

    /// The Test result is the card's word for the state, not the protocol's.
    @Test("a Test that answered says the state in the shop's words")
    func testSaysTheStateWord() throws {
        let words = Words()
        let raw = #"{"state":"printing","filename":"cube.gcode","progress":40,"type":"moonraker"}"#
        let status = try JSONDecoder().decode(KhaytEngine.PrinterStatus.self, from: Data(raw.utf8))
        let said = MachineSheet.answered(status, words)
        #expect(said.hasPrefix(words.callIt("mach.live_printing")))
        #expect(said.hasSuffix("cube.gcode"))
    }

    // MARK: - 2. A Mac-only shop can add its first maintenance task

    @Test("a shop with maintenance on and no tasks still gets a card to add one to")
    func emptyMaintenanceIsACard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let machine = try #require(shop.machines.first)
        shop.setMaintTaskRowsForTesting([])

        shop.features.insert("maintenance")
        let card = await shop.maintenance(for: machine)
        #expect(card != nil, "no card means no New Task button and no service log")
        #expect(card?.tasks.isEmpty == true)

        shop.features.remove("maintenance")
        #expect(await shop.maintenance(for: machine) == nil, "nil is for maintenance switched off")
    }

    // MARK: - 3. "none" is not a connection

    @Test("\"none\" opens as no protocol and is not offered Send to printer")
    func noneIsNotLinked() async throws {
        #expect(Shop.connectionType("none") == "")
        #expect(Shop.connectionType(nil) == "")
        #expect(Shop.connectionType("moonraker") == "moonraker")

        let shop = Shop()
        await shop.load(.sample)
        let ids = shop.machines.prefix(3).map(\.id)
        try #require(ids.count == 3)
        shop.connectMachineForTesting(ids[0], type: "none")
        shop.connectMachineForTesting(ids[1], type: "moonraker")
        // A protocol this app cannot speak is still listed — the send sheet
        // says why, rather than hiding the shop's own printer.
        shop.connectMachineForTesting(ids[2], type: "klipper-something")
        let offered = Set(shop.sendablePrinters.map(\.id))
        #expect(!offered.contains(ids[0]), "a printer with type \"none\" was offered Send")
        #expect(offered.contains(ids[1]))
        #expect(offered.contains(ids[2]))

        let none = try #require(shop.machines.first { $0.id == ids[0] })
        let form = MachineSheet.Form.opening(none, kind: "fdm")
        #expect(form.apiType == "", "the picker has no tag for \"none\" and drew blank")
    }

    // MARK: - 4. A refused save says so

    @Test("a refused save reports false, so the sheet stays open")
    func refusedSaveIsFalse() async {
        let shop = Shop()
        await shop.load(.sample)
        let saved = await shop.saveMachine(["name": .string("Bench")], id: nil, catalogId: nil, opened: nil)
        #expect(saved == false)
        #expect(shop.spendProblem == shop.words.callIt("mac.move_sample"))
    }

    // MARK: - 5. A plug secret that cannot be sealed refuses the save

    struct CannotSeal: Error {}

    @Test("one secret that cannot be sealed refuses them all")
    func sealIsAllOrNothing() async throws {
        let typed = ["apiKey": "k", "token": "plug-token", "password": ""]
        await #expect(throws: CannotSeal.self) {
            _ = try await MachineSheet.sealEach(typed) { plain in
                if plain == "plug-token" { throw CannotSeal() }
                return "__enc__" + plain
            }
        }
        let fine = try await MachineSheet.sealEach(typed) { "__enc__" + $0 }
        #expect(fine == ["apiKey": "__enc__k", "token": "__enc__plug-token"],
                "a blank secret is kept, not sealed")
    }

    // MARK: - 6. A camera on a printer that is not on this network

    @Test("a printer host off this network gets no camera request, and no key")
    func publicPrinterHostIsRefused() async throws {
        let shop = await CameraFetchTests.shop()
        let machine = try CameraFetchTests.machine(host: "8.8.8.8",
                                                   snapshot: "http://8.8.8.8/webcam/?action=snapshot",
                                                   type: "octoprint")
        var asked = 0
        let frame = await Camera.fetch(machine, shop: shop) { _ in
            asked += 1
            return (Data(), HTTPURLResponse())
        }
        #expect(asked == 0, "the printer's key went to a public address")
        #expect(frame == .failed("refused"))
    }

    @Test("the LAN rule is the poller's")
    func lanRule() async throws {
        let engine = try KhaytEngine()
        #expect(await PrinterWatch.onThisNetwork(URL(string: "http://192.168.1.50/x")!, engine: engine))
        #expect(await PrinterWatch.onThisNetwork(URL(string: "http://printer.local:7125/")!, engine: engine))
        #expect(!(await PrinterWatch.onThisNetwork(URL(string: "http://8.8.8.8/")!, engine: engine)))
        #expect(!(await PrinterWatch.onThisNetwork(URL(string: "http://127.0.0.1/")!, engine: engine)))
        #expect(!(await PrinterWatch.onThisNetwork(URL(string: "http://169.254.169.254/")!, engine: engine)))
    }

    // MARK: - 7. Big figures do not trap

    @Test("a bed of 1e300 is drawn, not a crash")
    func hugeBedDoesNotTrap() throws {
        let raw = #"{"id":"M1","name":"Big","bed":{"x":1e300,"y":-1e300,"z":250}}"#
        let machine = try JSONDecoder().decode(Machine.self, from: Data(raw.utf8))
        let size = try #require(machine.bedSize)
        #expect(size.hasSuffix("× 250"))
        #expect(!size.contains("mm"), "the unit is the caller's, in the shop's language")
    }

    // MARK: - 8. Downtime rows keep their identity

    @Test("a downtime row keeps its id while it is edited, and two equal rows are two rows")
    func downtimeIdentity() {
        var block = Shop.DowntimeBlock(from: "2026-10-20T09:00", to: "2026-10-20T13:00", reason: "")
        let id = block.id
        block.reason = "Nozzle swap"
        #expect(block.id == id, "typing a reason gave the row a new identity")
        let twin = Shop.DowntimeBlock(from: block.from, to: block.to, reason: block.reason)
        #expect(twin.id != block.id)
        #expect(twin == block, "equality is the window, not the row")
    }

    // MARK: - 10. What a failure says is in the shop's language

    @Test("a printer failure is said in Arabic for an Arabic shop, and in English for a log")
    func failuresAreTranslated() {
        let words = Words()
        // Every sentence the watch can say has an English AND an Arabic entry.
        let errors: [any Error] = [
            PrinterWatch.Refusal.noHost, PrinterWatch.Refusal.notALanAddress("8.8.8.8"), PrinterWatch.Refusal.badPort(0), PrinterWatch.Refusal.redirected,
            PrinterWatch.Refusal.http(503, ""), PrinterWatch.Refusal.http(401, "denied"), PrinterWatch.Refusal.notJSON,
            PrinterWatch.Refusal.noHistoryKept(""), PrinterWatch.Refusal.noHistoryKept("duet"),
            PrinterWatch.Refusal.handshakeRefused("bad password"), PrinterWatch.Refusal.needsSerial,
            PrinterWatch.Refusal.unreadable("bambu"), PrinterWatch.Refusal.needsMainboardId,
            SdcpSocket.Trouble.refused("x"), SdcpSocket.Trouble.silent, SdcpSocket.Trouble.closed,
            SdcpSocket.Trouble.socket("x"),
            BambuMqtt.Trouble.malformed, BambuMqtt.Trouble.certificateChanged,
            BambuMqtt.Trouble.refused(5), BambuMqtt.Trouble.silent,
            BambuMqtt.Trouble.closed("hungUp"), BambuMqtt.Trouble.closed("cancelled"),
            BambuMqtt.Trouble.closed("other"),
            URLError(.timedOut), URLError(.cannotConnectToHost), URLError(.cannotFindHost),
        ]
        for error in errors {
            let said = PrinterWatch.sentence(error)
            #expect(said != nil, "\(error) has no sentence")
            guard let key = said?.key else { continue }
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) has no English")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) has no Arabic")
            let english = PrinterWatch.say(error)
            #expect(!english.contains("{"), "\(key) left a placeholder: \(english)")
            #expect(PrinterWatch.say(error, words) == english, "an English shop reads the log's sentence")
        }
        #expect(PrinterWatch.Refusal.notALanAddress("8.8.8.8").description.contains("8.8.8.8"))
        #expect(Words.english("mac.pw_bambu_silent").contains("Developer Mode"))
    }

    @Test("the stored problem on a card is the shop's language")
    func stateWordsAreTheCards() {
        let words = Words()
        #expect(PrinterWatch.stateWord("PRINTING", words) == words.callIt("mach.live_printing"))
        #expect(PrinterWatch.stateWord("paused", words) == words.callIt("rec.paused"))
        #expect(PrinterWatch.stateWord("busy", words) == "busy")
    }

    // MARK: - 9. No typed arrows or unit letters left on these screens

    @Test("the machine screens draw no literal arrow or English unit")
    func noLiteralArrowsOrUnits() {
        let profit = EmptyStateTests.source("MachineProfit.swift")
        #expect(!profit.contains(#"Text("→")"#))
        #expect(!profit.contains(#"" kWh""#))
        let floor = EmptyStateTests.source("ShopFloor.swift")
        #expect(!floor.contains(#") mm""#))
        #expect(!floor.contains(#") W""#))
        #expect(Words.own["mac.unit_kwh"]?["ar"]?.isEmpty == false)
    }
}
