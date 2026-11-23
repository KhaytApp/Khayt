import SwiftUI
import AppKit
import KhaytCore

/// Pairing a phone by code, with a role, and the paired phones with their
/// roles (Figma Qqxg4imtKVgC3TfNGcRGOk, page 26, frames 1 to 7; signed off
/// Nov 22 2026). Settings ▸ Online.
///
/// ── DRAWN ONLY WHILE PAIRING BY CODE IS ON ───────────────────────────────
///
/// `LanConnectorPairing.phoneCodeEnabled` is off until the phone that pairs by
/// code ships. Off, Settings ▸ Online is exactly what it was (`PairedPhones`,
/// `PairAPhone`): the PIN, one line per phone, no roles.
///
/// ── THE VIEWS DRAW; THE SHOP DECIDES ─────────────────────────────────────
///
/// Who may approve, which roles they may give, and what may be set on a phone
/// are `Shop+PhoneRoles` asking the shared rule (`lib/device-roles.js`). The
/// views below are handed the answers and only disable what would be refused.
enum PhonePairingUI {

    /// Whether the page-26 screens are drawn. A snapshot run turns it on for
    /// itself; nothing else does.
    @MainActor static var forcedOn = false
    @MainActor static var on: Bool { forcedOn || LanConnectorPairing.phoneCodeEnabled }

    /// The roles in the order the frames list them: least first.
    nonisolated static let order = ["viewer", "operator", "manager", "owner"]

    /// `roles` (the rule's answer, in any order) as the frames list them.
    nonisolated static func listed(_ roles: [String]) -> [String] {
        order.filter(roles.contains)
    }

    nonisolated static func nameKey(_ role: String) -> String { "mac.prole_" + role }
    nonisolated static func noteKey(_ role: String) -> String { "mac.prole_" + role + "_note" }

    /// A phone that asked, as the sheet shows it.
    struct Asked: Equatable {
        let pairId: String
        let name: String
        let app: String
        let version: String
        let address: String
        /// Six digits, as the rule computed them.
        let check: String
    }

    /// How the last window ended, for the panel.
    enum Ended: Equatable {
        case paired(name: String, role: String?)
        case timedOut
        case offersUsed
        case pinUnreadable
        /// The PIN path's own endings, in its own words (`PairAPhone.outcome`).
        case said(String, warn: Bool)
    }

    /// What the Pair a phone panel shows.
    enum Panel: Equatable {
        /// Nothing open: the button, and how the last window ended.
        case closed(Ended?)
        /// Open, nobody asking. `denied` is the phone just turned down.
        case waiting(denied: String?)
        /// A phone asked and revealed: its number and the role choice.
        case asked(Asked)
    }

    /// The panel for the two windows as they stand. `code` is the code path's
    /// window, `pin` the PIN path's; they open and close together.
    @MainActor
    static func panel(code: LanConnectorPairing, pin: LanPairingWindow, denied: String?, approvedRole: String?,
                      dismissed: Bool, words: Words) -> Panel {
        if code.isOpenNow || pin.deadline != nil {
            if let asked = code.pending, let check = asked.check {
                return .asked(Asked(pairId: asked.pairId, name: asked.name, app: asked.app, version: asked.version,
                                    address: asked.address, check: check))
            }
            return .waiting(denied: denied)
        }
        if dismissed { return .closed(nil) }
        switch code.lastClosed {
        case .paired(let name)?: return .closed(.paired(name: name, role: approvedRole))
        case .offersUsed?: return .closed(.offersUsed)
        case .pinUnreadable?: return .closed(.pinUnreadable)
        case .timedOut?:
            // The PIN path may have paired a phone in the same window.
            if case .paired? = pin.lastClosed { break }
            return .closed(.timedOut)
        case .serverStopped?, .byOwner?, nil: break
        }
        if let said = PairAPhone.outcome(pin.lastClosed, words: words) {
            return .closed(.said(said.text, warn: said.warn))
        }
        return .closed(nil)
    }

    /// The phone's name as shown: its own, or "Phone" when it sent none.
    @MainActor static func shown(_ name: String, _ words: Words) -> String {
        let clean = tidy(name)
        return clean.isEmpty ? words.callIt("mac.phones_unnamed") : clean
    }

