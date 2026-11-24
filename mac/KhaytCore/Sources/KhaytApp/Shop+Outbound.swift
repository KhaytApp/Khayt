import Foundation
import KhaytCore

/// "Make no internet calls" on the Mac (P8; `lib/outbound.js`, Figma Mac
/// file page 27): what the shop's switch and this Mac's own switch are, who
/// may change them, and telling the gate every call site asks
/// (`OutboundGate`).
///
/// ── TWO SWITCHES ─────────────────────────────────────────────────────────
///
/// The SHOP's is in the book, `settings.network.offline`, so every computer
/// and the phone follow it. THIS MAC's is in UserDefaults and can only be
/// stricter. The rule reads both; nothing here decides what either blocks.
///
/// ── ONLY THE OWNER CHANGES EITHER (Turki, Nov 22) ─────────────────────────
///
/// `security`/`edit`, as the staff lock and the Orca price switch are, asked
/// in the write. A manager sees the pane and cannot change it.
///
/// ── WHAT IS WRITTEN (the design's names, shared with the desktop) ─────────
///
/// `settings.network = { offline, keep: [purpose ids], changedAt, changedBy }`.
/// `changedAt` and `changedBy` are stamped when `offline` CHANGES, in either
/// direction, and stay when it is turned off. A Keep tick leaves them alone:
/// re-stamping them would re-date "Turned on by" and restart the 30-day
/// updates clock.
extension Shop {

    nonisolated static let offlineHereKey = "network.offlineHere"
    nonisolated static let offlineHereAtKey = "network.offlineHereAt"

    /// The app's first act: the book is unread, and this Mac's own switches
    /// are known already. Never puts a loaded shop back to "starting".
    ///
    /// Only in the app itself: a development run (`swift run`, the snapshot
    /// runner) has no shop feeding the gate, and would stay "starting", so
    /// offline, for its whole life.
    static func outboundBegins(defaults: UserDefaults = .standard, gate: OutboundGate = .app,
                               inTheApp: Bool = Shop.inTheApp) {
        guard inTheApp else { return }
        gate.update(local: .init(offline: defaults.bool(forKey: offlineHereKey),
                                 installCountOff: defaults.bool(forKey: ActiveCountSender.offKey)))
        if gate.currentBook == .none { gate.update(book: .unread) }
    }

    // MARK: - Reading

    /// `settings.network`, as the book holds it.
    var networkSettings: [String: JSONValue] {
        if case .object(let n)? = settingsDict["network"] { return n }
        return [:]
    }

    /// This Mac's own switch.
    var outboundOfflineHere: Bool { outboundDefaults.bool(forKey: Self.offlineHereKey) }

    /// What this Mac says for itself: its own switch, and its install-count switch.
    var outboundLocal: OutboundGate.Local {
        .init(offline: outboundOfflineHere,
              installCountOff: outboundDefaults.bool(forKey: ActiveCountSender.offKey))
    }

    /// Tell the gate what this shop's settings and this Mac say now. Called
    /// whenever the settings are set, and after either local switch changes.
    ///
    /// ONLY THE SHOP'S OWN BOOK SAYS. The sample book has no switch, so
    /// opening it (anyone can, from the book menu) would otherwise put an
    /// offline shop's Mac back online: updates, the install count and public
    /// addresses typed into a printer would all go out again. While the
    /// sample is open, and when the shop's book cannot be read, the gate
    /// keeps what the shop's book last said (`lastKnownKey`).
    func tellOutboundGate() {
        guard feedsOutboundGate else { return }
        outboundGate.update(local: outboundLocal)
        outboundGate.update(book: .settings(Self.outboundBook(real: source.isReal || networkBookForTests != nil, settings: settingsDict,
                                                              defaults: outboundDefaults)))
        // Whether the shop's own book has the staff lock on, remembered for
        // this Mac's own switches (`thisMacsSwitchesAreOpen`).
        if source.isReal, outboundDefaults.bool(forKey: Self.lockLastKnownKey) != lockSwitchedOn {
            outboundDefaults.set(lockSwitchedOn, forKey: Self.lockLastKnownKey)
        }
        outboundRevision &+= 1
    }

