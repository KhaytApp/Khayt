import Foundation
import KhaytCore

/// A paired phone's role, and approving a phone that asked to pair by code
/// (phone pairing design, decided Nov 22 2026: D-P1 to D-P7).
///
/// ── WHO MAY GIVE WHICH ROLE ───────────────────────────────────────────────
///
/// The shared rule decides (`lib/device-roles.js grantable`): the owner may
/// give any role, a manager up to manager, anyone else none (D-P3). The
/// person is whoever is at this Mac: with the staff lock off, the owner, as
/// everywhere; with it on, whoever is signed in, and nobody when nobody is.
/// That is about the PERSON approving. The phone's own role is a grant to
/// that device and holds whether the lock is on or off (D-P5).
///
/// APPROVING a phone is open to whoever the rule lets grant a role: an owner
/// or a manager, within what they may grant. OPENING the Pair a phone window
/// is unchanged (`settings`/`edit`, which under the lock is the owner):
/// whether a manager may open it too is a question for Turki. CHANGING a paired
/// phone's role is the owner's alone (`security`/`edit`): a manager must not
/// be able to lift their own phone, or lower the owner's.
///
/// Both gates are asked in the writes. The screens that call these follow
/// their Figma frames; nothing here draws.
extension Shop {

    /// The role of whoever is at this Mac, for `grantable`: the owner with
    /// the lock not in force, the signed-in person's with it, nil when the
    /// lock is in force and nobody is signed in.
    var phoneApproverRole: String? {
        guard lockInForce else { return "owner" }
        guard let op = signedIn else { return nil }
        return lockRole(op.id)
    }

    /// The roles this person may give a phone, most powerful first; empty
    /// when they may give none.
    func phoneRolesGrantable() async -> [String] {
        guard let engine, let approver = phoneApproverRole else { return [] }
        return (try? await engine.deviceRolesGrantable(by: approver)) ?? []
    }

    /// What the approve sheet starts on: the rule's default (Operator, D-P2)
    /// when this person may give it, else the least they may give.
    func phoneDefaultRole() async -> String? {
        let may = await phoneRolesGrantable()
        guard !may.isEmpty, let engine else { return nil }
        let preferred = (try? await engine.deviceDefaultRole()) ?? "operator"
        return may.contains(preferred) ? preferred : may.last
    }

    /// The role a listed phone holds, as the rule reads its record: a phone
    /// paired with the owner PIN before roles is the owner (D-P1).
    func phoneRole(_ phone: LanDevices.Listed) async -> String {
        guard let engine else { return "viewer" }
        let record = KhaytEngine.deviceRecord(kind: phone.kind, role: phone.role, rolesVersion: phone.rolesVersion)
        return (try? await engine.deviceRole(record)) ?? "viewer"
    }

    /// Why an approval or a role change did not happen.
    enum PhoneRoleRefusal: Equatable {
        /// The lock, or nobody signed in.
        case notAllowed
        /// This person may not give that role (`grantable`).
        case roleNotGrantable
        /// No request is waiting with a check number, or the window shut.
        case nothingToApprove
        /// The PIN could not be read, so nothing could be enrolled.
        case pinUnreadable
        /// The request waiting is not the one the person was shown: another
        /// phone asked meanwhile, or the number changed.
        case notTheOneShown
        /// The phone was paired with the owner PIN, so it holds the PIN and
        /// cannot be held to a lesser role. Remove it and pair it by code.
        case pairedWithPin
    }

    /// Approve the phone that asked, with `role`. The numbers were compared
    /// by the person; this enrols the device with the role and no PIN tag.
    /// Returns nil when the phone was paired.
    ///
    /// `pairId` and `check` are the request the person was SHOWN and compared.
    /// The approval is for that request and no other: if something else is
    /// waiting when the button is pressed, nothing is enrolled.
    func approvePhone(role: String, pairId: String, check: String) async -> PhoneRoleRefusal? {
        // Who may approve is the shared rule's answer (`grantable`, D-P3): the
        // owner, or a manager up to manager. Under the staff lock a manager
        // cannot change settings, so asking `settings`/`edit` here would
        // refuse the manager the decision lets approve. Nobody signed in, or a
        // role that may give none, is refused and told so.
        let may = await phoneRolesGrantable()
        guard !may.isEmpty else {
            moveProblem = words.callIt(needsSignIn ? "mac.lock_sign_in_first" : "mac.lock_not_allowed")
            return .notAllowed
        }
        guard may.contains(role) else { return .roleNotGrantable }
        // Only inside the window the person opened: a Pair a phone window that
        // has shut takes the code path with it.
        guard lanPairing.isOpen() else { lanPhonePairing.close(); return .nothingToApprove }
        guard lanPhonePairing.pending?.check != nil else { return .nothingToApprove }
        // The PIN in force now: enrolment makes room among devices tagged
        // with another PIN, so it must be the real one, never "".
        let pin: String
        do { pin = try await Secrets.open(lanConfig.pin, for: source) }
        catch { lanPhonePairing.refuse(.pinUnreadable); return .pinUnreadable }
        let store = lanDeviceStore
        let now = Date()
        // Asked again after the awaits above, on the request as it is now.
        guard let pending = lanPhonePairing.pending, pending.pairId == pairId, pending.check == check else {
            return .notTheOneShown
        }
        var enrolled = false
        try? lanPhonePairing.approve { asked in
            guard asked.pairId == pairId, asked.check == check,
                  let phonePublic = asked.pluginPublic else { throw CancellationError() }
            try store.admitPhone(phonePublic: phonePublic, serverKey: asked.serverKey, deviceId: asked.deviceId,
                                 name: asked.name, role: role, pin: pin, now: now)
            enrolled = true
        }
        refreshPairedPhones()
        if enrolled { lanPairing.close() }
        return enrolled ? nil : .nothingToApprove
    }

    /// The person said the numbers do not match, or does not know the phone.
    func denyPhone() {
        lanPhonePairing.deny()
    }

    /// Change a paired phone's role. The owner's alone, and within what the
    /// rule lets the owner give. Takes effect on the phone's next request.
    func setPhoneRole(_ id: String, _ role: String) async -> PhoneRoleRefusal? {
        guard permitted("security", "edit") else { return .notAllowed }
        guard await phoneRolesGrantable().contains(role) else { return .roleNotGrantable }
        // What may be set on THIS phone is the shared rule's (`settableRoles`):
        // a phone paired with the owner PIN can only be the owner.
        if let phone = lanDeviceStore.list().first(where: { $0.id == id && $0.kind == nil }),
           let engine, let approver = phoneApproverRole {
            let record = KhaytEngine.deviceRecord(kind: phone.kind, role: phone.role, rolesVersion: phone.rolesVersion)
            let settable = (try? await engine.deviceRolesSettable(on: record, by: approver)) ?? []
            guard settable.contains(role) else { return phone.codePaired ? .roleNotGrantable : .pairedWithPin }
        }
        guard lanDeviceStore.setRole(id, role) else { return .nothingToApprove }
        refreshPairedPhones()
        return nil
    }
}
