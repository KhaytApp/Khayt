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
        outboundGate.update(book: .settings(Self.outboundBook(real: source.isReal, settings: settingsDict,
                                                              defaults: outboundDefaults)))
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
    nonisolated static func network(_ network: JSONValue?, offline: Bool, by name: String?, at: Date) -> JSONValue {
        var n: [String: JSONValue] = { if case .object(let o)? = network { return o }; return [:] }()
        // Anything stored that is not exactly `false` reads as on (the rule's
        // `onSwitch`), so "was it on" is asked the same way.
        let was: Bool = { guard let v = n["offline"] else { return false }; return v != .bool(false) && v != .null }()
        n["offline"] = .bool(offline)
        if was != offline {
            n["changedAt"] = .string(StoreWriter.iso(at))
            n["changedBy"] = name.map(JSONValue.string) ?? .null
        }
        return .object(n)
    }

    /// `settings.network` with one purpose kept, or no longer kept, while
    /// offline. Only a purpose the rule knows, never `lan` (always allowed)
    /// and never `tunnel` (the Mac has none). The stamp is not touched.
    nonisolated static func network(_ network: JSONValue?, keep purpose: OutboundPurpose, _ kept: Bool) -> JSONValue {
        var n: [String: JSONValue] = { if case .object(let o)? = network { return o }; return [:] }()
        var list: [String] = { if case .array(let a)? = n["keep"] { return a.compactMap { if case .string(let s) = $0 { s } else { nil } } }; return [] }()
        list.removeAll { $0 == purpose.rawValue }
        if kept { list.append(purpose.rawValue) }
        let known = Set(OutboundPurpose.allCases.map(\.rawValue))
        n["keep"] = .array(list.filter { known.contains($0) && $0 != "lan" }.map(JSONValue.string))
        return .object(n)
    }

    /// The purposes a shop may tick Keep on, on the Mac.
    nonisolated static let keepable: [OutboundPurpose] = OutboundPurpose.allCases.filter { $0 != .lan && $0 != .tunnel }

    private func writeNetwork(_ change: @escaping @Sendable (JSONValue?) -> JSONValue) async -> Bool {
        // lock: callers — setOutboundOffline, setOutboundKeep
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return false }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                var settings: [String: JSONValue] = { if case .object(let o)? = root["settings"] { return o }; return [:] }()
                settings["network"] = change(settings["network"])
                root["settings"] = .object(settings)
            }
            return true
        } catch {
            moveProblem = ErrorText.plain(error)
            return false
        }
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
        guard await writeNetwork({ Self.network($0, offline: on, by: name, at: now) }) else { return false }
        // Before the reload, which awaits: told now from what was written.
        var held = settingsDict
        held["network"] = Self.network(held["network"], offline: on, by: name, at: now)
        settingsValue = .object(held)
        if !on, !outboundGate.isOffline { outboundGate.clearCounts() }
        if !on { outboundNotice = nil }
        await load(source)
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
        await load(source)
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
        outboundDefaults.set(on, forKey: Self.offlineHereKey)
        // When it was turned on, for the count of days without updates.
        if on { outboundDefaults.set(Date(), forKey: Self.offlineHereAtKey) }
        else { outboundDefaults.removeObject(forKey: Self.offlineHereAtKey); outboundNotice = nil }
        tellOutboundGate()
        if !on, !outboundGate.isOffline { outboundGate.clearCounts() }
        return true
    }

    // MARK: - The privacy switches are the owner's (Turki, Nov 22)

    /// May whoever is here change the install count or the crash and usage
    /// opt-ins? Under the staff lock only the owner (`security`/`edit`, as
    /// the outbound switch asks); with the lock off, anyone, as before.
    /// Refused with its own words, beside the switch and on the shop window.
    func ownerAllowsPrivacy(saying key: String) -> Bool {
        // An earlier refusal of this kind is not left on the shop window.
        if let old = privacyProblem, moveProblem == old { moveProblem = nil }
        privacyProblem = nil
        if lockAllows("security", "edit") { return true }
        let said = words.callIt(needsSignIn ? "mac.lock_sign_in_first" : key)
        privacyProblem = said
        moveProblem = said
        return false
    }

    /// Turn this Mac's anonymous install count on or off. This Mac's own
    /// switch, not the book's, so a sample or read-only book can still flip
    /// it; but under the lock it is the owner's, like the opt-ins beside it.
    @discardableResult
    func setInstallCount(_ on: Bool, sender: ActiveCountSender = .shared) -> Bool {
        guard ownerAllowsPrivacy(saying: "mac.priv_owner_count") else { return false }
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
    /// Whether the row is offered at all. Off until the one call it makes is
    /// wired to Khayt Cloud's route: a switch that sends nothing must not be
    /// on screen saying it does.
    nonisolated(unsafe) static var tellOthersOffered = false

    var outboundTellsOthers: Bool { Self.tellOthersOffered && outboundDefaults.bool(forKey: Self.tellOthersKey) }

    /// The owner's alone, like the two switches.
    @discardableResult
    func setOutboundTellsOthers(_ on: Bool) -> Bool {
        moveProblem = nil
        guard permitted("security", "edit") else { return false }
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