    /// The settings the gate goes by: the shop's own book's, remembered on
    /// this Mac as they are read; for any other book, what was remembered.
    nonisolated static func outboundBook(real: Bool, settings: [String: JSONValue], defaults: UserDefaults) -> JSONValue {
        guard real else { return lastKnownSettings(defaults, telemetry: settings["telemetry"]) }
        let network = settings["network"] ?? .object([:])
        if let data = try? JSONEncoder().encode(network), data != defaults.data(forKey: lastKnownKey) {
            defaults.set(data, forKey: lastKnownKey)
        }
        return .object(settings.filter { OutboundGate.settingsRead.contains($0.key) })
    }

    /// The shop's `settings.network` as its book last said it, kept on this
    /// Mac for the moments no book of the shop's is open.
    nonisolated static let lastKnownKey = "network.lastKnown"

    nonisolated static func lastKnownSettings(_ defaults: UserDefaults, telemetry: JSONValue? = nil) -> JSONValue {
        var settings: [String: JSONValue] = [:]
        if let data = defaults.data(forKey: lastKnownKey), let network = try? JSONDecoder().decode(JSONValue.self, from: data) {
            settings["network"] = network
        }
        if let telemetry { settings["telemetry"] = telemetry }
        return .object(settings)
    }

    /// The shop's book could not be read. The gate must not stay "starting"
    /// for ever (nothing but the shop's network would ever be called, not
    /// even the cloud the shop would restore from): it goes by what the book
    /// last said, which for a Mac that never had the switch on is online.
    func outboundLoadFailed() {
        guard feedsOutboundGate, outboundGate.currentBook == .unread else { return }
        outboundGate.update(local: outboundLocal)
        outboundGate.update(book: .settings(Self.lastKnownSettings(outboundDefaults)))
    }

    /// May whoever is here change either switch, or a Keep tick? Asks, says nothing.
    var mayChangeOutbound: Bool { lockAllows("security", "edit") }

    // MARK: - Writing

    /// `settings.network` with the shop's switch set. The stamp moves only
    /// when the switch itself changes; `keep` is left as it was.
    nonisolated static func network(_ network: JSONValue?, offline: Bool, by name: String?, at: Date,
                                    viaCloud: Bool? = nil) -> JSONValue {
        Self.network(network, offline: offline, by: name, stamp: StoreWriter.iso(at), viaCloud: viaCloud)
    }

    /// The same, with the stamp AS TEXT, written exactly as given. A stamp
    /// the shared rule made (one millisecond after another) must not pass
    /// through a `Date` on its way to the book: a thousandth of a second is
    /// not exact in a Double, and written back it can land one millisecond
    /// early, on the very stamp it has to be later than.
    nonisolated static func network(_ network: JSONValue?, offline: Bool, by name: String?, stamp: String,
                                    viaCloud: Bool? = nil) -> JSONValue {
        var n: [String: JSONValue] = { if case .object(let o)? = network { return o }; return [:] }()
        // Anything stored that is not exactly `false` reads as on (the rule's
        // `onSwitch`), so "was it on" is asked the same way.
        let was: Bool = { guard let v = n["offline"] else { return false }; return v != .bool(false) && v != .null }()
        n["offline"] = .bool(offline)
        if was != offline {
            n["changedAt"] = .string(stamp)
            n["changedBy"] = name.map(JSONValue.string) ?? .null
        }
        // Whether this change went through Khayt Cloud (nil: not a change).
        if let viaCloud { n["via"] = viaCloud ? .string(NetworkSwitch.viaCloud) : nil }
        return .object(n)
    }

    /// Whether a stored `settings.network` has the switch on, read as the
    /// rule reads it: anything but exactly `false` (or absent) is on.
    nonisolated static func offlineOf(_ network: JSONValue?) -> Bool {
        guard case .object(let n)? = network, let v = n["offline"] else { return false }
        return v != .bool(false) && v != .null
    }

