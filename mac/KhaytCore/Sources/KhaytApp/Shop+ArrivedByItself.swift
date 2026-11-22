import Foundation
import UserNotifications
import KhaytCore

/// What the shop is owed when the book changes WITHOUT anybody at this Mac
/// pressing anything: a customer approving their quote on the LAN page, a
/// storefront posting an order.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// Both arrive through `LanServer` and are written straight into the book —
/// correctly — and then nothing else happened. Electron's renderer, told of
/// the same two events by its LAN server, says so on screen and fires the
/// `quote_approved` webhook (`renderer/app-boot.js`). On this Mac the job just
/// appeared under Pending, and a shop that was not looking at the board found
/// out when the customer asked where their print was.
@MainActor
extension Shop {

    /// After a customer's LAN approval has been written: the `quote_approved`
    /// webhook, built by `lib/webhook-bus.js` from the job as approved, and a
    /// line saying it — on screen and, when the app can, as a notification.
    func afterLanApproval(_ approved: JSONValue?) async {
        guard let engine, case .object(let job)? = approved,
              let id = Self.plainString(job["id"]) else { return }
        let settings = settingsDict
        let owed = (try? await engine.webhookDeliveries(
            order: .object(job),
            effects: [WebhookEffect(kind: "webhook", event: "quote_approved", newStatus: nil)],
            settings: DevConnectors.withDev(settings),
            shopName: Self.plainString(settings["bizEn"]) ?? Self.plainString(settings["bizAr"]) ?? "Khayt",
            clientName: Self.emailClientName(for: job, in: clientRows),
            currency: Self.shopCurrencyOf(settings),
            at: ISO8601DateFormatter().string(from: Date()),
            nowMs: Date().timeIntervalSince1970 * 1000)) ?? []
        let said = words.callIt("ord.client_quote_approved", ["id": .string(id)])
        moveNotices = [said]
        Self.notifyArrival(title: Self.plainString(job["project"]) ?? id, body: said, id: "quote-approved:" + id)
        if !owed.isEmpty { await fire(owed) }
    }

    /// After a Salla or Zid order has been written: say it arrived.
    func afterStorefrontOrder(_ platform: String, order: JSONValue?) {
        guard case .object(let job)? = order, let id = Self.plainString(job["id"]) else { return }
        let said = words.callIt(platform == "zid" ? "zidOrderReceived" : "sallaOrderReceived")
        Self.notifyArrival(title: said, body: Self.plainString(job["project"]) ?? id, id: "storefront:" + id)
    }

    /// One macOS notification, when this process can post one at all
    /// (`PrinterNotice.canDeliver`: a test runner or `swift run` cannot).
    static func notifyArrival(title: String, body: String, id: String) {
        guard PrinterNotice.canDeliver else { return }
        Task.detached {
            let centre = UNUserNotificationCenter.current()
            _ = try? await centre.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "arrived"
            try? await centre.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
