import Foundation
import SafariServices
import Testing
@testable import KhaytApp

/// beta.7: opening Settings › Preferences trapped (SIGTRAP).
///
/// `BrowserExtensionSettings` is a `View`, so it is main-actor, and the reply
/// it handed `SFSafariExtensionManager` inherited that. Safari answers on its
/// own XPC queue, Swift 6 checks a closure's isolation on entry, and the app
/// died. The snapshot pass never saw it because it pretends Safari's answer.
///
/// Neither test here is on the main actor, on purpose: both call from where
/// Safari calls.
@Suite struct SafariStateIsolationTests {

    @Test("the reply handed to Safari runs on a queue that is not main without trapping")
    func replyRunsOffMain() async {
        let state = await withCheckedContinuation { (done: CheckedContinuation<BrowserExtensionSettings.SafariState, Never>) in
            let reply = BrowserExtensionSettings.safariReply(done)
            // Exactly what Safari does: call it from its own serial queue.
            DispatchQueue(label: "test.SafariServices.ExtensionHelper").async {
                #expect(!Thread.isMainThread)
                reply(nil, NSError(domain: SFErrorDomain, code: 1))
            }
        }
        #expect(state == .notFound)
    }

    @Test("the open-settings reply also runs off main without trapping")
    func ignoredReplyRunsOffMain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "test.SafariServices.open").async {
                BrowserExtensionSettings.ignoredReply(nil)
                done.resume()
            }
        }
    }

    /// The real API, unpretended: an identifier Safari has never heard of
    /// still gets its answer on the XPC queue, which is the path that
    /// trapped. If this Mac's Safari service does not answer at all (a
    /// headless runner), the race gives up after ten seconds — the trap,
    /// had it come, would have taken the whole process with it first.
    @Test("asking the real Safari from off the main actor returns instead of trapping")
    func realSafariOffMain() async {
        BrowserExtensionSettings.pretendSafari = nil
        let answer: BrowserExtensionSettings.SafariState? = await withTaskGroup(of: BrowserExtensionSettings.SafariState?.self) { group in
            group.addTask { await Task.detached { await BrowserExtensionSettings.askSafari("app.khayt.test.no-such-extension") }.value }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let answer { #expect(answer == .notFound) }
    }
}
