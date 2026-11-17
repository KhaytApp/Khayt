import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Connected apps section (`ConnectedAppsScreen`): dark behind "Pair a
/// slicer", its own shelf, and Remove keeping a slicer's files (Dev Hub, Nov 16).
@MainActor
@Suite(.serialized)
struct ConnectedAppsSectionTests {

    // The flag (`LanConnectorPairing.enabledForTests`) is shared by every LAN
    // suite, which turn it ON while running in parallel. These tests never
    // switch it off: the gates are pure and take the flag as an argument.

    @Test("dark while Pair a slicer is off: no row, not reachable, no Help article")
    func darkWhileOff() {
        #expect(!Shop.flagAllows(.connectedApps, pairingOn: false))
        #expect(Shop.flagAllows(.connectedApps, pairingOn: true))
        for other in [Shop.Shelf.machines, .inventory, .giftCards, .jobs(nil)] {
            #expect(Shop.flagAllows(other, pairingOn: false), "\(other) is not behind the flag")
        }
        #expect(!HelpBook.shown("connected-apps", pairingOn: false))
        #expect(HelpBook.shown("connected-apps", pairingOn: true))
        #expect(HelpBook.shown("machines", pairingOn: false), "every other article is always there")
        #expect(HelpBook.order.contains("connected-apps"))
    }