    /// `settings.network` with one purpose kept, or no longer kept, while
    /// offline. Only a purpose the rule knows, never `lan` (always allowed)
    /// and never `tunnel` (the Mac has none). The stamp is not touched.
    nonisolated static func network(_ network: JSONValue?, keep purpose: OutboundPurpose, _ kept: Bool) -> JSONValue {
        var n: [String: JSONValue] = { if case .object(let o)? = network { return o }; return [:] }()
        // The switch-sync call is not in `keep`: unticking its row writes
        // `dropSwitchSync`, which the rule reads (`switchSyncKept`).
        if purpose == .switchSync {
            if kept { n["dropSwitchSync"] = nil } else { n["dropSwitchSync"] = .bool(true) }
            return .object(n)
        }
        var list: [String] = { if case .array(let a)? = n["keep"] { return a.compactMap { if case .string(let s) = $0 { s } else { nil } } }; return [] }()
        list.removeAll { $0 == purpose.rawValue }
        if kept { list.append(purpose.rawValue) }
        let known = Set(OutboundPurpose.allCases.map(\.rawValue))
        n["keep"] = .array(list.filter { known.contains($0) && !NetworkSwitch.neverKept.contains($0) }.map(JSONValue.string))
        return .object(n)
    }

    /// The kept purposes replaced as a whole (a phone sends the list it
    /// showed). Only purposes that may be kept, in the rule's own order.
    nonisolated static func network(_ network: JSONValue?, keepAll kept: [OutboundPurpose]) -> JSONValue {
        var n: [String: JSONValue] = { if case .object(let o)? = network { return o }; return [:] }()
        let wanted = Set(kept.map(\.rawValue))
        let mine = Set(phoneKeepable.map(\.rawValue))
        // What is in the book that this list does not speak for stays: a
        // purpose only a newer app knows, ticked there, is not this request's
        // to untick.
        let others: [JSONValue] = { if case .array(let a)? = n["keep"] { return a.filter { if case .string(let s) = $0 { !mine.contains(s) } else { false } } }; return [] }()
        n["keep"] = .array(phoneKeepable.map(\.rawValue).filter { wanted.contains($0) }.map(JSONValue.string) + others)
        return .object(n)
    }

    /// The purposes a PHONE may send in `keep`: every purpose the rule lets a
    /// shop keep, which is all of them but `lan` and the switch-sync call.
    /// Wider than the Mac's own rows (`keepable` leaves out the tunnel, which
    /// the Mac does not have): the Windows/Linux app can tick it, the phone is
    /// then shown it, and a phone must be able to send back the list it showed.
    nonisolated static let phoneKeepable: [OutboundPurpose] = OutboundPurpose.allCases.filter {
        !NetworkSwitch.neverKept.contains($0.rawValue)
    }

    /// The purposes a shop may tick Keep on, on the Mac.
    nonisolated static let keepable: [OutboundPurpose] = OutboundPurpose.allCases.filter { $0 != .lan && $0 != .tunnel }

    private func writeNetwork(_ change: @escaping @Sendable (JSONValue?) -> JSONValue) async -> Bool {
        // lock: callers — changeOutboundOffline, setOutboundKeep
        if networkBookForTests == nil, source.build == nil { moveProblem = words.callIt("mac.move_sample"); return false }
        return await writeNetworkSettings(change, says: true)
    }

    /// The stamps a new change must come after: this Mac's own and the
    /// highest heard, but ONLY those within what a stamp may be ahead of the
    /// clock (`NetworkSwitch.aheadAllowed`, ten minutes: the limit a value is
    /// applied under and the server accepts). A stamp further ahead is a
    /// mistake already in the book (a clock that was wrong once, a book
    /// restored from a Mac whose clock was): following it would stamp every
    /// later change in that future, where the server refuses it and no other
    /// computer applies it, until the real date caught up.
    func stampsToComeAfter(now: Date) -> [String] {
        [networkSwitchOwnStamp, networkSwitchHighestSeen].compactMap { stamp -> String? in
            guard let stamp, let when = NetworkSwitch.date(stamp), when <= now.addingTimeInterval(NetworkSwitch.aheadAllowed) else { return nil }
            return stamp
        }
    }

