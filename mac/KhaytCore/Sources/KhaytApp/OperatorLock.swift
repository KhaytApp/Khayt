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
//    row close the pad for a minute; after that every wrong one closes it
//    again, for twice as long each time up to fifteen minutes, until a right
//    PIN. Kept in this Mac's defaults, not the book, so quitting does not
//    reset it (the same user can delete those defaults — and can also edit
//    the book's file: the lock is not encryption, see below).
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
    /// Switched on but not yet READ (`lockReady`) counts as in force: the
    /// levels decide who the owners are, and before they are read the answer
    /// was "nobody", which made the lock not in force — open (alpha.62 review).
    var lockInForce: Bool { lockSwitchedOn && (!lockReady || !lockOwners.isEmpty) }

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

    /// What a write to the book IS, to the lock — required by every Shop write
    /// helper (`writeToOneOrder`, `write`, `writeKits`, …), so a new writer
    /// cannot be added without saying. `WritersAreGatedTests` holds every
    /// direct `StoreWriter` call in the app to a `permitted` or a `.system`.
    enum LockGate: Equatable {
        /// A person's action, allowed by `lib/rbac.js` for `area`/`action`.
        case person(_ area: String, _ action: String)
        /// Not a person's action — a merge, a reading, a migration — with why.
        /// Never refused: the lock gates people, not the book keeping itself.
        case system(_ why: String)
    }

    /// `permitted(area, action)` for a gate; a `.system` write passes.
    func permitted(_ gate: LockGate) -> Bool {
        switch gate {
        case .person(let area, let action): permitted(area, action)
        case .system: true
        }
    }

    /// The area a collection's records belong to, for writes that put back
    /// whatever they were given (undo, a sync loss): the most demanding area
    /// any of the records touches is asked. Staff and the lock's own settings
    /// are `security`; anything unknown is the owner's (`settings`).
    static func lockArea(ofCollection c: String) -> String {
        switch c {
        case "printLog", "waitingList", "recurringOrders", "orderTemplates", "presets": "orders"
        case "inventory", "consumables", "products", "suppliers", "purchaseOrders", "purchaseLog",
             "kits", "wasteLog", "machines", "printFiles", "maintenanceTasks", "hub_maint_log_v1": "inventory"
        // Sites are made and removed in Settings (`saveLocation` asks settings).
        case "locations": "settings"
        case "clients", "communications": "clients"
        case "expenses", "giftCards", "invoices": "invoicing"
        case "timeEntries", "activityLog", "auditLog": "logs"
        case "operators": "security"
        default: "settings"
        }
    }

    /// May whoever is here put back records of these collections?
    func permittedRestoring(_ collections: some Sequence<String>) -> Bool {
        for c in Set(collections) where !permitted(Self.lockArea(ofCollection: c), "edit") { return false }
        return true
    }

    /// Every sheet and dialog the window can raise, put away. Called on every
    /// change of who is signed in. The list is every `Shop` flag a
    /// `.sheet`/`.confirmationDialog`/`.alert` is bound to;
    /// `SheetsDismissOnLockTests` reads the sources and fails if one is added
    /// without being put here.
    func dismissEverySheet() {
        addingConsumable = false; addingExpense = false; addingMachine = false; addingSpool = false
        askingTheBook = false; checkingCloud = false; confirmingSignOut = false
        findingPrinters = false; importingSpoolman = false; issuingGiftCard = false
        loggingWaste = false; namingGroup = false; pausingProduction = false
        planningBatch = false; planningCampaign = false; reviewingDeposits = false
        reviewingSyncLosses = false; scanning = false; schedulingWork = false
        sendingFeedback = false; settingUpShop = false; showingOnlineOrders = false
        showingSpoolRepair = false; showingWebStore = false; signingIntoCloud = false
        takingAJob = false
        billingOrder = nil; confirmingCancel = nil; draftingFor = nil; droppingFrom = nil
        editingConsumable = nil; editingCustomer = nil; editingMachine = nil
        editingProduct = nil; editingSpool = nil; editingSupplier = nil; editingTemplate = nil
        loggingPurchaseFor = nil; messagingFor = nil; movingGroups = nil
        pendingCompletion = nil; pendingEdit = nil; pendingHold = nil; pendingInvoice = nil
        pendingLabels = nil; pendingLibraryDelete = nil; pendingPayment = nil
        pendingQcFail = nil; pendingSend = nil; pendingShipment = nil
        planFor = nil; ratingFor = nil; receivingGoods = nil; restoring = nil
        showingHistoryFor = nil; spoolHistoryFor = nil
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
        // No engine, no matrix: NOT ready, so a switched-on lock stays closed.
        // It returned with no roles here, which emptied the owners and made
        // the lock not in force — open on the one failure that should shut it.
        guard let engine else { rbac = nil; lockRoles = [:]; lockReady = false; return }
        rbac = try? await engine.rbac()
        defer { lockReady = rbac != nil }
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

    /// Wrong PINs before the pad cools down.
    static let lockTries = 10

    /// The wrong-PIN record: how many in a row since the last right one, and
    /// when the pad opens again (epoch ms, 0 when it is open).
    ///
    /// CONSECUTIVE, reset only by a right PIN. It reused the LAN server's
    /// windowed bucket, whose count expired a cooldown after the FIRST wrong
    /// PIN — so nine guesses a minute never tripped it, 12,960 a day, and
    /// every four-digit PIN fell inside a day (alpha.62 review). Now ten in a
    /// row close the pad, each closing longer than the last up to fifteen
    /// minutes, and waiting a closing out does not give the ten back.
    struct LockFailures: Equatable { var count: Int; var until: Double }

    func lockFailures() -> LockFailures {
        let rec = lockDefaults.dictionary(forKey: Self.failuresKey)
        return LockFailures(count: rec?["count"] as? Int ?? 0, until: rec?["until"] as? Double ?? 0)
    }

    /// When the pad opens again, if it is cooling down.
    func lockCooldown(now: Date = Date()) async -> Date? {
        let rec = lockFailures()
        let at = now.timeIntervalSince1970 * 1000
        return rec.until > at ? Date(timeIntervalSince1970: rec.until / 1000) : nil
    }

    private func recordWrongPin(now: Date) async {
        let d = lockDefaults
        var rec = lockFailures()
        rec.count += 1
        if rec.count >= Self.lockTries {
            let lockouts = d.integer(forKey: Self.lockoutsKey)
            let ms = min(Self.lockMaxCooldown, Self.lockBaseCooldown * pow(2, Double(lockouts)))
            rec.until = now.timeIntervalSince1970 * 1000 + ms
            // One more try after a cooldown, not ten: the count stays at the
            // threshold until a right PIN, so each wrong one closes it again.
            rec.count = Self.lockTries - 1
            d.set(lockouts + 1, forKey: Self.lockoutsKey)
        }
        d.set(["count": rec.count, "until": rec.until], forKey: Self.failuresKey)
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
        let ok = await PinWork.run { PinHash.verify(pin, stored) }
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
              let fresh = await PinWork.run({ PinHash.hash(pin) })
        else { return }
        // Never fail the sign-in over the upgrade: the PIN was right, and the
        // next correct one tries again.
        // lock: system — the PIN was just verified; this re-hashes that same
        // PIN, guarded on the stored hash not having changed meanwhile.
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
        let ok = await PinWork.run { PinHash.verify(plain, stored) }
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
    /// 4 to 8 digits, typed on any keyboard: Arabic-Indic and Persian
    /// digits count (`PinHash.normalize`), as the Arabic layout types them.
    static func isValidPin(_ pin: String) -> Bool {
        let digits = PinHash.normalize(pin)
        return (4...8).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber }
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
            guard let h = await PinWork.run({ PinHash.hash(pin) })
            else { moveProblem = words.callIt("mac.lock_failed"); return }
            hash = h
        }
        do {
            try StoreWriter.update(build) { root in Self.writePinHash(into: &root, id: id, hash: hash) }
            await load(source)
        } catch { moveProblem = String(describing: error) }
    }

    /// Would this change leave the lock switched on with nobody who can sign
    /// in as the owner? Demoting, deactivating or removing the last such owner
    /// emptied `lockOwners`, the lock stopped being "in force", and every
    /// screen opened — the switch-off that `switchLockOff` asks a PIN for,
    /// done without one (alpha.62 review). `stillOwner` is what the person
    /// will be after the change.
    func leavesNoOwner(_ id: String, stillOwner: Bool) -> Bool {
        guard lockSwitchedOn, !stillOwner else { return false }
        return lockOwners.map(\.id) == [id]
    }

    /// The access level the LOCK will read for this person once `fields` are
    /// saved — not the level the editor shows. A legacy record has no
    /// `roleKey`; the lock reads its job title (`roleFromLegacy`, lock on), so
    /// renaming "Admin" demoted the last owner without touching the level
    /// picker, and the guard asked the picker (alpha.62 re-check). Writing the
    /// shown level on every save is NOT the fix: the editor shows a blank
    /// title as "owner" (the other app's lock-off reading) where the lock
    /// reads "operator", and that would promote people.
    func lockLevelAfterSave(_ id: String, _ fields: ShopOperator.Fields,
                            opened: ShopOperator.Fields?) async -> String {
        // The picker moved: that is an explicit level, and it is written.
        if let opened, opened.roleKey != fields.roleKey { return fields.roleKey }
        if let stored = shopOperator(id)?.roleKey { return stored }
        guard let engine else { return "viewer" }
        return (try? await engine.roleFromLegacy(fields.role, hasLock: true)) ?? "viewer"
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
        // lock: system — gated by an OWNER'S PIN, verified below, not by
        // whoever is signed in: a Mac left signed in is not proof of who is at it.
        if let until = await lockCooldown(now: now) { return .coolingDown(until: until) }
        let hashes = lockOwners.compactMap { rawPinHash($0.id) }
        let ok = await PinWork.run {
            hashes.contains { PinHash.verify(ownerPin, $0) }
        }
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
            // lock: callers — switchLockOn, switchLockOff
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
        guard let hash = await PinWork.run({ PinHash.hash(plain) })
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

/// PIN hashing off the main actor AND off the cooperative pool.
///
/// A PIN check is 200,000 rounds of PBKDF2 — tens of milliseconds of
/// blocking CPU, more on a slow machine. It ran in `Task.detached`, which
/// borrows a cooperative-pool thread for all of it: on a three-thread CI
/// runner, hashes from the lock's tests held the pool while the LAN server's
/// tests waited 22 minutes for a thread and timed out (alpha.62 CI). A
/// dispatch queue and a continuation hold no pool thread while they wait —
/// the pattern memory calls swift-pool-starvation, and `Mesh3MFTests.offMain`.
enum PinWork {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: work()) }
        }
    }
}
