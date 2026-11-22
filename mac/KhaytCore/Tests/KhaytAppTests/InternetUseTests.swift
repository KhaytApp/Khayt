import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Internet use page (Figma page 27): the rows are the rule's, in the
/// frames' order; the Mac adds only "not set up", the counts, and the words.
@Suite(.serialized) @MainActor
struct InternetUseTests {

    static func rows(offline: Bool, keep: [String] = [], telemetry: Bool = false, local: OutboundGate.Local = .init()) -> [OutboundGate.Row] {
        let gate = OutboundGate()
        var settings: [String: JSONValue] = ["network": .object(["offline": .bool(offline), "keep": .array(keep.map(JSONValue.string))])]
        if telemetry { settings["telemetry"] = .object(["crashOptIn": .bool(true), "usageOptIn": .bool(true)]) }
        gate.update(local: local)
        gate.update(book: .settings(.object(settings)))
        return gate.rows()
    }

    @Test("every purpose the rule lists has a place in the frames' order, except the tunnel the Mac does not have")
    func orderCoversTheRule() {
        let listed = Set(InternetUse.order)
        #expect(listed == Set(OutboundPurpose.allCases).subtracting([.tunnel]))
        #expect(InternetUse.order.count == listed.count, "no purpose twice")
        #expect(InternetUse.order.first == .updates && InternetUse.order.last == .lan)
        let webhooks = InternetUse.order.firstIndex(of: .webhooks)!
        #expect(InternetUse.order[webhooks + 1] == .storefront, "Online store after Webhooks (decided Nov 22)")
    }

    @Test("switch off: everything set up is Allowed, the opt-ins read Off by their own switch, and there is no Keep column")
    func switchOff() {
        let lines = InternetUse.lines(rows: Self.rows(offline: false), offline: false, notSetUp: [.webhooks], blocked: [:])
        func state(_ p: OutboundPurpose) -> InternetUse.State? { lines.first { $0.purpose == p }?.state }
        #expect(lines.map(\.purpose) == InternetUse.order)
        #expect(state(.updates) == .allowed && state(.cloud) == .allowed)
        #expect(state(.crashReports) == .ownSwitch && state(.usageStats) == .ownSwitch)
        #expect(state(.webhooks) == .notSetUp)
        #expect(state(.lan) == .always)
        #expect(!lines.contains { $0.keepShown })
        #expect(lines.allSatisfy { $0.blocked == nil })
    }

    @Test("switch on: blocked rows carry their count, a kept one reads Kept, Not set up wins over Blocked, the network row has no tick")
    func switchOn() {
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let lines = InternetUse.lines(rows: Self.rows(offline: true, keep: ["storage"], telemetry: true), offline: true,
                                      notSetUp: [.webhooks, .taxAuthority],
                                      blocked: [.updates: .init(count: 2, last: at), .storage: .init(count: 9, last: at)])
        func line(_ p: OutboundPurpose) -> InternetUse.Line { lines.first { $0.purpose == p }! }
        #expect(line(.updates).state == .blocked && line(.updates).blocked?.count == 2)
        #expect(line(.storage).state == .kept && line(.storage).kept && line(.storage).blocked == nil, "a kept row shows no old count")
        #expect(line(.webhooks).state == .notSetUp && line(.taxAuthority).state == .notSetUp)
        #expect(line(.crashReports).state == .blocked, "opted in, and the switch refuses it")
        #expect(line(.lan).state == .always && !line(.lan).keepShown)
        #expect(lines.filter { $0.purpose != .lan }.allSatisfy { $0.keepShown })
        #expect(line(.ai).automatic == false && line(.updates).automatic)
    }

    @Test("this Mac's own switch blocks the same rows, and the install count's own switch reads Off")
    func hereAndInstallCount() {
        let lines = InternetUse.lines(rows: Self.rows(offline: false, local: .init(offline: true, installCountOff: true)),
                                      offline: true, notSetUp: [], blocked: [:])
        #expect(lines.first { $0.purpose == .cloud }?.state == .blocked)
        // The rule says the switch first: without being told otherwise the count reads Blocked.
        #expect(lines.first { $0.purpose == .installCount }?.state == .blocked)
        // Told its own switch is off, the row says that, online or not (frame A).
        let told = InternetUse.lines(rows: Self.rows(offline: true), offline: true, notSetUp: [],
                                     ownOff: [.installCount, .crashReports], blocked: [.crashReports: .init(count: 3, last: Date())])
        #expect(told.first { $0.purpose == .installCount }?.state == .ownSwitch)
        #expect(told.first { $0.purpose == .crashReports }?.state == .ownSwitch)
        #expect(told.first { $0.purpose == .crashReports }?.blocked == nil)
        #expect(told.first { $0.purpose == .usageStats }?.state == .blocked)
        let online = InternetUse.lines(rows: Self.rows(offline: false, local: .init(offline: false, installCountOff: true)),
                                       offline: false, notSetUp: [], blocked: [:])
        #expect(online.first { $0.purpose == .installCount }?.state == .ownSwitch)
        #expect(online.first { $0.purpose == .cloud }?.state == .allowed)
    }