    /// The stamp a change made now carries: the shared rule's
    /// (`lib/network-switch.js stampAfter`), as text. With no engine, or if
    /// the rule cannot be asked, the clock: no worse than before the rule.
    func outboundChangeStamp(now: Date) async -> String {
        let seen = stampsToComeAfter(now: now)
        if let stamped = try? await engine?.networkSwitchStampAfter(now: now, seen: seen), NetworkSwitch.date(stamped) != nil {
            return stamped
        }
        return StoreWriter.iso(now)
    }

    /// Turn the shop's switch on or off. The owner's alone.
    ///
    /// THIS MAC STOPS AT ONCE: the gate is told as soon as the book is
    /// written. Nothing is sent first. The native Mac never sends settings
    /// to Khayt Cloud and never takes them from it (`cloud-outbox.js`: a
    /// setting is one object, with nowhere to go in a change), so there is no
    /// announcement it could make; a phone reads the switch from this Mac's
    /// own book over the shop's network. How the other computers learn is not
    /// decided here (an open question on the draft).
    @discardableResult
    func setOutboundOffline(_ on: Bool, now: Date = Date()) async -> Bool {
        moveProblem = nil
        guard permitted("security", "edit") else { return false }
        let name: String? = lockInForce ? signedIn?.name : nil
        return await changeOutboundOffline(on, by: name, keep: nil, now: now)
    }

    /// The change itself, for whoever was let through: the owner at this Mac
    /// (`setOutboundOffline`) or an owner's phone on the signed route
    /// (`phoneSetOutbound`). ONE path, so a flip from the phone is stamped,
    /// told to the other computers and applied here exactly as one made at
    /// the Mac. `keep`, when given, replaces the kept purposes in the same
    /// write; nil leaves them as they are.
    func changeOutboundOffline(_ on: Bool, by name: String?, keep: [OutboundPurpose]?, now: Date = Date()) async -> Bool {
        // lock: callers — setOutboundOffline, phoneSetOutbound
        // One change at a time: a second click while the last call is in
        // flight would be judged against a book that is about to change.
        guard !outboundChanging else { return false }
        outboundChanging = true
        defer { outboundChanging = false }
        let before = networkSettings
        // The stamp is monotonic: never earlier than the newest one this Mac
        // has seen (the book's own and the highest heard from Khayt Cloud),
        // so a computer whose clock runs ahead cannot make every change made
        // here lose. The shared rule says when (`stampAfter`, as on the
        // desktop), and its answer is written as it came.
        let at = await outboundChangeStamp(now: now)
        let kept = keep
        let withKeep: @Sendable (JSONValue) -> JSONValue = { value in
            guard let kept else { return value }
            return Self.network(value, keepAll: kept)
        }
        let next = withKeep(Self.network(.object(before), offline: on, by: name, stamp: at))
        let changed = Self.offlineOf(.object(before)) != on
        let stamp: String? = { if changed, case .object(let n) = next, case .string(let s)? = n["changedAt"] { return s }; return nil }()
        // What this Mac had seen before this change, for judging what another
        // computer set at the same moment.
        let seenBefore = NetworkSwitch.later(networkSwitchHighestSeen, networkSwitchOwnStamp)
        // TURNED ON, WITH THE OPTION ON: the one last call, while this Mac may
        // still make it. Ten seconds at most; then it stops whatever came back.
        // It "came through Khayt Cloud" only if that call was answered: then
        // the rule keeps the one call that hears it turned off. A switch
        // turned on with nothing sent, or turned off, is this Mac's alone.
        var told = false
        if on, changed { told = await tellOthersSwitchedOn(next) }
        // Sent, so seen: whatever becomes of the write below, the value this
        // Mac itself published is never taken for another computer's.
        if told, let stamp { sawNetworkSwitchStamp(stamp, now: now) }
        let via: Bool? = changed ? (on && told) : nil
        guard await writeNetwork({ withKeep(Self.network($0, offline: on, by: name, stamp: at, viaCloud: via)) }) else { return false }
        if let stamp { sawNetworkSwitchStamp(stamp, now: now) }
        if keep != nil { tellOutboundGate() }
        // TURNED OFF: this Mac is online again; its first calls say so to
        // Khayt Cloud if a value is published there (`Shop+NetworkSwitch`).
        if !on, changed { await tellOthersSwitchedOff(next, seenBefore: seenBefore) }
        if !on, !outboundGate.isOffline { outboundGate.clearCounts() }
        if !on { outboundNotice = nil }
        await reloadAfterNetworkWrite()
        return true
    }

