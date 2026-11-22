import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The two questions and the switch-updates row as Turki signed them off
/// (Mac Figma page 27, G1 211:221, G2 211:245, G3 211:271; Nov 22).
@Suite(.serialized) @MainActor
struct NetworkSwitchFramesTests {

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/KhaytApp")

    static func at(_ hour: Int, _ minute: Int, day: Int = 22) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = day; c.hour = hour; c.minute = minute
        return Calendar.book.date(from: c) ?? Date()
    }

    @Test("G1: the old switch is asked with its date, and offers Apply it here first, then Leave this Mac as it is")
    func oldSwitch() async {
        let shop = await OperatorLockTests.shop(on: false)
        let ask = NetworkSwitchAsk.oldSwitch(at: Self.at(9, 0, day: 12))
        let said = NetworkSwitchWords.sentence(ask, words: shop.words)
        #expect(said.hasPrefix("Your shop turned off internet use on "))
        #expect(said.contains("12") && said.contains("2026") && said.hasSuffix("Apply it here?"))
        #expect(ask.choices.map { shop.words.callIt($0.key) } == ["Apply it here", "Leave this Mac as it is"])
        #expect(ask.choices.map(\.apply) == [true, false])
    }

    @Test("G2: the sentence says which way each computer turned it, and only turning ON offers Keep it on this Mac only")
    func changedElsewhere() async {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        let time = w.say(Self.at(14, 7), .dateTime.hour().minute())
        let on = NetworkSwitchAsk.changedElsewhere(at: Self.at(14, 7), turningOn: true)
        #expect(NetworkSwitchWords.sentence(on, words: w)
                == "The switch was turned off at another computer at \(time), just as you turned it on here. Use the newer setting, or keep this Mac offline on its own?")
        #expect(on.choices.map { w.callIt($0.key) } == ["Use the newer setting", "Keep it on this Mac only"])
        let off = NetworkSwitchAsk.changedElsewhere(at: Self.at(14, 7), turningOn: false)
        #expect(NetworkSwitchWords.sentence(off, words: w)
                == "The switch was turned on at another computer at \(time), just as you turned it off here. Your shop has turned off internet use.")
        #expect(off.choices.map { w.callIt($0.key) } == ["Use the newer setting"], "no second choice: it would loosen the shop's switch")
        // No time known: the general sentence and the clock hint, with the buttons of whichever case it is.
        for turningOn in [true, false] {
            let anon = NetworkSwitchAsk.changedElsewhere(at: nil, turningOn: turningOn)
            #expect(NetworkSwitchWords.sentence(anon, words: w)
                    == "The switch was changed at another computer. If this happens every time you change it, check this Mac's clock.")
            #expect(anon.choices.count == (turningOn ? 2 : 1))
        }
    }

    @Test("G2, under the switch: only this Mac follows it, and neither told nor unreachable is claimed")
    func onlyThisMac() async {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        #expect(InternetUse.onlyHere(.changedElsewhere(at: nil, turningOn: true)))
        #expect(!InternetUse.onlyHere(.changedElsewhere(at: Date(), turningOn: false)), "turned off here: this Mac is not offline on its own")
        #expect(!InternetUse.onlyHere(.oldSwitch(at: nil)) && !InternetUse.onlyHere(nil))
        var line = InternetUse.ShopLine(offline: true, tellsOthers: true, by: "Sara", at: Self.at(14, 7), told: .told(Self.at(14, 7)))
        line.onlyHere = true
        let said = InternetUse.sentence(line, words: w)
        #expect(said.hasPrefix("Only this Mac follows it. Turned on by Sara on "))
        #expect(said.hasSuffix("This Mac has stopped. Your other computers have not been told: turn it on there too."))
        #expect(!said.contains(w.callIt("mac.net_who_shop")), "it is not for the whole shop")
        var failed = line; failed.told = .failed
        #expect(InternetUse.sentence(failed, words: w) == said, "Khayt Cloud was reached: not 'could not be reached' either")
        // With the switch off there is nothing to say about who follows it alone.
        var off = line; off.offline = false
        #expect(!InternetUse.sentence(off, words: w).contains("Only this Mac"))
    }

    @Test("G3: the row's five states, and the advice only where its tick was offered and unticked")
    func switchUpdatesRow() async {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        func line(_ state: InternetUse.State, tick: Bool, kept: Bool) -> InternetUse.Line {
            .init(purpose: .switchSync, state: state, automatic: true, keepShown: tick, kept: kept, blocked: nil)
        }
        #expect(InternetUse.title(.switchSync, w) == "Hearing when the switch is turned off")
        #expect(w.callIt("mac.net_d_switch-sync")
                == "Khayt asks Khayt Cloud whether your shop's switch changed at another computer: at start, at each sync and every 15 minutes. While the switch is on this is the one call it keeps, only to hear when it is turned off. Nothing else is sent.")
        #expect(w.callIt("mac.net_c_switch-sync")
                == "While this is blocked, turn the switch off on this Mac yourself when the shop comes back online.")
        // 1 kept and ticked; 2 unticked: blocked, with the advice; 3 this Mac only: blocked, no tick, no advice;
        // 4 switch off: allowed; 5 not signed in: not set up.
        #expect(!InternetUse.saysConsequence(line(.kept, tick: true, kept: true)))
        #expect(InternetUse.saysConsequence(line(.blocked, tick: true, kept: false)))
        #expect(!InternetUse.saysConsequence(line(.blocked, tick: false, kept: false)))
        #expect(!InternetUse.saysConsequence(line(.allowed, tick: false, kept: false)))
        #expect(!InternetUse.saysConsequence(line(.notSetUp, tick: false, kept: false)))
        #expect([InternetUse.State.kept, .blocked, .allowed, .notSetUp].map { w.callIt($0.wordKey) } == ["Kept", "Blocked", "Allowed", "Not set up"])
        // The other rows that said what is lost while blocked still do.
        let updates = InternetUse.Line(purpose: .updates, state: .blocked, automatic: true, keepShown: true, kept: false, blocked: nil)
        #expect(InternetUse.saysConsequence(updates))
    }

    @Test("the question is on every screen with the way to Internet use, and on that page too; the old plain banner is gone")
    func whereItIsShown() throws {
        let banners = try String(contentsOf: Self.sources.appending(path: "Banners.swift"), encoding: .utf8)
        #expect(banners.contains("NetworkSwitchQuestion(shop: shop, ask: ask)"))
        #expect(!banners.contains("NetworkSwitchWords.sentence(ask"), "the plain banner was replaced")
        let question = try String(contentsOf: Self.sources.appending(path: "Shop+NetworkSwitch.swift"), encoding: .utf8)
        let body = try #require(question.range(of: "struct NetworkSwitchQuestion"))
        #expect(question[body.upperBound...].contains("OpenInternetUse(shop: shop)"), "the existing link, not a new screen")
        #expect(question[body.upperBound...].contains(".disabled(!mayAnswer)"), "others see it and cannot answer")
        let page = try String(contentsOf: Self.sources.appending(path: "InternetUse.swift"), encoding: .utf8)
        #expect(page.contains("NetworkSwitchQuestion(shop: shop, ask: ask, link: false"))
    }

    @Test("every new sentence exists in all nine languages, with its fields")
    func nineLanguages() async throws {
        let resources = Self.sources.appending(path: "Resources")
        let keys = ["mac.net_ask_off_there", "mac.net_ask_on_there", "mac.net_ask_elsewhere_anon", "mac.net_who_only_mac",
                    "mac.net_d_switch-sync", "mac.net_c_switch-sync"]
        for lang in ["de", "es", "fr", "ja", "pt-BR", "tr", "zh"] {
            let data = try Data(contentsOf: resources.appending(path: "mac-words-\(lang).json"))
            let table = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
            for key in keys {
                let said = try #require(table[key], Comment(rawValue: "\(lang) \(key)"))
                #expect(!said.isEmpty)
                if key == "mac.net_ask_off_there" || key == "mac.net_ask_on_there" {
                    #expect(said.contains("{time}"), Comment(rawValue: "\(lang) \(key)"))
                }
            }
            #expect(table["mac.net_ask_elsewhere"] == nil, "the retired sentence is gone in \(lang)")
        }
        let shop = await OperatorLockTests.shop(on: false)
        for key in keys { #expect(shop.words.callIt(key) != key) }
    }
}
