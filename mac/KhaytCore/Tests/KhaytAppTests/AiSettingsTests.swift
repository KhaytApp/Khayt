import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The assistant's settings, and the consent in front of them.
///
/// The Mac app had no AI surface at all: a shop could be sent to the other app
/// to choose a provider, and had no way on this one to see — let alone refuse —
/// that drafting a reply sends a customer's name to a vendor.
///
/// What is asserted here is that the screen reads the SAME rules as the gate.
/// A settings screen that computes consent itself is a screen that can show a
/// feature as off while the gate runs it, which is the failure `ai-privacy.js`
/// was written to end.
@MainActor
struct AiSettingsTests {

    static func settings(_ ai: [String: JSONValue]) -> [String: JSONValue] {
        ["ai": .object(ai)]
    }

    // MARK: - The features and their disclosure

    @Test("every feature the rule knows about reaches the screen, with its disclosure")
    func featuresReachTheScreen() async throws {
        let engine = try KhaytEngine()
        let features = try await engine.aiFeatures(settings: Self.settings([:]))

        // The four are quote, price, reply and assistant. Asserted by NAME
        // rather than by count, because a fifth arriving silently is exactly
        // what this should notice.
        #expect(Set(features.map(\.id)) == ["quote", "price", "reply", "assistant"],
                Comment(rawValue: "got \(features.map(\.id))"))
        for f in features {
            #expect(!f.labelKey.isEmpty, "\(f.id) has no name to show")
            #expect(!f.sendsKey.isEmpty, "\(f.id) has no disclosure, so its switch says nothing")
            #expect(["own", "business", "customer"].contains(f.dataClass),
                    Comment(rawValue: "\(f.id): unknown data class \(f.dataClass)"))
        }
    }

    @Test("the one that sends a customer's name is marked as such")
    func customerDataIsMarked() async throws {
        let features = try await KhaytEngine().aiFeatures(settings: Self.settings([:]))
        let reply = try #require(features.first { $0.id == "reply" })
        #expect(reply.sendsCustomerData,
                "reply drafting sends a customer's name and balance and must carry the badge")
        // And the others do not, or the badge stops meaning anything.
        #expect(features.filter(\.sendsCustomerData).map(\.id) == ["reply"],
                Comment(rawValue: "marked: \(features.filter(\.sendsCustomerData).map(\.id))"))
    }

    // MARK: - Consent, which the screen must not work out for itself

    @Test("the master switch off means every feature reads as off")
    func masterOff() async throws {
        let engine = try KhaytEngine()
        let features = try await engine.aiFeatures(settings: Self.settings([
            "enabled": .bool(false),
            "features": .object(["quote": .bool(true), "price": .bool(true),
                                 "reply": .bool(true), "assistant": .bool(true)]),
        ]))
        #expect(features.allSatisfy { !$0.enabled },
                "the master switch is off and something still reads as on")
    }

    @Test("the master switch on does not turn a refused feature on")
    func perFeatureStillWins() async throws {
        let engine = try KhaytEngine()
        let features = try await engine.aiFeatures(settings: Self.settings([
            "enabled": .bool(true),
            "features": .object(["quote": .bool(true), "price": .bool(false),
                                 "reply": .bool(false), "assistant": .bool(true)]),
        ]))
        let on = Set(features.filter(\.enabled).map(\.id))
        #expect(on == ["quote", "assistant"], Comment(rawValue: "on: \(on.sorted())"))
    }

    @Test("a book from before per-feature consent does not inherit it for customer data")
    func migrationRefusesCustomerData() async throws {
        // The old single toggle never mentioned sending a customer's name, so
        // it cannot stand as permission for it. The others inherit; `reply`
        // does not, and is flagged as needing an answer.
        let engine = try KhaytEngine()
        let features = try await engine.aiFeatures(settings: Self.settings(["enabled": .bool(true)]))

        let reply = try #require(features.first { $0.id == "reply" })
        #expect(!reply.enabled, "consent for customer data was inherited from a toggle that never asked")
        #expect(reply.needsConsent, "nothing tells the shop this was switched off for it")

        let quote = try #require(features.first { $0.id == "quote" })
        #expect(quote.enabled, "a feature sending only the shop's own words was needlessly reset")
        #expect(!quote.needsConsent)
    }

    @Test("the screen's answer is the gate's answer, feature by feature")
    func screenAgreesWithTheGate() async throws {
        // THE ONE THAT MATTERS. `aiFeatures` asks `isFeatureEnabled` rather
        // than recomputing, so these cannot drift — this proves it across every
        // combination of the master switch and one feature's own answer.
        let engine = try KhaytEngine()
        for master in [true, false] {
            for wanted in [true, false] {
                let s = Self.settings([
                    "enabled": .bool(master),
                    "features": .object(["quote": .bool(wanted), "price": .bool(wanted),
                                         "reply": .bool(wanted), "assistant": .bool(wanted)]),
                ])
                let features = try await engine.aiFeatures(settings: s)
                for f in features {
                    #expect(f.enabled == (master && wanted),
                            Comment(rawValue: "master=\(master) wanted=\(wanted) \(f.id)=\(f.enabled)"))
                }
            }
        }
    }

    @Test("the privacy claim is qualified only when something really sends it")
    func customerDataClaim() async throws {
        let engine = try KhaytEngine()
        let off = Self.settings(["enabled": .bool(true),
                                 "features": .object(["reply": .bool(false)])])
        let on = Self.settings(["enabled": .bool(true),
                                "features": .object(["reply": .bool(true)])])
        #expect(try await engine.aiSendsCustomerData(settings: off) == false)
        #expect(try await engine.aiSendsCustomerData(settings: on) == true)
        // And the master switch alone settles it.
        let masterOff = Self.settings(["enabled": .bool(false),
                                       "features": .object(["reply": .bool(true)])])
        #expect(try await engine.aiSendsCustomerData(settings: masterOff) == false)
    }

    // MARK: - Which AI

    @Test("all four providers reach the chooser")
    func providersReachTheChooser() async throws {
        let providers = try await KhaytEngine().aiProviders()
        #expect(providers.map(\.id) == ["anthropic", "openai", "google", "compatible"],
                Comment(rawValue: "got \(providers.map(\.id))"))
        for p in providers {
            #expect(!p.label.isEmpty, "\(p.id) has no name to show in the list")
        }
        // The self-hosted entry is the only one with no model to guess and the
        // only one that must be given an address.
        let compatible = try #require(providers.first { $0.id == "compatible" })
        #expect(compatible.defaultModel.isEmpty)
        #expect(compatible.needsBaseUrl)
        #expect(providers.filter(\.needsBaseUrl).map(\.id) == ["compatible"])
    }

    @Test("a shop that has chosen nothing is on Anthropic, as the rule says")
    func providerFallback() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.aiProviderOf(settings: [:]).id == "anthropic")
        #expect(try await engine.aiProviderOf(settings: Self.settings([:])).id == "anthropic")
        // Nonsense falls back rather than leaving the screen blank.
        #expect(try await engine.aiProviderOf(
            settings: Self.settings(["provider": .string("nonsense")])).id == "anthropic")
        #expect(try await engine.aiProviderOf(
            settings: Self.settings(["provider": .string("openai")])).id == "openai")
    }

    // MARK: - The address a key travels to

    @Test("the address field refuses what would put the key on the wire")
    func addressIsChecked() async throws {
        let engine = try KhaytEngine()
        // Blank is fine — every vendor but the compatible one has its own.
        #expect(try await engine.aiAddressProblem("") == nil)
        #expect(try await engine.aiAddressProblem("   ") == nil)
        // A shop's own endpoint, and a model on the bench.
        #expect(try await engine.aiAddressProblem("https://gw.example.sa") == nil)
        #expect(try await engine.aiAddressProblem("http://localhost:11434") == nil)
        #expect(try await engine.aiAddressProblem("http://192.168.1.9:11434") == nil)
        // And the one that matters: plain http to a public host.
        let problem = try await engine.aiAddressProblem("http://gw.example.sa")
        #expect(problem?.contains("https") == true,
                Comment(rawValue: "got \(problem ?? "nil")"))
        #expect(try await engine.aiAddressProblem("not a url") != nil)
        #expect(try await engine.aiAddressProblem("https://u:p@x.example") != nil)
    }
}
