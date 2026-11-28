import SwiftUI
import KhaytCore

/// Settings ▸ General ▸ Internet use (Figma Mac file, page 27, frames A–E):
/// the shop's "make no internet calls" switch, this Mac's own, and one row for
/// each kind of call Khayt makes, with what the switch does to it.
///
/// THE ROWS ARE THE RULE'S. `OutboundGate.rows()` is `describe()` in
/// `lib/outbound.js`; this file only orders them as the frames do, words them,
/// and adds what only the Mac knows: whether a thing is set up at all, and how
/// often a call was refused since launch. It decides nothing about what is
/// blocked.
enum InternetUse {

    /// The frames' order. `tunnel` is not listed: the Mac has no public tunnel.
    static let order: [OutboundPurpose] = [
        .updates, .installCount, .crashReports, .usageStats, .cloud, .switchSync, .storage, .messaging, .webhooks,
        .storefront, .payments, .ai, .taxAuthority, .exchangeRates, .makerrun, .catalogues, .lookups, .lan,
    ]

    /// The purposes whose row says what the shop loses while it is blocked.
    static let consequences: Set<OutboundPurpose> = [.updates, .cloud, .messaging, .storefront, .payments]

    /// Whether the line under the switch says "Only this Mac follows it": the
    /// owner was turning the switch ON, another computer's change was kept,
    /// and that change was not also "on" (`there`, when it was read).
    static func onlyHere(_ ask: NetworkSwitchAsk?, there: Bool?) -> Bool {
        ask?.onlyThisMac(there: there) ?? false
    }

    /// Whether a blocked row says what to do meanwhile. The switch-updates row
    /// says it only where its tick is offered (the switch came through Khayt
    /// Cloud and the row was unticked): on a Mac offline by its own switch
    /// there is no call to keep and nothing to advise (frame G3).
    static func saysConsequence(_ line: Line) -> Bool {
        guard line.state == .blocked else { return false }
        if line.purpose == .switchSync { return line.keepShown }
        return consequences.contains(line.purpose)
    }

    enum State: Equatable {
        case allowed, blocked, kept, ownSwitch, notSetUp, always

        var wordKey: String {
            switch self {
            case .allowed: "mac.net_s_allowed"
            case .blocked: "mac.net_s_blocked"
            case .kept: "mac.net_s_kept"
            case .ownSwitch: "mac.net_s_own"
            case .notSetUp: "mac.net_s_unset"
            case .always: "mac.net_s_always"
            }
        }
    }

    struct Line: Identifiable, Equatable {
        let purpose: OutboundPurpose
        var id: String { purpose.rawValue }
        let state: State
        let automatic: Bool
        /// Whether the Keep tick is drawn, and whether it is ticked.
        let keepShown: Bool
        let kept: Bool
        let blocked: OutboundGate.Blocked?
    }

