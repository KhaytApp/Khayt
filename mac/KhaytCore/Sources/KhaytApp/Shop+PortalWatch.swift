import Foundation
import AppKit
import KhaytCore

/// "Check portal", on its own: what customers did with the links this shop
/// published, read when the app comes to the front and every fifteen minutes.
///
/// ── WHY ────────────────────────────────────────────────────────────────────
///
/// A customer's approval and their deposit reached the book only when somebody
/// opened the job's link sheet and pressed "Check response". A quote approved
/// on Sunday sat as a quote until Tuesday, and its deposit was typed in by hand
/// beside a sheet that already said it was paid.
///
/// ── WHAT IT COSTS THE CLOUD ────────────────────────────────────────────────
///
/// One `GET /v1/shops/{id}/published` per look, whatever the number of jobs —
/// the list carries every link's answer and payment, and each job is matched
/// in it (`responseFor`). That owner route sits in no rate-limit bucket
/// (khayt-cloud docs/api-contract.md, Rate limiting); a 429 all the same holds
/// the timer off for an hour. Coming to the front looks at most once a
/// minute, and nothing is asked when no published job is waiting on anything.
///
/// ── WHAT IT DOES WITH THE ANSWER ──────────────────────────────────────────
///
/// Exactly what "Check response" does, job by job: a payment is recorded once
/// (`recordPortalDeposit`), and an approval moves a quote to Pending through
/// `moveJob` — only when the person at this Mac may move jobs, since a move is
/// theirs to make and a locked Mac leaves the quote for them to see.
extension Shop {

    static let portalWatchEvery: Duration = .seconds(15 * 60)
    /// Coming to the front looks again only after this long.
    static let portalWatchMinGap: TimeInterval = 60
    /// After the cloud says "too many".
    static let portalWatchBackOff: TimeInterval = 60 * 60

    func startWatchingPortal() {
        guard portalWatchTask == nil else { return }
        portalWatchTask = Task { [weak self] in
            // Not in the first seconds of a launch, which has enough to read.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.checkPortalNow()
                try? await Task.sleep(for: Self.portalWatchEvery)
            }
        }
        if portalWatchObserver == nil {
            portalWatchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.checkPortalNow() }
                }
            }
        }
    }

    func stopWatchingPortal() {
        portalWatchTask?.cancel()
        portalWatchTask = nil
        if let token = portalWatchObserver { NotificationCenter.default.removeObserver(token) }
        portalWatchObserver = nil
    }

    /// The published jobs worth asking about, with their tokens: a quote
    /// (waiting on an answer), or a job that asked for a deposit the portal has
    /// not yet paid onto it. A void, or a page coming down, is not asked about.
    nonisolated static func portalJobsToWatch(_ jobs: [JSONValue]) -> [(id: String, token: String)] {
        jobs.compactMap { row in
            guard case .object(let o) = row, o["cloudPublished"] == .bool(true),
                  o[takedownPendingKey] != .bool(true), o["voidedAt"] == nil || o["voidedAt"] == .null,
                  case .string(let id)? = o["id"], case .string(let token)? = o["trackingToken"],
                  !token.isEmpty else { return nil }
            let status = plainString(o["status"]) ?? ""
            var depositAsked = false
            if case .number(let d)? = o["cloudDeposit"], d > 0 { depositAsked = true }
            var depositIn = false
            if case .array(let paid)? = o["portalPayments"], !paid.isEmpty { depositIn = true }
            guard status == "quote" || (depositAsked && !depositIn) else { return nil }
            return (id, token)
        }
    }

    /// One look at the portal for every job waiting on it.
    func checkPortalNow(now: Date = Date()) async {
        guard !portalWatchBusy, let engine, source.build != nil, portalReachable else { return }
        if let notBefore = portalWatchNotBefore, now < notBefore { return }
        if let last = portalWatchedAt, now.timeIntervalSince(last) < Self.portalWatchMinGap { return }
        let waiting = Self.portalJobsToWatch(orderRows)
        guard !waiting.isEmpty else { return }
        portalWatchBusy = true
        defer { portalWatchBusy = false }
        portalWatchedAt = now
        // lock: system — the customer's own answer and their provider's payment, read back; no person acts here.
        let items: JSONValue
        do {
            let creds = try await portalCredentials()
            items = try await PortalClient.listPublished(baseUrl: creds.url, shopId: creds.shopId,
                                                         token: creds.token, engine: engine)
        } catch {
            if case PortalClient.Failure.owner(let said)? = error as? PortalClient.Failure, said.code == "rate" {
                portalWatchNotBefore = now.addingTimeInterval(Self.portalWatchBackOff)
            }
            return   // quietly: the next look tries again, and the sheet's button says why
        }
        for job in waiting {
            guard let raw = portalRecord(job.id),
                  let said = try? await engine.portalResponse(items: items, pubToken: job.token, order: .object(raw))
            else { continue }
            if said.paid { await recordPortalDeposit(job.id, items: items, token: job.token, quiet: true) }
            if said.advance, cloudRoleCanWrite, lockAllows("orders", "edit") {
                let kept = moveNotices
                await moveJob(job.id, to: .pending)
                if orders.first(where: { $0.id == job.id })?.status == "pending" {
                    moveNotices = kept + [words.callIt("cloud.portal_approved_advanced")]
                }
            }
        }
    }
}
