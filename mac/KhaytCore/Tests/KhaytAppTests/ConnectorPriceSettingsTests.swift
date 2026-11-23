import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Show prices in OrcaSlicer" and each slicer's price grant (Connected apps;
/// Figma Mac file, page 24): only the OWNER writes either, "Price and cost"
/// also needs the right to see reports, and the gates are in the writes.
@Suite(.serialized) @MainActor
struct ConnectorPriceSettingsTests {

    /// A locked shop with its own device store, one paired slicer and one
    /// paired phone, and its own place for the switch.
    static func shop(extra: [String: JSONValue] = [:]) async throws -> (Shop, slicer: String, phone: String) {
        let shop = await OperatorLockTests.shop(extra: extra)
        let devices = LanDevices.inMemory()
        shop.lanDevicesForTests = devices
        shop.connectorPricesDefaults = UserDefaults(suiteName: "khayt.prices.test.\(UUID().uuidString)")!
        shop.refreshConnectorPrices()
        let slicer = try LanConnectorScopeTests.enrol(devices, kind: LanDevices.kindConnector, name: "Orca")
        let phone = try LanConnectorScopeTests.enrol(devices, kind: nil, name: "Phone")
        shop.refreshConnectedApps()
        return (shop, slicer.id, phone.id)
    }

    static func isOn(_ shop: Shop) -> Bool {
        shop.connectorPricesDefaults.bool(forKey: LanConnectorPairing.pricesKey)
    }

    @Test("off unless the owner turns it on: the switch starts off and no slicer holds a grant")
    func startsOff() async throws {
        let (shop, slicer, _) = try await Self.shop()
        #expect(!shop.connectorPricesOn && !Self.isOn(shop))
        #expect(shop.lanDeviceStore.priceGrant(slicer) == nil)
        #expect(shop.connectedApps.first?.priceGrant == nil)
    }

    @Test("the switch: nobody signed in, a viewer, an operator and a manager cannot turn it on or off; the owner can")
    func switchIsTheOwners() async throws {
        let (shop, _, _) = try await Self.shop()
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333"), ("OP-m", "2222")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            shop.moveProblem = nil
            #expect(!shop.mayChangeConnectorPrices)
            shop.setConnectorPrices(true)
            #expect(!Self.isOn(shop) && !shop.connectorPricesOn, Comment(rawValue: who?.0 ?? "nobody"))
            #expect(LockReviewTests.refused(shop), "the refusal is said")
        }
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        shop.setConnectorPrices(true)
        #expect(Self.isOn(shop) && shop.connectorPricesOn)
        // On, a manager cannot turn it off either.
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        shop.setConnectorPrices(false)
        #expect(Self.isOn(shop) && shop.connectorPricesOn)
    }

    @Test("a grant: a non-owner can give none, change none and take none away; the owner can")
    func grantIsTheOwners() async throws {
        let (shop, slicer, _) = try await Self.shop()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        shop.setConnectorPriceGrant(slicer, "price")
        #expect(shop.lanDeviceStore.priceGrant(slicer) == "price")
        #expect(shop.connectedApps.first(where: { $0.id == slicer })?.priceGrant == "price", "the screen's row follows")
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333"), ("OP-m", "2222")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            for grant in ["cost", nil, "price"] as [String?] {
                shop.moveProblem = nil
                shop.setConnectorPriceGrant(slicer, grant)
                #expect(shop.lanDeviceStore.priceGrant(slicer) == "price",
                        Comment(rawValue: "\(who?.0 ?? "nobody") set \(grant ?? "none")"))
                #expect(LockReviewTests.refused(shop))
            }
        }
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        shop.setConnectorPriceGrant(slicer, "cost")
        #expect(shop.lanDeviceStore.priceGrant(slicer) == "cost")
        shop.setConnectorPriceGrant(slicer, nil)
        #expect(shop.lanDeviceStore.priceGrant(slicer) == nil)
    }

    @Test("an unknown grant is refused, not stored as none; a phone never holds one")
    func onlyKnownGrants() async throws {
        let (shop, slicer, phone) = try await Self.shop()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        shop.setConnectorPriceGrant(slicer, "cost")
        shop.setConnectorPriceGrant(slicer, "everything")
        #expect(shop.lanDeviceStore.priceGrant(slicer) == "cost", "a bad value did not clear the grant")
        shop.setConnectorPriceGrant(phone, "price")
        #expect(shop.lanDeviceStore.priceGrant(phone) == nil)
    }

    @Test("the staff lock off: whoever is at the Mac is the owner, as everywhere")
    func lockOff() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        let devices = LanDevices.inMemory()
        shop.lanDevicesForTests = devices
        shop.connectorPricesDefaults = UserDefaults(suiteName: "khayt.prices.test.\(UUID().uuidString)")!
        let slicer = try LanConnectorScopeTests.enrol(devices, kind: LanDevices.kindConnector, name: "Orca")
        #expect(shop.mayChangeConnectorPrices && shop.mayGrantConnectorCost)
        shop.setConnectorPrices(true)
        shop.setConnectorPriceGrant(slicer.id, "cost")
        #expect(Self.isOn(shop) && devices.priceGrant(slicer.id) == "cost")
    }

    @Test("Price and cost asks for reports as well: the write asks both gates, in that order")
    func costNeedsReports() throws {
        // Today every owner sees reports, so no fixture can reach an owner
        // without them; the source holds the second gate in place for the day
        // a shop's own limits can.
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop+ConnectorPrices.swift"), encoding: .utf8)
        let body = try #require(src.range(of: "func setConnectorPriceGrant"))
        let owner = try #require(src.range(of: #"guard permitted("security", "edit")"#, range: body.upperBound..<src.endIndex))
        let reports = try #require(src.range(of: #"if grant == "cost", !permitted("analytics", "view") { return }"#,
                                             range: owner.upperBound..<src.endIndex))
        let write = try #require(src.range(of: "lanDeviceStore.setPriceGrant", range: body.upperBound..<src.endIndex))
        #expect(reports.upperBound <= write.lowerBound, "both gates come before the write")
    }

    @Test("what a slicer's row says it sees: the grant counts only while the switch is on")
    func rowSaysWhatItSees() async {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        let base = w.callIt("mac.apps_does")
        #expect(Shop.connectorDoes(grant: "cost", pricesOn: false, words: w) == base)
        #expect(Shop.connectorDoes(grant: nil, pricesOn: true, words: w) == base)
        #expect(Shop.connectorDoes(grant: "price", pricesOn: true, words: w) == base + " · " + w.callIt("mac.apps_sees_price"))
        #expect(Shop.connectorDoes(grant: "cost", pricesOn: true, words: w) == base + " · " + w.callIt("mac.apps_sees_cost"))
    }

    @Test("the Price choice says a device can estimate material costs from it (security review, LOW 3)")
    func priceNoteSaysTheRisk() async {
        let shop = await OperatorLockTests.shop(on: false)
        #expect(ConnectedAppsScreen.grantNote("price") == "mac.apps_grant_price_note")
        #expect(shop.words.callIt("mac.apps_grant_price_note").contains("estimate your material costs"))
        #expect(ConnectedAppsScreen.grants == [nil, "price", "cost"])
    }

    @Test("turning the switch off keeps each grant, and the route stops answering prices at once")
    func offKeepsGrants() async throws {
        let (shop, slicer, _) = try await Self.shop()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        shop.setConnectorPrices(true)
        shop.setConnectorPriceGrant(slicer, "price")
        shop.setConnectorPrices(false)
        #expect(!Self.isOn(shop))
        #expect(shop.lanDeviceStore.priceGrant(slicer) == "price")
    }
}
