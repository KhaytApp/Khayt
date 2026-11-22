import Foundation
import Testing
import CryptoKit
import KhaytCore
@testable import KhaytApp

/// The pairing-by-code screens (Figma Mac file, page 26): what the panel shows
/// for each state of the two windows, what each ending says, who is offered
/// which roles, and that the screens stay as they were while the switch is off.
@Suite(.serialized) @MainActor
struct PhonePairingUITests {

    static func panel(_ shop: Shop, denied: String? = nil, role: String? = nil, dismissed: Bool = false) -> PhonePairingUI.Panel {
        PhonePairingUI.panel(code: shop.lanPhonePairing, pin: shop.lanPairing, denied: denied, approvedRole: role,
                             dismissed: dismissed, words: shop.words)
    }

    @Test("the roles are listed least first, and only the ones the rule gave")
    func roleOrder() {
        #expect(PhonePairingUI.listed(["owner", "manager", "operator", "viewer"]) == ["viewer", "operator", "manager", "owner"])
        #expect(PhonePairingUI.listed(["manager", "operator", "viewer"]) == ["viewer", "operator", "manager"], "a manager is not offered Owner")
        #expect(PhonePairingUI.listed([]).isEmpty)
        #expect(PhonePairingUI.listed(["admin", "viewer"]) == ["viewer"], "a role the screens do not know is not drawn")
    }

    @Test("every role has a name and a line saying what it opens, and they differ")
    func roleWords() async {
        let shop = await OperatorLockTests.shop(on: false)
        var names: Set<String> = [], notes: Set<String> = []
        for role in PhonePairingUI.order {
            let name = shop.words.callIt(PhonePairingUI.nameKey(role)), note = shop.words.callIt(PhonePairingUI.noteKey(role))
            #expect(!name.hasPrefix("mac.") && !note.hasPrefix("mac."), Comment(rawValue: role))
            names.insert(name); notes.insert(note)
        }
        #expect(names.count == 4 && notes.count == 4)
        #expect(shop.words.callIt("mac.prole_owner") == "Owner", "the short name, as the frames say it")
    }

