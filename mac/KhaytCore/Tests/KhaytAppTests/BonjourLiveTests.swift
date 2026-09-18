import Foundation
import Testing
import Network
import KhaytCore
@testable import KhaytApp

/// Does the Mac actually appear on the network?
///
/// Every other test of this feature is about a rule — what the advertised name
/// should be, how an address is written down. None of them proves the thing that
/// matters, which is that a phone standing in the shop can see the Mac at all.
/// This one starts the real listener on the real interfaces and browses for it
/// with the same API the phone uses.
///
/// It needs mDNS to work on the machine running it. If this is the only failure
/// in a run, suspect the environment before the code — but do not silence it: a
/// silent skip is how a guard stops guarding, and the feature it guards has no
/// other proof that it works at all.
@MainActor
struct BonjourLiveTests {
    @Test("a server bound to the LAN is discoverable by name, and says it serves the book")
    func advertisesForReal() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        var book = shop.lanBook
        book["settings"] = .object(["shopName": .string("BonjourProbe")])
        let host = LanServer.Host(store: { book }, pin: "2468", engine: engine,
                                  now: { Date() }, nowText: { "09:16" },
                                  icon: { LanServer.bundledIcon($0) })
        let server = LanServer(host: host)
        _ = try await server.start(port: 0, bind: .lan)
        defer { server.stop() }

        let found: (name: String, servesBook: Bool)? = await withCheckedContinuation { cont in
            let once = Once()
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_khayt._tcp", domain: nil),
                                    using: NWParameters())
            browser.browseResultsChangedHandler = { results, _ in
                for r in results {
                    guard case .service(let name, _, _, _) = r.endpoint, name.hasPrefix("BonjourProbe") else { continue }
                    var serves = false
                    if case .bonjour(let txt) = r.metadata { serves = txt["store"] == "1" }
                    if once.first() { browser.cancel(); cont.resume(returning: (name, serves)) }
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if once.first() { browser.cancel(); cont.resume(returning: nil) }
            }
        }

        let result = try #require(found, "the Mac advertised nothing a browser could see in 20s")
        #expect(result.name.hasPrefix("BonjourProbe"))
        #expect(result.servesBook, "the TXT record did not say this Mac serves GET /api/store")
    }
}