    /// A phone's name is whatever the phone sent, and it is drawn beside the
    /// number the person compares. So it is one line and short here whatever
    /// arrived: no line or paragraph separators (which are not control
    /// characters and would draw a second line, say a fake number), no braces
    /// (the sentences it is put into use `{placeholders}`), at most 60
    /// scalars, so a pile of combining marks cannot grow it either.
    nonisolated static func tidy(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar) { out.append(" "); continue }
            if scalar == "{" || scalar == "}" { continue }
            out.append(scalar)
            if out.count >= 60 { break }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    /// The check number as drawn: "418 207" inside a left-to-right isolate, so
    /// its two halves keep their order in a right-to-left sentence or pane.
    nonisolated static func number(_ check: String) -> String {
        "\u{2066}" + LanConnectorPairing.spaced(check) + "\u{2069}"
    }

    /// How long the approve sheet's controls wait after a request appears. A
    /// click already on its way to Stop must not land on a role, or on
    /// Approve, of a request that was not on screen when it was aimed.
    nonisolated static let settle: Duration = .milliseconds(900)

    /// "Khayt iPhone 1.2.0 · 192.168.1.47", leaving out what the phone did not say.
    nonisolated static func from(_ asked: Asked) -> String {
        let app = [tidy(asked.app), tidy(asked.version)].filter { !$0.isEmpty }.joined(separator: " ")
        return [app, asked.address].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The sentence an ending is said in, and its weight.
    @MainActor
    static func sentence(_ ended: Ended, words: Words) -> (text: String, tone: Tone) {
        switch ended {
        case .paired(let name, let role):
            let who = shown(name, words)
            guard let role else { return (words.callIt("mac.pair_done", ["name": .string(who)]), .good) }
            return (words.callIt("mac.ppair_paired", ["name": .string(who), "role": .string(words.callIt(nameKey(role)))]), .good)
        case .timedOut: return (words.callIt("mac.ppair_timed_out"), .plain)
        case .offersUsed: return (words.callIt("mac.ppair_offers_used"), .warn)
        case .pinUnreadable: return (words.callIt("mac.ppair_pin_unreadable"), .bad)
        case .said(let text, let warn): return (text, warn ? .warn : .plain)
        }
    }

    enum Tone { case good, plain, warn, bad }

    /// Under a paired phone's name: how it was paired and when it was last seen.
    @MainActor
    static func subline(_ phone: LanDevices.Listed, now: Date = Date(), words: Words) -> String {
        let seen = Calendar.book.isDate(phone.lastSeenAt, inSameDayAs: now)
            ? words.callIt("mac.phones_today")
            : words.say(phone.lastSeenAt, .dateTime.day().month(.abbreviated))
        return words.callIt(phone.codePaired ? "mac.phones_by_code" : "mac.phones_by_pin", ["date": .string(seen)])
    }

    /// Why an approval or a role change did not happen, said to the person.
    @MainActor
    static func refusal(_ refusal: Shop.PhoneRoleRefusal, words: Words) -> String {
        switch refusal {
        case .notAllowed: words.callIt("mac.lock_not_allowed")
        case .roleNotGrantable: words.callIt("mac.ppair_role_refused")
        case .nothingToApprove: words.callIt("mac.ppair_timed_out")
        case .notEnrolled: words.callIt("mac.ppair_failed")
        case .pinUnreadable: words.callIt("mac.ppair_pin_unreadable")
        case .notTheOneShown: words.callIt("mac.ppair_not_this")
        case .pairedWithPin: words.callIt("mac.phones_role_pin")
        }
    }
}

// MARK: - The role choices (frames 2, 3 and 7)

/// "THIS PHONE MAY": one radio row per role the person may give, with what it
/// opens. A role they may not give is not listed at all.
struct PhoneRoleChoices: View {
    let roles: [String]
    @Binding var role: String
    let words: Words
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(words.callIt("mac.ppair_may"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(PhonePairingUI.listed(roles), id: \.self) { choice in
                Button { role = choice } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: role == choice ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(role == choice ? AnyShapeStyle(Khayt.brand) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(words.callIt(PhonePairingUI.nameKey(choice)))
                                .fontWeight(role == choice ? .medium : .regular)
                            Text(words.callIt(PhonePairingUI.noteKey(choice)))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityAddTraits(role == choice ? .isSelected : [])
                .accessibilityIdentifier("phone-role-" + choice)
            }
        }
    }
}

// MARK: - Pair a phone (frames 1 to 4)

/// The panel alone, drawn from a `Panel` value: the live view below and the
/// snapshot runner both hand it one.
struct PhonePairingPanel: View {
    let panel: PhonePairingUI.Panel
    let words: Words
    /// Seconds left in the window, read on each tick.
    let remaining: () -> TimeInterval
    /// Where a phone reaches this Mac, shown while waiting.
    let address: String?
    /// The roles whoever is here may give, from the rule.
    let grantable: [String]
    @Binding var role: String
    var problem: String?
    var canOpen = true
    var busy = false
    var open: () -> Void = {}
    var stop: () -> Void = {}
    var approve: (PhonePairingUI.Asked) -> Void = { _ in }
    var deny: (PhonePairingUI.Asked) -> Void = { _ in }
    var done: () -> Void = {}
    var openOnline: () -> Void = {}
    /// False only in a capture, which photographs the sheet at once.
    var settles = true
    /// The request whose controls have been on screen long enough to press.
    @State private var settled: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch panel {
            case .asked(let asked):
                askedBody(asked, ready: !settles || settled == asked.pairId)
                    .task(id: asked.pairId) {
                        settled = nil
                        try? await Task.sleep(for: PhonePairingUI.settle)
                        if !Task.isCancelled { settled = asked.pairId }
                    }
            case .waiting(let denied): waitingBody(denied: denied)
            case .closed(let ended): closedBody(ended)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func left() -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(words.callIt("mac.ppair_left", ["time": .string(PairAPhone.clock(remaining(), locale: words.locale))]))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // Frame 1, and the "denied" state of frame 4.
    @ViewBuilder private func waitingBody(denied: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let denied {
                    Text(words.callIt("mac.ppair_denied", ["name": .string(PhonePairingUI.shown(denied, words))]))
                        .lineLimit(2).truncationMode(.middle)
                }
                Text(words.callIt("mac.ppair_waiting")).fontWeight(.medium)
            }
            Spacer(minLength: 8)
            left()
        }
        Text(words.callIt("mac.ppair_how"))
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let address {
            HStack {
                Text(verbatim: address)
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
                Spacer(minLength: 8)
                Button(words.callIt("common.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                }
                .controlSize(.small)
            }
        }
        Divider()
        Text(words.callIt("mac.ppair_note"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer(minLength: 0)
            Button(words.callIt("mac.ppair_stop"), action: stop)
                .accessibilityIdentifier("pair-close")
        }
    }

    // Frames 2 and 3.
    @ViewBuilder private func askedBody(_ asked: PhonePairingUI.Asked, ready: Bool) -> some View {
        // Held while saving, and for a moment after the request appears.
        let held = busy || !ready
        VStack(alignment: .leading, spacing: 2) {
            Text(words.callIt("mac.ppair_asks", ["name": .string(PhonePairingUI.shown(asked.name, words))]))
                .fontWeight(.medium)
                .lineLimit(2).truncationMode(.middle)
            let from = PhonePairingUI.from(asked)
            if !from.isEmpty {
                Text(verbatim: from).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        VStack(spacing: 2) {
            Text(verbatim: PhonePairingUI.number(asked.check))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityIdentifier("phone-check")
            Text(words.callIt("mac.ppair_check"))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        if grantable.isEmpty {
            Text(words.callIt("mac.lock_not_allowed"))
                .font(.callout).foregroundStyle(Khayt.attention)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            PhoneRoleChoices(roles: grantable, role: $role, words: words, disabled: held)
        }
        Divider()
        // An owner is told how to refuse; anyone who may not give Owner is told why it is not listed.
        Text(words.callIt(grantable.contains("owner") ? "mac.ppair_deny_note" : "mac.ppair_owner_only"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            left()
            Spacer(minLength: 8)
            Button(words.callIt("mac.ppair_deny")) { deny(asked) }
                .disabled(held)
                .accessibilityIdentifier("phone-deny")
            // No default action: Return in Settings at the wrong moment must
            // not approve a request that has just appeared (as for a slicer).
            Button(words.callIt("mac.ppair_approve")) { approve(asked) }
                .buttonStyle(.borderedProminent)
                .disabled(held || grantable.isEmpty || !grantable.contains(role))
                .accessibilityIdentifier("phone-approve")
        }
    }

    // Frame 4, and the button when nothing has happened yet.
    @ViewBuilder private func closedBody(_ ended: PhonePairingUI.Ended?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let ended {
                let said = PhonePairingUI.sentence(ended, words: words)
                Text(said.text)
                    .foregroundStyle(Self.colour(said.tone))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch ended {
            case .paired?:
                Button(words.callIt("common.done"), action: done)
            case .pinUnreadable?:
                Button(words.callIt("mac.ppair_open_online"), action: openOnline)
            default:
                Button(words.callIt("mac.pair_open"), action: open)
                    .disabled(!canOpen)
                    .accessibilityIdentifier("pair-open")
            }
        }
    }

    static func colour(_ tone: PhonePairingUI.Tone) -> AnyShapeStyle {
        switch tone {
        case .good: AnyShapeStyle(Khayt.done)
        case .plain: AnyShapeStyle(.primary)
        case .warn: AnyShapeStyle(Khayt.attention)
        case .bad: AnyShapeStyle(Khayt.late)
        }
    }
}

/// The panel, live: the two windows, the rule's roles, and the shop's writes.
struct PairAPhoneByCode: View {
    let shop: Shop
    @State private var role = "operator"
    @State private var grantable: [String] = []
    @State private var denied: String?
    @State private var approvedRole: String?
    @State private var dismissed = false
    @State private var problem: String?
    @State private var busy = false

    private var reachable: Bool { PairAPhone.pretendReachable || (shop.lanURL != nil && shop.lanRunning?.bindLan == true) }

    var body: some View {
        let code = shop.lanPhonePairing, pin = shop.lanPairing
        let panel = PhonePairingUI.panel(code: code, pin: pin, denied: denied, approvedRole: approvedRole,
                                         dismissed: dismissed, words: shop.words)
        VStack(alignment: .leading, spacing: 6) {
            PhonePairingPanel(
                panel: panel, words: shop.words,
                remaining: { code.remaining() ?? pin.remaining() ?? 0 },
                address: shop.lanURL, grantable: grantable, role: $role, problem: problem,
                canOpen: shop.mayOpenPairing && reachable, busy: busy,
                open: {
                    denied = nil; approvedRole = nil; problem = nil; dismissed = false
                    shop.openPairing()
                },
                stop: { shop.closePairing(); dismissed = true },
                approve: { asked in
                    let chosen = role
                    busy = true
                    Task {
                        let refusal = await shop.approvePhone(role: chosen, pairId: asked.pairId, check: asked.check)
                        busy = false
                        if let refusal { problem = PhonePairingUI.refusal(refusal, words: shop.words) }
                        else { approvedRole = chosen; problem = nil; denied = nil }
                    }
                },
                deny: { asked in
                    shop.denyPhone()
                    denied = asked.name
                    problem = nil
                },
                done: { dismissed = true },
                // This panel is in Settings ▸ Online already: going there also
                // puts the Pair a phone button back, or the panel would be
                // stuck on the sentence with no way to try again.
                openOnline: { dismissed = true; problem = nil; shop.settingsPane = .online })
            if shop.lanURL != nil, !reachable {
                Text(shop.words.callIt("mac.pair_loopback"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pin.lockedAddresses > 0, pin.deadline != nil {
                Text(shop.words.callIt("mac.pair_locked_some"))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Whoever is here, and so what they may give: asked of the rule again
        // when the person changes, and each time a phone asks.
        .task(id: Shop.PhoneAsk(person: shop.phoneApproverRole, pairId: code.pending?.pairId)) {
            grantable = await shop.phoneRolesGrantable()
            // Every request starts on the rule's default (Operator), never on
            // what the last phone was given: an owner who paired one phone as
            // Owner must not find Owner already selected for the next.
            role = await shop.phoneDefaultRole() ?? grantable.last ?? "operator"
            // What was said about the last request does not belong under this one.
            if code.pending != nil { denied = nil; problem = nil }
        }
        // Shut each window on time even when no phone asks.
        .task(id: code.deadline ?? pin.deadline) {
            while let left = code.remaining() ?? pin.remaining(), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(left))
            }
            guard !Task.isCancelled else { return }
            _ = code.isOpen(); _ = pin.isOpen()
        }
        // The two paths share one window: when either ends, both do. Watched
        // by count, since the same ending twice running is not a change.
        .onChange(of: code.closes) { _, _ in shop.pairingWindowClosed(); problem = nil }
        .onChange(of: pin.closes) { _, _ in shop.pairingWindowClosed(); problem = nil }
    }
}

extension Shop {
    /// What the role choice depends on: who is at this Mac, and which request.
    struct PhoneAsk: Equatable {
        let person: String?
        let pairId: String?
    }
}

// MARK: - Paired phones, with roles (frames 5 to 7)

/// One paired phone's row, drawn from values: the live list and the snapshot
/// runner both hand it these.
struct PairedPhoneRow: View {
    let phone: LanDevices.Listed
    /// The role the phone HOLDS, as the rule reads its record; nil until it
    /// has been read.
    let role: String?
    /// The roles the person here may set on THIS phone (empty: not changeable).
    let settable: [String]
    let mayRemove: Bool
    let words: Words
    var choose: (String) -> Void = { _ in }
    var remove: () -> Void = {}
    @State private var choosing = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: PhonePairingUI.shown(phone.name, words))
                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(PhonePairingUI.subline(phone, words: words))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(words.callIt("mac.phones_role")).font(.caption).foregroundStyle(.secondary)
            if phone.codePaired {
                // A button that opens the choices with what each opens
                // (frame 7), not a bare menu of four words.
                Button { choosing = true } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: role.map { words.callIt(PhonePairingUI.nameKey($0)) } ?? "\u{2026}")
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .controlSize(.small)
                .disabled(settable.isEmpty || role == nil)
                .accessibilityIdentifier("phone-role-change")
                .shopPopover(isPresented: $choosing, arrowEdge: .bottom) {
                    PhoneRoleMenu(name: PhonePairingUI.shown(phone.name, words), roles: settable, role: role ?? "", words: words) {
                        choosing = false
                        if $0 != role { choose($0) }
                    }
                }
            } else {
                // Paired with the PIN: it holds the PIN, so it is the owner.
                Text(verbatim: role.map { words.callIt(PhonePairingUI.nameKey($0)) } ?? "\u{2026}")
                    .foregroundStyle(settable.isEmpty ? .secondary : .primary)
            }
            Button(words.callIt("mac.phones_sign_out") + "\u{2026}", action: remove)
                .controlSize(.small)
                .disabled(!mayRemove)
        }
    }
}

/// Frame 7: the role choices for one phone, with what each opens.
struct PhoneRoleMenu: View {
    let name: String
    let roles: [String]
    let role: String
    let words: Words
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: name).font(.headline).lineLimit(1).truncationMode(.middle)
            PhoneRoleChoices(roles: roles, role: Binding(get: { role }, set: { choose($0) }), words: words)
            Divider()
            Text(words.callIt("mac.prole_holds"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 440)
    }
}

/// Settings ▸ Online: the paired phones with their roles, then Pair a phone.
struct PairedPhonesByCode: View {
    let shop: Shop
    @State private var removing: LanDevices.Listed?
    /// Each phone's role and what may be set on it, from the rule.
    @State private var roles: [String: String] = [:]
    @State private var settable: [String: [String]] = [:]
    /// The phones whoever is here may remove (`Shop.mayRemovePhone(_:)`).
    @State private var removable: Set<String> = []
    @State private var problem: String?

    var body: some View {
        let mayChange = shop.lockAllows("security", "edit")
        VStack(alignment: .leading, spacing: 10) {
            Text(shop.words.callIt("mac.phones_title")).font(.headline)
            if shop.pairedPhones.isEmpty {
                Text(shop.words.callIt("mac.phones_none")).foregroundStyle(.secondary)
            }
            ForEach(shop.pairedPhones) { phone in
                // Until the rule has been asked, a phone paired by code shows no
                // role rather than a guess; one paired with the PIN is the owner.
                PairedPhoneRow(phone: phone, role: roles[phone.id] ?? (phone.codePaired ? nil : "owner"),
                               settable: mayChange ? (settable[phone.id] ?? []) : [],
                               mayRemove: removable.contains(phone.id), words: shop.words,
                               choose: { role in
                                   Task {
                                       let refusal = await shop.setPhoneRole(phone.id, role)
                                       problem = refusal.map { PhonePairingUI.refusal($0, words: shop.words) }
                                       await readRoles()
                                   }
                               },
                               remove: { removing = phone })
                Divider()
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(shop.words.callIt(mayChange ? "mac.phones_roles_note" : "mac.phones_roles_manager"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PairAPhoneByCode(shop: shop)
        }
        .task(id: Shop.PhoneList(phones: shop.pairedPhones, person: shop.phoneApproverRole)) {
            shop.refreshPairedPhones()
            await readRoles()
        }
        .askFirst($removing,
                  title: { shop.words.callIt("mac.phones_sign_out_q", ["name": .string(PhonePairingUI.shown($0.name, shop.words))]) },
                  message: { _ in shop.words.callIt("mac.phones_sign_out_note") },
                  confirm: shop.words.callIt("mac.phones_sign_out"),
                  cancel: shop.words.callIt("common.cancel")) { phone in
            Task {
                problem = await shop.removePhone(phone.id) ? nil : shop.moveProblem
                await readRoles()
            }
        }
    }

    private func readRoles() async {
        var held: [String: String] = [:], may: [String: [String]] = [:], gone: Set<String> = []
        for phone in shop.pairedPhones {
            held[phone.id] = await shop.phoneRole(phone)
            may[phone.id] = await shop.phoneRolesSettable(on: phone)
            if await shop.mayRemovePhone(phone) { gone.insert(phone.id) }
        }
        roles = held
        settable = may
        removable = gone
    }
}

extension Shop {
    /// What the list's roles depend on: the phones, and who is at this Mac.
    struct PhoneList: Equatable {
        let phones: [LanDevices.Listed]
        let person: String?
    }
}
