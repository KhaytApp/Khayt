import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Under the staff lock, the anonymous install count and the crash and usage
/// opt-ins are the owner's to change (decided Nov 22; the desktop: #2636).
/// With the lock off, anyone can, as before.
@Suite(.serialized) @MainActor
struct PrivacyOwnerOnlyTests {

    static func sender() -> ActiveCountSender {
        ActiveCountSender(defaults: UserDefaults(suiteName: "khayt.privacy.test.\(UUID().uuidString)")!)
    }

    @Test("the install count: a manager, an operator, a viewer and nobody signed in are refused in its own words; the owner changes it")
    func installCount() async throws {
        let shop = await OperatorLockTests.shop()
        let sender = Self.sender()
        #expect(sender.enabled)
        for who in [("OP-m", "2222"), ("OP-x", "3333"), ("OP-v", "4444")] {
            shop.lockNow()
            #expect(await shop.signIn(who.0, pin: who.1) == .ok)
            #expect(shop.setInstallCount(false, sender: sender) == false, Comment(rawValue: who.0))
            #expect(sender.enabled, "not changed")
            #expect(shop.privacyProblem == shop.words.callIt("mac.priv_owner_count"))
            #expect(shop.moveProblem == shop.privacyProblem && LockReviewTests.refused(shop))
        }
        shop.lockNow()
        #expect(shop.setInstallCount(false, sender: sender) == false)
        #expect(shop.privacyProblem == shop.words.callIt("mac.lock_sign_in_first"))
        #expect(sender.enabled)
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(shop.setInstallCount(false, sender: sender))
        #expect(!sender.enabled && shop.privacyProblem == nil)
        // Turning it back ON is the owner's too: it is what sends.
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(shop.setInstallCount(true, sender: sender) == false && !sender.enabled)
    }

    @Test("the install count with the lock off: anyone, on any book, as before")
    func installCountLockOff() async {
        let shop = await OperatorLockTests.shop(on: false)
        let sender = Self.sender()
        #expect(shop.setInstallCount(false, sender: sender) && !sender.enabled)
        #expect(shop.setInstallCount(true, sender: sender) && sender.enabled)
        #expect(shop.privacyProblem == nil)
    }

    @Test("crash reports and usage statistics: everyone but the owner is refused, both ways, and told why")
    func optIns() async throws {
        let shop = await OperatorLockTests.shop()
        for who in [("OP-m", "2222"), ("OP-x", "3333"), ("OP-v", "4444")] {
            shop.lockNow()
            #expect(await shop.signIn(who.0, pin: who.1) == .ok)
            for change in [(true, true), (false, false)] {
                shop.privacyProblem = nil; shop.moveProblem = nil
                #expect(await shop.setTelemetry(crash: change.0, usage: change.1) == false, Comment(rawValue: who.0))
                #expect(shop.privacyProblem == shop.words.callIt("mac.priv_owner_telemetry"), "said, not silent")
                #expect(shop.moveProblem == shop.privacyProblem)
            }
        }
        shop.lockNow()
        #expect(await shop.setTelemetry(crash: true) == false)
        #expect(shop.privacyProblem == shop.words.callIt("mac.lock_sign_in_first"))
        // The owner passes the lock; the sample book then has nowhere to write, and that is said too.
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(await shop.setTelemetry(crash: true) == false)
        #expect(shop.privacyProblem == shop.words.callIt("mac.move_sample"))
        #expect(!LockReviewTests.refused(shop), "not a lock refusal, and the earlier one is gone from the shop window")
    }

    @Test("it asks what the outbound switch asks, in the writer; and the install count is no longer bound straight to the switch")
    func wiring() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let telemetry = try String(contentsOf: dir.appending(path: "Telemetry.swift"), encoding: .utf8)
        let at = try #require(telemetry.range(of: "func setTelemetry("))
        let body = telemetry[at.lowerBound...].prefix(1200)
        #expect(body.contains(#"ownerAllowsPrivacy(saying: "mac.priv_owner_telemetry")"#))
        #expect(!body.contains(#"permitted("settings", "edit")"#))
        let count = try String(contentsOf: dir.appending(path: "ActiveCountSender.swift"), encoding: .utf8)
        #expect(!count.contains("Toggle(isOn: $sender.enabled)"), "a bare binding has no owner check")
        #expect(count.contains("shop.setInstallCount("))
        let outbound = try String(contentsOf: dir.appending(path: "Shop+Outbound.swift"), encoding: .utf8)
        let gate = try #require(outbound.range(of: "func ownerAllowsPrivacy("))
        #expect(outbound[gate.lowerBound...].prefix(400).contains(#"lockAllows("security", "edit")"#))
    }
}
