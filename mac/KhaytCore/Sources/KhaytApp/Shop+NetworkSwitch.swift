import Foundation
import KhaytCore

/// "Also tell my other computers through Khayt Cloud" (page 27, frames
/// F1–F3): the shop's switch sent to, and heard from, Khayt Cloud's
/// `network-switch` route, for a shop whose owner opted in (`NetworkSwitch`,
/// khayt-cloud docs/api-contract.md).
///
/// ── WHAT THIS MAC SENDS, AND WHEN ────────────────────────────────────────
///
/// Only when the switch CHANGES, at the owner's hand, and only this one
/// setting, sealed with the shop's key:
///
///   turned ON   with the option on, one PUT as this Mac's last call before
///               it stops, capped at ten seconds; then it stops either way.
///   turned OFF  a GET first. If a value is published there, a PUT of
///               `offline: false` follows EVEN IF this Mac's option is off:
///               another computer published it, and leaving `offline: true`
///               there would keep switching every computer that starts.
///
/// ── WHAT THIS MAC HEARS, AND WHEN ────────────────────────────────────────
///
/// A GET at start and every fifteen minutes. While this Mac is offline, the
/// GET is made ONLY if it is offline because of a value it took from this
/// route or sent to it (`viaCloud`): that one call, carrying nothing, is how
/// the computers come back online together, and the page says so in a row of
/// its own. A Mac that went offline by its own switch, with the option off,
/// makes no call at all. A 404 (the shop stopped sharing) ends the calls.
///
/// A value is applied only after every check in `NetworkSwitch.read`. Two
/// are never applied without a person: an `offline: true` more than seven
/// days old on a Mac with no stamp of its own, and a value the server
/// answered a change made here with (a 409). Both wait in `networkSwitchAsk`.
///
/// ── WHO ──────────────────────────────────────────────────────────────────
///
/// Sending is the owner's (`security`/`edit`, and the server refuses any
/// token that is not the owner's). Hearing is every signed-in computer's.
/// The server enforces owner-only; a computer cannot check it (any member
/// holds the shop key). Accepted Nov 22: an owner signing key comes later.
extension Shop {

    // MARK: - What this Mac remembers

    /// The newest stamp this Mac has seen, applied or set itself. Never lowered.
    nonisolated static let highestSeenKey = "network.switchHighestSeen"
    /// This Mac is offline because of a value it took from the route or sent
    /// to it: the one call is kept.
    nonisolated static let viaCloudKey = "network.switchViaCloud"
    /// A published stamp waiting for a person's answer: never applied on its own.
    nonisolated static let heldStampKey = "network.switchHeld"

    var networkSwitchHighestSeen: String? { outboundDefaults.string(forKey: Self.highestSeenKey) }
    var networkSwitchViaCloud: Bool { outboundDefaults.bool(forKey: Self.viaCloudKey) }

    private func sawStamp(_ stamp: String) {
        if let next = NetworkSwitch.later(networkSwitchHighestSeen, stamp) {
            outboundDefaults.set(next, forKey: Self.highestSeenKey)
        }
    }

    private func setViaCloud(_ on: Bool) {
        outboundDefaults.set(on, forKey: Self.viaCloudKey)
        tellOutboundGate()
    }

    /// The rule's purpose ids, for a value's `keep` list.
    var outboundPurposeIds: Set<String> { Set(OutboundPurpose.allCases.map(\.rawValue)) }

    // MARK: - The route

    /// How a request is sent. A seam: a test answers as the server would.
    typealias NetworkSwitchFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Heard: Equatable {
        case published(String)
        /// 404: the shop never published one, or stopped sharing.
        case none
        /// Not reached, refused by the gate, or an answer that is not one.
        case failed
    }

    enum Sent: Equatable {
        case ok
        /// 409: the server holds a stamp at or after this one.
        case stale(String?)
        /// 403 (not the owner's token), 400, 413, 429: nothing was stored.
        case refused(Int)
        case failed
    }

    /// The session, the key and where to ask, or nil when this Mac is not
    /// signed in to Khayt Cloud with the key open.
    private func networkSwitchSession() async -> (CloudReader.Connection, String, Data)? {
        guard source.isReal, let dek = cloudDek, let (connection, token) = await vaultSession() else { return nil }
        return (connection, token, dek)
    }

    nonisolated static func networkSwitchGet(_ connection: CloudReader.Connection, token: String,
                                             fetch: NetworkSwitchFetch) async -> (Heard, NetworkSwitch.Published?) {
        guard var request = try? CloudReader.request(connection, token: token, method: "GET", tail: NetworkSwitch.tail) else {
            return (.failed, nil)
        }
        request.timeoutInterval = NetworkSwitch.lastCallCap
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await fetch(request), let http = response as? HTTPURLResponse else { return (.failed, nil) }
        if http.statusCode == 404 { return (.none, nil) }
        guard http.statusCode == 200, data.count <= 16_384,
              let published = try? JSONDecoder().decode(NetworkSwitch.Published.self, from: data) else { return (.failed, nil) }
        return (.published(published.changedAt), published)
    }

