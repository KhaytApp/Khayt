import Foundation
import KhaytCore

/// The shop's side of the customer portal: publish a job's link, take it
/// down, read what the customer did with it, and answer them.
///
/// The Mac only ever REPUBLISHED — a job the other app had published moved,
/// and the page followed. A job that existed only on this Mac could not be
/// put on the portal at all, so a shop on the Mac alone had a portal it could
/// not reach. Every decision here is `lib/portal-owner.js`'s or
/// `lib/portal-refresh.js`'s; this is the order the steps run in and the
/// writes to the book.
///
/// Writes go through `StoreWriter`, and `cloudPublished` is set only after the
/// cloud has taken the link — a job marked published that is not would have
/// every later move "refresh" a page nobody can open.
extension Shop {

    /// The portal is reachable: a verified cloud connection.
    var portalReachable: Bool { Self.cloudConnected(settingsDict) }

    /// The connection, with the bearer opened at the point of use (it is a
    /// sealed path; ciphertext as a bearer reads as an account that stopped
    /// working). Never stored.
    private func portalCredentials() async throws -> (url: String, shopId: String, token: String) {
        var cloud: [String: JSONValue] = [:]
        if case .object(let c)? = settingsDict["cloud"] { cloud = c }
        let token = try await Secrets.open(Self.plainString(cloud["token"]) ?? "", for: source)
        return (Self.plainString(cloud["url"]) ?? "", Self.plainString(cloud["shopId"]) ?? "", token)
    }

    /// The five steps the customer's page shows, in the shop's language.
    var portalStages: [String] {
        [
            words.callIt("track.received", fallback: "Received"),
            words.callIt("track.printing", fallback: "Printing"),
            words.callIt("track.finishing", fallback: "Finishing"),
            words.callIt("track.done", fallback: "Done"),
            words.callIt("track.ready", fallback: "Ready for pickup"),
        ]
    }

    /// A job's record as the book holds it — `Order` does not carry the
    /// portal fields, and these are read from what is on disk anyway.
    func portalRecord(_ id: Order.ID) -> [String: JSONValue]? {
        orderRows.lazy.compactMap(Self.asObject).first { Self.plainString($0["id"]) == id }
    }

    /// The job's tracking token, or nil before one is minted.
    func portalToken(_ id: Order.ID) -> String? {
        guard let t = Self.plainString(portalRecord(id)?["trackingToken"]), !t.isEmpty else { return nil }
        return t
    }

    /// The job's link is up.
    func isPortalPublished(_ id: Order.ID) -> Bool {
        portalRecord(id)?["cloudPublished"] == .bool(true) && portalToken(id) != nil
    }

    /// The link a published job's customer is sent, or nil when it is not published.
    func portalLink(for id: Order.ID) async -> String? {
        guard let engine, isPortalPublished(id), let tok = portalToken(id) else { return nil }
        var cloud: [String: JSONValue] = [:]
        if case .object(let c)? = settingsDict["cloud"] { cloud = c }
        let url = (try? await engine.portalUrl(baseUrl: Self.plainString(cloud["url"]) ?? "", pubToken: tok)) ?? ""
        return url.isEmpty ? nil : url
    }

