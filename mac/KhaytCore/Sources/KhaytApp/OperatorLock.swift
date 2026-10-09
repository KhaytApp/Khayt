import SwiftUI
import KhaytCore

// MARK: - The operator lock
//
// Staff sign in with a PIN, and their access level decides what they can open
// and change. The other app has had this since 3.x; this is the Mac's.
//
// ── WHAT IS SHARED, AND WHAT IS THIS MAC'S ────────────────────────────────
//
// Shared, so the two apps cannot disagree about who may do what:
//   - the permission matrix, `lib/rbac.js` (read as data, `KhaytEngine.Rbac`);
//   - the role a legacy record without `roleKey` gets, `roleFromLegacy`;
//   - the PIN format, `lib/pin-hash.js` (ported: `PinHash`, held to the
//     module by vectors the module wrote);
//   - the wrong-PIN bucket, `lib/lan-auth.js` `bumpFailure`/`isLockedOut`;
//   - the book's fields: `settings.operatorLockEnabled`, `operators[].pinHash`,
//     `operators[].roleKey`, `settings.recoveryCodeHash`.
//
// This Mac's, each for a stated reason — the other app does differently:
//
// 1. NOBODY SIGNED IN IS LOCKED. The other app reads "no active operator" as
//    the owner, so its "Lock now" (which clears the active operator) unlocks
//    everything. Here, with the lock in force, nobody signed in sees the
//    sign-in screen and nothing else.
// 2. WHO IS SIGNED IN IS NOT IN THE BOOK. The other app keeps it in
//    `settings.activeOperatorId`; this Mac keeps it in memory
//    (`Shop.lockSessionId`), so no copy of the book — a backup, a restore, the
//    other app on the same file — can sign anybody in here.
// 3. EVERY SIGN-IN NEEDS A PIN. The other app lets an operator with no PIN be
//    picked freely; an owner with no PIN would be owner access for anyone.
// 4. THE LOCK IS ONLY IN FORCE WITH AN OWNER WHO CAN SIGN IN — an active
//    operator at owner level with a readable PIN. Switched on without one, it
//    is reported as not in force rather than locking the shop out of its own
//    Mac. Settings says so.
// 5. WRONG PINS ARE THROTTLED, which the other app does not do: ten wrong in a
//    row lock the pad for a minute, doubling each time to fifteen minutes.
//    Kept in this Mac's defaults, not the book, so quitting does not reset it.
// 6. A LEGACY ROLE IS READ WITH THE LOCK ON (`hasLock: true`): a record with
//    no role is an operator, not the owner the other app takes it for.
//
// What this is NOT: encryption. The book is a file on this Mac; anybody who
// can open the file can read it. The lock keeps staff to their own part of the
// app, the way the other app's does.

extension Shop {

    /// The cooldown after the tenth wrong PIN, and its ceiling.
    static let lockBaseCooldown: Double = 60_000
    static let lockMaxCooldown: Double = 15 * 60_000

    /// What a PIN on file is, without ever handing the hash out.
    enum PinState: Equatable { case none, set, elsewhere, unreadable }

    /// `settings.operatorLockEnabled` — what the shop asked for.
    var lockSwitchedOn: Bool {
        if case .bool(true)? = settingsDict["operatorLockEnabled"] { return true }
        return false
    }

    /// An operator's access level under the lock.
    func lockRole(_ id: String) -> String { lockRoles[id] ?? "viewer" }

    func pinState(_ id: String) -> PinState {
        guard let hash = rawPinHash(id), !hash.isEmpty else { return .none }
        if hash == "__KHAYT_MASKED__" { return .elsewhere }
        return PinHash.isManaged(hash) ? .set : .unreadable
    }

    /// The stored hash, read where it is needed and nowhere else.
    private func rawPinHash(_ id: String) -> String? {
        for row in operatorRows {
            guard case .object(let r) = row, case .string(let rid)? = r["id"], rid == id else { continue }
            if case .string(let h)? = r["pinHash"] { return h }
            return nil
        }
        return nil
    }

    /// Owners who could sign in right now.
    var lockOwners: [ShopOperator] {
        operators.filter { $0.active && lockRole($0.id) == "owner" && pinState($0.id) == .set }
    }

