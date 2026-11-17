import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Connected apps section (`ConnectedAppsScreen`): dark behind "Pair a
/// slicer", its own shelf, and Remove keeping a slicer's files (Dev Hub, Nov 16).
@MainActor
@Suite(.serialized)
struct ConnectedAppsSectionTests {

    @Test("dark while Pair a slicer is off: no row, not reachable, not restored")
    func darkWhileOff() async throws {
        LanConnectorPairing.enabledForTests = false
        defer { LanConnectorPairing.enabledForTests = false }
        guard !UserDefaults.standard.bool(forKey: "connectorPairing") else { return }
        let shop = Shop()
        await shop.load(.sample)
        #expect(!shop.canShow(.connectedApps))
        #expect(Shelves.shelf("connected-apps", in: shop) == nil, "a window does not reopen onto it")
        #expect(!shop.goToScreens().entries.contains { $0.id == "screen:connected-apps" })

        LanConnectorPairing.enabledForTests = true
        #expect(shop.canShow(.connectedApps))
        #expect(Shelves.shelf("connected-apps", in: shop) == .connectedApps)
        #expect(Shelves.name(.connectedApps) == "connected-apps")
        shop.shelf = .connectedApps
        #expect(shop.showingConnectedApps)
        #expect(shop.shelfTitle == shop.words.callIt("mac.apps_title"))
        #expect(!shop.canSearch, "nothing to search on this screen")
    }

    @Test("the Help article on connected apps is in the book only while Pair a slicer is on")
    func helpFollowsTheFlag() {
        LanConnectorPairing.enabledForTests = false
        defer { LanConnectorPairing.enabledForTests = false }
        guard !UserDefaults.standard.bool(forKey: "connectorPairing") else { return }
        #expect(HelpBook.order.contains("connected-apps"))
        #expect(!HelpBook.shown("connected-apps"))
        #expect(HelpBook.shown("machines"), "every other article is always there")
        LanConnectorPairing.enabledForTests = true
        #expect(HelpBook.shown("connected-apps"))
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
}