    @Test("the panel: closed, waiting, a phone asking with its number, denied and still waiting")
    func panelStates() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        shop.lanDevicesForTests = LanDevices.inMemory()
        #expect(Self.panel(shop) == .closed(nil))
        let shown = try PhoneRolesTests.waitingPhone(shop)
        guard case .asked(let asked) = Self.panel(shop) else { Issue.record("no request shown"); return }
        #expect(asked.pairId == shown.pairId && asked.check == shown.check)
        #expect(asked.name == "Reem's iPhone" && asked.address == "192.168.1.47")
        #expect(PhonePairingUI.from(asked) == "Khayt iPhone 1 · 192.168.1.47")
        // Denied: the window stays open for another try, and says who was turned down.
        shop.denyPhone()
        #expect(Self.panel(shop, denied: asked.name) == .waiting(denied: "Reem's iPhone"))
        // Stopped by the person: nothing is said about it.
        shop.closePairing()
        #expect(Self.panel(shop, dismissed: true) == .closed(nil))
        #expect(Self.panel(shop) == .closed(nil), "closed by the owner is not an outcome to announce")
    }

    @Test("before a phone reveals its key there is no number, so the panel keeps waiting")
    func noNumberNoSheet() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        shop.lanPhonePairing = LanConnectorPairing(enabled: true, flavor: .phone)
        shop.lanPairing.open(); shop.lanPhonePairing.open()
        let commit = LanConnectorPairing.commitment(pluginPublic: "x", nonce: "y", flavor: .phone).base64EncodedString()
        _ = try shop.lanPhonePairing.request(commitment: commit, name: "Someone", app: "Khayt iPhone", version: "1",
                                             address: "192.168.1.9", identity: .init(), pollSecret: "s")
        #expect(shop.lanPhonePairing.pending != nil && shop.lanPhonePairing.pending?.check == nil)
        #expect(Self.panel(shop) == .waiting(denied: nil))
        shop.closePairing()
    }

    @Test("approved: paired as the role chosen, said in words; the list follows")
    func approvedSaysTheRole() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        shop.lanDevicesForTests = LanDevices.inMemory()
        let shown = try PhoneRolesTests.waitingPhone(shop)
        let refusal = await shop.approvePhone(role: "operator", pairId: shown.pairId, check: shown.check)
        // The sample's PIN may not be readable off a real book: both endings are said.
        if refusal == nil {
            #expect(Self.panel(shop, role: "operator") == .closed(.paired(name: "Reem's iPhone", role: "operator")))
            let said = PhonePairingUI.sentence(.paired(name: "Reem's iPhone", role: "operator"), words: shop.words)
            #expect(said.text == "Reem's iPhone is paired as Operator." && said.tone == .good)
            #expect(shop.pairedPhones.contains { $0.name == "Reem's iPhone" && $0.codePaired })
        } else {
            #expect(refusal == .pinUnreadable)
            #expect(Self.panel(shop) == .closed(.pinUnreadable))
        }
        shop.closePairing()
    }

    @Test("each ending has its sentence and weight")
    func endings() async {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        #expect(PhonePairingUI.sentence(.timedOut, words: w).text == "Nobody approved in time, so nothing was paired.")
        #expect(PhonePairingUI.sentence(.timedOut, words: w).tone == .plain)
        #expect(PhonePairingUI.sentence(.offersUsed, words: w).tone == .warn)
        #expect(PhonePairingUI.sentence(.offersUsed, words: w).text.hasPrefix("Three phones asked"))
        #expect(PhonePairingUI.sentence(.pinUnreadable, words: w).tone == .bad)
        #expect(PhonePairingUI.sentence(.paired(name: "", role: "viewer"), words: w).text == "Phone is paired as Viewer.")
        // A phone paired with the PIN in the same window keeps the PIN path's sentence.
        #expect(PhonePairingUI.sentence(.paired(name: "Old phone", role: nil), words: w).text == w.callIt("mac.pair_done", ["name": .string("Old phone")]))
        for refusal in [Shop.PhoneRoleRefusal.notAllowed, .roleNotGrantable, .nothingToApprove, .pinUnreadable, .notTheOneShown, .pairedWithPin] {
            let said = PhonePairingUI.refusal(refusal, words: w)
            #expect(!said.isEmpty && !said.hasPrefix("mac."), Comment(rawValue: "\(refusal)"))
        }
    }

    @Test("a paired phone's line: how it was paired, and today or the day it was last seen")
    func sublines() async {
        let shop = await OperatorLockTests.shop(on: false)
        let now = Date()
        let pinPaired = LanDevices.Listed(id: "a", name: "Turki's iPhone", createdAt: now, lastSeenAt: now)
        #expect(PhonePairingUI.subline(pinPaired, now: now, words: shop.words) == "Paired with the PIN, so it is the owner · last seen today")
        var byCode = LanDevices.Listed(id: "b", name: "Workshop iPad", createdAt: now, lastSeenAt: now.addingTimeInterval(-3 * 86_400))
        byCode.codePaired = true; byCode.role = "viewer"; byCode.rolesVersion = 1
        let line = PhonePairingUI.subline(byCode, now: now, words: shop.words)
        #expect(line.hasPrefix("Paired by code · last seen ") && !line.hasSuffix("today"))
    }

    @Test("who may set which role on a paired phone: the owner alone, and only Owner on a PIN-paired phone")
    func settable() async throws {
        let shop = await OperatorLockTests.shop()
        let devices = LanDevices.inMemory()
        shop.lanDevicesForTests = devices
        _ = try PhoneRolesTests.codePaired(devices, role: "operator", name: "Reem's iPhone")
        shop.refreshPairedPhones()
        let reem = try #require(shop.pairedPhones.first { $0.name == "Reem's iPhone" })
        let pinPaired = LanDevices.Listed(id: "pin", name: "Turki's iPhone", createdAt: Date(), lastSeenAt: Date())
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333"), ("OP-m", "2222")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            #expect(await shop.phoneRolesSettable(on: reem).isEmpty, Comment(rawValue: who?.0 ?? "nobody"))
        }
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(Set(await shop.phoneRolesSettable(on: reem)) == ["viewer", "operator", "manager", "owner"])
        #expect(await shop.phoneRolesSettable(on: pinPaired) == ["owner"], "it holds the PIN: nothing less can be held to")
    }

    @Test("removing a phone: whoever may change settings; a manager too, only while pairing by code is on")
    func whoMayRemove() async throws {
        let shop = await OperatorLockTests.shop()
        defer { PhonePairingUI.forcedOn = false }
        for on in [false, true] {
            PhonePairingUI.forcedOn = on
            for who in [nil, ("OP-v", "4444", false), ("OP-x", "3333", false), ("OP-m", "2222", on), ("OP-o", "1111", true)] as [(String, String, Bool)?] {
                shop.lockNow()
                if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
                #expect(shop.mayRemovePhone == (who?.2 ?? false), Comment(rawValue: "\(who?.0 ?? "nobody"), by code \(on)"))
            }
        }
        // The write asks the same question, and says so when it refuses.
        PhonePairingUI.forcedOn = true
        let devices = LanDevices.inMemory()
        shop.lanDevicesForTests = devices
        let peer = try PhoneRolesTests.codePaired(devices, role: "viewer")
        shop.lockNow()
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        shop.moveProblem = nil
        shop.signOutPhone(peer.id)
        #expect(devices.list().contains { $0.id == peer.id }, "an operator removed nothing")
        #expect(LockReviewTests.refused(shop))
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        shop.signOutPhone(peer.id)
        #expect(!devices.list().contains { $0.id == peer.id })
    }

    @Test("off by default: Settings ▸ Online is the screen it was")
    func offByDefault() throws {
        #expect(!PhonePairingUI.forcedOn)
        #expect(PhonePairingUI.on == LanConnectorPairing.phoneCodeEnabled)
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/Shop+PairedPhones.swift"), encoding: .utf8)
        let body = try #require(src.range(of: "if PhonePairingUI.on {"))
        #expect(src[body.upperBound...].prefix(160).contains("PairedPhonesByCode(shop: shop)"))
        #expect(src.contains("classic"), "the screen as it was is still there, drawn when the switch is off")
    }

    @Test("Approve is never the default action, and the number is drawn left to right")
    func approveIsDeliberate() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/PhonePairingViews.swift"), encoding: .utf8)
        #expect(!src.contains(".keyboardShortcut(.defaultAction)"), "Return must not approve a request that has just appeared")
        let number = try #require(src.range(of: "LanConnectorPairing.spaced(asked.check)"))
        #expect(src[number.upperBound...].prefix(260).contains(".environment(\\.layoutDirection, .leftToRight)"))
    }
}