    /// Publish a job's link — for a quote, with an optional deposit and pay
    /// link. Returns the link on success; on failure says why in `moveProblem`.
    ///
    /// In this order, as the desktop's `publishOrderToCloudPortal`: connected,
    /// allowed to write, the trial allows it, the deposit is well-formed; then
    /// the token is minted (once), the deposit and the trial's start written;
    /// then the PUT; and only then `cloudPublished`.
    @discardableResult
    func publishPortal(_ id: Order.ID, deposit: String? = nil, payUrl: String? = nil) async -> String? {
        moveProblem = nil
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return nil }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return nil }
        guard portalReachable else { moveProblem = words.callIt("cloud.portal_need_connect"); return nil }
        guard cloudRoleCanWrite else { moveProblem = words.callIt("mac.portal_viewer"); return nil }
        var cloud: [String: JSONValue] = [:]
        if case .object(let c)? = settingsDict["cloud"] { cloud = c }
        guard let gate = try? await engine.portalTrialGate(cloud: cloud, now: Date()) else { return nil }
        guard gate.allowed else { moveProblem = words.callIt("trial.portal_over"); return nil }

        var form: KhaytEngine.DepositForm?
        if deposit != nil || payUrl != nil {
            guard let f = try? await engine.portalDepositForm(deposit: deposit ?? "", payUrl: payUrl ?? "") else { return nil }
            guard f.ok else {
                moveProblem = words.callIt(f.error == "pay_url" ? "cloud.deposit_bad_url" : "cloud.deposit_bad_amount")
                return nil
            }
            form = f
        }

        // The token, the deposit and the trial's start — one write, before the PUT.
        var written: [String: JSONValue]?
        do {
            try StoreWriter.update(build) { root in
                var log = Self.rows(root, "printLog")
                guard let at = log.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(var record) = log[at] else { return }
                if (Self.plainString(record["trackingToken"]) ?? "").isEmpty {
                    record["trackingToken"] = .string(LanServer.randomToken(bytes: 16))
                }
                if let form {
                    record["cloudDeposit"] = form.cloudDeposit.map(JSONValue.number) ?? .null
                    record["cloudPayUrl"] = form.cloudPayUrl.map(JSONValue.string) ?? .null
                }
                StoreWriter.stamp(&record)
                log[at] = .object(record)
                root["printLog"] = .array(log)
                if gate.startAt != nil || form?.lastPayUrl != nil {
                    var settings = Self.settings(root)
                    var c: [String: JSONValue] = [:]
                    if case .object(let had)? = settings["cloud"] { c = had }
                    if let start = gate.startAt { c["portalTrialStartedAt"] = .string(start) }
                    if let last = form?.lastPayUrl { c["lastPayUrl"] = .string(last) }
                    settings["cloud"] = .object(c)
                    root["settings"] = .object(settings)
                }
                written = record
            }
        } catch {
            moveProblem = String(describing: error); return nil
        }
        await load(source)
        guard let record = written else { moveProblem = words.callIt("mac.move_gone"); return nil }

        do {
            let settings = settingsDict
            guard let request = try await engine.portalPayload(
                order: .object(record), settings: settings, clients: clientRows,
                shopName: Self.plainString(settings["bizEn"]) ?? Self.plainString(settings["bizAr"]) ?? "Khayt",
                shopAddress: Self.plainString(settings["addrEn"]) ?? Self.plainString(settings["addrAr"]) ?? "",
                stages: portalStages) else { return nil }
            let creds = try await portalCredentials()
            let note = try await PortalClient.publish(request, baseUrl: creds.url, shopId: creds.shopId,
                                                      token: creds.token, engine: engine)
            try StoreWriter.updateRecord(build, collection: "printLog", id: id) { r in
                r["cloudPublished"] = .bool(true)
            }
            await load(source)
            moveNotices = [words.callIt(note == nil ? "mac.portal_published" : "mac.portal_published_unlinked")]
            let link = (try? await engine.portalUrl(baseUrl: creds.url, pubToken: request.pubToken)) ?? ""
            return link.isEmpty ? nil : link
        } catch {
            moveProblem = portalSentence(error); return nil
        }
    }

    /// Take a job's link down; the job stops refreshing it.
    func unpublishPortal(_ id: Order.ID) async {
        moveProblem = nil
        guard let build = source.build, let engine, let tok = portalToken(id) else { return }
        guard cloudRoleCanWrite else { moveProblem = words.callIt("mac.portal_viewer"); return }
        do {
            let creds = try await portalCredentials()
            try await PortalClient.unpublish(pubToken: tok, baseUrl: creds.url, shopId: creds.shopId,
                                             token: creds.token, engine: engine)
            try StoreWriter.updateRecord(build, collection: "printLog", id: id) { r in
                r["cloudPublished"] = .bool(false)
            }
            await load(source)
            moveNotices = [words.callIt("cloud.portal_unpublished")]
        } catch {
            moveProblem = portalSentence(error)
        }
    }

    /// What the customer did with a quote's link. An approval moves a job
    /// still a quote to Pending through `moveJob` — the status rule, with
    /// everything a move owes outward — as the desktop's "Check response" did.
    func checkPortalResponse(_ id: Order.ID) async -> KhaytEngine.PortalResponse? {
        moveProblem = nil
        guard let engine, let tok = portalToken(id), let raw = portalRecord(id) else { return nil }
        do {
            let creds = try await portalCredentials()
            let items = try await PortalClient.listPublished(baseUrl: creds.url, shopId: creds.shopId,
                                                             token: creds.token, engine: engine)
            let said = try await engine.portalResponse(items: items, pubToken: tok, order: .object(raw))
            if said.advance, cloudRoleCanWrite { await moveJob(id, to: .pending) }
            return said
        } catch {
            moveProblem = portalSentence(error); return nil
        }
    }

    /// The conversation behind a published job's link.
    func portalThread(_ id: Order.ID) async throws -> [KhaytEngine.PortalMessage] {
        guard let engine, let tok = portalToken(id) else { return [] }
        let creds = try await portalCredentials()
        return try await PortalClient.messages(pubToken: tok, baseUrl: creds.url, shopId: creds.shopId,
                                               token: creds.token, engine: engine)
    }

    /// Answer the customer, as the shop. A viewer cannot; the sheet hides it.
    func replyOnPortal(_ id: Order.ID, text: String) async throws {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, let engine, let tok = portalToken(id) else { return }
        let creds = try await portalCredentials()
        try await PortalClient.reply(pubToken: tok, text: String(said.prefix(2000)), baseUrl: creds.url,
                                     shopId: creds.shopId, token: creds.token, engine: engine)
    }

    /// Republish a published job's page after an edit that is not a move —
    /// shipped, a tracking update, a payment — as the desktop's
    /// `order-flows.js` does after each. Nothing when the job owes nothing
    /// (`requestFor` decides: published, connected, trial allows).
    func republishPortalIfPublished(_ id: Order.ID) async {
        guard let engine, let raw = portalRecord(id) else { return }
        let settings = settingsDict
        guard let portal = try? await engine.portalRefresh(
            order: .object(raw), settings: settings, clients: clientRows,
            shopName: Self.plainString(settings["bizEn"]) ?? Self.plainString(settings["bizAr"]) ?? "Khayt",
            shopAddress: Self.plainString(settings["addrEn"]) ?? Self.plainString(settings["addrAr"]) ?? "",
            stages: portalStages, now: Date()) else { return }
        await refresh(portal)
    }

    /// A portal failure in words a shop can act on.
    func portalSentence(_ error: Error) -> String {
        if case PortalClient.Failure.owner(let said)? = error as? PortalClient.Failure {
            switch said.code {
            case "viewer": return words.callIt("mac.portal_viewer")
            case "other_shop": return words.callIt("mac.portal_other_shop")
            case "rate": return words.callIt("mac.portal_rate")
            case "not_this_shop": return words.callIt("mac.portal_not_here")
            default: return words.callIt("mac.portal_failed") + " " + said.text
            }
        }
        if let failure = error as? PortalClient.Failure {
            return words.callIt("mac.portal_failed") + " " + (failure.errorDescription ?? "")
        }
        return words.callIt("mac.portal_failed") + " " + String(describing: error)
    }
}
