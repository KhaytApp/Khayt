import Foundation

/// Finding the shop's Mac again after its address has changed.
///
/// ── THE ADDRESS IS A LEASE, NOT A NAME ──────────────────────────────────
///
/// Pairing resolves the Mac's Bonjour name to an IP and stores the IP, because
/// that is what a request needs. But a router hands addresses out on a lease:
/// restart it, or let the Mac sleep through a renewal, and the Mac comes back
/// on a different one — while the phone goes on knocking at the old door and
/// reports the shop as away. Seen on a real shop the morning after pairing.
///
/// So when the stored address stops answering, the phone looks the Mac up by
/// the NAME it was paired with, and if the name now resolves somewhere else,
/// moves there. It never picks a different Mac: only the paired name counts.
@MainActor
enum MacFinder {
    /// Browse for `name` for up to `timeout` seconds and resolve it.
    static func find(named name: String, timeout: TimeInterval = 4) async -> (host: String, port: Int)? {
        let browser = ShopBrowser()
        browser.start()
        defer { browser.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let shop = browser.shops.first(where: { $0.id == name }) {
                guard let found = await browser.resolve(shop, timeout: 3) else { return nil }
                return (found.host, Int(found.port))
            }
            if browser.failure != nil { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }
}