    @Test("Keep ticks belong to the shop's switch: under this Mac's own switch alone none is drawn, and a kept row is not called Kept")
    func keepNeedsTheShopSwitch() {
        // Only this Mac's switch, with something kept in the book from before.
        let hereOnly = InternetUse.lines(rows: Self.rows(offline: false, keep: ["storage"], local: .init(offline: true)),
                                         offline: true, shopOffline: false, notSetUp: [], blocked: [:])
        #expect(!hereOnly.contains { $0.keepShown })
        #expect(hereOnly.first { $0.purpose == .storage }?.state == .blocked, "this Mac's switch is answered before keep")
        // Both on: the ticks are the shop's and are drawn; this Mac still blocks.
        let both = InternetUse.lines(rows: Self.rows(offline: true, keep: ["storage"], local: .init(offline: true)),
                                     offline: true, shopOffline: true, notSetUp: [], blocked: [:])
        #expect(both.first { $0.purpose == .storage }?.keepShown == true)
        #expect(both.first { $0.purpose == .storage }?.state == .blocked)
    }

    @Test("the shop's switch is read as the rule reads it: malformed is on, null is off, this Mac's own switch is not the shop's")
    func shopSwitchIsTheRules() {
        func gate(_ network: JSONValue?, here: Bool = false) -> OutboundGate {
            let g = OutboundGate()
            g.update(local: .init(offline: here))
            g.update(book: .settings(.object(network.map { ["network": $0] } ?? [:])))
            return g
        }
        #expect(!gate(nil).isShopOffline)
        #expect(gate(.object(["offline": .bool(true)])).isShopOffline)
        #expect(!gate(.object(["offline": .null])).isShopOffline)
        #expect(gate(.string("x")).isShopOffline, "a malformed block fails closed, and the switch drawn says so")
        let here = gate(nil, here: true)
        #expect(here.isOffline && !here.isShopOffline)
    }

    @Test("the 30-day count runs only while a switch refuses updates: not for an online shop, not while the book is unread")
    func bannerOnlyUnderTheSwitch() async {
        let shop = await OperatorLockTests.shop(on: false)
        let gate = OutboundGate()
        shop.outboundGate = gate
        shop.outboundDefaults = UserDefaults(suiteName: "khayt.outbound.test.\(UUID().uuidString)")!
        let now = Date()
        #expect(shop.daysWithoutUpdates(now: now) == nil)
        gate.update(book: .unread)
        #expect(shop.daysWithoutUpdates(now: now) == nil, "starting is not a refusal by the switch")
        gate.update(book: .settings(.object(["network": .object(["offline": .bool(true), "keep": .array([.string("updates")])])])))
        #expect(shop.daysWithoutUpdates(now: now) == nil, "kept")
    }

