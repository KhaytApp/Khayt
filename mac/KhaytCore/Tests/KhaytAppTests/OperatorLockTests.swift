import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The operator lock on the Mac. See OperatorLock.swift for the rules and for
/// where, and why, they differ from the other app's.
///
/// PINs here are hashed at 1,000 rounds rather than 200,000 so the suite stays
/// fast; the format and the check are the same (`PinHashTests` covers the
/// production count against the JavaScript).
/// SERIALIZED: the wrong-PIN record is one per Mac (user defaults), and a
/// test that clears it mid-way through another's ten tries is a race.
@Suite(.serialized) @MainActor
struct OperatorLockTests {

    static func hash(_ pin: String) -> String { PinHash.hash(pin, iterations: 1_000)! }

    static func op(_ id: String, _ name: String, roleKey: String?, role: String = "",
                   pin: String? = nil, pinHash: String? = nil, active: Bool = true) -> JSONValue {
        var r: [String: JSONValue] = ["id": .string(id), "name": .string(name), "role": .string(role),
                                      "active": .bool(active)]
        if let roleKey { r["roleKey"] = .string(roleKey) }
        if let pin { r["pinHash"] = .string(hash(pin)) }
        if let pinHash { r["pinHash"] = .string(pinHash) }
        return .object(r)
    }

    /// Owner Noura (1111), manager Faisal (2222), operator Reem (3333),
    /// viewer Sami (4444).
    static func staff() -> [JSONValue] {
        [op("OP-o", "Noura", roleKey: "owner", pin: "1111"),
         op("OP-m", "Faisal", roleKey: "manager", pin: "2222"),
         op("OP-x", "Reem", roleKey: "operator", pin: "3333"),
         op("OP-v", "Sami", roleKey: "viewer", pin: "4444")]
    }