    /// The list, from the rule's rows.
    ///
    /// - `setUp`: the purposes the shop has not configured read "Not set up",
    ///   whatever the switch says; nothing would be sent either way.
    /// - `offline`: either switch is on. The Keep column exists only then
    ///   (frame B has none).
    /// - `ownOff`: the three with a switch of their own (the install count,
    ///   crash reports, usage statistics) that is off. The rule says so only
    ///   while the shop is online; while it is offline it answers "offline"
    ///   first, and the row would read Blocked for something the shop never
    ///   turned on. The frames say "Off (its own switch)" in both.
    /// - `shopOffline`: the SHOP's switch is on. Keep ticks belong to it
    ///   alone: this Mac's own switch is answered before `keep`, so under it
    ///   a tick would be drawn, written to the shared book, and ignored.
    static func lines(rows: [OutboundGate.Row], offline: Bool, shopOffline: Bool? = nil, notSetUp: Set<OutboundPurpose>,
                      ownOff: Set<OutboundPurpose> = [], viaCloud: Bool = false,
                      blocked: [OutboundPurpose: OutboundGate.Blocked]) -> [Line] {
        let byId = Dictionary(rows.map { ($0.purpose, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { purpose in
            guard let row = byId[purpose.rawValue] else { return nil }
            let state: State
            if purpose == .lan { state = .always }
            else if notSetUp.contains(purpose) { state = .notSetUp }
            else if row.reason == "opted-out" || ownOff.contains(purpose) { state = .ownSwitch }
            else if offline, row.kept, row.allowed { state = .kept }
            else if row.allowed { state = .allowed }
            else { state = .blocked }
            return Line(purpose: purpose, state: state, automatic: row.automatic,
                        // The switch-sync row's tick exists only where the rule
                        // reads it: the switch came through Khayt Cloud.
                        keepShown: (shopOffline ?? offline) && purpose != .lan
                            && (purpose != .switchSync || viaCloud),
                        kept: row.kept,
                        blocked: state == .blocked ? blocked[purpose] : nil)
        }
    }

    /// A row's name. MakerRun is a name, the same in every language, so it
    /// is not a word in the tables.
    @MainActor static func title(_ purpose: OutboundPurpose, _ words: Words) -> String {
        purpose == .makerrun ? "MakerRun" : words.callIt("mac.net_t_" + purpose.rawValue)
    }

    /// The line under "Make no internet calls", in whole sentences (frames
    /// F1–F3): who follows the switch, who turned it on and when, and whether
    /// the other computers were told.
    struct ShopLine: Equatable {
        var offline = false
        var tellsOthers = false
        var by: String?
        var at: Date?
        var told: Shop.ToldOthers?
        /// The switch was turned on here and Khayt Cloud kept another
        /// computer's change instead (the question of frame G2 is waiting):
        /// only this Mac follows it, and the others were not told.
        var onlyHere = false
    }

    @MainActor static func sentence(_ line: ShopLine, words: Words) -> String {
        var parts = [words.callIt(line.tellsOthers ? "mac.net_who_shop" : "mac.net_who_mac")]
        guard line.offline else { return (parts + [words.callIt("mac.net_off_tail")]).joined(separator: " ") }
        // Khayt Cloud was reached and this change was not the one it kept:
        // neither "were told" nor "could not be reached" is claimed (G2).
        if line.onlyHere { parts = [words.callIt("mac.net_who_only_mac")] }
        if let at = line.at {
            let fields: [String: JSONValue] = ["date": .string(words.say(at, .dateTime.day().month(.abbreviated))),
                                               "time": .string(words.say(at, .dateTime.hour().minute())),
                                               "name": .string(line.by ?? "")]
            parts.append(words.callIt(line.by == nil ? "mac.net_on_anon" : "mac.net_on_by", fields))
        }
        parts.append(words.callIt("mac.net_stopped"))
        if line.onlyHere { return (parts + [words.callIt("mac.net_not_told")]).joined(separator: " ") }
        guard line.tellsOthers else { return (parts + [words.callIt("mac.net_not_told")]).joined(separator: " ") }
        switch line.told {
        case .told(let when)?:
            parts.append(words.callIt("mac.net_told", ["time": .string(words.say(when, .dateTime.hour().minute()))]))
        case .failed?: parts.append(words.callIt("mac.net_tell_failed"))
        case nil: parts.append(words.callIt("mac.net_not_told"))
        }
        parts.append(words.callIt("mac.net_phones_follow"))
        return parts.joined(separator: " ")
    }

    /// How many whole days since a check for updates last went out, when the
    /// switch is what stops them. Nil while updates are allowed or kept.
    /// Counted from the last check that went out; a Mac that never checked
    /// counts from when the switch was turned on.
    ///
    /// From whichever is LATER: a Mac whose last check was two months ago and
    /// whose switch went on today has been without them, because of the
    /// switch, for no days yet. A stamp in the future is read as now.
    static func daysWithoutUpdates(allowed: Bool, lastChecked: Date?, switchedAt: Date?, now: Date) -> Int? {
        guard !allowed else { return nil }
        guard let since = [lastChecked, switchedAt].compactMap({ $0 }).map({ min($0, now) }).max() else { return nil }
        return max(0, Int(now.timeIntervalSince(since) / 86_400))
    }

    /// The banner on every screen appears from this many days (D2).
    static let bannerAfterDays = 30

    /// `settings.network.changedAt`, when it is a date.
    static func switchedAt(_ network: [String: JSONValue]) -> Date? {
        guard case .string(let text)? = network["changedAt"] else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func switchedBy(_ network: [String: JSONValue]) -> String? {
        guard case .string(let name)? = network["changedBy"], !name.isEmpty else { return nil }
        // The book is shared; a name is a name, not a paragraph.
        return String(name.prefix(60))
    }
}

extension Shop {

    /// What the shop has not set up, so its row says so in place of Allowed
    /// or Blocked. Each is the check the feature's own code makes before it
    /// sends; nothing here opens a secret.
    func internetUseNotSetUp(makerRunLinked: Bool) -> Set<OutboundPurpose> {
        let s = settingsDict
        func object(_ key: String) -> [String: JSONValue] { if case .object(let o)? = s[key] { return o }; return [:] }
        func on(_ value: JSONValue?) -> Bool { value == .bool(true) }
        func filled(_ value: JSONValue?) -> Bool { if case .string(let t)? = value { return !t.isEmpty }; return false }
        var missing: Set<OutboundPurpose> = []
        if !cloudConnected { missing.insert(.cloud) }
        // A bucket or Drive of the shop's own. The vault is Khayt Cloud's row.
        let remote = CloudLibrary.remoteInUse(s)
        if remote != .bucket, remote != .drive, !offsite.settings.enabled { missing.insert(.storage) }
        let ntfy = object("ntfy"), telegram = object("telegram")
        // "none" and "mailto" are saved by the email screen and send nothing from here.
        let emails = !["", "none", "mailto"].contains(emailProvider)
        let messaging = emails || smsProvider != nil || whatsAppBusinessAccount() != nil
            || (on(ntfy["enabled"]) && filled(ntfy["topic"]))
            || (filled(telegram["botToken"]) && filled(telegram["chatId"]))
        if !messaging { missing.insert(.messaging) }
        let webhooks = on(object("webhooks")["enabled"]) || on(object("eventWebhooks")["enabled"])
            || on(object("accountingSync")["enabled"]) || (ConnectorsSwitch.isOn() && !connectorEntries.isEmpty)
        if !webhooks { missing.insert(.webhooks) }
        // The store is asked of the cloud; unknown is not "not set up".
        if !cloudConnected || webStoreLive == false { missing.insert(.storefront) }
        if bnplProvidersOffered.isEmpty { missing.insert(.payments) }
        let ai = object("ai")
        if !filled(ai["apiKey"]), ai["provider"] != .string("compatible") { missing.insert(.ai) }
        if !ZatcaSubmit.phase2Ready(settings: s) { missing.insert(.taxAuthority) }
        if !makerRunLinked { missing.insert(.makerrun) }
        // Every Mac signed in to Khayt Cloud asks it for the shop's switch
        // while it may; one that is not signed in asks nothing.
        if !cloudConnected { missing.insert(.switchSync) }
        return missing
    }

    /// The whole list as the page draws it.
    func internetUseLines(makerRunLinked: Bool) -> [InternetUse.Line] {
        var ownOff: Set<OutboundPurpose> = []
        if !telemetryConsent.crash { ownOff.insert(.crashReports) }
        if !telemetryConsent.usage { ownOff.insert(.usageStats) }
        if outboundLocal.installCountOff { ownOff.insert(.installCount) }
        return InternetUse.lines(rows: outboundGate.rows(), offline: outboundGate.isOffline,
                          shopOffline: outboundGate.isShopOffline,
                          notSetUp: internetUseNotSetUp(makerRunLinked: makerRunLinked), ownOff: ownOff,
                          viaCloud: networkSwitchViaCloud,
                          blocked: outboundGate.blockedCounts())
    }

    /// Days without an update check, for the row and the banner: only while
    /// one of the two switches is what refuses it (never while the book is
    /// still unread, and never for a shop that is online).
    func daysWithoutUpdates(now: Date = Date()) -> Int? {
        let verdict = outboundGate.verdict(.updates)
        guard !verdict.allowed, verdict.reason == "offline" || verdict.reason == "offline-here" else { return nil }
        // When the switch that refuses it was turned on: this Mac's own, or the shop's.
        var switched: [Date] = []
        if outboundOfflineHere, let at = outboundDefaults.object(forKey: Self.offlineHereAtKey) as? Date { switched.append(at) }
        if outboundGate.isShopOffline, let at = InternetUse.switchedAt(networkSettings) { switched.append(at) }
        return InternetUse.daysWithoutUpdates(allowed: false, lastChecked: Updates.shared.lastChecked,
                                              switchedAt: switched.min(), now: now)
    }
}

// MARK: - The page

struct InternetUsePage: View {
    let shop: Shop
    var done: (() -> Void)?
    /// A photograph's stand-ins: the list as given, and "now".
    var pretend: [InternetUse.Line]?
    var now = Date()

    @State private var makerRunLinked = false
    @State private var tick = 0
    @Environment(\.photographFlat) private var flat

    private var words: Words { shop.words }
    private var lines: [InternetUse.Line] {
        _ = tick; _ = shop.outboundRevision
        return pretend ?? shop.internetUseLines(makerRunLinked: makerRunLinked)
    }
    /// The shop's switch as the RULE reads it, so the switch drawn here and
    /// the rows below it can never disagree.
    private var shopOffline: Bool { _ = shop.outboundRevision; return shop.outboundGate.isShopOffline }
    private var mayChange: Bool { pretendMayChange ?? shop.mayChangeOutbound }

    var body: some View {
        VStack(spacing: 0) {
            // The offscreen renderer draws nothing inside a scroll view, so a
            // photograph gets the content itself, at its full height.
            if flat { content } else { ScrollView { content } }
            if let done {
                Divider()
                HStack {
                    Spacer()
                    Button(words.callIt("common.done"), action: done).keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .background(Khayt.ground)
        .task {
            guard pretend == nil else { return }
            makerRunLinked = await shop.makerRun.isLinked()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("mac.net_title")).font(.system(size: 20, weight: .semibold))
            Text(words.callIt("mac.net_sub")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A slicer is its own program: Snapmaker Orca reports its crashes
            // and errors over the internet by itself (seen Nov 27), and this
            // switch cannot stop it. Said, so the switch never claims more.
            Text(words.callIt("mac.net_slicers")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The question waiting for the owner, here too: the every-screen
            // notice's link leads to this page (frames G1 and G2).
            if let ask = pretendAsk ?? (pretend == nil ? shop.networkSwitchAsk : nil) {
                NetworkSwitchQuestion(shop: shop, ask: ask, link: false, rounded: true, pretendMayAnswer: pretendMayChange,
                                      pretendThere: pretendThere)
            }
            switches
            // Frame H: the "off" made here waits for a sign-in. Under the
            // switch, and only for somebody who may change it.
            if pretendSignInEnded ?? (pretend == nil && shop.networkSwitchSignInEnded), mayChange {
                NetworkSwitchSignIn(shop: shop, pretendBy: pretendShopLine.map { $0.by }, pretendAt: pretendShopLine.map { $0.at })
            }
            Text(words.callIt("mac.net_list")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).padding(.top, 4)
            list
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The two switches

    private var switches: some View {
        card {
            switchRow(title: words.callIt("mac.net_switch"), note: shopNote, isOn: shopLine.offline, name: "internet-use-shop") { on in
                Task { await shop.setOutboundOffline(on); tick += 1 }
            }
            Divider()
            if offersTelling {
                switchRow(title: words.callIt("mac.net_tell"),
                          note: words.callIt(shopLine.tellsOthers ? "mac.net_tell_on" : "mac.net_tell_off"),
                          isOn: shopLine.tellsOthers, name: "internet-use-tell") { on in
                    shop.setOutboundTellsOthers(on); tick += 1
                }
                Divider()
            }
            switchRow(title: words.callIt("mac.net_here"), note: words.callIt("mac.net_here_note"),
                      isOn: pretendHere ?? shop.outboundOfflineHere, name: "internet-use-here") { on in
                shop.setOutboundOfflineHere(on); tick += 1
            }
            if !mayChange {
                Text(words.callIt("mac.net_owner_only")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            // A change that was not made says why HERE: the shop window's
            // banner is behind this sheet.
            if pretend == nil, let problem = shop.moveProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Khayt.late)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shopLine: InternetUse.ShopLine {
        pretendShopLine ?? .init(offline: shopOffline, tellsOthers: shop.outboundTellsOthers,
                                 by: InternetUse.switchedBy(shop.networkSettings),
                                 at: InternetUse.switchedAt(shop.networkSettings), told: shop.outboundToldOthers,
                                 onlyHere: InternetUse.onlyHere(shop.networkSwitchAsk, there: shop.networkSwitchHeld?.offline))
    }
    /// A capture's stand-in for the question waiting, and for who may answer.
    var pretendAsk: NetworkSwitchAsk?
    var pretendThere: Bool??
    var pretendShopLine: InternetUse.ShopLine?
    var pretendHere: Bool?
    var pretendMayChange: Bool?
    /// A capture's stand-in for frame H.
    var pretendSignInEnded: Bool?
    /// Whether the "tell my other computers" row is drawn (`Shop.tellOthersOffered`).
    var offersTelling = Shop.tellOthersOffered

    private var shopNote: String { InternetUse.sentence(shopLine, words: words) }

    private func switchRow(title: String, note: String, isOn: Bool, name: String,
                           set: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if flat {
                // The offscreen renderer draws a native switch as a yellow
                // placeholder; a photograph gets a drawn one.
                DrawnSwitch(isOn: isOn)
            } else {
                Toggle(title, isOn: Binding(get: { isOn }, set: set))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!mayChange)
                    .accessibilityIdentifier(name)
            }
        }
    }

    // MARK: The list

    private var showsKeep: Bool { lines.contains(where: \.keepShown) }

    private var list: some View {
        card {
            HStack(alignment: .top, spacing: 0) {
                Text(words.callIt("mac.net_col_what")).frame(maxWidth: .infinity, alignment: .leading)
                Text(words.callIt("mac.net_col_when")).frame(width: 100, alignment: .leading)
                Text(words.callIt("mac.net_col_state")).frame(width: 140, alignment: .leading)
                Text(showsKeep ? words.callIt("mac.net_col_off") : " ").frame(width: 70, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Divider()
            ForEach(lines) { line in
                row(line)
            }
        }
    }

    private func row(_ line: InternetUse.Line) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(InternetUse.title(line.purpose, words)).font(.system(size: 13, weight: .medium))
                Text(description(line)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if InternetUse.saysConsequence(line) {
                    Text(consequence(line.purpose)).font(.system(size: 12))
                        .foregroundStyle(updatesOverdue(line) ? Khayt.late : Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 10)
            Text(words.callIt(line.automatic ? "mac.net_auto" : "mac.net_asked"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            stateChip(line.state).frame(width: 140, alignment: .leading)
            Group {
                if line.keepShown { keep(line) } else { Color.clear.frame(height: 1) }
            }
            .frame(width: 70, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private func updatesOverdue(_ line: InternetUse.Line) -> Bool {
        line.purpose == .updates && (updateDays ?? 0) >= InternetUse.bannerAfterDays
    }

    private var updateDays: Int? {
        pretend == nil ? shop.daysWithoutUpdates(now: now) : pretendUpdateDays
    }
    var pretendUpdateDays: Int?
    var pretendLastChecked: Date?

    private func description(_ line: InternetUse.Line) -> String {
        var text = words.callIt("mac.net_d_" + line.purpose.rawValue)
        if let blocked = line.blocked, blocked.count > 0 {
            let time = JSONValue.string(words.say(blocked.last, .dateTime.hour().minute()))
            text += " " + (blocked.count == 1
                ? words.callIt("mac.net_blocked_1", ["time": time])
                : words.callIt("mac.net_blocked_n", ["n": .string(words.numeral(blocked.count)), "time": time]))
        }
        return text
    }

    private func consequence(_ purpose: OutboundPurpose) -> String {
        guard purpose == .updates else { return words.callIt("mac.net_c_" + purpose.rawValue) }
        guard let last = pretend == nil ? Updates.shared.lastChecked : pretendLastChecked else {
            return words.callIt("mac.net_c_updates_never")
        }
        let date = JSONValue.string(words.say(last, .dateTime.day().month(.abbreviated).year()))
        if let days = updateDays, days >= InternetUse.bannerAfterDays {
            return words.callIt("mac.net_c_updates_days", ["date": date, "n": .string(words.numeral(days))])
        }
        return words.callIt("mac.net_c_updates", ["date": date])
    }

    @ViewBuilder private func stateChip(_ state: InternetUse.State) -> some View {
        let text = Text(words.callIt(state.wordKey)).font(.system(size: 11, weight: .medium))
        switch state {
        case .blocked:
            text.foregroundStyle(Khayt.late).padding(.horizontal, 8).padding(.vertical, 2)
                .background(Khayt.late.opacity(0.12), in: Capsule())
        case .kept:
            text.foregroundStyle(Khayt.done).padding(.horizontal, 8).padding(.vertical, 2)
                .background(Khayt.done.opacity(0.12), in: Capsule())
        case .allowed:
            text.foregroundStyle(.primary).padding(.horizontal, 8).padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(Khayt.hairline))
        case .always:
            text.foregroundStyle(.primary).padding(.horizontal, 8).padding(.vertical, 2)
        case .ownSwitch, .notSetUp:
            text.foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 2)
        }
    }

    private func keep(_ line: InternetUse.Line) -> some View {
        let label = words.callIt("mac.net_keep")
        return Group {
            if flat {
                HStack(spacing: 5) {
                    DrawnTick(isOn: line.kept)
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Toggle(isOn: Binding(get: { line.kept }, set: { kept in
                    Task { await shop.setOutboundKeep(line.purpose, kept); tick += 1 }
                })) {
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox).controlSize(.small)
                .disabled(!mayChange)
                .accessibilityLabel(label + ": " + InternetUse.title(line.purpose, words))
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Khayt.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Khayt.hairline))
    }
}

/// A switch drawn for a photograph (the offscreen renderer cannot draw the
/// native one).
struct DrawnSwitch: View {
    let isOn: Bool
    var body: some View {
        Capsule().fill(isOn ? Khayt.brand : Color.secondary.opacity(0.35))
            .frame(width: 28, height: 16)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 12, height: 12).padding(2)
            }
    }
}

struct DrawnTick: View {
    let isOn: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3).fill(isOn ? Khayt.brand : Khayt.surface)
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isOn ? Khayt.brand : Color.secondary.opacity(0.5)))
            .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
    }
}

// MARK: - Where it is opened from

/// The row in Settings ▸ General that opens the page.
struct InternetUseRow: View {
    let shop: Shop
    @State private var open = false
    private var isOn: Bool { _ = shop.outboundRevision; return shop.outboundGate.isOffline }

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shop.words.callIt("mac.net_title"))
                    Text(shop.words.callIt(isOn ? "mac.net_row_on" : "mac.net_row_off"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(shop.words.callIt("mac.net_open")) { open = true }
                    .accessibilityIdentifier("internet-use-open")
            }
            .shopSheet(isPresented: $open) {
                InternetUsePage(shop: shop, done: { open = false })
                    // Inside the Settings window's own minimum (800 × 640).
                    .frame(width: 780, height: 600)
            }
            .onChange(of: shop.opensInternetUse) { _, wanted in
                if wanted { open = true; shop.opensInternetUse = false }
            }
            .onAppear {
                if shop.opensInternetUse { open = true; shop.opensInternetUse = false }
            }
        }
    }
}

/// "Open Internet use", beside a refusal and on the banner (frames C and D).
struct OpenInternetUse: View {
    let shop: Shop
    var body: some View {
        SettingsLink { Text(shop.words.callIt("mac.net_open_use")) }
            .simultaneousGesture(TapGesture().onEnded {
                shop.settingsPane = .general
                shop.opensInternetUse = true
            })
    }
}

/// The banner on every screen once no update check has gone out for 30 days
/// (frame C, D2). Not closable: it goes when updates are kept or the switch
/// is turned off.
struct UpdatesBlockedBanner: View {
    let shop: Shop
    var now = Date()

    var body: some View {
        let _ = shop.outboundRevision
        if let days = shop.daysWithoutUpdates(now: now), days >= InternetUse.bannerAfterDays {
            let here = shop.outboundGate.verdict(.updates).reason == "offline-here"
            Banner(text: shop.words.callIt(here ? "mac.net_banner_here" : "mac.net_banner",
                                           ["n": .string(shop.words.numeral(days))]),
                   symbol: "exclamationmark.shield", tint: Khayt.late) {
                HStack(spacing: 8) {
                    // Keeping updates is the shop's switch's Keep tick; it
                    // cannot loosen this Mac's own switch.
                    if shop.mayChangeOutbound, !here {
                        Button(shop.words.callIt("mac.net_keep_updates")) {
                            Task { await shop.setOutboundKeep(.updates, true) }
                        }
                    }
                    OpenInternetUse(shop: shop)
                }
            }
        }
    }
}
