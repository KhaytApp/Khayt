import Foundation
import Testing
@testable import KhaytApp

/// What the Online pane says this app does, against what it actually routes.
///
/// The pane's description ended with a sentence sending the shop to the other
/// app for the customer intake form, quote approval and the calendar feed.
/// All three have been served out of `LanServer.swift` since alpha.18. A shop
/// reading it would have gone and started a second app to be handed something
/// this one was already answering on the same Wi‑Fi — and the words were right
/// when they were written, which is exactly why nothing caught them changing
/// from true to false.
///
/// So the claim is held to the route table rather than to anyone's memory of
/// it. This is the same correction as the assistant pane's "runs in the
/// Windows and Linux app" (#1466), and deliberately the same shape of guard:
/// a feature this app performs is a failing build, not a note.
@MainActor
struct OnlinePaneTruthTests {

    /// One capability the LAN API offers, how to tell whether this app serves
    /// it, and the word the pane would use for it.
    ///
    /// `route` is matched against `LanServer.swift`'s source rather than
    /// against a list kept here, so deleting a route fails this test and
    /// adding one is noticed the moment the pane's wording disagrees.
    struct Capability {
        let name: String
        /// A distinctive fragment of the route that answers it.
        let route: String
        /// What the pane calls it, in the closing sentence.
        let english: [String]
        let arabic: [String]
    }

    static let capabilities: [Capability] = [
        .init(name: "the live queue", route: "case (\"/api/queue\", true)",
              english: ["live queue"], arabic: ["قائمة الانتظار"]),
        .init(name: "the customer intake form", route: "case (\"/api/intake\", false)",
              english: ["intake"], arabic: ["طلبات العملاء"]),
        .init(name: "quote approval", route: "Self.approvePath(path) != nil",
              english: ["quote approval"], arabic: ["اعتماد عروض"]),
        .init(name: "the calendar feed", route: "case (\"/calendar.ics\", true)",
              english: ["calendar"], arabic: ["تقويم"]),
        .init(name: "the survey", route: "case (\"/api/survey\", false)",
              english: ["survey"], arabic: ["استبيان"]),
        .init(name: "orders from Salla and Zid", route: "case (Self.storefrontHookPath + \"salla\", false)",
              english: ["salla", "zid", "storefront"], arabic: ["سلة", "زد"]),
    ]

    /// The sentence that sends the shop somewhere else, if there is one.
    ///
    /// Found by the standing phrase rather than by position: the pane may gain
    /// sentences, and a guard that reads the last one would stop looking at the
    /// right words without failing.
    static func elsewhereSentence(_ text: String, marker: String) -> String? {
        for sentence in text.components(separatedBy: ". ") where sentence.contains(marker) {
            return sentence
        }
        return nil
    }

    @Test("the Online pane does not send a shop elsewhere for what this app serves")
    func paneMatchesTheRoutes() throws {
        let server = MenuCoverageTests.source("LanServer.swift")
        #expect(!server.isEmpty, "LanServer.swift moved")

        // Read from the catalogue itself rather than through `callIt`, which
        // answers in whichever language the app happens to be in.
        let english = try #require(Words.own["mac.online_desc"]?["en"],
                                   "the Online pane lost its description")

        let sentence = Self.elsewhereSentence(english, marker: "run in that app")
        for capability in Self.capabilities {
            let served = server.contains(capability.route)
            #expect(served, Comment(rawValue: "\(capability.name) is no longer routed — \(capability.route)"))
            guard served, let sentence else { continue }
            for word in capability.english {
                #expect(!sentence.lowercased().contains(word.lowercased()),
                        Comment(rawValue: "the pane sends the shop to the other app for "
                                + "\(capability.name), which this app serves: \"\(sentence)\""))
            }
        }
    }

    /// The Arabic says the same thing, because a shop reading Arabic is sent to
    /// the other app by its own sentence and not by the English one.
    @Test("the Arabic pane makes the same claim as the English")
    func arabicMatchesTheRoutes() throws {
        let server = MenuCoverageTests.source("LanServer.swift")
        let arabic = try #require(Words.own["mac.online_desc"]?["ar"],
                                  "the Online pane has no Arabic")

        // The Arabic sentence that defers to the other app names it. Split on
        // the full stop as well as the Arabic comma: a clause ending in "."
        // otherwise reads as part of the next sentence, and the one that says
        // what this app serves is judged by the one that says what it does not.
        let sentence = arabic.components(separatedBy: CharacterSet(charactersIn: "،."))
            .first { $0.contains("ذلك التطبيق") }
        for capability in Self.capabilities where server.contains(capability.route) {
            guard let sentence else { continue }
            for word in capability.arabic {
                #expect(!sentence.contains(word),
                        Comment(rawValue: "the Arabic pane defers \(capability.name) to the other app"))
            }
        }
    }

    /// The other half: what genuinely has NOT been lifted is still declared.
    ///
    /// Without this the guard is satisfied by a pane that promises everything,
    /// which is the opposite failure and the worse one — a shop waiting for a
    /// webhook this app never sends.
    @Test("what this app does not serve is still said plainly")
    func unservedIsDeclared() throws {
        let server = MenuCoverageTests.source("LanServer.swift")
        let english = try #require(Words.own["mac.online_desc"]?["en"]).lowercased()
        let arabic = try #require(Words.own["mac.online_desc"]?["ar"])
        // The carrier and printer webhooks: no route here answers one, and the
        // pane says where they run. Salla and Zid ARE answered, and the
        // capability list above holds the pane to that.
        let unserved: [(name: String, route: String, english: String, arabic: String)] = [
            ("carrier webhooks", "\"smsa\"", "carrier", "الشحن"),
            ("printer webhooks", "webhook/printer", "printer", "الطابعات"),
        ]
        for hook in unserved {
            #expect(!server.contains(hook.route),
                    Comment(rawValue: "\(hook.name) are served now — say so in the Online pane"))
            #expect(english.contains(hook.english),
                    Comment(rawValue: "the pane no longer says where \(hook.name) run"))
            #expect(arabic.contains(hook.arabic),
                    Comment(rawValue: "the Arabic pane no longer says where \(hook.name) run"))
        }
    }
}