    /// Tick or untick Keep for one purpose. The owner's alone.
    @discardableResult
    func setOutboundKeep(_ purpose: OutboundPurpose, _ kept: Bool) async -> Bool {
        moveProblem = nil
        guard permitted("security", "edit") else { return false }
        guard Self.keepable.contains(purpose) else { return false }
        guard await writeNetwork({ Self.network($0, keep: purpose, kept) }) else { return false }
        if kept { outboundNotice = nil }
        await reloadAfterNetworkWrite()
        tellOutboundGate()
        return true
    }

    /// Turn this Mac's own switch on or off. The owner's alone too: it can
    /// only make this Mac stricter, but turning it OFF again is a decision
    /// about what leaves the shop, and that is the owner's.
    @discardableResult
    func setOutboundOfflineHere(_ on: Bool) -> Bool {
        moveProblem = nil
        guard permitted("security", "edit") else { return false }
        // Stricter is always allowed; looser is not, from a book that is not
        // the shop's while the shop's has the lock on.
        guard on || thisMacsSwitchesAreOpen else { moveProblem = words.callIt("mac.lock_not_allowed"); return false }
        outboundDefaults.set(on, forKey: Self.offlineHereKey)
        // When it was turned on, for the count of days without updates.
        if on { outboundDefaults.set(Date(), forKey: Self.offlineHereAtKey) }
        else { outboundDefaults.removeObject(forKey: Self.offlineHereAtKey); outboundNotice = nil }
        tellOutboundGate()
        if !on, !outboundGate.isOffline { outboundGate.clearCounts() }
        return true
    }

    // MARK: - The privacy switches are the owner's (Turki, Nov 22)

    /// THE SAMPLE BOOK HAS NO LOCK, and anyone can open it from the book
    /// menu. The book's switches are safe from that (the sample is not the
    /// shop's book), but this Mac's own are not the book's: a signed-in
    /// operator could open the sample, where nobody is locked out of
    /// anything, flip the install count or turn "Also on this Mac only" off,
    /// and go back. So while a book that is not the shop's is open, this
    /// Mac's own switches go by whether the SHOP's book had the lock on when
    /// it was last read, and with it on they are not changed from there.
    nonisolated static let lockLastKnownKey = "lock.lastKnownOn"

    var thisMacsSwitchesAreOpen: Bool { source.isReal || !outboundDefaults.bool(forKey: Self.lockLastKnownKey) }

    /// May whoever is here change the install count or the crash and usage
    /// opt-ins? Under the staff lock only the owner (`security`/`edit`, as
    /// the outbound switch asks); with the lock off, anyone, as before.
    /// Refused with its own words, beside the switch and on the shop window.
    func ownerAllowsPrivacy(saying key: String) -> Bool {
        clearPrivacyProblem()
        if lockAllows("security", "edit") { return true }
        return refusePrivacy(needsSignIn ? "mac.lock_sign_in_first" : key, beside: key)
    }

    /// Forget the last privacy refusal, beside its switch and on the shop
    /// window (only if the shop window still shows that same sentence).
    func clearPrivacyProblem() {
        if let old = privacyProblem, moveProblem == old { moveProblem = nil }
        privacyProblem = nil; privacyProblemKey = nil
    }

    private func refusePrivacy(_ sentence: String, beside key: String) -> Bool {
        let said = words.callIt(sentence)
        privacyProblem = said
        privacyProblemKey = key
        moveProblem = said
        return false
    }

    /// Turn this Mac's anonymous install count on or off. This Mac's own
    /// switch, not the book's, so a sample or read-only book can still flip
    /// it; but under the lock it is the owner's, like the opt-ins beside it.
    @discardableResult
    func setInstallCount(_ on: Bool, sender: ActiveCountSender = .shared) -> Bool {
        guard ownerAllowsPrivacy(saying: "mac.priv_owner_count") else { return false }
        guard thisMacsSwitchesAreOpen else { return refusePrivacy("mac.priv_owner_count", beside: "mac.priv_owner_count") }
        sender.enabled = on
        tellOutboundGate()
        return true
    }