    @Test("a name from the shared book is cut to a name's length; a refusal that names a host is never put on every screen")
    func bounded() async throws {
        #expect(InternetUse.switchedBy(["changedBy": .string(String(repeating: "a", count: 500))])?.count == 60)
        let shop = await OperatorLockTests.shop(on: false)
        shop.noteOutboundRefusal(.init(purpose: .ai, reason: "lan-host-public", host: "internal.example"), sentence: "x internal.example")
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.outboundNotice == nil)
    }

    @Test("days without updates: nil while allowed; counted from the last check that went out, else from when the switch was turned on")
    func updateDays() {
        let now = Date(timeIntervalSince1970: 1_795_000_000), day = 86_400.0
        #expect(InternetUse.daysWithoutUpdates(allowed: true, lastChecked: now.addingTimeInterval(-40 * day), switchedAt: nil, now: now) == nil)
        #expect(InternetUse.daysWithoutUpdates(allowed: false, lastChecked: now.addingTimeInterval(-32 * day - 60), switchedAt: now.addingTimeInterval(-40 * day), now: now) == 32)
        // Last checked two months ago, switch turned on today: no days yet, and no banner at once.
        #expect(InternetUse.daysWithoutUpdates(allowed: false, lastChecked: now.addingTimeInterval(-60 * day), switchedAt: now, now: now) == 0)
        // A stamp from the future (another computer's clock) is read as now.
        #expect(InternetUse.daysWithoutUpdates(allowed: false, lastChecked: nil, switchedAt: now.addingTimeInterval(9 * day), now: now) == 0)
        #expect(InternetUse.daysWithoutUpdates(allowed: false, lastChecked: nil, switchedAt: now.addingTimeInterval(-29.9 * day), now: now) == 29)
        #expect(InternetUse.daysWithoutUpdates(allowed: false, lastChecked: nil, switchedAt: nil, now: now) == nil)
        #expect(InternetUse.daysWithoutUpdates(allowed: false, lastChecked: now.addingTimeInterval(day), switchedAt: nil, now: now) == 0, "a clock set back is not negative days")
        #expect(InternetUse.bannerAfterDays == 30)
    }

    @Test("the book's stamp: read with or without fractional seconds; no name while the lock is off")
    func stamp() {
        #expect(InternetUse.switchedAt(["changedAt": .string("2026-11-21T14:02:00.000Z")]) != nil)
        #expect(InternetUse.switchedAt(["changedAt": .string("2026-11-21T14:02:00Z")]) != nil)
        #expect(InternetUse.switchedAt(["changedAt": .null]) == nil && InternetUse.switchedAt([:]) == nil)
        #expect(InternetUse.switchedBy(["changedBy": .null]) == nil && InternetUse.switchedBy(["changedBy": .string("")]) == nil)
        #expect(InternetUse.switchedBy(["changedBy": .string("Sara Example")]) == "Sara Example")
    }

    @Test("the line under the switch says who really follows it (frames F1–F3)")
    func shopLine() async {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let off = InternetUse.sentence(.init(), words: w)
        #expect(off == w.callIt("mac.net_who_mac") + " " + w.callIt("mac.net_off_tail"))
        let notTold = InternetUse.sentence(.init(offline: true, by: "Sara Example", at: at), words: w)
        #expect(notTold.hasPrefix(w.callIt("mac.net_who_mac")) && notTold.contains("Sara Example"))
        #expect(notTold.hasSuffix(w.callIt("mac.net_not_told")))
        #expect(!notTold.contains("next sync"), "nothing is promised that this Mac does not do")
        let anon = InternetUse.sentence(.init(offline: true, at: at), words: w)
        #expect(!anon.contains("{name}") && !anon.contains(" by "))
        let told = InternetUse.sentence(.init(offline: true, tellsOthers: true, by: "Sara Example", at: at, told: .told(at)), words: w)
        #expect(told.hasPrefix(w.callIt("mac.net_who_shop")) && told.hasSuffix(w.callIt("mac.net_phones_follow")))
        #expect(!told.contains(w.callIt("mac.net_not_told")))
        let failed = InternetUse.sentence(.init(offline: true, tellsOthers: true, at: at, told: .failed), words: w)
        #expect(failed.contains(w.callIt("mac.net_tell_failed")))
        // The option on, and no telling tried yet: it does not claim one.
        let pending = InternetUse.sentence(.init(offline: true, tellsOthers: true, at: at), words: w)
        #expect(pending.contains(w.callIt("mac.net_not_told")))
        for text in [off, notTold, told, failed, pending] { #expect(!text.contains("{") && !text.contains("mac.net_")) }
    }

    @Test("telling the other computers: hidden and off until its call is wired; the owner's alone when offered")
    func tellOthers() async {
        #expect(Shop.tellOthersOffered == false, "flip this only with the wiring that makes the call")
        let shop = await OperatorLockTests.shop()
        shop.outboundDefaults = UserDefaults(suiteName: "khayt.outbound.test.\(UUID().uuidString)")!
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(shop.setOutboundTellsOthers(true) == false && LockReviewTests.refused(shop))
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(shop.setOutboundTellsOthers(true))
        #expect(shop.outboundDefaults.bool(forKey: Shop.tellOthersKey))
        #expect(!shop.outboundTellsOthers, "stored, and still not acted on while the row is not offered")
    }

    @Test("a refusal of something a person asked for is noted for every screen; an automatic one is not")
    func notice() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        shop.noteOutboundRefusal(.init(purpose: .cloud, reason: "offline"), sentence: "x")
        shop.noteOutboundRefusal(.init(purpose: .exchangeRates, reason: "settings-unknown"), sentence: "x")
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.outboundNotice == nil)
        let said = shop.outboundSentence(.init(purpose: .exchangeRates, reason: "offline"))
        shop.noteOutboundRefusal(.init(purpose: .exchangeRates, reason: "offline"), sentence: said)
        try await Task.sleep(for: .milliseconds(50))
        #expect(shop.outboundNotice == said)
        #expect(Shop.askedFor.allSatisfy { p in Self.rows(offline: false).first { $0.purpose == p.rawValue }?.automatic == false },
                "the rule calls each of these person-started")
    }

    @Test("every row has its words in the shop's language: a title, a description, and a consequence where one is drawn")
    func words() async {
        let shop = await OperatorLockTests.shop(on: false)
        for purpose in InternetUse.order {
            let title = InternetUse.title(purpose, shop.words)
            #expect(!title.isEmpty && !title.hasPrefix("mac."), Comment(rawValue: purpose.rawValue))
            #expect(!shop.words.callIt("mac.net_d_" + purpose.rawValue).hasPrefix("mac."), Comment(rawValue: purpose.rawValue))
        }
        for purpose in InternetUse.consequences where purpose != .updates {
            #expect(!shop.words.callIt("mac.net_c_" + purpose.rawValue).hasPrefix("mac."), Comment(rawValue: purpose.rawValue))
        }
        for state in [InternetUse.State.allowed, .blocked, .kept, .ownSwitch, .notSetUp, .always] {
            #expect(!shop.words.callIt(state.wordKey).hasPrefix("mac."))
        }
    }
}