    /// Switched on AND somebody can sign in as the owner — see (4) above.
    var lockInForce: Bool { lockSwitchedOn && !lockOwners.isEmpty }

    /// The operator signed in on this Mac, if they still exist and are active.
    var signedIn: ShopOperator? {
        guard let id = lockSessionId, let op = shopOperator(id), op.active else { return nil }
        return op
    }

    /// The sign-in screen stands in front of everything.
    var needsSignIn: Bool { lockInForce && signedIn == nil }

    /// May whoever is at this Mac do `action` in `area`? The one question
    /// every gate asks. Lock not in force: yes, everything, as before. In force
    /// with nobody signed in, or with no matrix to ask: no — closed, not open.
    func lockAllows(_ area: String, _ action: String) -> Bool {
        guard lockInForce else { return true }
        guard let op = signedIn, let rbac else { return false }
        return rbac.can(role: lockRole(op.id), area: area, action: action, lockEnabled: true)
    }

    /// The authority half of a gate: refuse, and say so, rather than write.
    /// Every destructive or privileged write in `Shop` starts with this, so
    /// no path to it — a menu, a shortcut, a sheet — can step around it.
    func permitted(_ area: String, _ action: String) -> Bool {
        if lockAllows(area, action) { return true }
        moveProblem = words.callIt(needsSignIn ? "mac.lock_sign_in_first" : "mac.lock_not_allowed")
        return false
    }

    /// The screen a shelf is gated on, under the lock.
    static func lockArea(of shelf: Shelf) -> String? {
        switch shelf {
        case .reports: "analytics"
        case .customers: "clients"
        default: nil
        }
    }

    /// Read the matrix and every operator's level. With the book, after the
    /// operators are read.
    func refreshLock() async {
        guard let engine else { rbac = nil; lockRoles = [:]; return }
        rbac = try? await engine.rbac()
        var roles: [String: String] = [:]
        for op in operators {
            if let key = op.roleKey {
                roles[op.id] = key
            } else {
                roles[op.id] = (try? await engine.roleFromLegacy(op.role, hasLock: true)) ?? "viewer"
            }
        }
        lockRoles = roles
        // Somebody signed in who has since been removed, deactivated or lost
        // their PIN is signed out — their session was them.
        if let id = lockSessionId, signedIn == nil || pinState(id) != .set { lockSessionId = nil }
    }

    // MARK: Signing in

    enum SignInResult: Equatable {
        case ok, wrong, noPin, elsewhere, unreadable
        case coolingDown(until: Date)
    }

    /// The wrong-PIN record, kept in this Mac's defaults.
    private static let failuresKey = "khayt.lock.failures"
    private static let lockoutsKey = "khayt.lock.lockouts"

    func lockFailures() -> KhaytEngine.LanFailures? {
        let d = lockDefaults
        guard let rec = d.dictionary(forKey: Self.failuresKey),
              let c = rec["count"] as? Double, let r = rec["resetAt"] as? Double else { return nil }
        return KhaytEngine.LanFailures(count: c, resetAt: r)
    }

    /// When the pad opens again, if it is cooling down.
    func lockCooldown(now: Date = Date()) async -> Date? {
        guard let engine, let rec = lockFailures(),
              (try? await engine.lanIsLockedOut(rec, now: now)) == true else { return nil }
        return Date(timeIntervalSince1970: rec.resetAt / 1000)
    }

    private func recordWrongPin(now: Date) async {
        guard let engine else { return }
        let d = lockDefaults
        let lockouts = d.integer(forKey: Self.lockoutsKey)
        let ms = min(Self.lockMaxCooldown, Self.lockBaseCooldown * pow(2, Double(lockouts)))
        guard let next = try? await engine.lanBumpFailure(lockFailures(), now: now, lockoutMs: ms) else { return }
        d.set(["count": next.count, "resetAt": next.resetAt], forKey: Self.failuresKey)
        if (try? await engine.lanIsLockedOut(next, now: now)) == true { d.set(lockouts + 1, forKey: Self.lockoutsKey) }
    }

