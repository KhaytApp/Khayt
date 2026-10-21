import Foundation
import KhaytCore
import StoreKit

/// The iPhone's half of the anonymous daily install count.
///
/// The rules (the day, the flags, the six-field body, what an answer means)
/// are KhaytCore's `ActiveCount`, the same code the Mac sends by. Here are
/// only the phone's parts: the switch, where the two dates are kept, the
/// release channel, and when to send. Once a UTC day at most, when the app
/// opens or comes back to the front.
@MainActor
final class ActiveCountSender {
    /// Whether the count is sent at all, and Settings shows its switch.
    /// khaytapp.com/privacy `#active-count` describes it (live 21 October
    /// 2026). Until the cloud route is switched on it answers 404, which is
    /// an ordinary retry an hour later, so nothing is counted and nothing
    /// is shown to the person.
    static let ready = true

    private let settings: ConnectionSettings
    private let defaults: UserDefaults
    private let session: URLSession
    private let isReady: Bool
    private let channel: () async -> String?
    private var sending = false
    /// After a failed try: wait an hour, as the Mac does, rather than on
    /// every return to the front.
    private var retryNotBefore: Date?

    private enum Keys {
        static let lastCounted = "khayt.activeCount.lastCounted"
        static let doneDay = "khayt.activeCount.doneDay"
    }

    init(settings: ConnectionSettings, defaults: UserDefaults = .standard, session: URLSession = .shared,
         ready: Bool = ActiveCountSender.ready, channel: @escaping () async -> String? = ActiveCountSender.releaseChannel) {
        self.settings = settings
        self.defaults = defaults
        self.session = session
        self.isReady = ready
        self.channel = channel
    }

    var state: ActiveCount.State {
        get { ActiveCount.State(lastCounted: defaults.string(forKey: Keys.lastCounted),
                                doneDay: defaults.string(forKey: Keys.doneDay)) }
        set {
            defaults.set(newValue.lastCounted, forKey: Keys.lastCounted)
            defaults.set(newValue.doneDay, forKey: Keys.doneDay)
        }
    }

    /// Send today's ping if it is owed. Switched off: nothing, and the dates
    /// stay, so switching back on is not a new install.
    func tick(now: Date = Date()) async {
        guard isReady, settings.countInstall, !sending, state.due(now: now) else { return }
        if let wait = retryNotBefore, now < wait { return }
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              ActiveCount.accepts(version: version) else { return }
        sending = true
        defer { sending = false }
        // No channel, a build from Xcode, say: not an install to count.
        guard let channel = await channel() else { return }
        let flags = ActiveCount.flags(lastCounted: state.lastCounted, now: now)
        var request = URLRequest(url: ActiveCount.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ActiveCount.body(platform: "ios", channel: channel, version: version, flags: flags)
        let status = ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        let outcome = ActiveCount.outcome(status: status)
        state = state.after(outcome, now: now)
        switch outcome {
        case .retry: retryNotBefore = now.addingTimeInterval(3600)
        case .refused:
            retryNotBefore = nil
            print("[ActiveCount] 422: the cloud refused this phone's body")
        case .counted: retryNotBefore = nil
        }
    }

    /// TestFlight installs are signed in the sandbox, App Store ones in
    /// production (`AppTransaction.environment`). A debug build, or one
    /// StoreKit cannot place, sends nothing.
    nonisolated static func releaseChannel() async -> String? {
        #if DEBUG
        return nil
        #else
        guard let result = try? await AppTransaction.shared else { return nil }
        let environment: AppStore.Environment
        switch result {
        case .verified(let t): environment = t.environment
        case .unverified(let t, _): environment = t.environment
        }
        switch environment {
        case .sandbox: return "beta"
        case .production: return "stable"
        default: return nil
        }
        #endif
    }
}
