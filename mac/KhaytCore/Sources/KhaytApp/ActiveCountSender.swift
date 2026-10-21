import Foundation
import SwiftUI
import KhaytCore

/// This Mac's half of the anonymous active-install count (`ActiveCount` in
/// KhaytCore has the rules): the switch, the two stored days, and the send.
///
/// PER INSTALL, not per book: the switch and the days live in this Mac's
/// `UserDefaults`, because the book syncs between machines and one Mac's
/// "counted today" is not another's. ON by default (21 October 2026). A
/// development build sends nothing, as for telemetry.
///
/// Driven by `Telemetry`'s minute tick, which already runs from launch: a
/// ping at launch, and again if the app is still open when the UTC date
/// changes. A failed send waits an hour, then tries again with the same flags.
@MainActor @Observable
final class ActiveCountSender {

    static let shared = ActiveCountSender()

    static let offKey = "activeCount.off"
    static let lastCountedKey = "activeCount.lastCounted"
    static let doneDayKey = "activeCount.doneDay"
    static let retryAfter: TimeInterval = 3600

    /// The policy is live (khayt-website #60, khaytapp.com/privacy
    /// `#active-count-en`, 21 October 2026). Until Khayt Cloud switches the
    /// route on it answers 404, which is a retry an hour later — nothing is
    /// counted and nothing is lost. False sends nothing and hides the switch.
    nonisolated static let READY = true

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var fetch: Telemetry.Fetch = { try await URLSession.shared.data(for: $0) }
    @ObservationIgnored var appVersion: String = Feedback.appVersion().version
    @ObservationIgnored var sendsFromThisBuild = Bundle.main.bundleIdentifier != nil
    @ObservationIgnored var ready = ActiveCountSender.READY
    @ObservationIgnored private var notBefore = Date.distantPast
    @ObservationIgnored private var sending = false

    /// The Settings switch. Stored as "off" so a Mac that never chose is on.
    var enabled: Bool {
        didSet { defaults.set(!enabled, forKey: Self.offKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = !defaults.bool(forKey: Self.offKey)
    }

    var state: ActiveCount.State {
        get {
            ActiveCount.State(lastCounted: defaults.string(forKey: Self.lastCountedKey),
                              doneDay: defaults.string(forKey: Self.doneDayKey))
        }
        set {
            defaults.set(newValue.lastCounted, forKey: Self.lastCountedKey)
            defaults.set(newValue.doneDay, forKey: Self.doneDayKey)
        }
    }

    /// Send today's ping if one is owed. Returns what happened, for a test.
    @discardableResult
    func tick() async -> String {
        guard ready else { return "held" }
        guard enabled else { return "off" }
        guard sendsFromThisBuild else { return "development-build" }
        let at = now()
        guard state.due(now: at) else { return "done" }
        guard at >= notBefore, !sending else { return "waiting" }
        guard ActiveCount.accepts(version: appVersion) else { return "version" }
        sending = true
        defer { sending = false }

        let flags = ActiveCount.flags(lastCounted: state.lastCounted, now: at)
        var request = URLRequest(url: ActiveCount.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ActiveCount.body(platform: "mac", channel: Telemetry.channel(forVersion: appVersion),
                                            version: appVersion, flags: flags)
        let status: Int
        do {
            let (_, response) = try await fetch(request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            status = 0
        }
        let outcome = ActiveCount.outcome(status: status)
        // Switched off while the request was out: keep the days as they were.
        guard enabled else { return "off" }
        state = state.after(outcome, now: at)
        switch outcome {
        case .counted: return "counted"
        case .refused:
            FileHandle.standardError.write(Data("active count: 422 for version \(appVersion)\n".utf8))
            return "refused"
        case .retry:
            notBefore = at.addingTimeInterval(Self.retryAfter)
            return "retry"
        }
    }
}

/// The switch, in Settings ▸ Preferences beside crash reports. Not the
/// book's: it is this Mac's, so a read-only or sample book can still turn it off.
struct ActiveCountSettings: View {
    let shop: Shop
    @Bindable var sender = ActiveCountSender.shared

    var body: some View {
        if sender.ready { toggle }
    }

    private var toggle: some View {
        Section {
            Toggle(isOn: $sender.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shop.words.callIt("mac.active_count"))
                    Text(shop.words.callIt("mac.active_count_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
