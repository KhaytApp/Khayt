import AppKit
import SwiftUI
import KhaytCore

/// `KHAYT_SNAPSHOT_INTERNETUSE=1`: the Internet use page as Figma page 27
/// draws it (frames A, B, C, E and F1–F3), on the sample book, in memory.
/// Sample names only ("Sara Example"). Nothing is written and nothing is sent.
extension Snapshot {

    static func captureInternetUse(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        await settle()
        let rtl = Direction.rtlLanguages.contains(shop.words.language)
        func shot(_ name: String, width: CGFloat = 900, _ view: some View) {
            captureView(named: "netuse-\(name)\(tag)",
                        view.frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }

        // A fixed "now" and a fixed switch time, as the frames have them.
        var parts = DateComponents(); parts.year = 2026; parts.month = 11; parts.day = 21; parts.hour = 14; parts.minute = 2
        let switched = Calendar.book.date(from: parts) ?? Date()
        let now = switched.addingTimeInterval(10 * 60)
        let lastChecked = Calendar.book.date(byAdding: .day, value: -7, to: switched) ?? switched

        // The rule's own rows for each state, from a gate nobody else asks.
        func rows(offline: Bool, keep: [String] = []) -> [OutboundGate.Row] {
            let gate = OutboundGate()
            gate.update(book: .settings(.object(["network": .object([
                "offline": .bool(offline), "keep": .array(keep.map(JSONValue.string))])])))
            return gate.rows()
        }
        let notSetUp: Set<OutboundPurpose> = [.webhooks, .taxAuthority]
        let blocked: [OutboundPurpose: OutboundGate.Blocked] = [
            .updates: .init(count: 2, last: now), .installCount: .init(count: 1, last: switched.addingTimeInterval(60)),
        ]
        let on = InternetUse.lines(rows: rows(offline: true, keep: ["storage"]), offline: true, notSetUp: notSetUp,
                                   ownOff: [.crashReports, .usageStats], blocked: blocked)
        let off = InternetUse.lines(rows: rows(offline: false), offline: false, notSetUp: notSetUp, blocked: [:])

        func page(_ lines: [InternetUse.Line], _ line: InternetUse.ShopLine, mayChange: Bool = true,
                  telling: Bool = false, days: Int? = nil, checked: Date? = lastChecked) -> InternetUsePage {
            var page = InternetUsePage(shop: shop, pretend: lines, now: now)
            page.pretendShopLine = line
            page.pretendHere = false
            page.pretendMayChange = mayChange
            page.offersTelling = telling
            page.pretendUpdateDays = days
            page.pretendLastChecked = checked
            return page
        }
        let by = InternetUse.ShopLine(offline: true, tellsOthers: false, by: "Sara Example", at: switched, told: nil)

        shot("A-switch-on", page(on, by))
        shot("B-switch-off", page(off, .init()))
        let stale = Calendar.book.date(byAdding: .day, value: -32, to: now) ?? now
        shot("C-updates-30-days", VStack(spacing: 0) {
            Banner(text: shop.words.callIt("mac.net_banner", ["n": .string(shop.words.numeral(32))]),
                   symbol: "exclamationmark.shield", tint: Khayt.late) {
                HStack(spacing: 8) {
                    Button(shop.words.callIt("mac.net_keep_updates")) {}
                    Button(shop.words.callIt("mac.net_open_use")) {}
                }
            }
            page(on, by, days: 32, checked: stale)
        })
        shot("D-refused", width: 640, VStack(spacing: 8) {
            ForEach(Array([OutboundBlocked(purpose: .exchangeRates, reason: "offline"),
                           OutboundBlocked(purpose: .cloud, reason: "offline-here"),
                           OutboundBlocked(purpose: .lan, reason: "lan-host-public", host: "ntfy.example.com"),
                           OutboundBlocked(purpose: .cloud, reason: "settings-unknown")].enumerated()), id: \.offset) { _, refusal in
                Banner(text: shop.outboundSentence(refusal), symbol: "wifi.slash", tint: Khayt.attention) {
                    if refusal.reason != "settings-unknown" { Button(shop.words.callIt("mac.net_open_use")) {} }
                }
            }
        }.padding(16))
        shot("E-manager", page(on, by, mayChange: false))
        shot("F1-not-told", page(on, by, telling: true))
        var told = by; told.tellsOthers = true; told.told = .told(switched)
        shot("F2-told", page(on, told, telling: true))
        shot("F3-off-offered", page(off, .init(), telling: true))
        var failed = told; failed.told = .failed
        shot("F2b-tell-failed", page(on, failed, telling: true))

        // ── G1–G3 (signed off Nov 22): the two questions and the new row ──
        var early = DateComponents(); early.year = 2026; early.month = 11; early.day = 12; early.hour = 9
        let oldOff = Calendar.book.date(from: early) ?? switched
        let there = switched.addingTimeInterval(5 * 60)   // 14:07, as the frames have it
        // `there`: what the other computer set, as read after the 409.
        func question(_ ask: NetworkSwitchAsk, owner: Bool = true, there: Bool? = nil) -> some View {
            NetworkSwitchQuestion(shop: shop, ask: ask, pretendMayAnswer: owner, pretendThere: .some(there))
        }
        // G1: an old "off" met by a Mac with no switch history, for the owner
        // and for anybody else (the same question, buttons off).
        shot("G1-old-switch", width: 640, VStack(spacing: 12) {
            question(.oldSwitch(at: oldOff))
            question(.oldSwitch(at: oldOff), owner: false)
        }.padding(.vertical, 12))
        // G2: changed at another computer, each way, and with no time known.
        shot("G2-changed-elsewhere", width: 640, VStack(spacing: 12) {
            question(.changedElsewhere(at: there, turningOn: true), there: false)
            question(.changedElsewhere(at: there, turningOn: false), there: true)
            question(.changedElsewhere(at: nil, turningOn: true))
            question(.changedElsewhere(at: nil, turningOn: false))
        }.padding(.vertical, 12))
        // G2, on the Internet use page: the question at the top, and under the
        // switch "Only this Mac follows it … have not been told".
        var only = InternetUse.ShopLine(offline: true, tellsOthers: true, by: "Sara Example", at: there, told: nil)
        only.onlyHere = true
        var asking = page(on, only, telling: true)
        asking.pretendAsk = .changedElsewhere(at: there, turningOn: true)
        asking.pretendThere = .some(false)
        shot("G2-page-only-this-mac", asking)
        // G3: the switch-updates row in its five states.
        func hearing(_ state: InternetUse.State, tick: Bool, kept: Bool) -> InternetUse.Line {
            .init(purpose: .switchSync, state: state, automatic: true, keepShown: tick, kept: kept, blocked: nil)
        }
        for (name, line) in [("1-kept", hearing(.kept, tick: true, kept: true)),
                             ("2-unticked", hearing(.blocked, tick: true, kept: false)),
                             ("3-this-mac-only", hearing(.blocked, tick: false, kept: false)),
                             ("4-switch-off", hearing(.allowed, tick: false, kept: false)),
                             ("5-not-signed-in", hearing(.notSetUp, tick: false, kept: false))] {
            let offline = name != "4-switch-off"
            shot("G3-row-\(name)", page([line], offline ? by : .init()))
        }
    }
}
