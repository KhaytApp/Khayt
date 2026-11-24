import Foundation
import LocalAuthentication
import SwiftUI

/// The lock when Khayt opens (Turki, Nov 22; Figma "SIGNED OFF (Turki, Nov 22)
/// · App lock (Face ID / passcode) · iPhone", 265:2).
///
/// - On by default on a phone that holds the shop's book (owner, manager). A
///   floor phone keeps no book, so there is nothing on it to lock.
/// - Khayt locks when it starts, and again after it has been in the
///   background for the chosen time (1 minute by default).
/// - What opens it is the iPhone's own Face ID or passcode
///   (`LocalAuthentication`), never a Khayt PIN: nothing new to remember, and
///   a lost Khayt PIN cannot lock anyone out of their own book.
/// - Widgets, Live Activities and the lock-screen progress are not locked.
enum AppLockRule {
    /// How long Khayt may sit in the background before it locks again.
    enum After: Int, CaseIterable, Identifiable, Sendable {
        case immediately = 0, oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900
        var id: Int { rawValue }
        static let standard: After = .oneMinute
        var labelKey: String {
            switch self {
            case .immediately: return "lock.after.immediately"
            case .oneMinute: return "lock.after.1"
            case .fiveMinutes: return "lock.after.5"
            case .fifteenMinutes: return "lock.after.15"
            }
        }
    }

    /// Whether this phone has a book worth locking by default: a real shop
    /// (not the sample one, not an unpaired phone) on an owner or manager phone.
    static func onByDefault(hasShop: Bool, sampleShop: Bool, holdsBook: Bool) -> Bool {
        hasShop && !sampleShop && holdsBook
    }

    /// The lock in force: the person's own choice when they made one, else the default.
    static func enabled(choice: Bool?, hasShop: Bool, sampleShop: Bool, holdsBook: Bool) -> Bool {
        choice ?? onByDefault(hasShop: hasShop, sampleShop: sampleShop, holdsBook: holdsBook)
    }

    /// Whether coming back to the front locks Khayt: only when it left the
    /// front (`leftAt`), the lock is on, and it was away at least `after`. A
    /// clock set back while away (a negative gap) locks: the time cannot be told.
    static func locksOnReturn(enabled: Bool, after: After, leftAt: Date?, now: Date) -> Bool {
        guard enabled, let leftAt else { return false }
        let away = now.timeIntervalSince(leftAt)
        return away < 0 || away >= TimeInterval(after.rawValue)
    }
}

/// What the iPhone can check, and the check itself. A protocol so a test can
/// stand in for Face ID.
protocol DeviceOwnerChecking: Sendable {
    /// Face ID, Touch ID or Optic ID, when one is set up.
    func biometryName() -> String?
    /// Whether the iPhone has a passcode at all. Without one nothing can be
    /// checked, and Khayt does not lock: there is no lock to open.
    func canCheck() -> Bool
    /// `biometricsOnly`: Face ID alone (the first button). Otherwise Face ID
    /// with the iPhone's passcode as the way out ("Use passcode").
    func check(reason: String, biometricsOnly: Bool) async -> Bool
}

struct LocalAuthenticationChecker: DeviceOwnerChecking {
    func biometryName() -> String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    func canCheck() -> Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    func check(reason: String, biometricsOnly: Bool) async -> Bool {
        let context = LAContext()
        let policy: LAPolicy = biometricsOnly ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: nil) else { return false }
        return (try? await context.evaluatePolicy(policy, localizedReason: reason)) ?? false
    }
}

/// The lock's state for the running app, and this phone's two choices.
@MainActor
final class AppLock: ObservableObject {
    /// The person's own choice; nil while they have made none (the default applies).
    @Published var choice: Bool? {
        didSet {
            if let choice { defaults.set(choice, forKey: Keys.choice) } else { defaults.removeObject(forKey: Keys.choice) }
        }
    }
    @Published var after: AppLockRule.After {
        didSet { defaults.set(after.rawValue, forKey: Keys.after) }
    }
    /// Whether Khayt is locked now.
    @Published private(set) var locked = false
    /// The last check failed (frame L2).
    @Published private(set) var failed = false
    @Published private(set) var checking = false

    private let defaults: UserDefaults
    private let checker: DeviceOwnerChecking
    private var leftAt: Date?
    private var started = false

    private enum Keys {
        static let choice = "khayt.lock.choice"
        static let after = "khayt.lock.after"
    }

    init(defaults: UserDefaults = .standard, checker: DeviceOwnerChecking = LocalAuthenticationChecker()) {
        self.defaults = defaults
        self.checker = checker
        choice = defaults.object(forKey: Keys.choice) as? Bool
        after = (defaults.object(forKey: Keys.after) as? Int).flatMap(AppLockRule.After.init(rawValue:)) ?? .standard
    }

    var biometryName: String? { checker.biometryName() }
    /// False on an iPhone with no passcode: nothing can be checked there.
    var canLock: Bool { checker.canCheck() }

    /// Khayt started: locked from the first frame when the lock is on.
    func start(enabled: Bool) {
        guard !started else { return }
        started = true
        if enabled, canLock { locked = true }
    }

    /// Khayt went to the BACKGROUND (another app, the Home Screen, the
    /// iPhone locked). Merely inactive does not count: the Face ID sheet
    /// itself, Control Centre and Notification Centre make the app inactive,
    /// and counting them re-locked Khayt the moment Face ID succeeded, in a
    /// loop with "Immediately" (review of #2691).
    func wentToBackground(now: Date = Date()) {
        if leftAt == nil { leftAt = now }
    }

    /// Khayt is in front again.
    func cameBack(enabled: Bool, now: Date = Date()) {
        // The iPhone's own check is in front: not a return from anywhere.
        guard !checking else { return }
        defer { leftAt = nil }
        if !locked, canLock, AppLockRule.locksOnReturn(enabled: enabled, after: after, leftAt: leftAt, now: now) {
            locked = true
            failed = false
        }
    }

    /// The person turned the lock off in Settings, which is itself behind the
    /// lock. Nothing else opens Khayt without a check: a role change or a
    /// dropped sign-in while locked leaves it locked (review of #2691).
    func turnedOffInSettings() { choice = false; locked = false; failed = false }

    /// Ask the iPhone. `biometricsOnly` is the first button; the second
    /// ("Use passcode") lets the iPhone's passcode open it.
    func unlock(biometricsOnly: Bool) async {
        guard locked, !checking else { return }
        checking = true
        defer { checking = false }
        if await checker.check(reason: L10n.tr("lock.reason"), biometricsOnly: biometricsOnly) {
            locked = false
            failed = false
            leftAt = nil
        } else {
            failed = true
        }
    }
}

/// "Hide job names on the lock screen" (Turki, Nov 22): off by default. When
/// on, print alerts and the Live Activity say "A print" instead of the job's
/// title or the printer's file name. Kept in the App Group, where the
/// notification and widget extensions read it (`LockScreenPrivacy`).
@MainActor
final class LockScreenNames: ObservableObject {
    @Published var hidden: Bool {
        didSet { defaults?.set(hidden, forKey: LockScreenPrivacy.key) }
    }
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: LockScreenPrivacy.group)) {
        self.defaults = defaults
        hidden = LockScreenPrivacy.hidesJobNames(defaults)
    }
}