    private func clearWrongPins() {
        lockDefaults.removeObject(forKey: Self.failuresKey)
        lockDefaults.removeObject(forKey: Self.lockoutsKey)
    }

    /// Sign `id` in with `pin`. A correct PIN on an old unsalted hash is
    /// re-hashed in the salted format — the only moment it can be, since it is
    /// the only moment the PIN is in hand — through the write chain.
    func signIn(_ id: String, pin: String, now: Date = Date()) async -> SignInResult {
        if let until = await lockCooldown(now: now) { return .coolingDown(until: until) }
        switch pinState(id) {
        case .none: return .noPin
        case .elsewhere: return .elsewhere
        case .unreadable: return .unreadable
        case .set: break
        }
        guard let stored = rawPinHash(id), shopOperator(id)?.active == true else { return .noPin }
        // PBKDF2 at 200,000 rounds is a noticeable fraction of a second: off
        // the main actor, so the pad does not freeze while it checks.
        let ok = await Task.detached(priority: .userInitiated) { PinHash.verify(pin, stored) }.value
        guard ok else {
            await recordWrongPin(now: now)
            if let until = await lockCooldown(now: now) { return .coolingDown(until: until) }
            return .wrong
        }
        clearWrongPins()
        lockSessionId = id
        if PinHash.needsUpgrade(stored) { await upgradePin(id, from: stored, pin: pin) }
        return .ok
    }

    /// Sign out. With the lock in force, the sign-in screen comes straight back.
    func lockNow() { lockSessionId = nil }

    private func upgradePin(_ id: String, from stored: String, pin: String) async {
        guard let build = source.build,
              let fresh = await Task.detached(priority: .userInitiated, operation: { PinHash.hash(pin) }).value
        else { return }
        // Never fail the sign-in over the upgrade: the PIN was right, and the
        // next correct one tries again.
        try? StoreWriter.update(build) { root in
            Self.writePinHash(into: &root, id: id, hash: fresh, onlyIf: stored)
        }
        await load(source)
    }

    /// The recovery code, for an owner who has forgotten their PIN: it signs in
    /// as the first owner who could sign in, who should then set a new PIN.
    func signInWithRecovery(_ code: String, now: Date = Date()) async -> SignInResult {
        if let until = await lockCooldown(now: now) { return .coolingDown(until: until) }
        guard case .string(let stored)? = settingsDict["recoveryCodeHash"], PinHash.isManaged(stored),
              let owner = lockOwners.first else { return .noPin }
        let plain = Self.normalizeRecoveryCode(code)
        guard plain.count == 12 else { await recordWrongPin(now: now); return .wrong }
        let ok = await Task.detached(priority: .userInitiated) { PinHash.verify(plain, stored) }.value
        guard ok else {
            await recordWrongPin(now: now)
            if let until = await lockCooldown(now: now) { return .coolingDown(until: until) }
            return .wrong
        }
        clearWrongPins()
        lockSessionId = owner.id
        return .ok
    }

    // MARK: The recovery code (app-security.js's format)

    static let recoveryAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// `KHAYT-XXXX-XXXX-XXXX`, from a CSPRNG.
    static func generateRecoveryCode() -> String? {
        var bytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let chars = bytes.map { recoveryAlphabet[Int($0) % recoveryAlphabet.count] }
        let blocks = stride(from: 0, to: 12, by: 4).map { String(chars[$0..<$0 + 4]) }
        return "KHAYT-" + blocks.joined(separator: "-")
    }

    /// `normalizeRecoveryCode`: upper case, letters and digits only, the
    /// leading KHAYT dropped — what the hash is taken over.
    static func normalizeRecoveryCode(_ code: String) -> String {
        var s = code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if s.hasPrefix("KHAYT") { s.removeFirst(5) }
        return s
    }

    // MARK: Writes (owner only)