    static func shop(_ operators: [JSONValue] = staff(), on: Bool = true,
                     extra: [String: JSONValue] = [:]) async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        var settings: [String: JSONValue] = ["operatorLockEnabled": .bool(on)]
        for (k, v) in extra { settings[k] = v }
        // Its own wrong-PIN record: tests run side by side, and a shared one
        // is a race between them.
        shop.lockDefaults = UserDefaults(suiteName: "khayt.lock.test.\(UUID().uuidString)")!
        await shop.useLockFixture(operators: operators, settings: settings)
        return shop
    }

    /// Each shop has a private record (see `shop`); nothing global to clear.
    static func clearThrottle() {}

    // MARK: - One matrix

    @Test("the Mac's lookup is lib/rbac.js's can(), for every role, area and action")
    func matrixParity() async throws {
        let engine = try KhaytEngine()
        let rbac = try await engine.rbac()
        #expect(rbac.roles == ["owner", "manager", "operator", "viewer"])
        let roles = rbac.roles + ["", "OWNER", "admin", "nobody"]
        let areas = rbac.areas + ["", "nope", "ANALYTICS"]
        let actions = rbac.actions + ["", "x", "VIEW"]
        var checked = 0
        for role in roles { for area in areas { for action in actions { for lock in [true, false] {
            let js = try await engine.rbacCan(role: role, area: area, action: action, lockEnabled: lock)
            #expect(rbac.can(role: role, area: area, action: action, lockEnabled: lock) == js,
                    Comment(rawValue: "\(role)/\(area)/\(action)/\(lock)"))
            checked += 1
        } } } }
        #expect(checked > 500)
    }

    @Test("a record with no access level reads with the lock ON: empty is an operator, Admin is the owner")
    func legacyRoles() async {
        let shop = await Self.shop([
            Self.op("OP-a", "A", roleKey: nil, role: "Admin", pin: "1111"),
            Self.op("OP-b", "B", roleKey: nil, role: "", pin: "2222"),
            Self.op("OP-c", "C", roleKey: nil, role: "Technician", pin: "3333"),
        ])
        #expect(shop.lockRole("OP-a") == "owner")
        #expect(shop.lockRole("OP-b") == "operator", "the other app reads this as the owner; not here")
        #expect(shop.lockRole("OP-c") == "operator")
    }

    // MARK: - Off, on, and on-but-not-in-force

    @Test("switched off, everything is allowed and nobody is asked")
    func offIsOpen() async {
        let shop = await Self.shop(on: false)
        #expect(!shop.lockInForce)
        #expect(!shop.needsSignIn)
        #expect(shop.lockAllows("destructive", "create"))
        #expect(shop.canShow(.reports))
    }

    @Test("switched on with no owner who can sign in, it is not in force — the shop is never locked out")
    func notInForceWithoutAnOwnerPin() async {
        for owner in [Self.op("OP-o", "Noura", roleKey: "owner"),
                      Self.op("OP-o", "Noura", roleKey: "owner", pinHash: "__KHAYT_MASKED__"),
                      Self.op("OP-o", "Noura", roleKey: "owner", pinHash: "MTIzNA=="),
                      Self.op("OP-o", "Noura", roleKey: "owner", pin: "1111", active: false)] {
            let shop = await Self.shop([owner, Self.op("OP-x", "Reem", roleKey: "operator", pin: "3333")])
            #expect(shop.lockSwitchedOn)
            #expect(!shop.lockInForce)
            #expect(!shop.needsSignIn)
        }
        let shop = await Self.shop()
        #expect(shop.lockInForce)
        #expect(shop.needsSignIn, "nobody signed in is LOCKED, not the owner")
        #expect(!shop.lockAllows("orders", "view"))
        #expect(!shop.canShow(.reports))
    }

    // MARK: - Signing in

    @Test("a PIN signs its owner in; their level decides the rest; Lock brings the screen back")
    func signInAndLevels() async {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-x", pin: "1111") == .wrong, "another person's PIN")
        #expect(shop.signedIn == nil)

        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        #expect(shop.signedIn?.id == "OP-x")
        #expect(!shop.needsSignIn)
        // An operator: jobs yes, Reports and deleting no, customers to look at.
        #expect(!shop.canShow(.reports))
        #expect(shop.canShow(.customers))
        #expect(shop.lockAllows("orders", "edit"))
        #expect(!shop.lockAllows("orders", "delete"))
        #expect(!shop.permitted("inventory", "delete"))
        #expect(shop.moveProblem != nil, "a refusal says so")

        shop.lockNow()
        #expect(shop.needsSignIn)

        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(shop.canShow(.reports), "a manager reads the reports")
        #expect(shop.lockAllows("settings", "view"))
        #expect(!shop.lockAllows("settings", "edit"), "and changes no settings")
        #expect(!shop.lockAllows("destructive", "create"))

        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(shop.lockAllows("security", "edit"))
        #expect(shop.lockAllows("destructive", "create"))
        Self.clearThrottle()
    }

    @Test("no PIN, a PIN set on another computer, an unreadable one: none of them signs anybody in")
    func noFreeSwitch() async {
        let shop = await Self.shop(Self.staff() + [
            Self.op("OP-n", "NoPin", roleKey: "owner"),
            Self.op("OP-e", "Elsewhere", roleKey: "owner", pinHash: "__KHAYT_MASKED__"),
            Self.op("OP-u", "Old", roleKey: "owner", pinHash: "MTIzNA=="),
        ])
        #expect(await shop.signIn("OP-n", pin: "") == .noPin, "the other app lets this one in for free")
        #expect(await shop.signIn("OP-e", pin: "1234") == .elsewhere)
        #expect(await shop.signIn("OP-u", pin: "1234") == .unreadable)
        #expect(shop.signedIn == nil)
        Self.clearThrottle()
    }

    @Test("ten wrong PINs and the pad cools down — even the right PIN waits")
    func throttle() async {
        let shop = await Self.shop()
        var last: Shop.SignInResult = .ok
        for _ in 0..<10 { last = await shop.signIn("OP-x", pin: "0000") }
        guard case .coolingDown(let until) = last else {
            Issue.record("no cooldown after ten wrong PINs: \(last)"); Self.clearThrottle(); return
        }
        #expect(until > Date())
        #expect(await shop.signIn("OP-x", pin: "3333") != .ok)
        #expect(shop.signedIn == nil)
        // Kept in this Mac's defaults, not in memory: quitting does not reset it.
        #expect(shop.lockDefaults.dictionary(forKey: "khayt.lock.failures") != nil)
        Self.clearThrottle()
    }

    @Test("signed-in person removed or deactivated: signed out")
    func sessionFollowsTheBook() async {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        var staff = Self.staff()
        staff[2] = Self.op("OP-x", "Reem", roleKey: "operator", pin: "3333", active: false)
        await shop.useLockFixture(operators: staff, settings: ["operatorLockEnabled": .bool(true)])
        #expect(shop.signedIn == nil)
        #expect(shop.needsSignIn)
        Self.clearThrottle()
    }

    // MARK: - Switching off, and the recovery code

    @Test("switching off needs an owner's PIN, even when an owner is signed in")
    func offNeedsAnOwnerPin() async {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(await shop.switchLockOff(ownerPin: "2222") == .wrong, "a manager's PIN is not an owner's")
        #expect(shop.lockSwitchedOn)
        Self.clearThrottle()
    }

    @Test("a recovery code has the other app's shape, and signs in as an owner who can")
    func recoveryCode() async throws {
        let code = try #require(Shop.generateRecoveryCode())
        #expect(code.wholeMatch(of: /KHAYT-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}/) != nil)
        let plain = Shop.normalizeRecoveryCode(code)
        #expect(plain.count == 12)
        #expect(Shop.normalizeRecoveryCode(" khayt-" + plain.lowercased()) == plain)

        let shop = await Self.shop(extra: ["recoveryCodeHash": .string(Self.hash(plain))])
        #expect(shop.hasRecoveryCode)
        #expect(await shop.signInWithRecovery("KHAYT-AAAA-AAAA-AAAA") == .wrong)
        #expect(await shop.signInWithRecovery(code.lowercased()) == .ok)
        #expect(shop.lockRole(try #require(shop.signedIn).id) == "owner")
        Self.clearThrottle()
    }

    // MARK: - Writes

    @Test("a PIN is written as a salted hash, and an upgrade never overwrites a PIN changed meanwhile")
    func pinWrites() {
        var root: [String: JSONValue] = ["operators": .array(Self.staff())]
        let fresh = Self.hash("9999")
        Shop.writePinHash(into: &root, id: "OP-x", hash: fresh)
        guard case .object(let r)? = Shop.rows(root, "operators").first(where: { Shop.recordId($0) == "OP-x" }),
              case .string(let stored)? = r["pinHash"] else { Issue.record("not written"); return }
        #expect(PinHash.verify("9999", stored))
        #expect(r["rev"] != nil, "stamped, so the other app's merge sees it")
        // The upgrade path names the hash it read; a different one is left alone.
        Shop.writePinHash(into: &root, id: "OP-x", hash: Self.hash("1"), onlyIf: "not-what-is-there")
        guard case .object(let after)? = Shop.rows(root, "operators").first(where: { Shop.recordId($0) == "OP-x" })
        else { return }
        #expect(after["pinHash"] == .string(stored))
        #expect(Shop.isValidPin("1234") && Shop.isValidPin("12345678"))
        #expect(!Shop.isValidPin("123") && !Shop.isValidPin("123456789") && !Shop.isValidPin("12a4")
                && !Shop.isValidPin("١٢٣٤"))
    }

    @Test("the customer link answers to the lock: nobody signed in, or a viewer, cannot publish, unpublish or reply")
    func portalAnswersToTheLock() async throws {
        let shop = await Self.shop()
        let job = try #require(shop.orders.first?.id)
        // Locked: nobody signed in.
        #expect(await shop.publishPortal(job) == nil)
        #expect(shop.moveProblem != nil)
        await shop.unpublishPortal(job)
        #expect(shop.moveProblem != nil)
        await #expect(throws: (any Error).self) { try await shop.replyOnPortal(job, text: "hello") }
        // A viewer reads orders and edits nothing.
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)
        #expect(!shop.lockAllows("orders", "edit"))
        #expect(await shop.publishPortal(job) == nil)
        #expect(shop.moveProblem == shop.words.callIt("mac.lock_not_allowed"))
        // An operator gets past the LOCK — and on to the portal's own checks
        // (this sample has no cloud), which is the next refusal, not this one.
        shop.lockNow()
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        _ = await shop.publishPortal(job)
        #expect(shop.moveProblem != shop.words.callIt("mac.lock_not_allowed"))
        #expect(shop.moveProblem != shop.words.callIt("mac.lock_sign_in_first"))
    }

    @Test("every privileged write refuses while nobody is signed in")
    func writesRefuseWhenLocked() async {
        let shop = await Self.shop()
        for (area, action) in [("inventory", "delete"), ("clients", "edit"), ("settings", "edit"),
                               ("security", "edit"), ("destructive", "create"), ("cloud", "edit"),
                               ("orders", "edit"), ("invoicing", "edit"), ("logs", "delete")] {
            shop.moveProblem = nil
            #expect(!shop.permitted(area, action), Comment(rawValue: "\(area)/\(action)"))
            #expect(shop.moveProblem != nil)
        }
        Self.clearThrottle()
    }
}
