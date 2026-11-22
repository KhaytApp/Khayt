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

    /// The app's first act: the book is unread, and this Mac's own switches
    /// are known already. Never puts a loaded shop back to "starting".
    static func outboundBegins(defaults: UserDefaults = .standard, gate: OutboundGate = .app) {
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
    func tellOutboundGate() {
        guard feedsOutboundGate else { return }
        outboundGate.update(local: outboundLocal)
        outboundGate.update(book: .settings(settingsValue))
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
    /// TURNING IT ON LETS ONE SYNC GO OUT FIRST. The switch lives in the book,
    /// and the other computers and the phone learn it by sync: a switch that
    /// blocked its own announcement would leave them calling out for ever
    /// (the sync trap, design 1.4). So the book is written, one push is made
    /// while the gate still holds the old settings, and only then is the gate
    /// told. If that push fails, this Mac is offline all the same and the
    /// others learn at their next sync with any computer that has it.
    @discardableResult
    func setOutboundOffline(_ on: Bool, now: Date = Date()) async -> Bool {
        moveProblem = nil
        guard permitted("security", "edit") else { return false }
        let name: String? = lockInForce ? signedIn?.name : nil
        guard await writeNetwork({ Self.network($0, offline: on, by: name, at: now) }) else { return false }
        if on, Self.cloudConnected(settingsDict), cloudUnlocked {
            await sendToCloud(byPerson: false)
        }
        if !on { outboundGate.clearCounts() }
        await load(source)
        tellOutboundGate()
        return true
    }

    /// Tick or untick Keep for one purpose. The owner's alone.
    @discardableResult
    func setOutboundKeep(_ purpose: OutboundPurpose, _ kept: Bool) async -> Bool {
        moveProblem = nil
        guard permitted("security", "edit") else { return false }
        guard Self.keepable.contains(purpose) else { return false }
        guard await writeNetwork({ Self.network($0, keep: purpose, kept) }) else { return false }
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
        if !on, !outboundGate.isOffline { outboundGate.clearCounts() }
        tellOutboundGate()
        return true
    }

    // MARK: - Saying a refusal

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
