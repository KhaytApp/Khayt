import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Frame H (Mac file, page 27, node 217:223, signed off Nov 23): the switch
/// was turned back on here, the "off" could not be sent to the other
/// computers, and the reason is that this Mac's Khayt Cloud sign-in ended.
@MainActor
@Suite(.serialized)
struct NetworkSwitchSignInTests {
    typealias W = NetworkSwitchWiringTests
    static let on: JSONValue = .object(["offline": .bool(true), "changedAt": .string(W.stamp(3600)), "via": .string("cloud"),
                                        "changedBy": .string("Sara")])
    static func there() throws -> Data { try W.published(.init(offline: true, keep: [], changedAt: W.stamp(3600), changedBy: nil)) }

    @Test("a 401 while sending “off” is a sign-in that ended: said so, kept, and sent by itself after signing in again")
    func signInEnded() async throws {
        let (shop, server, book) = await W.shop(option: true, network: Self.on)
        await server.answerGet(401, Data(#"{"error":"unauthorized"}"#.utf8))
        #expect(await W.gated(shop) { await shop.setOutboundOffline(false) })
        // This Mac is online again: only the telling waits.
        #expect(W.obj(book.network)["offline"] == .bool(false))
        let stamp = try #require(shop.networkSwitchUnsentOff)
        #expect(shop.networkSwitchSignInEnded, "the 401 was treated like any other failure")
        // Still signed out at the next check: still said.
        #expect(await W.gated(shop) { await shop.retryUnsentOff() } == .unsent)
        #expect(shop.networkSwitchSignInEnded)
        // The network drops meanwhile: nothing was heard about the sign-in either way, so what was known stands.
        shop.networkSwitchFetch = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await W.gated(shop) { await shop.retryUnsentOff() } == .unsent)
        #expect(shop.networkSwitchSignInEnded, "a dead network un-said the sign-in")
        // Signed in again: the SAME change goes, and the banner with it.
        shop.networkSwitchFetch = { request in
            let (status, body) = await server.handle(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: request.httpBody)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        await server.answerGet(200, try Self.there())
        await server.forget()
        await W.gated(shop) { await shop.checkNetworkSwitch() }
        let asked = await server.asked
        #expect(asked.prefix(2).map(\.method) == ["GET", "PUT"])
        #expect(try W.sent(asked[1].body, shop).changedAt == stamp, "never a fresh stamp")
        #expect(shop.networkSwitchUnsentOff == nil && !shop.networkSwitchSignInEnded)
    }

    @Test("the PUT can be the call that says so; an answer given only to somebody signed in un-says it")
    func onThePutAndBack() async throws {
        let (shop, server, _) = await W.shop(option: true, network: Self.on)
        await server.answerGet(200, try Self.there())
        await server.answerPut(401, Data())
        #expect(await W.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchUnsentOff != nil && shop.networkSwitchSignInEnded)
        // Signed in, and Khayt Cloud is merely down: not a sign-in problem any more.
        await server.answerPut(503, Data())
        #expect(await W.gated(shop) { await shop.retryUnsentOff() } == .unsent)
        #expect(shop.networkSwitchUnsentOff != nil && !shop.networkSwitchSignInEnded)
    }

    @Test("it is not said for a failure that is not a sign-in, nor once the “off” is no longer waiting")
    func notOtherwise() async throws {
        // Khayt Cloud down from the start.
        var (shop, server, _) = await W.shop(option: true, network: Self.on)
        await server.answerGet(500, Data())
        #expect(await W.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchUnsentOff != nil && !shop.networkSwitchSignInEnded)
        // Sent at once: nothing waits.
        (shop, server, _) = await W.shop(option: true, network: Self.on)
        await server.answerGet(200, try Self.there())
        #expect(await W.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchUnsentOff == nil && !shop.networkSwitchSignInEnded)
        // A 401, then the owner turns the switch ON again: the old "off" is not the shop's word any more.
        (shop, server, _) = await W.shop(option: true, network: Self.on)
        await server.answerGet(401, Data())
        #expect(await W.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchSignInEnded)
        shop.forgetUnsentOff()
        #expect(!shop.networkSwitchSignInEnded, "the flag outlived the “off” it was about")
        // The verdict itself.
        let heard = SignInHeard()
        #expect(heard.verdict == nil)
        heard.note(503); #expect(heard.verdict == nil)
        // Not Khayt Cloud's own answer: a captive portal's page, a proxy's 404. Nothing is learned.
        heard.note(200, body: Data("<html>Sign in to the hotel Wi-Fi</html>".utf8)); #expect(heard.verdict == nil)
        heard.note(404, body: Data(#"{"error":"not found"}"#.utf8)); #expect(heard.verdict == nil)
        heard.note(404, body: Data(#"{"reason":"none"}"#.utf8)); #expect(heard.verdict == false)
        heard.note(401); #expect(heard.verdict == true, "a 401 on any call of the attempt wins")
    }

    @Test("a newer “off” does not inherit an older one's sign-in; and it is not said while the switch is on")
    func notInherited() async throws {
        let (shop, server, book) = await W.shop(option: true, network: Self.on)
        await server.answerGet(401, Data())
        #expect(await W.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchSignInEnded)
        let revision = shop.outboundRevision
        // The switch comes back ON by a sync (another computer's change), not by the owner here:
        // the slot is still there until the next check, but the banner must not show.
        var n = W.obj(book.network)
        n["offline"] = .bool(true)
        book.network = .object(n)
        var settings = shop.settingsDict
        settings["network"] = .object(n)
        shop.settingsValue = .object(settings)
        #expect(shop.networkSwitchUnsentOff != nil && !shop.networkSwitchSignInEnded, "“turned back on” said while the switch is on")
        // The owner turns it OFF again with no network at all: a NEW change, about which nothing is known.
        shop.networkSwitchFetch = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await W.gated(shop) { await shop.setOutboundOffline(false) })
        #expect(shop.networkSwitchUnsentOff != nil)
        #expect(!shop.networkSwitchSignInEnded, "an older change's 401 was carried over to this one")
        #expect(shop.outboundRevision != revision, "the page was never told to redraw")
    }

    @Test("signing in to Khayt Cloud sends a waiting “off” at once, not at the next quarter-hour check")
    func signingInSendsIt() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let cloud = try String(contentsOf: app.appending(path: "Shop+Cloud.swift"), encoding: .utf8)
        let signedIn = try #require(cloud.range(of: #"? [words.callIt("mac.cloud_signed_in")]"#))
        let retry = try #require(cloud.range(of: "if networkSwitchUnsentOff != nil { Task { await self.checkNetworkSwitch() } }"))
        #expect(retry.upperBound < signedIn.lowerBound && cloud.distance(from: retry.upperBound, to: signedIn.lowerBound) < 200,
                "the retry is not on the successful sign-in's path")
    }

    @Test("the words are frame H's, with the name and the time when the book has them")
    func words() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        #expect(w.callIt("mac.net_h_title") == "Internet use was turned back on here, but your other computers don’t know yet.")
        #expect(w.callIt("mac.net_h_sign_in") == "Sign in again")
        let at = Date(timeIntervalSince1970: 1_795_100_000)
        let time = w.say(at, .dateTime.hour().minute())
        #expect(NetworkSwitchSignIn.detail(by: "Sara", at: at, words: w)
                == "Sara turned it back on at \(time), but this Mac is no longer signed in to Khayt Cloud. Sign in again and Khayt will tell them.")
        #expect(NetworkSwitchSignIn.detail(by: nil, at: at, words: w).hasPrefix("It was turned back on at \(time), but this Mac"))
        #expect(NetworkSwitchSignIn.detail(by: "Sara", at: nil, words: w).hasPrefix("This Mac is no longer signed in to Khayt Cloud."))
        // Arabic: the frame's sentence, سحابة خيط and never Latin "Khayt".
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/Words.swift"), encoding: .utf8)
        #expect(source.contains(#""mac.net_h_title": ["en": "Internet use was turned back on here, but your other computers don’t know yet.", "ar": "أُعيد تشغيل الاتصال بالإنترنت على هذا الجهاز، لكن أجهزتك الأخرى لم تعرف بذلك بعد."]"#))
        #expect(source.contains(#""mac.net_h_sign_in": ["en": "Sign in again", "ar": "سجّل الدخول مرة أخرى"]"#))
    }

    @Test("drawn under the switch, only for somebody who may change it, and it opens the existing sign-in")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let pane = try String(contentsOf: app.appending(path: "InternetUse.swift"), encoding: .utf8)
        let switches = try #require(pane.range(of: "            switches\n"))
        let banner = try #require(pane.range(of: "shop.networkSwitchSignInEnded), mayChange {"))
        let list = try #require(pane.range(of: #"Text(words.callIt("mac.net_list"))"#))
        #expect(switches.upperBound < banner.lowerBound && banner.upperBound < list.lowerBound, "not under the switch")
        let view = try String(contentsOf: app.appending(path: "NetworkSwitchSignIn.swift"), encoding: .utf8)
        #expect(view.contains(".shopSheet(isPresented: $signingIn) { CloudSignInSheet(shop: shop) }"), "a sign-in of its own")
        #expect(!view.contains("StoreWriter") && !view.contains("setOutbound"), "the banner changes nothing itself")
    }
}