    // MARK: - Saying a refusal

    /// The purposes only a person starts (the rule's `automatic: false`): a
    /// refusal of one is somebody's action being refused, so it is also said
    /// with "Open Internet use". The automatic ones are counted on their row
    /// and announce nothing (frame D).
    nonisolated static let askedFor: Set<OutboundPurpose> = [.ai, .taxAuthority, .exchangeRates, .makerrun, .catalogues]

    /// Called as a refusal is put into words. Set on the next turn of the
    /// main queue: this runs inside whatever is drawing the sentence.
    func noteOutboundRefusal(_ blocked: OutboundBlocked, sentence: String) {
        // Never one that names a host: this is drawn on every screen.
        guard Self.askedFor.contains(blocked.purpose), blocked.reason != "settings-unknown", blocked.host == nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if self?.outboundNotice != sentence { self?.outboundNotice = sentence } }
        }
    }

    // MARK: - Telling the other computers (page 27, frames F1–F3)

    /// "Also tell my other computers through Khayt Cloud". This Mac's own
    /// choice, off unless the owner turns it on.
    nonisolated static let tellOthersKey = "network.tellOthers"
    /// Whether the row is offered at all. On since its one call is wired to
    /// Khayt Cloud's route (`Shop+NetworkSwitch`); it was hidden until then,
    /// because a switch that sends nothing must not be on screen saying it does.
    nonisolated(unsafe) static var tellOthersOffered = true

    var outboundTellsOthers: Bool { Self.tellOthersOffered && outboundDefaults.bool(forKey: Self.tellOthersKey) }

    /// The owner's alone, like the two switches.
    @discardableResult
    func setOutboundTellsOthers(_ on: Bool) -> Bool {
        moveProblem = nil
        guard permitted("security", "edit") else { return false }
        guard thisMacsSwitchesAreOpen else { moveProblem = words.callIt("mac.lock_not_allowed"); return false }
        outboundDefaults.set(on, forKey: Self.tellOthersKey)
        return true
    }

    /// What became of the last telling: nil when none was tried.
    enum ToldOthers: Equatable { case told(Date), failed }
    nonisolated static let toldAtKey = "network.toldOthersAt"
    nonisolated static let tellFailedKey = "network.tellOthersFailed"
    var outboundToldOthers: ToldOthers? {
        if outboundDefaults.bool(forKey: Self.tellFailedKey) { return .failed }
        return (outboundDefaults.object(forKey: Self.toldAtKey) as? Date).map(ToldOthers.told)
    }

    /// A refused call, in the shop's words (page 27, frame D): never a network
    /// error and never silent for something a person asked for.
    func outboundSentence(_ blocked: OutboundBlocked) -> String {
        Self.outboundSentence(blocked, words: words)
    }

    static func outboundSentence(_ blocked: OutboundBlocked, words: Words) -> String {
        let what = JSONValue.string(words.callIt("mac.net_need_" + blocked.purpose.rawValue))
        switch blocked.reason {
        case "offline-here": return words.callIt("mac.net_blocked_here", ["what": what])
        case "lan-host-public", "lan-host-missing":
            return words.callIt("mac.net_blocked_lan", ["host": .string(blocked.host ?? "")])
        case "settings-unknown": return words.callIt("mac.net_blocked_starting")
        case "opted-out": return words.callIt("mac.net_blocked_opted", ["what": what])
        default: return words.callIt("mac.net_blocked_offline", ["what": what])
        }
    }
}

/// `OutboundBlocked` says itself wherever an error is put into words
/// (`ErrorText.plain`, `Shop.said`): the shop that is on screen lends its
/// language. Before a shop has loaded there is one sentence it can be.
extension OutboundBlocked: LocalizedError {
    @MainActor static var speaker: (@MainActor (OutboundBlocked) -> String)?

    public var errorDescription: String? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { Self.speaker?(self) } ?? description
        }
        return description
    }
}
