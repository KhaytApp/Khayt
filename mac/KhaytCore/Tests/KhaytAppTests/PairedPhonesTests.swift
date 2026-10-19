import Foundation
import Testing
import CryptoKit
import KhaytCore
@testable import KhaytApp

/// Settings → Online → Paired phones (Oct 2026): a lost phone could only be
/// cut off by changing the PIN, which signed out every phone.
@MainActor
struct PairedPhonesTests {
    @Test("the list is the store's, and Sign out removes that phone alone")
    func signOut() throws {
        let shop = Shop()
        let store = LanDevices.inMemory()
        shop.lanDevicesForTests = store
        let pub = { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString() }
        let a = try store.enrol(phonePublic: pub(), name: "A", pin: "24682468", identity: .init(), now: Date())
        _ = try store.enrol(phonePublic: pub(), name: "B", pin: "24682468", identity: .init(), now: Date())
        shop.refreshPairedPhones()
        #expect(shop.pairedPhones.count == 2)
        shop.signOutPhone(a.deviceId)
        #expect(shop.pairedPhones.map(\.name) == ["B"])
        #expect(store.count == 1)
    }

    @Test("wired: the server checks the same store the list shows, and Settings asks first")
    func wired() throws {
        #expect(try LockRound3Tests.source("LanServer.swift").contains("host.devices = lanDeviceStore"))
        #expect(try LockRound3Tests.source("OnlinePane.swift").contains("PairedPhones(shop: shop)"))
        #expect(try LockRound3Tests.source("Shop+PairedPhones.swift").contains(".askFirst($signingOut"))
    }
}