    nonisolated static func networkSwitchPut(_ value: NetworkSwitch.Value, connection: CloudReader.Connection, token: String,
                                             dek: Data, fetch: NetworkSwitchFetch) async -> Sent {
        guard let body = try? NetworkSwitch.putBody(value, shopId: connection.shopId, dek: dek),
              var request = try? CloudReader.request(connection, token: token, method: "PUT", tail: NetworkSwitch.tail) else {
            return .failed
        }
        // Ten seconds, then this Mac stops anyway.
        request.timeoutInterval = NetworkSwitch.lastCallCap
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await fetch(request), let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200: return .ok
        case 409:
            let at: String? = {
                guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .string(let s)? = o["changedAt"], NetworkSwitch.date(s) != nil else { return nil }
                return s
            }()
            return .stale(at)
        default: return .refused(http.statusCode)
        }
    }

    var networkSwitchFetcher: NetworkSwitchFetch {
        networkSwitchFetch ?? { request in try await CloudReader.session.data(for: request) }
    }

    // MARK: - Sending: the switch changed here

    /// The switch is about to be turned ON here, by the owner, with the
    /// option on: the one last call, before this Mac stops. `network` is
    /// `settings.network` as it is about to be written.
    ///
    /// Returns whether the others were told. A 409 is not "told": somebody
    /// changed the switch at another computer at or after this moment, which
    /// is said and never silently obeyed or overridden.
    func tellOthersSwitchedOn(_ network: JSONValue) async {
        // lock: callers — setOutboundOffline
        guard outboundTellsOthers, let value = NetworkSwitch.value(of: network, purposes: outboundPurposeIds) else { return }
        guard let (connection, token, dek) = await networkSwitchSession() else { noteTold(.failed); return }
        let sent = await Self.networkSwitchPut(value, connection: connection, token: token, dek: dek, fetch: networkSwitchFetcher)
        afterSending(sent, value: value)
    }

    /// The switch was turned OFF here, by the owner: a GET first, then
    /// `offline: false` if a value is published there or this Mac's option is
    /// on. This Mac is online again by now, so these are its first calls.
    func tellOthersSwitchedOff(_ network: JSONValue) async {
        // lock: callers — setOutboundOffline
        defer { outboundDefaults.set(false, forKey: Self.viaCloudKey) }
        guard let value = NetworkSwitch.value(of: network, purposes: outboundPurposeIds) else { return }
        guard let (connection, token, dek) = await networkSwitchSession() else {
            if outboundTellsOthers { noteTold(.failed) }
            return
        }
        let (heard, _) = await Self.networkSwitchGet(connection, token: token, fetch: networkSwitchFetcher)
        let publishedThere: Bool = { if case .published = heard { return true }; return false }()
        // Nothing published and the option off here: the shop does not share
        // the switch, and this Mac sends nothing.
        guard publishedThere || outboundTellsOthers else { return }
        let sent = await Self.networkSwitchPut(value, connection: connection, token: token, dek: dek, fetch: networkSwitchFetcher)
        afterSending(sent, value: value, option: outboundTellsOthers)
    }

    private func afterSending(_ sent: Sent, value: NetworkSwitch.Value, option: Bool = true) {
        switch sent {
        case .ok:
            noteTold(.told(Date()))
            // Offline because of a value this Mac sent: the one call is kept.
            if value.offline { outboundDefaults.set(true, forKey: Self.viaCloudKey) }
        case .stale(let at):
            // Changed at another computer at or after this moment. Said, and
            // held: it is not applied over what the person just did here.
            noteTold(.failed)
            if let at { outboundDefaults.set(at, forKey: Self.heldStampKey) }
            networkSwitchAsk = .changedElsewhere(at: at.flatMap(NetworkSwitch.date))
        case .refused, .failed:
            if option { noteTold(.failed) }
        }
        outboundRevision &+= 1
    }

    private func noteTold(_ told: ToldOthers) {
        switch told {
        case .told(let at):
            outboundDefaults.set(at, forKey: Self.toldAtKey)
            outboundDefaults.set(false, forKey: Self.tellFailedKey)
        case .failed:
            outboundDefaults.set(true, forKey: Self.tellFailedKey)
        }
    }

    // MARK: - Hearing

    /// Whether this Mac may ask the route now: signed in, and either online
    /// or offline because of a value from the route. Its own switch, or a
    /// shop switch nobody shared, means no call at all.
    var hearsNetworkSwitch: Bool {
        guard feedsOutboundGate, source.isReal else { return false }
        if outboundOfflineHere { return false }
        return !outboundGate.isShopOffline || networkSwitchViaCloud
    }

    /// One GET, and what it leads to. Called at start and every fifteen
    /// minutes (`NetworkSwitch.checkEvery`).
    func checkNetworkSwitch(now: Date = Date()) async {
        guard hearsNetworkSwitch, let (connection, token, dek) = await networkSwitchSession() else { return }
        let (heard, published) = await Self.networkSwitchGet(connection, token: token, fetch: networkSwitchFetcher)
        switch heard {
        case .failed: return
        case .none:
            // The shop stopped sharing: the one call ends. Nothing is turned
            // on or off by that; this Mac keeps the value it last applied.
            if networkSwitchViaCloud { setViaCloud(false) }
        case .published:
            guard let published else { return }
            await heardNetworkSwitch(published, shopId: connection.shopId, dek: dek, now: now)
        }
    }

    /// A published value: checked, then applied, held for a person, or ignored.
    func heardNetworkSwitch(_ published: NetworkSwitch.Published, shopId: String, dek: Data, now: Date = Date()) async {
        let ownStamp: String? = {
            if case .string(let s)? = networkSettings["changedAt"], NetworkSwitch.date(s) != nil { return s }
            return nil
        }()
        let seen = NetworkSwitch.later(networkSwitchHighestSeen, ownStamp)
        switch NetworkSwitch.read(published, shopId: shopId, dek: dek, highestSeen: seen, purposes: outboundPurposeIds) {
        case .failure(.old): return
        case .failure(let why):
            FileHandle.standardError.write(Data("khayt: network switch: ignored, \(why.rawValue)\n".utf8))
        case .success(let value):
            // Waiting for a person already: not applied on its own, not asked twice.
            if outboundDefaults.string(forKey: Self.heldStampKey) == value.changedAt {
                if networkSwitchAsk == nil { networkSwitchAsk = .changedElsewhere(at: NetworkSwitch.date(value.changedAt)) }
                held = value
                return
            }
            if NetworkSwitch.asksFirst(value, hasOwnStamp: seen != nil, now: now) {
                held = value
                networkSwitchAsk = .oldSwitch(at: NetworkSwitch.date(value.changedAt))
                return
            }
            await applyNetworkSwitch(value)
        }
    }

    /// The value waiting for a person, kept only while the app runs: it is
    /// read again from the route at the next start.
    private var held: NetworkSwitch.Value? {
        get { networkSwitchHeld }
        set { networkSwitchHeld = newValue }
    }

    /// The person's answer to `networkSwitchAsk`: apply what the other
    /// computer set, or leave this Mac as it is. Either way it is not asked
    /// again for that value.
    func answerNetworkSwitch(apply: Bool) async {
        // The question is the owner's to answer: it decides whether this Mac
        // makes internet calls.
        guard permitted("security", "edit") else { return }
        let value = held
        networkSwitchAsk = nil
        held = nil
        outboundDefaults.removeObject(forKey: Self.heldStampKey)
        guard let value else { return }
        // Seen, so it is not offered again whichever way the answer went.
        sawStamp(value.changedAt)
        guard apply else { return }
        await applyNetworkSwitch(value)
    }

    /// Put a checked value in the book and tell the gate. This Mac's own
    /// switch is never touched: a value with `offline: false` lifts the
    /// shop's switch, not the computer's.
    @discardableResult
    func applyNetworkSwitch(_ value: NetworkSwitch.Value) async -> Bool {
        // lock: system — the shop's own switch, as its owner set it at another computer, checked and sealed with the shop's key
        guard let build = source.build, source.isReal else { return false }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                var settings: [String: JSONValue] = { if case .object(let o)? = root["settings"] { return o }; return [:] }()
                settings["network"] = NetworkSwitch.applied(value, to: settings["network"])
                root["settings"] = .object(settings)
            }
        } catch { return false }
        sawStamp(value.changedAt)
        // Offline because of a value from the route: the one call is kept.
        outboundDefaults.set(value.offline, forKey: Self.viaCloudKey)
        var now = settingsDict
        now["network"] = NetworkSwitch.applied(value, to: now["network"])
        settingsValue = .object(now)
        if !value.offline {
            if !outboundGate.isOffline { outboundGate.clearCounts() }
            outboundNotice = nil
        }
        await load(source)
        return true
    }

    /// Start hearing: now, and every fifteen minutes while the app runs.
    func startNetworkSwitchChecks() {
        networkSwitchTask?.cancel()
        networkSwitchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.checkNetworkSwitch()
                try? await Task.sleep(for: .seconds(NetworkSwitch.checkEvery))
            }
        }
    }
}

/// What a person is asked about a value from Khayt Cloud before it is applied.
enum NetworkSwitchAsk: Equatable {
    /// A new install met an `offline: true` more than seven days old:
    /// "Your shop turned off internet use on <date>. Apply it here?"
    case oldSwitch(at: Date?)
    /// The switch was changed here just now, and the server answered that
    /// another computer changed it at or after that moment.
    case changedElsewhere(at: Date?)
}

/// The two questions, in the shop's words.
@MainActor
enum NetworkSwitchWords {
    static func sentence(_ ask: NetworkSwitchAsk, words: Words) -> String {
        switch ask {
        case .oldSwitch(let at):
            let date = at.map { words.say($0, .dateTime.day().month(.abbreviated).year()) } ?? ""
            return words.callIt("mac.net_ask_old", ["date": .string(date)])
        case .changedElsewhere(let at):
            guard let at else { return words.callIt("mac.net_ask_elsewhere_anon") }
            return words.callIt("mac.net_ask_elsewhere", ["time": .string(words.say(at, .dateTime.hour().minute()))])
        }
    }
}