    /// 4 to 8 digits — `isValidPin` in the other app.
    static func isValidPin(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func writePinHash(into root: inout [String: JSONValue], id: String, hash: String,
                             onlyIf previous: String? = nil) {
        var rows = Self.rows(root, "operators")
        guard let at = rows.firstIndex(where: { Self.recordId($0) == id }),
              case .object(var r) = rows[at] else { return }
        if let previous {
            guard case .string(let now)? = r["pinHash"], now == previous else { return }
        }
        r["pinHash"] = .string(hash)
        StoreWriter.stamp(&r)
        rows[at] = .object(r)
        root["operators"] = .array(rows)
    }

    /// Set, change or clear (`pin == nil`) someone's PIN.
    ///
    /// Owner-level (`security`/`edit`), and refused when it would leave the
    /// lock switched on with nobody able to sign in as the owner — clearing the
    /// last owner's PIN would quietly switch the lock off.
    func setPin(_ id: String, to pin: String?) async {
        moveProblem = nil
        guard permitted("security", "edit") else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        if let pin, !Self.isValidPin(pin) { moveProblem = words.callIt("sec.pin_invalid_format"); return }
        if pin == nil, lockSwitchedOn, lockOwners.map(\.id) == [id] {
            moveProblem = words.callIt("mac.lock_last_owner"); return
        }
        var hash = ""
        if let pin {
            guard let h = await Task.detached(priority: .userInitiated, operation: { PinHash.hash(pin) }).value
            else { moveProblem = words.callIt("mac.lock_failed"); return }
            hash = h
        }
        do {
            try StoreWriter.update(build) { root in Self.writePinHash(into: &root, id: id, hash: hash) }
            await load(source)
        } catch { moveProblem = String(describing: error) }
    }

    /// Switch the lock on. Needs an owner who can sign in, or it would not be
    /// in force; whoever switches it on then signs in like everybody else.
    func switchLockOn() async {
        moveProblem = nil
        guard permitted("security", "edit") else { return }
        guard !lockOwners.isEmpty else { moveProblem = words.callIt("mac.lock_needs_owner"); return }
        await writeLockSwitch(true)
    }

    /// Switch it off — only with an owner's PIN, even for an owner signed in,
    /// because a Mac left signed in is not proof of who is at it.
    func switchLockOff(ownerPin: String, now: Date = Date()) async -> SignInResult {
        moveProblem = nil
        if let until = await lockCooldown(now: now) { return .coolingDown(until: until) }
        let hashes = lockOwners.compactMap { rawPinHash($0.id) }
        let ok = await Task.detached(priority: .userInitiated) {
            hashes.contains { PinHash.verify(ownerPin, $0) }
        }.value
        guard ok else {
            await recordWrongPin(now: now)
            if let until = await lockCooldown(now: now) { return .coolingDown(until: until) }
            return .wrong
        }
        clearWrongPins()
        await writeLockSwitch(false)
        return .ok
    }

    private func writeLockSwitch(_ on: Bool) async {
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        do {
            try StoreWriter.update(build) { root in
                var settings: [String: JSONValue] = [:]
                if case .object(let s)? = root["settings"] { settings = s }
                settings["operatorLockEnabled"] = .bool(on)
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch { moveProblem = String(describing: error) }
    }

    /// A new recovery code, shown once. Writes its hash the way the other
    /// app's security setup does (and marks security on, so that app's
    /// destructive-action gates ask for it too).
    func makeRecoveryCode() async -> String? {
        moveProblem = nil
        guard permitted("security", "edit") else { return nil }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return nil }
        guard let code = Self.generateRecoveryCode() else { moveProblem = words.callIt("mac.lock_failed"); return nil }
        let plain = Self.normalizeRecoveryCode(code)
        guard let hash = await Task.detached(priority: .userInitiated, operation: { PinHash.hash(plain) }).value
        else { moveProblem = words.callIt("mac.lock_failed"); return nil }
        do {
            try StoreWriter.update(build) { root in
                var settings: [String: JSONValue] = [:]
                if case .object(let s)? = root["settings"] { settings = s }
                settings["recoveryCodeHash"] = .string(hash)
                settings["recoveryCodeCreatedAt"] = .string(Shop.today(Date()))
                settings["securityEnabled"] = .bool(true)
                root["settings"] = .object(settings)
            }
            await load(source)
            return code
        } catch { moveProblem = String(describing: error); return nil }
    }

    var hasRecoveryCode: Bool {
        if case .string(let h)? = settingsDict["recoveryCodeHash"] { return PinHash.isManaged(h) }
        return false
    }
}
