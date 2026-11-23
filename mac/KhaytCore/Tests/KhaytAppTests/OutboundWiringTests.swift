import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Make no internet calls" wired into the Mac: a refused call throws the one
/// distinct error BEFORE a request exists, the shop's switches are the
/// owner's alone, and the book is written with the names the desktop writes.
/// Each test turns the switch on for its own task only (`OutboundGate.scoped`).
@Suite(.serialized) @MainActor
struct OutboundWiringTests {

    static func offline(keep: [String] = []) -> OutboundGate {
        let gate = OutboundGate()
        gate.update(book: .settings(.object(["network": .object(["offline": .bool(true),
                                                                 "keep": .array(keep.map(JSONValue.string))])])))
        return gate
    }

    static let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com", shopId: "shop_sample", storedToken: "")

    @Test("Khayt Cloud: a refused request is never built; the online store's routes are kept on their own")
    func cloudBuilder() throws {
        // Nobody said anything: today's behaviour.
        _ = try CloudReader.request(Self.connection, token: "t", method: "GET", tail: "/deltas")
        try OutboundGate.$scoped.withValue(Self.offline()) {
            #expect(throws: OutboundBlocked(purpose: .cloud, reason: "offline")) {
                _ = try CloudReader.request(Self.connection, token: "t", method: "GET", tail: "/deltas")
            }
            #expect(throws: OutboundBlocked(purpose: .storefront, reason: "offline")) {
                _ = try CloudReader.request(Self.connection, token: "t", method: "PUT", tail: "/lead-time")
            }
            #expect(OutboundGate.shared.blocked(.cloud)?.count == 1)
        }
        try OutboundGate.$scoped.withValue(Self.offline(keep: ["storefront"])) {
            _ = try CloudReader.request(Self.connection, token: "t", method: "PUT", tail: "/catalog")
            #expect(throws: OutboundBlocked.self) {
                _ = try CloudReader.request(Self.connection, token: "t", method: "GET", tail: "/keyset")
            }
        }
        // The scope ended: the app's gate was never touched.
        _ = try CloudReader.request(Self.connection, token: "t", method: "GET", tail: "/deltas")
    }

    @Test("the shop's own services: refused before a request, each by its purpose")
    func purposes() async throws {
        let gate = Self.offline()
        try await OutboundGate.$scoped.withValue(gate) {
            await #expect(throws: OutboundBlocked(purpose: .catalogues, reason: "offline")) {
                _ = try await Shop.fetchConnectorBytes(Shop.connectorIndexURL, 1024)
            }
            await #expect(throws: OutboundBlocked(purpose: .catalogues, reason: "offline")) {
                let _: [String] = try await OrcaFilamentProfiles.fetch(URL(string: "https://bedready.io/x.json")!, cap: 10, as: [String].self)
            }
            #expect(await Shop.fetchWebCover("https://makerworld.com/cover.png") == nil)
            let engine = try KhaytEngine()
            await #expect(throws: OutboundBlocked(purpose: .webhooks, reason: "offline")) {
                _ = try await WebhookClient.post(Data(), to: URL(string: "https://hooks.example.com/x")!, headers: [],
                                                 engine: engine, purpose: .webhooks)
            }
            await #expect(throws: OutboundBlocked(purpose: .messaging, reason: "offline")) {
                _ = try await WebhookClient.post(Data(), to: URL(string: "https://sms.example.com/x")!, headers: [],
                                                 engine: engine, purpose: .messaging)
            }
        }
        #expect(gate.blocked(.catalogues)?.count == 2)
        #expect(gate.blocked(.lookups)?.count == 1 && gate.blocked(.webhooks)?.count == 1 && gate.blocked(.messaging)?.count == 1)
    }

    @Test("a service the shop hosts itself: allowed on the shop's network, refused at a public address")
    func selfHosted() throws {
        let gate = Self.offline()
        try gate.require(.messaging, orLanHost: "192.168.1.9")
        try gate.require(.messaging, orLan: URL(string: "http://ntfy.local/shop")!)
        #expect(throws: OutboundBlocked(purpose: .messaging, reason: "lan-host-public", host: "ntfy.example.com")) {
            try gate.require(.messaging, orLan: URL(string: "https://ntfy.example.com/shop")!)
        }
        // Messaging kept: any address.
        try Self.offline(keep: ["messaging"]).require(.messaging, orLanHost: "ntfy.example.com")
    }

    @Test("printers: the shop's network is never blocked; an address that leads outside is refused while the switch is on")
    func lan() async throws {
        let engine = try KhaytEngine()
        await OutboundGate.$scoped.withValue(Self.offline()) {
            let outside = await PrinterWatch.pinned(URL(string: "http://printer.example.com/webcam")!, engine: engine,
                                                    lookUp: { _ in ["192.168.1.40"] })
            #expect(outside == nil, "a public name is refused before it is looked up")
            #expect(PrinterSweep.request("192.168.1.40", port: 80, path: "/") != nil)
            #expect(PrinterSweep.request("8.8.8.8", port: 80, path: "/") == nil)
        }
        #expect(PrinterSweep.request("8.8.8.8", port: 80, path: "/") != nil, "switch off: as before")
    }

    @Test("the install count and telemetry are not sent, and nothing is queued for later")
    func phoneHome() async throws {
        let defaults = UserDefaults(suiteName: "khayt.outbound.test.\(UUID().uuidString)")!
        let sender = ActiveCountSender(defaults: defaults)
        sender.sendsFromThisBuild = true
        sender.ready = true
        let sent = Counter()
        sender.fetch = { _ in await sent.bump(); throw URLError(.notConnectedToInternet) }
        let said = await OutboundGate.$scoped.withValue(Self.offline()) { await sender.tick() }
        #expect(said == "blocked" || said == "done" || said == "version" || said == "waiting", "\(said)")
        #expect(await sent.count == 0, "nothing reached the network")
        // Telemetry: one kind refused by the switch is not recorded and is
        // not "allowed"; before the book is read it is neither, so nothing is dropped.
        OutboundGate.$scoped.withValue(Self.offline(keep: ["crash-reports"])) {
            #expect(Telemetry.switchSays(.crashReports) == .allows)
            #expect(Telemetry.switchSays(.usageStats) == .refuses)
        }
        let starting = OutboundGate(); starting.update(book: .unread)
        OutboundGate.$scoped.withValue(starting) { #expect(Telemetry.switchSays(.usageStats) == .notKnownYet) }
        #expect(Telemetry.switchSays(.usageStats) == .allows, "no switch: the opt-in alone decides")
    }

    actor Counter { var count = 0; func bump() { count += 1 } }

    // MARK: - The switches

    @Test("the book's fields: the stamp moves only when the switch changes, a Keep tick never moves it")
    func networkRecord() {
        let t1 = Date(timeIntervalSince1970: 1_795_000_000), t2 = t1.addingTimeInterval(3600)
        func obj(_ v: JSONValue) -> [String: JSONValue] { if case .object(let o) = v { return o }; return [:] }
        let on = Shop.network(nil, offline: true, by: "Sara Example", at: t1)
        #expect(obj(on)["offline"] == .bool(true))
        #expect(obj(on)["changedBy"] == .string("Sara Example") && obj(on)["changedAt"] == .string(StoreWriter.iso(t1)))
        // On again: nothing changed, the stamp stays.
        #expect(Shop.network(on, offline: true, by: "Someone Else", at: t2) == on)
        // A Keep tick leaves the stamp alone.
        let kept = Shop.network(on, keep: .storage, true)
        #expect(obj(kept)["keep"] == .array([.string("storage")]))
        #expect(obj(kept)["changedAt"] == obj(on)["changedAt"] && obj(kept)["changedBy"] == obj(on)["changedBy"])
        #expect(obj(Shop.network(kept, keep: .storage, true))["keep"] == .array([.string("storage")]), "each once")
        #expect(obj(Shop.network(kept, keep: .storage, false))["keep"] == .array([]))
        // Off: stamped again, with no name when the staff lock is off; keep stays.
        let off = Shop.network(kept, offline: false, by: nil, at: t2)
        #expect(obj(off)["offline"] == .bool(false) && obj(off)["changedBy"] == .null)
        #expect(obj(off)["changedAt"] == .string(StoreWriter.iso(t2)) && obj(off)["keep"] == .array([.string("storage")]))
        // A value an older client stored reads as ON, so turning it "on" is no change.
        let odd: JSONValue = .object(["offline": .string("true"), "changedAt": .string("x")])
        #expect(obj(Shop.network(odd, offline: true, by: "A", at: t1))["changedAt"] == .string("x"))
        // Junk in keep is dropped; lan is never kept.
        let junk: JSONValue = .object(["keep": .array([.string("nope"), .string("lan"), .number(3), .string("ai")])])
        #expect(obj(Shop.network(junk, keep: .cloud, true))["keep"] == .array([.string("ai"), .string("cloud")]))
        #expect(!Shop.keepable.contains(.lan) && !Shop.keepable.contains(.tunnel) && Shop.keepable.contains(.storefront))
        #expect(Shop.keepable.count == OutboundPurpose.allCases.count - 2, "tunnel is the only purpose left out besides lan")
    }

    @Test("only the owner changes either switch or a Keep tick; everyone else is refused and told")
    func ownerOnly() async throws {
        let shop = await OperatorLockTests.shop()
        shop.outboundDefaults = UserDefaults(suiteName: "khayt.outbound.test.\(UUID().uuidString)")!
        shop.outboundGate = OutboundGate()
        shop.feedsOutboundGate = true
        for who in [nil, ("OP-v", "4444"), ("OP-x", "3333"), ("OP-m", "2222")] as [(String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            #expect(!shop.mayChangeOutbound)
            #expect(await shop.setOutboundOffline(true) == false)
            #expect(LockReviewTests.refused(shop), Comment(rawValue: who?.0 ?? "nobody"))
            #expect(await shop.setOutboundKeep(.storage, true) == false)
            #expect(shop.setOutboundOfflineHere(true) == false)
            #expect(!shop.outboundOfflineHere && !shop.outboundGate.isOffline)
        }
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(shop.mayChangeOutbound)
        // This Mac's own switch: on at once, and the gate is told.
        #expect(shop.setOutboundOfflineHere(true))
        #expect(shop.outboundOfflineHere && shop.outboundGate.isOffline)
        #expect(shop.outboundGate.verdict(.cloud).reason == "offline-here")
        // A manager cannot turn it off again.
        shop.lockNow()
        #expect(await shop.signIn("OP-m", pin: "2222") == .ok)
        #expect(shop.setOutboundOfflineHere(false) == false)
        #expect(shop.outboundOfflineHere)
        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(shop.setOutboundOfflineHere(false) && !shop.outboundGate.isOffline)
        // The shop's switch on the sample book: the owner passes the gate; the sample has nowhere to write.
        #expect(await shop.setOutboundOffline(true) == false)
        #expect(!LockReviewTests.refused(shop) && shop.moveProblem == shop.words.callIt("mac.move_sample"))
        #expect(await shop.setOutboundKeep(.lan, true) == false, "lan is never a Keep tick")
    }

    @Test("a shop tells the gate only when it is the app's shop; and only the shop's own book says, never the sample")
    func feeding() async {
        let shop = await OperatorLockTests.shop(on: false)   // the sample book
        let gate = OutboundGate()
        let defaults = UserDefaults(suiteName: "khayt.outbound.test.\(UUID().uuidString)")!
        shop.outboundGate = gate
        shop.outboundDefaults = defaults
        var settings = shop.settingsDict
        settings["network"] = .object(["offline": .bool(true)])
        shop.settingsValue = .object(settings)
        #expect(gate.currentBook == .none, "a test's shop does not move a gate unless it says so")
        shop.feedsOutboundGate = true
        shop.settingsValue = .object(settings)
        #expect(!gate.isOffline, "the sample book's own switch is not the shop's")

        // The shop's own book says, and this Mac remembers what it said.
        let offline: [String: JSONValue] = ["network": .object(["offline": .bool(true), "keep": .array([.string("cloud")])]),
                                            "bizLogo": .string("data:image/png;base64,AAAA")]
        gate.update(book: .settings(Shop.outboundBook(real: true, settings: offline, defaults: defaults)))
        #expect(gate.isOffline && gate.verdict(.updates).reason == "offline" && gate.verdict(.cloud).allowed)
        if case .settings(.object(let kept)) = gate.currentBook { #expect(Set(kept.keys) == ["network"], "only what the rule reads is held") }
        // Opening the sample afterwards does NOT put this Mac back online.
        shop.settingsValue = .object(shop.settingsDict)
        #expect(gate.isOffline && gate.verdict(.updates).reason == "offline" && gate.verdict(.cloud).allowed)
        // The shop's book turning it off is believed, and remembered.
        gate.update(book: .settings(Shop.outboundBook(real: true, settings: ["network": .object(["offline": .bool(false)])], defaults: defaults)))
        shop.settingsValue = .object(shop.settingsDict)
        #expect(!gate.isOffline)
    }

    @Test("a book that cannot be read does not leave the gate at starting for ever: it goes by what the book last said")
    func loadFailed() async {
        let shop = await OperatorLockTests.shop(on: false)
        let gate = OutboundGate()
        let defaults = UserDefaults(suiteName: "khayt.outbound.test.\(UUID().uuidString)")!
        shop.outboundGate = gate; shop.outboundDefaults = defaults; shop.feedsOutboundGate = true
        gate.update(book: .unread)
        #expect(gate.verdict(.cloud).reason == "settings-unknown")
        shop.outboundLoadFailed()
        #expect(gate.verdict(.cloud).allowed, "never offline before: the cloud it would restore from is reachable")
        // A Mac whose shop was offline stays offline.
        _ = Shop.outboundBook(real: true, settings: ["network": .object(["offline": .bool(true)])], defaults: defaults)
        gate.update(book: .unread)
        shop.outboundLoadFailed()
        #expect(gate.verdict(.cloud).reason == "offline")
        // And a loaded shop is never overwritten by a late failure.
        gate.update(book: .settings(.object([:])))
        shop.outboundLoadFailed()
        #expect(gate.verdict(.cloud).allowed)
    }

    @Test("a name that reads as the shop's own must also resolve inside it while the switch is on")
    func resolvedNames() async throws {
        let outside: @Sendable (String) async -> [String] = { _ in ["192.168.1.20", "203.0.113.9"] }
        let inside: @Sendable (String) async -> [String] = { _ in ["192.168.1.20"] }
        // Switch off: no lookup is made at all.
        try await OutboundLan.requireResolved("spoolman.local", gate: OutboundGate(), lookUp: { _ in Issue.record("looked up"); return [] })
        let gate = Self.offline()
        try await OutboundLan.requireResolved("spoolman.local", gate: gate, lookUp: inside)
        try await OutboundLan.requireResolved("192.168.1.20", gate: gate, lookUp: { _ in Issue.record("an address needs no lookup"); return [] })
        await #expect(throws: OutboundBlocked.self) {
            try await OutboundLan.requireResolved("spoolman.local", gate: gate, lookUp: outside)
        }
        #expect(gate.blocked(.lan)?.count == 1)
        // The same before the book is read.
        let starting = OutboundGate(); starting.update(book: .unread)
        await #expect(throws: OutboundBlocked.self) {
            try await OutboundLan.requireResolved("ntfy", gate: starting, lookUp: outside)
        }
    }

    @Test("a refusal is said in words, by reason; never a network error")
    func sentences() async {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        #expect(Shop.outboundSentence(.init(purpose: .exchangeRates, reason: "offline"), words: w)
                == "Khayt is set to make no internet calls. This needs exchange rates.")
        #expect(Shop.outboundSentence(.init(purpose: .cloud, reason: "offline-here"), words: w)
                == "This Mac is set to make no internet calls. This needs Khayt Cloud.")
        #expect(Shop.outboundSentence(.init(purpose: .messaging, reason: "lan-host-public", host: "ntfy.example.com"), words: w)
                == "Khayt is set to make no internet calls, and ntfy.example.com is not on your shop's network.")
        #expect(Shop.outboundSentence(.init(purpose: .ai, reason: "settings-unknown"), words: w) == "Khayt is starting. Try again in a moment.")
        for purpose in OutboundPurpose.allCases {
            let need = w.callIt("mac.net_need_" + purpose.rawValue)
            #expect(!need.hasPrefix("mac."), Comment(rawValue: purpose.rawValue))
        }
        // Wherever an error is put into words, a blocked call says its sentence.
        OutboundBlocked.speaker = { Shop.outboundSentence($0, words: w) }
        defer { OutboundBlocked.speaker = nil }
        #expect(ErrorText.plain(OutboundBlocked(purpose: .ai, reason: "offline")) == "Khayt is set to make no internet calls. This needs AI assist.")
        #expect(shop.said(OutboundBlocked(purpose: .ai, reason: "offline")).contains("AI assist"))
    }
}