    @Test("on: named, restored, its own title, nothing to search")
    func onScreen() async throws {
        LanConnectorPairing.enabledForTests = true   // only ever turned ON, as the LAN suites do
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.canShow(.connectedApps))
        #expect(Shelves.shelf("connected-apps", in: shop) == .connectedApps)
        #expect(Shelves.name(.connectedApps) == "connected-apps")
        shop.shelf = .connectedApps
        #expect(shop.showingConnectedApps)
        #expect(shop.shelfTitle == shop.words.callIt("mac.apps_title"))
        #expect(!shop.canSearch, "nothing to search on this screen")
    }

    @Test("Remove keeps the slicer's waiting files and says how many")
    func removeKeepsFiles() async throws {
        let shop = Shop()
        await shop.load(.sample)
        func upload(_ id: String, from connector: String?) -> SlicerUpload {
            var u = SlicerUpload(id: id, name: "\(id).gcode", arrived: Date(), bytes: 10)
            if let connector { u.source = "connector"; u.connectorId = connector; u.connectorName = "OrcaSlicer on Studio PC" }
            return u
        }
        shop.slicerUploads = [upload("SU-1", from: "dev_A1234567890123"), upload("SU-2", from: "dev_A1234567890123"),
                              upload("SU-3", from: "dev_B1234567890123"), upload("SU-4", from: nil)]
        let a = LanDevices.Listed(id: "dev_A1234567890123", name: "OrcaSlicer on Studio PC",
                                  createdAt: Date(), lastSeenAt: Date(), kind: LanDevices.kindConnector)
        let c = LanDevices.Listed(id: "dev_C1234567890123", name: "", createdAt: Date(), lastSeenAt: Date(),
                                  kind: LanDevices.kindConnector)
        #expect(ConnectedAppsScreen.filesFrom(a.id, shop: shop) == 2)
        let note = ConnectedAppsScreen.removeNote(for: a, shop: shop)
        #expect(note.hasPrefix(shop.words.callIt("mac.apps_remove_note")))
        #expect(note.contains(shop.words.counting(2, "mac.apps_remove_keeps")))
        #expect(ConnectedAppsScreen.removeNote(for: c, shop: shop) == shop.words.callIt("mac.apps_remove_note"),
                "nothing waiting from it, nothing to say")
    }

    @Test("an inbox row says where a file came from and what a plugin asked, never acting on it")
    func rowSourceAndAsk() async throws {
        let shop = Shop()
        await shop.load(.sample)
        var octo = SlicerUpload(id: "SU-1", name: "a.gcode", arrived: Date(), bytes: 1)
        #expect(SlicerInboxRows.source(octo, words: shop.words) == shop.words.callIt("mac.su_from_octo"))
        #expect(SlicerInboxRows.asked(octo, words: shop.words) == nil)
        octo.source = "connector"; octo.connectorName = "OrcaSlicer on Studio PC"
        octo.suggested = .object(["intent": .string("quote")])
        #expect(SlicerInboxRows.source(octo, words: shop.words).contains("OrcaSlicer on Studio PC"))
        #expect(SlicerInboxRows.asked(octo, words: shop.words) == shop.words.callIt("mac.su_asked_quote"))
        octo.suggested = .object(["intent": .string("attach"), "jobId": .string("J-1042")])
        #expect(SlicerInboxRows.asked(octo, words: shop.words)?.contains("J-1042") == true)
        octo.suggested = .object(["intent": .string("inbox")])
        #expect(SlicerInboxRows.asked(octo, words: shop.words) == nil)
    }

    @Test("a job made from a plugin's file carries where it came from; an OctoPrint file carries nothing")
    func jobFromPluginFileCarriesOrigin() {
        var item = SlicerUpload(id: "SU-1", name: "Bracket_PLA.gcode", arrived: Date(), bytes: 10)
        #expect(Shop.slicerCarried(item).isEmpty, "the OctoPrint path has no plugin to show the file to")
        item.source = "connector"; item.connectorId = "dev_SampleStudioPC0001"
        item.sha256 = String(repeating: "a", count: 64); item.sliceId = "ABCDEFGHIJKLMNOP"
        item.connectorName = "OrcaSlicer on Studio PC"
        #expect(Shop.slicerCarried(item) == ["fromSlicer": .object([
            "connectorId": .string("dev_SampleStudioPC0001"), "name": .string("Bracket_PLA.gcode"),
            "sha256": .string(String(repeating: "a", count: 64)), "sliceId": .string("ABCDEFGHIJKLMNOP")])],
                "the plugin's name and suggestion stay in the inbox; the job keeps only what identifies the file")
    }

    @Test("the activity line names the file and the plugin, and the plugin as the one who did it")
    func activityLineForAPluginFile() {
        var root: [String: JSONValue] = ["auditLog": .array([]),
                                         "settings": .object(["activeOperatorId": .string("op_owner")])]
        let snapshot = root
        Shop.appendActivity(&root, text: Shop.slicerArrivalText("Bracket_PLA.gcode", plugin: "OrcaSlicer on Studio PC"),
                            ref: "SU-1", settings: Shop.settings(root), root: snapshot,
                            action: "slicer_inbox", actor: ("connector:dev_SampleStudioPC0001", "OrcaSlicer on Studio PC"))
        guard case .array(let log)? = root["auditLog"], case .object(let row)? = log.last else {
            Issue.record("no line written"); return
        }
        #expect(row["action"] == .string("slicer_inbox"))
        #expect(row["detail"] == .string("Bracket_PLA.gcode · OrcaSlicer on Studio PC"))
        #expect(row["ref"] == .string("SU-1"))
        #expect(row["operatorId"] == .string("connector:dev_SampleStudioPC0001"), "not the person signed in")
        #expect(row["operatorName"] == .string("OrcaSlicer on Studio PC"))
    }

    @Test("\"Asked: print\" names the machine the shop knows; an id it no longer has is left unsaid")
    func askedPrintNamesTheMachine() async throws {
        let shop = Shop()
        await shop.load(.sample)
        var item = SlicerUpload(id: "SU-1", name: "a.gcode", arrived: Date(), bytes: 1)
        item.source = "connector"
        item.suggested = .object(["intent": .string("print"), "machineId": .string("m_1")])
        let named = SlicerInboxRows.asked(item, words: shop.words, machine: { $0 == "m_1" ? "U1-01" : nil })
        #expect(named == shop.words.callIt("mac.su_asked_print_on", ["machine": .string("U1-01")]))
        #expect(named?.contains("U1-01") == true)
        let gone = SlicerInboxRows.asked(item, words: shop.words, machine: { _ in nil })
        #expect(gone == shop.words.callIt("mac.su_asked_print"))
    }
}
