import Foundation
import SwiftUI
import KhaytCore

/// "Also tell my other computers through Khayt Cloud" (page 27, frames
/// F1–F3): the shop's switch sent to, and heard from, Khayt Cloud's
/// `network-switch` route, for a shop whose owner opted in (`NetworkSwitch`,
/// khayt-cloud docs/api-contract.md).
///
/// ── WHAT THIS MAC SENDS, AND WHEN ────────────────────────────────────────
///
/// Only a change the owner made, and only this one setting, sealed with the
/// shop's key. It is sent when the switch changes; an "off" that could not
/// be sent then is sent again at a later check, the same change with the
/// same stamp (`retryUnsentOff`), never anything the owner did not do:
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

    // MARK: - What this Mac remembers, per shop

    /// The newest stamp this Mac has seen for a shop, applied or set itself.
    /// Never lowered.
    nonisolated static let highestSeenKey = "network.switchHighestSeen"
    /// A published stamp waiting for a person's answer: never applied on its own.
    nonisolated static let heldStampKey = "network.switchHeld"

    /// The shop these stamps belong to. They are kept per shop: a Mac that
    /// has seen one shop's stamps must not ignore another shop's older ones.
    var networkSwitchShopId: String {
        if let pretend = networkSwitchSessionForTests { return pretend.0.shopId }
        if case .object(let cloud)? = settingsDict["cloud"], case .string(let id)? = cloud["shopId"] { return id }
        return ""
    }

    nonisolated static func highestSeenKey(_ shopId: String) -> String { highestSeenKey + "." + shopId }
    nonisolated static func heldStampKey(_ shopId: String) -> String { heldStampKey + "." + shopId }

    var networkSwitchHighestSeen: String? { outboundDefaults.string(forKey: Self.highestSeenKey(networkSwitchShopId)) }
    var networkSwitchHeldStamp: String? { outboundDefaults.string(forKey: Self.heldStampKey(networkSwitchShopId)) }

    /// The stamp in this Mac's own book, when it is one.
    var networkSwitchOwnStamp: String? {
        if case .string(let s)? = networkSettings["changedAt"], NetworkSwitch.date(s) != nil { return s }
        return nil
    }

    /// The shop's switch came through Khayt Cloud (`settings.network.via`):
    /// applied from the route, or sent there by this Mac. The rule keeps the
    /// one call for it, and only for it.
    var networkSwitchViaCloud: Bool { networkSettings["via"] == .string(NetworkSwitch.viaCloud) }

    /// Remember a stamp as seen. One further ahead than the server would
    /// accept (ten minutes) is not remembered: a Mac whose clock was wrong
    /// once would otherwise ignore every real value until that date.
    func sawNetworkSwitchStamp(_ stamp: String, now: Date = Date()) {
        guard let when = NetworkSwitch.date(stamp), when <= now.addingTimeInterval(NetworkSwitch.aheadAllowed) else { return }
        if let next = NetworkSwitch.later(networkSwitchHighestSeen, stamp) {
            outboundDefaults.set(next, forKey: Self.highestSeenKey(networkSwitchShopId))
        }
    }

    private func holdStamp(_ stamp: String?) {
        let key = Self.heldStampKey(networkSwitchShopId)
        if let stamp { outboundDefaults.set(stamp, forKey: key) } else { outboundDefaults.removeObject(forKey: key) }
    }

    /// Which way the person was turning the switch when another computer's
    /// change beat it: kept with the held stamp, so the question is the same
    /// one after a restart.
    nonisolated static func heldTurningOnKey(_ shopId: String) -> String { "network.switchHeldTurningOn." + shopId }
    var networkSwitchHeldTurningOn: Bool { outboundDefaults.bool(forKey: Self.heldTurningOnKey(networkSwitchShopId)) }

    /// The rule's purpose ids, for a value's `keep` list.
    var outboundPurposeIds: Set<String> { Set(OutboundPurpose.allCases.map(\.rawValue)) }

    // MARK: - The book

    /// Change `settings.network` in the book on disk and in memory. A test's
    /// own book (`networkBookForTests`) stands in for the file.
    /// `says`: a failure is put in `moveProblem`, for a change a person made.
    func writeNetworkSettings(_ change: @escaping @Sendable (JSONValue?) -> JSONValue, says: Bool = false) async -> Bool {
        // lock: callers — applyNetworkSwitch, markViaCloud, writeNetwork
        if let book = networkBookForTests {
            book.network = change(book.network)
        } else {
            guard let build = source.build else { return false }
            do {
                try await StoreWriter.updateOffMain(build) { root in
                    var settings: [String: JSONValue] = { if case .object(let o)? = root["settings"] { return o }; return [:] }()
                    settings["network"] = change(settings["network"])
                    root["settings"] = .object(settings)
                }
            } catch {
                if says { moveProblem = ErrorText.plain(error) }
                return false
            }
        }
        var now = settingsDict
        now["network"] = change(now["network"])
        settingsValue = .object(now)
        return true
    }

    /// Read the book again after a write. A test's book is the memory.
    func reloadAfterNetworkWrite() async {
        if networkBookForTests == nil { await load(source) }
    }

    /// Write whether the switch came through Khayt Cloud.
    private func markViaCloud(_ on: Bool) async {
        // lock: system — a marker of where the shop's switch came from, set by what Khayt Cloud answered
        guard networkSwitchViaCloud != on else { return }
        guard await writeNetworkSettings({ NetworkSwitch.marked($0, viaCloud: on) }) else { return }
        await reloadAfterNetworkWrite()
    }

    // MARK: - The route

    /// How a request is sent. A seam: a test answers as the server would.
    typealias NetworkSwitchFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Heard: Equatable {
        case published(String)
        /// 404 `{reason: "none"}`: the shop never published one, or stopped sharing.
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
        if let pretend = networkSwitchSessionForTests { return pretend }
        guard source.isReal, let dek = cloudDek, let (connection, token) = await vaultSession() else { return nil }
        return (connection, token, dek)
    }

    /// One request, answered within `NetworkSwitch.lastCallCap` or not at
    /// all: a real limit, not an idle timeout a slow server can stretch.
    nonisolated static func capped(_ request: URLRequest, fetch: @escaping NetworkSwitchFetch,
                                   cap: TimeInterval = NetworkSwitch.lastCallCap) async -> (Int, Data)? {
        await withTaskGroup(of: (Int, Data)?.self) { group in
            group.addTask {
                guard let (data, response) = try? await fetch(request), let http = response as? HTTPURLResponse else { return nil }
                return (http.statusCode, data)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(cap))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated static func networkSwitchGet(_ connection: CloudReader.Connection, token: String,
                                             fetch: @escaping NetworkSwitchFetch) async -> (Heard, NetworkSwitch.Published?) {
        guard var request = try? CloudReader.request(connection, token: token, method: "GET", tail: NetworkSwitch.tail) else {
            return (.failed, nil)
        }
        request.timeoutInterval = NetworkSwitch.lastCallCap
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (status, data) = await capped(request, fetch: fetch), data.count <= 16_384 else { return (.failed, nil) }
        if status == 404 {
            // Only the route's own "none". Any other 404 (a proxy, a server
            // without the route) is not the shop stopping sharing.
            guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data), o["reason"] == .string("none") else {
                return (.failed, nil)
            }
            return (.none, nil)
        }
        guard status == 200, let published = try? JSONDecoder().decode(NetworkSwitch.Published.self, from: data) else { return (.failed, nil) }
        return (.published(published.changedAt), published)
    }

    nonisolated static func networkSwitchPut(_ value: NetworkSwitch.Value, connection: CloudReader.Connection, token: String,
                                             dek: Data, fetch: @escaping NetworkSwitchFetch) async -> Sent {
        guard let body = try? NetworkSwitch.putBody(value, shopId: connection.shopId, dek: dek),
              var request = try? CloudReader.request(connection, token: token, method: "PUT", tail: NetworkSwitch.tail) else {
            return .failed
        }
        request.timeoutInterval = NetworkSwitch.lastCallCap
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ten seconds, then this Mac stops anyway.
        guard let (status, data) = await capped(request, fetch: fetch) else { return .failed }
        switch status {
        case 200: return .ok
        case 409:
            let at: String? = {
                guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .string(let s)? = o["changedAt"], NetworkSwitch.date(s) != nil else { return nil }
                return s
            }()
            return .stale(at)
        default: return .refused(status)
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
    @discardableResult
    func tellOthersSwitchedOn(_ network: JSONValue) async -> Bool {
        // lock: callers — setOutboundOffline
        // Turned on again: an "off" still waiting to be sent is superseded.
        forgetUnsentOff()
        guard outboundTellsOthers, let value = NetworkSwitch.value(of: network, purposes: outboundPurposeIds) else { return false }
        guard let (connection, token, dek) = await networkSwitchSession() else { noteTold(.failed); return false }
        // What this Mac had seen BEFORE this change: what the other computer
        // set is judged against that, not against the change it beat.
        let seenBefore = NetworkSwitch.later(networkSwitchHighestSeen, networkSwitchOwnStamp)
        let sent = await Self.networkSwitchPut(value, connection: connection, token: token, dek: dek, fetch: networkSwitchFetcher)
        afterSending(sent, turningOn: true)
        if case .stale = sent { await holdPublished(connection, token: token, dek: dek, seenBefore: seenBefore) }
        return sent == .ok
    }

    /// What became of saying "off".
    enum ToldOff: Equatable {
        /// Sent and accepted, or found already published with this very stamp.
        case sent
        /// Nothing is published there (the shop never shared the switch, or
        /// its owner stopped sharing): nothing to send.
        case nothingPublished
        /// Another computer changed the switch at or after this moment: asked.
        /// Only for the owner's own change, never for a retry.
        case changedElsewhere
        /// A retry found a newer value there, or was beaten: the old "off" is
        /// dropped and the newer value is heard like any other.
        case superseded
        /// Khayt Cloud will not take it from this computer (not the owner's
        /// token, or a request it rejects): not tried again.
        case refused
        /// Not signed in, Khayt Cloud not reached, or a failure that may
        /// pass: the others may still be offline. Tried again.
        case unsent
        /// This Mac's book holds no switch to send.
        case nothingToSend
    }

    /// Whether a refused PUT is worth sending again: a timeout, "too many",
    /// or the server's own fault. Anything else it will refuse every time.
    nonisolated static func refusalMayPass(_ status: Int) -> Bool { status == 408 || status == 429 || status >= 500 }

    /// The switch was turned OFF here, by the owner: a GET first, then
    /// `offline: false` ONLY if a value is published there (Dev Hub, Nov 22;
    /// whatever this Mac's option says). After the route's own 404 nothing is
    /// sent. This Mac is online again by now, so these are its first calls.
    /// `seenBefore` is the newest stamp this Mac had seen before the change.
    ///
    /// AN "OFF" THAT COULD NOT BE SENT IS TRIED AGAIN (Cloud lane's review):
    /// the other computers may be offline because of the value this shop
    /// published, and this Mac is the one that knows it was turned off. The
    /// stamp is remembered and `retryUnsentOff` sends the SAME change, with
    /// the same stamp, at each check until it is sent or superseded.
    ///
    /// A RETRY (`retry: true`) IS NOT THE OWNER'S PRESS, so it never asks and
    /// never sends over something newer: a value published there with a later
    /// stamp, or a 409, drops the old "off" and leaves the newer value to be
    /// heard and applied like any other. Raising the "changed at another
    /// computer" question from a retry held that newer value back, and left
    /// this Mac online against the shop until somebody answered (review).
    @discardableResult
    func tellOthersSwitchedOff(_ network: JSONValue, seenBefore: String?, retry: Bool = false) async -> ToldOff {
        // lock: callers — setOutboundOffline, retryUnsentOff
        guard let value = NetworkSwitch.value(of: network, purposes: outboundPurposeIds), !value.offline,
              let mine = NetworkSwitch.date(value.changedAt) else {
            forgetUnsentOff()
            return .nothingToSend
        }
        // A shop that is not on Khayt Cloud at all has published nothing.
        guard !networkSwitchShopId.isEmpty else { forgetUnsentOff(); return .nothingPublished }
        guard let (connection, token, dek) = await networkSwitchSession() else {
            if outboundTellsOthers { noteTold(.failed) }
            rememberUnsentOff(value.changedAt, seenBefore: seenBefore)
            return .unsent
        }
        let (heard, _) = await Self.networkSwitchGet(connection, token: token, fetch: networkSwitchFetcher)
        // The retry waited on the network: if the switch was changed here
        // meanwhile, this "off" is no longer the shop's word.
        if retry, !unsentOffStillStands(value.changedAt) { forgetUnsentOff(); return .superseded }
        switch heard {
        case .failed:
            // Not known whether a value is published there: neither sent nor
            // given up.
            if outboundTellsOthers { noteTold(.failed) }
            rememberUnsentOff(value.changedAt, seenBefore: seenBefore)
            return .unsent
        case .none:
            // Nothing is published: nothing to send, and nothing failed.
            forgetUnsentOff()
            outboundDefaults.set(false, forKey: Self.tellFailedKey)
            return .nothingPublished
        case .published(let there):
            if let thereAt = NetworkSwitch.date(there) {
                // Already there with this very stamp: an earlier send whose
                // answer was lost. Sending it again would be refused as
                // stale, and read as another computer's change.
                if thereAt == mine {
                    forgetUnsentOff()
                    noteTold(.told(Date()))
                    outboundRevision &+= 1
                    return .sent
                }
                if retry, thereAt > mine { forgetUnsentOff(); return .superseded }
            }
        }
        let sent = await Self.networkSwitchPut(value, connection: connection, token: token, dek: dek, fetch: networkSwitchFetcher)
        switch sent {
        case .ok:
            afterSending(sent, turningOn: false, option: outboundTellsOthers)
            forgetUnsentOff()
            return .sent
        case .stale:
            forgetUnsentOff()
            if retry { return .superseded }
            afterSending(sent, turningOn: false, option: outboundTellsOthers)
            await holdPublished(connection, token: token, dek: dek, seenBefore: seenBefore)
            return .changedElsewhere
        case .refused(let status) where !Self.refusalMayPass(status):
            afterSending(sent, turningOn: false, option: outboundTellsOthers)
            forgetUnsentOff()
            return .refused
        case .refused, .failed:
            afterSending(sent, turningOn: false, option: outboundTellsOthers)
            rememberUnsentOff(value.changedAt, seenBefore: seenBefore)
            return .unsent
        }
    }

    // MARK: - An "off" that could not be sent

    nonisolated static func unsentOffKey(_ shopId: String) -> String { "network.switchOffUnsent." + shopId }
    nonisolated static func unsentOffSeenBeforeKey(_ shopId: String) -> String { "network.switchOffUnsentSeenBefore." + shopId }

    /// The stamp of an "off" this Mac made and could not send, if any.
    var networkSwitchUnsentOff: String? { outboundDefaults.string(forKey: Self.unsentOffKey(networkSwitchShopId)) }

    private func rememberUnsentOff(_ stamp: String, seenBefore: String?) {
        outboundDefaults.set(stamp, forKey: Self.unsentOffKey(networkSwitchShopId))
        let key = Self.unsentOffSeenBeforeKey(networkSwitchShopId)
        if let seenBefore { outboundDefaults.set(seenBefore, forKey: key) } else { outboundDefaults.removeObject(forKey: key) }
    }

    func forgetUnsentOff() {
        outboundDefaults.removeObject(forKey: Self.unsentOffKey(networkSwitchShopId))
        outboundDefaults.removeObject(forKey: Self.unsentOffSeenBeforeKey(networkSwitchShopId))
    }

    /// Whether the unsent "off" is still this shop's current word: the book
    /// still holds that very change (same stamp, still off), and nothing
    /// newer has been seen from Khayt Cloud. Anything else supersedes it: the
    /// switch was changed here again, or another computer's newer value was
    /// applied.
    func unsentOffStillStands(_ stamp: String) -> Bool {
        guard networkSwitchOwnStamp == stamp, !Self.offlineOf(.object(networkSettings)),
              let when = NetworkSwitch.date(stamp) else { return false }
        if let seen = networkSwitchHighestSeen.flatMap(NetworkSwitch.date), seen > when { return false }
        return true
    }

    /// Send an "off" that could not be sent before: the same change, with
    /// its own stamp, never a fresh one. Called by each check. Dropped when
    /// superseded; kept when it still cannot be sent.
    @discardableResult
    func retryUnsentOff() async -> ToldOff? {
        // One at a time: the check runs on a timer and beside each sync, and
        // two retries sending the same stamp read each other as a conflict.
        guard !networkSwitchRetrying, let stamp = networkSwitchUnsentOff else { return nil }
        guard unsentOffStillStands(stamp) else { forgetUnsentOff(); return nil }
        // Only the owner's own change is ever sent, and only where this Mac
        // may make the call at all.
        guard !outboundOfflineHere, lockAllows("security", "edit") else { return .unsent }
        networkSwitchRetrying = true
        defer { networkSwitchRetrying = false }
        let seenBefore = outboundDefaults.string(forKey: Self.unsentOffSeenBeforeKey(networkSwitchShopId))
        return await tellOthersSwitchedOff(.object(networkSettings), seenBefore: seenBefore, retry: true)
    }

    private func afterSending(_ sent: Sent, turningOn: Bool, option: Bool = true) {
        switch sent {
        case .ok:
            noteTold(.told(Date()))
        case .stale(let at):
            // Changed at another computer at or after this moment. Said, and
            // held: it is not applied over what the person just did here. The
            // others were not told of THIS change, and Khayt Cloud was reached,
            // so neither "told" nor "could not be reached" is claimed.
            outboundDefaults.removeObject(forKey: Self.toldAtKey)
            outboundDefaults.set(false, forKey: Self.tellFailedKey)
            holdStamp(at)
            outboundDefaults.set(turningOn, forKey: Self.heldTurningOnKey(networkSwitchShopId))
            networkSwitchAsk = .changedElsewhere(at: at.flatMap(NetworkSwitch.date), turningOn: turningOn)
        case .refused, .failed:
            if option { noteTold(.failed) }
        }
        outboundRevision &+= 1
    }

    /// After a 409: read what the other computer set, so the person can be
    /// offered it. It is held, never applied here, and only if it passes
    /// every check against what this Mac had seen before the change: an old
    /// value replayed behind a 409 is not offered.
    private func holdPublished(_ connection: CloudReader.Connection, token: String, dek: Data, seenBefore: String?) async {
        let (_, published) = await Self.networkSwitchGet(connection, token: token, fetch: networkSwitchFetcher)
        guard let published,
              case .success(let value) = NetworkSwitch.read(published, shopId: connection.shopId, dek: dek,
                                                            highestSeen: seenBefore, purposes: outboundPurposeIds),
              !NetworkSwitch.isAhead(value, now: Date()) else { return }
        networkSwitchHeld = value
        holdStamp(value.changedAt)
        networkSwitchAsk = .changedElsewhere(at: NetworkSwitch.date(value.changedAt), turningOn: networkSwitchHeldTurningOn)
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

    /// Whether this Mac may ask the route now. The RULE answers
    /// (`switch-sync`): yes while online; while offline only when the switch
    /// came through Khayt Cloud and the row is not unticked; never under this
    /// Mac's own switch. Asked without counting a refusal: nobody pressed
    /// anything.
    var hearsNetworkSwitch: Bool {
        guard feedsOutboundGate || networkSwitchSessionForTests != nil,
              source.isReal || networkSwitchSessionForTests != nil else { return false }
        return outboundGate.verdict(.switchSync).allowed
    }

    /// One GET, and what it leads to. Called at start, beside each sync, and
    /// every fifteen minutes (`NetworkSwitch.checkEvery`). Not while the
    /// owner is changing the switch here: that change says its own piece.
    func checkNetworkSwitch(now: Date = Date()) async {
        guard !outboundChanging, hearsNetworkSwitch else { return }
        // An "off" made here that could not be sent goes first: the same
        // change, the same stamp. A 409 there asks the owner, as at the time.
        if networkSwitchUnsentOff != nil {
            _ = await retryUnsentOff()
            guard !outboundChanging else { return }
        }
        guard let (connection, token, dek) = await networkSwitchSession() else { return }
        let asked = (source, networkSwitchShopId)
        let (heard, published) = await Self.networkSwitchGet(connection, token: token, fetch: networkSwitchFetcher)
        // The answer belongs to the book and shop it was asked for, and is
        // dropped if the owner changed the switch while it was in flight.
        guard !outboundChanging, asked.0 == source, asked.1 == networkSwitchShopId, asked.1 == connection.shopId else { return }
        switch heard {
        case .failed: return
        case .none:
            // The shop stopped sharing: the one call ends. Nothing is turned
            // on or off by that; this Mac keeps the value it last applied.
            await markViaCloud(false)
        case .published:
            guard let published else { return }
            await heardNetworkSwitch(published, shopId: connection.shopId, dek: dek, now: now)
        }
    }

    /// A published value: checked, then applied, held for a person, or ignored.
    func heardNetworkSwitch(_ published: NetworkSwitch.Published, shopId: String, dek: Data, now: Date = Date()) async {
        switch NetworkSwitch.hearing(published, shopId: shopId, dek: dek, highestSeen: networkSwitchHighestSeen,
                                     ownStamp: networkSwitchOwnStamp, heldStamp: networkSwitchHeldStamp,
                                     purposes: outboundPurposeIds, now: now) {
        case .ignore(.old): return
        case .ignore(let why):
            FileHandle.standardError.write(Data("khayt: network switch: ignored, \(why.rawValue)\n".utf8))
        case .askChangedElsewhere(let value):
            networkSwitchHeld = value
            if networkSwitchAsk == nil {
                networkSwitchAsk = .changedElsewhere(at: NetworkSwitch.date(value.changedAt), turningOn: networkSwitchHeldTurningOn)
            }
        case .askOld(let value):
            networkSwitchHeld = value
            networkSwitchAsk = .oldSwitch(at: NetworkSwitch.date(value.changedAt))
        case .apply(let value):
            // A change made here was answered with "changed elsewhere" and the
            // person has not chosen yet: whatever is published now waits too.
            if case .changedElsewhere? = networkSwitchAsk {
                networkSwitchHeld = value
                holdStamp(value.changedAt)
                networkSwitchAsk = .changedElsewhere(at: NetworkSwitch.date(value.changedAt), turningOn: networkSwitchHeldTurningOn)
                return
            }
            // A newer value overtakes an old one still waiting for an answer:
            // the question is about a switch the shop has since changed.
            if case .oldSwitch? = networkSwitchAsk {
                networkSwitchAsk = nil
                networkSwitchHeld = nil
            }
            await applyNetworkSwitch(value, shopId: shopId)
        }
    }

    /// The person's answer to `networkSwitchAsk`.
    ///
    /// AN OLD SWITCH (a new install): apply it, or leave this Mac as it is.
    ///
    /// CHANGED AT ANOTHER COMPUTER (Turki, Nov 22, as signed off for the
    /// desktop): this Mac's own switch can only be stricter than the shop's.
    /// - `apply` ("Use the newer setting"): the shop's switch here follows
    ///   the other computer.
    /// - not `apply` ("Keep it on this Mac only"), offered only when the
    ///   person was turning the switch ON: the shop's switch follows the other
    ///   computer AND this Mac's own switch is turned on, so this Mac alone
    ///   makes no internet calls.
    /// - when the person was turning it OFF there is no second choice:
    ///   staying online here while the shop is offline would loosen the
    ///   shop's switch. Anything but "use it" is read as "use it".
    func answerNetworkSwitch(apply: Bool) async {
        // The question is the owner's to answer: it decides whether this Mac
        // makes internet calls.
        guard permitted("security", "edit") else { return }
        let ask = networkSwitchAsk
        var value = networkSwitchHeld
        // ── "USE THE NEWER SETTING", AND THE NEWER SETTING IS NOT HELD ───────
        //
        // The read after the 409 failed, or the app restarted (only the stamp
        // is kept). The answer itself reads it, once: the owner pressed the
        // button, so this is their call, made even while the shop's switch is
        // on here (never under this Mac's own switch). Read: applied below.
        // Not read: THE QUESTION STAYS. Clearing it with nothing applied left
        // this Mac offline with no question, and, its switch not having come
        // through Khayt Cloud, no call it may make to hear the switch again.
        if case .changedElsewhere(_, let turningOn)? = ask, value == nil, apply || !turningOn {
            guard !networkSwitchAnswering else { return }
            networkSwitchAnswering = true
            defer { networkSwitchAnswering = false }
            networkSwitchAnswerProblem = nil
            switch await readNewerSetting() {
            case .read(let read): value = read
            case .nothingPublished:
                networkSwitchAnswerProblem = words.callIt("mac.net_ask_nothing_there")
                return
            case .unreached:
                networkSwitchAnswerProblem = words.callIt("mac.net_ask_unreached")
                return
            case .overtaken:
                // The owner changed the switch on this Mac after the question
                // was asked, and that change is newer than the other
                // computer's. Khayt Cloud WAS reached; there is nothing to
                // apply and nothing left to ask. Saying "could not be
                // reached" here was false (review).
                guard networkSwitchAsk == ask else { return }
                networkSwitchAsk = nil
                networkSwitchHeld = nil
                holdStamp(nil)
                outboundDefaults.removeObject(forKey: Self.heldTurningOnKey(networkSwitchShopId))
                return
            }
            // Asked while the read was in flight: the question may have been
            // answered by a check that heard the value, or the book changed.
            guard networkSwitchAsk == ask else { return }
        }
        networkSwitchAnswerProblem = nil
        let stamp = value?.changedAt ?? networkSwitchHeldStamp
        networkSwitchAsk = nil
        networkSwitchHeld = nil
        holdStamp(nil)
        outboundDefaults.removeObject(forKey: Self.heldTurningOnKey(networkSwitchShopId))
        switch ask {
        case .oldSwitch?:
            guard apply, let value else {
                // Left as it is: seen, so a later check does not apply it
                // behind the person's back.
                if let stamp { sawNetworkSwitchStamp(stamp) }
                return
            }
            await applyNetworkSwitch(value, shopId: networkSwitchShopId)
        case .changedElsewhere(_, let turningOn)?:
            // "Keep it on this Mac only": this Mac's own switch, first, so
            // there is no moment at which it is back online.
            if !apply, turningOn { setOutboundOfflineHere(true) }
            // The shop's switch follows the newer setting. When that value
            // could not be read, it is not marked seen: the next check that
            // may ask applies it, as "use the newer setting" says.
            guard let value else { return }
            let applied = await applyNetworkSwitch(value, shopId: networkSwitchShopId, asAnswer: true)
            // Not applied, and not because this Mac already has it or newer:
            // the book could not be written. The question comes back with the
            // value, so the answer can be given again; it is never dropped
            // with nothing applied.
            if !applied, !networkSwitchAlreadySeen(value) {
                networkSwitchHeld = value
                holdStamp(value.changedAt)
                outboundDefaults.set(turningOn, forKey: Self.heldTurningOnKey(networkSwitchShopId))
                networkSwitchAsk = .changedElsewhere(at: NetworkSwitch.date(value.changedAt), turningOn: turningOn)
                networkSwitchAnswerProblem = words.callIt("mac.net_ask_not_saved")
            }
        case nil:
            return
        }
    }

    /// Whether this Mac has already seen this value, or a newer one, from
    /// Khayt Cloud (applied by a check, or left as it is by the owner).
    func networkSwitchAlreadySeen(_ value: NetworkSwitch.Value) -> Bool {
        guard let seen = networkSwitchHighestSeen.flatMap(NetworkSwitch.date), let when = NetworkSwitch.date(value.changedAt) else { return false }
        return when <= seen
    }

    /// What the owner's answer read.
    enum NewerSetting: Equatable {
        case read(NetworkSwitch.Value)
        /// Khayt Cloud answered, and holds no setting for this shop now.
        case nothingPublished
        /// Not signed in, not reached, refused, or a value that fails a check.
        case unreached
        /// Read, and older than a change made on this Mac since the question
        /// was asked: the question is about a switch the owner has since set.
        case overtaken
    }

    /// The ONE `switch-sync` GET the owner's answer makes. The value must
    /// pass every check a heard value passes, and be the one the 409 spoke
    /// of or newer: at or after the stamp the server gave then, else at or
    /// after this Mac's own change. An older value replayed here is not it.
    func readNewerSetting(now: Date = Date()) async -> NewerSetting {
        guard !outboundOfflineHere, let (connection, token, dek) = await networkSwitchSession(),
              connection.shopId == networkSwitchShopId else { return .unreached }
        let fetch = networkSwitchFetcher
        // The owner pressed the button: the gate makes the token here, at
        // the press, and the shared rule lets this ONE call through on it
        // (`lib/outbound.js` answerToken; spent by the gate when used).
        let answer = outboundGate.answerToken()
        let (heard, published) = await OutboundGate.$answer.withValue(answer) {
            await Self.networkSwitchGet(connection, token: token, fetch: fetch)
        }
        switch heard {
        case .failed: return .unreached
        case .none: return .nothingPublished
        case .published:
            guard let published,
                  case .success(let value) = NetworkSwitch.read(published, shopId: connection.shopId, dek: dek,
                                                                highestSeen: networkSwitchHighestSeen, purposes: outboundPurposeIds),
                  !NetworkSwitch.isAhead(value, now: now), let when = NetworkSwitch.date(value.changedAt) else { return .unreached }
            // BOTH floors, as on the desktop: not older than the stamp the 409
            // gave (the value it spoke of, or a newer one), AND not older than
            // this Mac's own change. Either alone lets an older value replayed
            // behind the 409 answer the question.
            if let conflict = networkSwitchHeldStamp.flatMap(NetworkSwitch.date), when < conflict { return .unreached }
            if let own = networkSwitchOwnStamp.flatMap(NetworkSwitch.date), when < own { return .overtaken }
            return .read(value)
        }
    }

    /// Put a checked value in the book and tell the gate. Refused when it is
    /// not newer than what this Mac has seen (asked again here, at the write),
    /// or when the open book is not that shop's any more. This Mac's own
    /// switch is never touched: a value with `offline: false` lifts the
    /// shop's switch, not the computer's.
    @discardableResult
    func applyNetworkSwitch(_ value: NetworkSwitch.Value, shopId: String, asAnswer: Bool = false) async -> Bool {
        // lock: system — the shop's own switch, as its owner set it at another computer, checked and sealed with the shop's key
        guard source.isReal || networkBookForTests != nil, shopId == networkSwitchShopId, !shopId.isEmpty,
              let when = NetworkSwitch.date(value.changedAt) else { return false }
        // The owner's answer applies the value the 409 spoke of, which the
        // server placed AT or after this Mac's own change: the same instant
        // is still the other computer's, and still newer than anything seen
        // from Khayt Cloud. Everything else must be strictly newer than both.
        let seen = asAnswer ? networkSwitchHighestSeen : NetworkSwitch.later(networkSwitchHighestSeen, networkSwitchOwnStamp)
        if let seen, let seenAt = NetworkSwitch.date(seen), when <= seenAt { return false }
        if asAnswer, let own = networkSwitchOwnStamp.flatMap(NetworkSwitch.date), when < own { return false }
        guard await writeNetworkSettings({ NetworkSwitch.applied(value, to: $0) }) else { return false }
        sawNetworkSwitchStamp(value.changedAt)
        if !value.offline {
            if !outboundGate.isOffline { outboundGate.clearCounts() }
            outboundNotice = nil
        }
        await reloadAfterNetworkWrite()
        return true
    }

    /// Start hearing: now, and every fifteen minutes while the app runs. A
    /// question that was waiting when the app last quit is asked again.
    func startNetworkSwitchChecks() {
        if networkSwitchAsk == nil, let stamp = networkSwitchHeldStamp {
            networkSwitchAsk = .changedElsewhere(at: NetworkSwitch.date(stamp), turningOn: networkSwitchHeldTurningOn)
        }
        networkSwitchTask?.cancel()
        networkSwitchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.checkNetworkSwitch()
                try? await Task.sleep(for: .seconds(NetworkSwitch.checkEvery))
            }
        }
    }
}

/// A test's book: `settings.network`, in memory.
final class NetworkBookForTests: @unchecked Sendable {
    private let lock = NSLock()
    private var held: JSONValue?
    init(_ network: JSONValue? = nil) { held = network }
    var network: JSONValue? {
        get { lock.lock(); defer { lock.unlock() }; return held }
        set { lock.lock(); defer { lock.unlock() }; held = newValue }
    }
}

/// What a person is asked about a value from Khayt Cloud before it is applied.
enum NetworkSwitchAsk: Equatable {
    /// A new install met an `offline: true` more than seven days old:
    /// "Your shop turned off internet use on <date>. Apply it here?"
    case oldSwitch(at: Date?)
    /// The switch was changed here just now, and the server answered that
    /// another computer changed it at or after that moment. `turningOn`: the
    /// person was turning it on (then "Keep it on this Mac only" is offered).
    case changedElsewhere(at: Date?, turningOn: Bool)
}

/// The two questions, in the shop's words.
///
/// ── WHICH WAY THE OTHER COMPUTER TURNED IT IS READ, NEVER ASSUMED ─────────
///
/// A 409 says only that another computer changed the switch at or after this
/// moment, not to what. On a Mac whose clock runs behind, both may have turned
/// it ON. So the sentence names a direction only when the other computer's
/// value was read (`there`, its `offline`) and is the opposite of what was
/// done here. Unread, or the same way, it says the switch was changed at
/// another computer and nothing it cannot know (review of the frames, Nov 22).
@MainActor
enum NetworkSwitchWords {
    static func sentence(_ ask: NetworkSwitchAsk, there: Bool?, words: Words) -> String {
        switch ask {
        case .oldSwitch(let at):
            let date = at.map { words.say($0, .dateTime.day().month(.abbreviated).year()) } ?? ""
            return words.callIt("mac.net_ask_old", ["date": .string(date)])
        case .changedElsewhere(let at, let turningOn):
            // Which way each computer turned it (page 27, frame G2). With no
            // time from Khayt Cloud, or no known opposite value, the general
            // sentence and the clock hint.
            guard let at, ask.opposite(there: there) else { return words.callIt("mac.net_ask_elsewhere_anon") }
            return words.callIt(turningOn ? "mac.net_ask_off_there" : "mac.net_ask_on_there",
                                ["time": .string(words.say(at, .dateTime.hour().minute()))])
        }
    }
}

extension NetworkSwitchAsk {
    /// The other computer's value was read and is the opposite of what was
    /// done here: turned OFF there while turning ON here, or the reverse.
    func opposite(there: Bool?) -> Bool {
        guard case .changedElsewhere(_, let turningOn) = self, let there else { return false }
        return there != turningOn
    }

    /// Whether this Mac alone follows the switch while the question waits:
    /// it was turned ON here, and the other computer did not turn it on too.
    /// Unread counts: this Mac is offline and nothing says the others are.
    func onlyThisMac(there: Bool?) -> Bool {
        guard case .changedElsewhere(_, true) = self else { return false }
        return there != true
    }

    /// The buttons a question offers, as (word key, the answer it gives).
    /// "Keep it on this Mac only" is offered only when the switch was being
    /// turned ON here and the other computer did not turn it on as well: then
    /// there is nothing to keep, the shop is offline everywhere.
    func choices(there: Bool?) -> [(key: String, apply: Bool)] {
        switch self {
        case .oldSwitch: [("mac.net_ask_apply", true), ("mac.net_ask_leave", false)]
        case .changedElsewhere:
            onlyThisMac(there: there) ? [("mac.net_ask_newer", true), ("mac.net_ask_here_only", false)] : [("mac.net_ask_newer", true)]
        }
    }

    /// The buttons when the other computer's value is not known.
    var choices: [(key: String, apply: Bool)] { choices(there: nil) }
}
