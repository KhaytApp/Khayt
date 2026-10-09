import SwiftUI
import KhaytCore

// The operator lock's screens. The rules are in OperatorLock.swift.

// MARK: - The sign-in screen

/// What stands in front of every screen while the lock is in force and nobody
/// is signed in. Plain controls in a fixed-width column: no `GeometryReader`,
/// nothing that measures itself — a new view that does is how this app has
/// hung before.
struct LockScreen: View {
    let shop: Shop
    @State private var who = ""
    @State private var pin = ""
    @State private var code = ""
    @State private var useRecovery = false
    @State private var message: String?
    @State private var busy = false
    @FocusState private var pinFocused: Bool

    /// Everybody who could sign in: active, with a PIN this Mac can check.
    private var people: [ShopOperator] {
        shop.operators.filter { $0.active && shop.pinState($0.id) == .set }
    }

    var body: some View {
        let words = shop.words
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            Text(words.callIt("mac.lock_title"))
                .font(.title2.weight(.semibold))
            Text(words.callIt(useRecovery ? "mac.lock_recovery_hint" : "mac.lock_hint"))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if useRecovery {
                TextField(words.callIt("sec.recovery_ph"), text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(go)
            } else {
                Picker(words.callIt("op.enter_pin"), selection: $who) {
                    ForEach(people) { op in
                        Text(op.role.isEmpty ? op.name : op.name + " · " + op.role).tag(op.id)
                    }
                }
                .labelsHidden()
                SecureField(words.callIt("sec.pin_ph"), text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .focused($pinFocused)
                    .onSubmit(go)
            }
            Button(action: go) {
                Text(words.callIt("mac.lock_sign_in")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || (useRecovery ? code.isEmpty : (pin.isEmpty || who.isEmpty)))
            if let message {
                Text(message)
                    .font(.callout).foregroundStyle(Khayt.late)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(words.callIt(useRecovery ? "mac.lock_use_pin" : "sec.use_recovery")) {
                useRecovery.toggle(); message = nil; pin = ""; code = ""
            }
            .buttonStyle(.link)
            .disabled(!useRecovery && !shop.hasRecoveryCode)
            // THE WAY BACK, said. A shop that never made a recovery code saw a
            // greyed-out link and nothing else, and an owner who forgot their
            // PIN had no idea what to do (alpha.62 review).
            if !useRecovery {
                Text(words.callIt(shop.hasRecoveryCode ? "mac.lock_forgot" : "mac.lock_forgot_no_code"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Khayt.ground)
        .onAppear {
            if who.isEmpty { who = people.first?.id ?? "" }
            pinFocused = true
        }
    }

    private func go() {
        guard !busy else { return }
        busy = true
        Task {
            let result = useRecovery
                ? await shop.signInWithRecovery(code)
                : await shop.signIn(who, pin: pin)
            busy = false
            pin = ""
            message = LockScreen.say(result, shop.words)
            if result == .ok { code = "" }
        }
    }

    /// What a sign-in result tells the person at the pad. Nil for success.
    static func say(_ result: Shop.SignInResult, _ words: Words) -> String? {
        switch result {
        case .ok: nil
        case .wrong: words.callIt("op.wrong_pin")
        case .noPin: words.callIt("mac.lock_no_pin")
        case .elsewhere: words.callIt("op.pin_elsewhere")
        case .unreadable: words.callIt("mac.lock_pin_unreadable")
        case .coolingDown(let until):
            words.callIt("mac.lock_cooling", ["time": .string(words.say(until, .dateTime.hour().minute()))])
        }
    }
}

/// A screen the person signed in may not open — reached by a window restoring
/// onto it, or a shelf that was allowed a moment ago.
struct NotAllowed: View {
    let shop: Shop
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.system(size: 28)).foregroundStyle(.secondary)
            Text(shop.words.callIt("mac.lock_screen_not_allowed"))
                .font(.headline)
                .multilineTextAlignment(.center)
            if let op = shop.signedIn {
                Text(shop.words.callIt("mac.lock_signed_in_as", ["name": .string(op.name)]))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button(shop.words.callIt("mac.lock_switch_person")) { shop.lockNow() }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Khayt.ground)
    }
}

// MARK: - Settings → Operations → Staff sign-in

/// Switch the lock on and off, set PINs, make a recovery code. Owner-level:
/// everyone else sees it and cannot change it.
struct LockSection: View {
    let shop: Shop
    @State private var pinFor: ShopOperator?
    @State private var turningOff = false
    @State private var shown: ShownCode?

    struct ShownCode: Identifiable { let code: String; var id: String { code } }

    var body: some View {
        let words = shop.words
        let canChange = shop.lockAllows("security", "edit") && shop.canWrite
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("mac.lock_section")).font(.headline)
            Text(words.callIt("mac.lock_section_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(status).font(.callout)
                .foregroundStyle(shop.lockSwitchedOn && !shop.lockInForce ? Khayt.late : .primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if shop.lockSwitchedOn {
                    Button(words.callIt("mac.lock_switch_off") + "\u{2026}") { turningOff = true }
                } else {
                    Button(words.callIt("mac.lock_switch_on")) { Task { await shop.switchLockOn() } }
                        .disabled(shop.lockOwners.isEmpty)
                }
                Button(words.callIt(shop.hasRecoveryCode ? "sec.regen_recovery" : "mac.lock_make_recovery") + "\u{2026}") {
                    Task {
                        if let code = await shop.makeRecoveryCode() { shown = ShownCode(code: code) }
                    }
                }
            }
            .disabled(!canChange)
            if !shop.operators.isEmpty {
                Divider()
                ForEach(shop.operators) { op in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(op.name)
                            Text(words.callIt("role." + shop.lockRole(op.id)) + " · " + pinWords(op.id))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(words.callIt(shop.pinState(op.id) == .none ? "mac.lock_set_pin" : "mac.lock_change_pin") + "\u{2026}") {
                            pinFor = op
                        }
                        if shop.pinState(op.id) != .none {
                            Button(words.callIt("mac.lock_clear_pin")) {
                                Task { await shop.setPin(op.id, to: nil) }
                            }
                        }
                    }
                    .disabled(!canChange)
                }
            }
        }
        .sheet(item: $pinFor) { op in SetPinSheet(shop: shop, person: op) }
        .sheet(isPresented: $turningOff) { LockOffSheet(shop: shop) }
        .sheet(item: $shown) { s in RecoveryCodeSheet(shop: shop, code: s.code) }
    }

    private var status: String {
        let words = shop.words
        if !shop.lockSwitchedOn { return words.callIt("mac.lock_status_off") }
        if !shop.lockInForce { return words.callIt("mac.lock_status_not_in_force") }
        if let op = shop.signedIn { return words.callIt("mac.lock_signed_in_as", ["name": .string(op.name)]) }
        return words.callIt("mac.lock_status_on")
    }

    private func pinWords(_ id: String) -> String {
        switch shop.pinState(id) {
        case .none: shop.words.callIt("mac.lock_pin_none")
        case .set: shop.words.callIt("mac.lock_pin_set")
        case .elsewhere: shop.words.callIt("mac.lock_pin_elsewhere_short")
        case .unreadable: shop.words.callIt("mac.lock_pin_unreadable_short")
        }
    }
}

/// Set or change one person's PIN: typed twice, 4 to 8 digits.
struct SetPinSheet: View {
    let shop: Shop
    let person: ShopOperator
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var again = ""

    var body: some View {
        let words = shop.words
        let valid = Shop.isValidPin(pin) && pin == again
        let note: String = {
            if !pin.isEmpty && !Shop.isValidPin(pin) { return "sec.pin_invalid_format" }
            if !again.isEmpty && pin != again { return "mac.lock_pins_differ" }
            return "mac.lock_pin_rule"
        }()
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("mac.lock_pin_for", ["name": .string(person.name)])).font(.headline)
            SecureField(words.callIt("sec.pin_ph"), text: $pin)
                .textFieldStyle(.roundedBorder)
            SecureField(words.callIt("mac.lock_pin_again"), text: $again)
                .textFieldStyle(.roundedBorder)
            Text(words.callIt(note))
                .font(.caption)
                .foregroundStyle(note == "mac.lock_pin_rule" ? AnyShapeStyle(.secondary) : AnyShapeStyle(Khayt.late))
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("common.save")) {
                    Task { await shop.setPin(person.id, to: pin); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Switching the lock off asks for an owner's PIN, even of an owner.
struct LockOffSheet: View {
    let shop: Shop
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("mac.lock_switch_off")).font(.headline)
            Text(words.callIt("mac.lock_off_hint"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(words.callIt("sec.pin_ph"), text: $pin)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
            if let message {
                Text(message).font(.callout).foregroundStyle(Khayt.late)
            }
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("mac.lock_switch_off"), role: .destructive, action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func go() {
        guard !busy, !pin.isEmpty else { return }
        busy = true
        Task {
            let result = await shop.switchLockOff(ownerPin: pin)
            busy = false
            pin = ""
            if result == .ok { dismiss() } else { message = LockScreen.say(result, shop.words) }
        }
    }
}

/// A recovery code, shown once: only its hash is kept.
struct RecoveryCodeSheet: View {
    let shop: Shop
    let code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("mac.lock_recovery_title")).font(.headline)
            Text(words.callIt("mac.lock_recovery_once"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            HStack {
                Spacer()
                Button(words.callIt("mac.lock_recovery_done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Who is signed in, and the way to lock, where the hand already is: under
/// the site picker in both sidebars. On a shared Mac the next person used to
/// act as the previous one without knowing it — the name was only in Settings
/// (alpha.62 review). Nothing at all while the lock is not in force.
struct SignedInRow: View {
    let shop: Shop

    var body: some View {
        if shop.lockInForce, let who = shop.signedIn {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text(shop.words.callIt("mac.lock_signed_in_as", ["name": .string(who.name)]))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button {
                    shop.lockNow()
                } label: {
                    Image(systemName: "lock")
                }
                .buttonStyle(.borderless)
                .help(shop.words.callIt("mac.lock_now"))
                .accessibilityLabel(shop.words.callIt("mac.lock_now"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}
