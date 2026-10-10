import ActivityKit
import Foundation
import KhaytCore

/// Hands this phone's Live Activity push tokens to Khayt Cloud, so the
/// activities keep moving while the app is closed (khayt-cloud #112,
/// "Live Activities" in docs/api-contract.md).
///
/// Two kinds of token, both from ActivityKit and never from UserNotifications:
///
/// - **start** — `Activity.pushToStartTokenUpdates`, one per app. With it the
///   cloud can START an activity when the Mac sees a print begin, even with the
///   phone in a pocket. It is registered only while Live Activities are on in
///   Settings; switching them off withdraws it, or the shop's printers would
///   keep putting activities on a Lock Screen that asked for none.
/// - **update** — `activity.pushTokenUpdates`, one per running activity, sent
///   with its machine. It is withdrawn when the activity ends on the phone.
///
/// An activity the CLOUD started arrives through `Activity.activityUpdates`,
/// and its update token is handled exactly like one the app started.
///
/// A token that came before this phone was signed in to the cloud is kept, and
/// `sendAll()` registers it after the sign-in.
@MainActor
final class LiveActivityPush {
    private weak var api: KhaytAPIClient?
    private let enabled: () -> Bool

    /// The push-to-start token, hex.
    private(set) var startToken: String?
    /// Each running activity's update token, by activity id.
    private(set) var updateTokens: [String: (machineId: String, hex: String)] = [:]
    private var watched: Set<String> = []
    private var tasks: [Task<Void, Never>] = []

    init(api: KhaytAPIClient, enabled: @escaping () -> Bool) {
        self.api = api
        self.enabled = enabled
    }

    /// Start listening. Called once, at launch.
    func begin() {
        tasks.append(Task { [weak self] in
            for await data in Activity<PrintActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                let hex = Self.hex(data)
                let old = self.startToken
                self.startToken = hex
                if let old, old != hex { await self.api?.deleteLiveActivityToken(hex: old) }
                if self.enabled() { await self.api?.putLiveActivityToken(kind: .start, hex: hex, machineId: nil) }
            }
        })
        for activity in Activity<PrintActivityAttributes>.activities { watch(activity) }
        tasks.append(Task { [weak self] in
            for await activity in Activity<PrintActivityAttributes>.activityUpdates {
                self?.watch(activity)
            }
        })
    }

    /// Follow one activity: register each token it is given, and withdraw the
    /// last one when it ends.
    func watch(_ activity: Activity<PrintActivityAttributes>) {
        let id = activity.id
        guard watched.insert(id).inserted else { return }
        let machineId = activity.attributes.machineId
        tasks.append(Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self else { return }
                let hex = Self.hex(data)
                // Apple: "invalidate the previous, now-outdated token" on a new one.
                if let old = self.updateTokens[id]?.hex, old != hex { await self.api?.deleteLiveActivityToken(hex: old) }
                self.updateTokens[id] = (machineId, hex)
                await self.api?.putLiveActivityToken(kind: .update, hex: hex, machineId: machineId)
            }
        })
        tasks.append(Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self else { return }
                if let gone = self.updateTokens.removeValue(forKey: id) {
                    await self.api?.deleteLiveActivityToken(hex: gone.hex)
                }
                return
            }
        })
    }

    /// Register everything held: after a sign-in, and after Live Activities
    /// are switched back on.
    func sendAll() async {
        guard let api else { return }
        if let startToken, enabled() { await api.putLiveActivityToken(kind: .start, hex: startToken, machineId: nil) }
        for (_, t) in updateTokens { await api.putLiveActivityToken(kind: .update, hex: t.hex, machineId: t.machineId) }
    }

    /// Live Activities switched off: the cloud must not start any more.
    func withdrawStart() async {
        guard let startToken else { return }
        await api?.deleteLiveActivityToken(hex: startToken)
    }

    nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

extension KhaytAPIClient {
    enum LiveActivityTokenKind: String { case start, update }

    /// The `PUT …/live-activity/tokens` body. Pure, for the tests.
    nonisolated static func liveActivityTokenBody(kind: LiveActivityTokenKind, hex: String, machineId: String?,
                                                  bundleId: String, env: String) -> [String: String] {
        var body = ["kind": kind.rawValue, "token": hex, "bundleId": bundleId, "env": env]
        if kind == .update, let machineId { body["machineId"] = machineId }
        return body
    }

    /// Best effort, like `registerForPush`: a refusal leaves the activity
    /// running on the countdown it already has. A viewer is never registered.
    func putLiveActivityToken(kind: LiveActivityTokenKind, hex: String, machineId: String?) async {
        guard let session = cloud, session.canWrite,
              var request = try? CloudReader.request(
                CloudReader.Connection(url: session.url, shopId: session.shopId, storedToken: ""),
                token: session.token, method: "PUT", tail: "/live-activity/tokens") else { return }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.liveActivityTokenBody(
            kind: kind, hex: hex, machineId: machineId,
            bundleId: Bundle.main.bundleIdentifier ?? "com.khaytapp.companion", env: Self.pushEnvironment))
        _ = try? await CloudReader.session.data(for: request)
    }

    func deleteLiveActivityToken(hex: String) async {
        guard let session = cloud,
              let request = try? CloudReader.request(
                CloudReader.Connection(url: session.url, shopId: session.shopId, storedToken: ""),
                token: session.token, method: "DELETE", tail: "/live-activity/tokens/" + hex) else { return }
        _ = try? await CloudReader.session.data(for: request)
    }
}
