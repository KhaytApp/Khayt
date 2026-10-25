import AppKit
import Foundation
import SafariServices
import KhaytWebSave

/// The native end of "Save to Khayt" in Safari.
///
/// Safari hands every `browser.runtime.sendNativeMessage` from the extension
/// to this class, in this sandboxed extension, and to nothing else — a web
/// page cannot send one. Each message is checked by `WebSave` and written into
/// the app group's inbox (`WebInbox`), and the answer is the app's own when it
/// comes within a few seconds, or `queued` when it does not: Khayt is not
/// open, and the page is added the next time it is.
///
/// It never opens the book, never fetches anything and never launches the
/// app. The app reads the inbox; this only writes to it.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        // As bytes, so nothing that is not Sendable crosses to the queue.
        let raw = item?.userInfo?[SFExtensionMessageKey]
        let data = raw.flatMap { JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil }
        let box = ContextBox(context)
        // Off the extension's own thread: waiting for the answer sleeps.
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = Self.handle(data)
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            box.context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    /// The context, carried to the queue that answers it. Used there once and
    /// by nothing else, which is the whole of what Sendable would promise.
    private final class ContextBox: @unchecked Sendable {
        let context: NSExtensionContext
        init(_ context: NSExtensionContext) { self.context = context }
    }

    /// The extension's message, answered by the one path the browser host
    /// answers with too (`WebInbox.reply`): checked, written into the inbox,
    /// and the app's answer or `queued`.
    static func handle(_ data: Data?) -> [String: Any] {
        WebInbox.reply(toMessageData: data, browser: "safari", inbox: WebInbox.directory(),
                       appRunning: appIsRunning)
    }

    static var appIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "app.khayt.mac").isEmpty
    }
}
