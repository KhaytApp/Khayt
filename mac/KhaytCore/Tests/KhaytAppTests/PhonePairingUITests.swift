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
        // The window's own approval, with no PIN in the way: paired, and said with the role.
        let again = try PhoneRolesTests.waitingPhone(shop)
        _ = again
        shop.lanPhonePairing.approve { _ in }
        shop.pairingWindowClosed()
        #expect(Self.panel(shop, role: "manager") == .closed(.paired(name: "Reem's iPhone", role: "manager")))
        #expect(shop.lanPairing.deadline == nil, "the PIN path shut with it")
        #expect(Self.panel(shop, role: "manager", dismissed: true) == .closed(nil), "Done puts the button back")
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
        #expect(PhonePairingUI.refusal(.notEnrolled, words: w) != PhonePairingUI.refusal(.nothingToApprove, words: w),
                "a failed write is not said as a timeout")
        for refusal in [Shop.PhoneRoleRefusal.notAllowed, .roleNotGrantable, .nothingToApprove, .pinUnreadable, .notTheOneShown, .pairedWithPin, .notEnrolled] {
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

    @Test("removing a phone: the owner any phone; a manager only a code-paired phone at Manager or below, and only while pairing by code is on")
    func whoMayRemove() async throws {
        let shop = await OperatorLockTests.shop()
        defer { PhonePairingUI.forcedOn = false }
        let devices = LanDevices.inMemory()
        shop.lanDevicesForTests = devices
        _ = try PhoneRolesTests.codePaired(devices, role: "viewer", name: "Viewer phone")
        _ = try PhoneRolesTests.codePaired(devices, role: "manager", name: "Manager phone")
        _ = try PhoneRolesTests.codePaired(devices, role: "owner", name: "Owner by code")
        shop.refreshPairedPhones()
        func phone(_ name: String) throws -> LanDevices.Listed { try #require(shop.pairedPhones.first { $0.name == name }) }
        let pinPaired = LanDevices.Listed(id: "pin", name: "Turki's iPhone", createdAt: Date(), lastSeenAt: Date())
        var slicer = LanDevices.Listed(id: "orca", name: "Orca", createdAt: Date(), lastSeenAt: Date())
        slicer.kind = LanDevices.kindConnector

        // The switch off: only whoever may change settings, as it was.
        PhonePairingUI.forcedOn = false
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(await shop.mayRemovePhone(try phone("Viewer phone")) == false)

        PhonePairingUI.forcedOn = true
        // A manager: a phone a manager could have paired, and nothing else.
        #expect(await shop.mayRemovePhone(try phone("Viewer phone")))
        #expect(await shop.mayRemovePhone(try phone("Manager phone")))
        #expect(await shop.mayRemovePhone(try phone("Owner by code")) == false, "not a phone holding Owner")
        #expect(await shop.mayRemovePhone(pinPaired) == false, "not the owner's PIN-paired phone")
        #expect(await shop.mayRemovePhone(slicer) == false, "a slicer is not a phone")
        // The write asks the same question on the stored record, and says so.
        let ownerPhone = try phone("Owner by code")
        shop.moveProblem = nil
        #expect(await shop.removePhone(ownerPhone.id) == false)
        #expect(devices.list().contains { $0.id == ownerPhone.id }, "a manager did not remove the owner's phone")
        #expect(LockReviewTests.refused(shop))
        let viewerPhone = try phone("Viewer phone")
        #expect(await shop.removePhone(viewerPhone.id))
        #expect(!devices.list().contains { $0.id == viewerPhone.id })

        // An operator, a viewer and nobody: nothing.
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            let managerPhone = try phone("Manager phone")
            #expect(await shop.mayRemovePhone(managerPhone) == false, Comment(rawValue: who?.0 ?? "nobody"))
            #expect(await shop.removePhone(managerPhone.id) == false)
            #expect(devices.list().contains { $0.id == managerPhone.id })
        }
        // The owner: any phone.
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(await shop.mayRemovePhone(pinPaired))
        #expect(await shop.removePhone(ownerPhone.id))
        // The classic sign-out is still settings-only, and never removes a slicer.
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        let left = try phone("Manager phone")
        shop.signOutPhone(left.id)
        #expect(devices.list().contains { $0.id == left.id }, "the old button's write did not widen")
    }

    @Test("the two paths share one window: when either ends, both do, even when it ends the same way twice")
    func windowsCloseTogether() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        shop.lanDevicesForTests = LanDevices.inMemory()
        for round in 1...2 {
            shop.lanPhonePairing = round == 1 ? LanConnectorPairing(enabled: true, flavor: .phone) : shop.lanPhonePairing
            shop.lanPairing.open(); shop.lanPhonePairing.open()
            let before = (shop.lanPairing.closes, shop.lanPhonePairing.closes)
            // The PIN path ends (here: the person's own Stop on that window alone).
            shop.lanPairing.close()
            #expect(shop.lanPairing.closes == before.0 + 1, "counted every time, round \(round)")
            shop.pairingWindowClosed()
            #expect(!shop.lanPhonePairing.isOpenNow, "the code path shut with it, round \(round)")
            #expect(shop.lanPhonePairing.closes == before.1 + 1)
        }
        // The other way: the code path ends, the PIN path follows.
        shop.lanPairing.open(); shop.lanPhonePairing.open()
        shop.lanPhonePairing.refuse(.pinUnreadable)
        shop.pairingWindowClosed()
        #expect(shop.lanPairing.deadline == nil)
        #expect(Self.panel(shop) == .closed(.pinUnreadable), "and the real ending is the one said")
        // Twice running, the same ending: still counted, still said.
        let closes = shop.lanPhonePairing.closes
        shop.lanPairing.open(); shop.lanPhonePairing.open()
        shop.lanPhonePairing.refuse(.pinUnreadable)
        #expect(shop.lanPhonePairing.closes == closes + 1)
        shop.pairingWindowClosed()
        #expect(shop.lanPairing.deadline == nil && Self.panel(shop) == .closed(.pinUnreadable))
        // Nothing open: asking again changes nothing.
        shop.pairingWindowClosed()
        #expect(shop.lanPairing.deadline == nil && !shop.lanPhonePairing.isOpenNow)
    }

    @Test("a name is one short line whatever the phone sent, and the number keeps its order")
    func namesAreTidied() async {
        let shop = await OperatorLockTests.shop(on: false)
        #expect(PhonePairingUI.tidy("Reem's iPhone") == "Reem's iPhone")
        #expect(PhonePairingUI.tidy("Reem\u{2028}418 207") == "Reem 418 207", "a line separator does not start a second line")
        #expect(PhonePairingUI.tidy("A\nB\u{2029}C\u{0085}D") == "A B C D")
        #expect(PhonePairingUI.tidy("{role} {name}") == "role name", "no placeholders to expand")
        #expect(PhonePairingUI.tidy("a\u{202E}b") == "a b", "no direction override")
        #expect(PhonePairingUI.tidy(String(repeating: "e\u{0301}", count: 500)).unicodeScalars.count <= 60)
        #expect(PhonePairingUI.shown("\u{2028}\u{2029}", shop.words) == shop.words.callIt("mac.phones_unnamed"))
        let said = PhonePairingUI.sentence(.paired(name: "X {role}", role: "viewer"), words: shop.words).text
        #expect(said == "X role is paired as Viewer.")
        let number = PhonePairingUI.number("418207")
        #expect(number.unicodeScalars.first == "\u{2066}" && number.unicodeScalars.last == "\u{2069}")
        #expect(number.contains("418") && number.contains("207"))
        let asked = PhonePairingUI.Asked(pairId: "p", name: "n", app: "Khayt\u{2028}Fake", version: "1.2.0", address: "192.168.1.47", check: "1")
        #expect(PhonePairingUI.from(asked) == "Khayt Fake 1.2.0 · 192.168.1.47")
    }

    @Test("off by default: nothing turns the screens on but the Mac's own switch, and the old screen is the other branch")
    func offByDefault() throws {
        #expect(!PhonePairingUI.forcedOn, "no test or capture left it on")
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        // Only a test sets `forcedOn`: no source file does, so no build can ship with the screens forced.
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("PhonePairingUI.forcedOn = "), Comment(rawValue: file.lastPathComponent))
            #expect(!text.contains("forcedOn = true"), Comment(rawValue: file.lastPathComponent))
        }
        let src = try String(contentsOf: dir.appending(path: "Shop+PairedPhones.swift"), encoding: .utf8)
        let branch = try #require(src.range(of: "if PhonePairingUI.on {"))
        let after = src[branch.upperBound...].prefix(120)
        #expect(after.contains("PairedPhonesByCode(shop: shop)") && after.contains("} else {") && after.contains("classic"))
        // The old screen's own rows are still in the file, under `classic`.
        let classic = try #require(src.range(of: "@ViewBuilder private var classic: some View {"))
        #expect(src[classic.upperBound...].contains("PairAPhone(shop: shop)"))
        #expect(src[classic.upperBound...].contains("shop.signOutPhone(phone.id)"))
    }

    @Test("Approve is never the default action, and the number is drawn left to right")
    func approveIsDeliberate() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/PhonePairingViews.swift"), encoding: .utf8)
        #expect(!src.contains(".keyboardShortcut(.defaultAction)"), "Return must not approve a request that has just appeared")
        let number = try #require(src.range(of: "PhonePairingUI.number(asked.check)"))
        #expect(src[number.upperBound...].prefix(260).contains(".environment(\\.layoutDirection, .leftToRight)"))
        // The controls wait a moment after a request appears, and a new request starts on the default role.
        #expect(src.contains("askedBody(asked, ready: !settles || settled == asked.pairId)"))
        #expect(src.contains("role = await shop.phoneDefaultRole() ?? grantable.last ?? \"operator\""))
    }

    /// "Sign out" is the one word for taking a phone off, in every app
    /// (Turki, Nov 22). The list says it, asks with it and confirms with it;
    /// "Remove" is not said of a phone anywhere.
    @Test("a paired phone is signed out, in those words, in every language")
    func signOutIsTheWord() async throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let view = try String(contentsOf: sources.appending(path: "PhonePairingViews.swift"), encoding: .utf8)
        #expect(view.contains(#"words.callIt("mac.phones_sign_out") + "\u{2026}""#))
        #expect(view.contains(#"callIt("mac.phones_sign_out_q""#) && view.contains(#"confirm: shop.words.callIt("mac.phones_sign_out")"#))
        #expect(!view.contains("phones_remove"))
        let words = try String(contentsOf: sources.appending(path: "Words.swift"), encoding: .utf8)
        #expect(!words.contains("\"mac.phones_remove"), "the retired keys are gone")
        #expect(words.contains(#""mac.phones_sign_out": ["en": "Sign out", "ar": "تسجيل الخروج"]"#))
        // The sentences beside the list say the same word.
        for key in ["mac.phones_roles_note", "mac.phones_roles_manager", "mac.phones_role_pin"] {
            let line = try #require(words.split(separator: "\n").first { $0.contains("\"\(key)\"") })
            #expect(line.contains("sign") && !line.lowercased().contains("remove"), Comment(rawValue: key))
            #expect(!line.contains("إزال") && !line.contains("أزل"), Comment(rawValue: key + " (ar)"))
        }
        // A paired slicer too: one word for taking any paired device off.
        #expect(words.contains(#""mac.apps_remove": ["en": "Sign out", "ar": "تسجيل الخروج"]"#))
        #expect(words.contains(#""mac.apps_remove_q": ["en": "Sign out “{name}”?""#))
        let folder = sources.appending(path: "Resources")
        let gone = ["Entfernen", "entfernen", "Quitar", "quítalo", "quites", "Retirer", "retirez", "retiriez", "削除", "Remover", "remova", "removê", "Kaldır", "kaldır", "移除"]
        for lang in ["de", "es", "fr", "ja", "pt-BR", "tr", "zh"] {
            let data = try Data(contentsOf: folder.appending(path: "mac-words-\(lang).json"))
            let table = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(table["mac.phones_remove"] == nil && table["mac.phones_remove_q"] == nil, Comment(rawValue: lang))
            // The slicer's button says what the phone's does, word for word.
            #expect(table["mac.apps_remove"] == table["mac.phones_sign_out"], Comment(rawValue: lang))
            #expect(table["mac.apps_remove_q"] == table["mac.phones_sign_out_q"], Comment(rawValue: lang))
            for key in ["mac.phones_roles_note", "mac.phones_roles_manager", "mac.phones_role_pin"] {
                let said = try #require(table[key], Comment(rawValue: lang + " " + key))
                #expect(!gone.contains { said.contains($0) }, Comment(rawValue: "\(lang) \(key): \(said)"))
            }
        }
    }
}
