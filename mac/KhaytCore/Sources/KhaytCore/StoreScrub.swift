import Foundation

/// Copies of a secret that must not exist, removed on every write.
///
/// `lib/store-secret-paths.js` `DROP_PATHS`, mirrored here because the write
/// path (`StoreWriter`) runs without the engine, on the phone too. The list is
/// pinned to the JavaScript one by `StoreScrubTests`, so the two cannot drift.
///
/// `settings.webhooks.subscriptions[].secret`: `migrateLegacyWebhooks` used to
/// copy the shop's signing secret onto every migrated subscription, and the
/// desktop saved what it migrated — so the real secret sat in a path that is
/// neither sealed on disk nor masked for a phone. A subscription with no
/// secret signs with `settings.webhooks.secret`, so removing the copy changes
/// no signature.
public enum StoreScrub {

    /// The paths, as `DROP_PATHS` spells them.
    public static let dropPaths = ["settings.webhooks.subscriptions[].secret"]

    /// Remove every value at a drop path, in place. Returns how many went.
    @discardableResult
    public static func dropStrays(_ root: inout [String: JSONValue]) -> Int {
        guard case .object(var settings)? = root["settings"],
              case .object(var webhooks)? = settings["webhooks"],
              case .array(var subs)? = webhooks["subscriptions"] else { return 0 }
        var dropped = 0
        for i in subs.indices {
            guard case .object(var sub) = subs[i], sub["secret"] != nil else { continue }
            sub.removeValue(forKey: "secret")
            subs[i] = .object(sub)
            dropped += 1
        }
        guard dropped > 0 else { return 0 }
        webhooks["subscriptions"] = .array(subs)
        settings["webhooks"] = .object(webhooks)
        root["settings"] = .object(settings)
        return dropped
    }
}
