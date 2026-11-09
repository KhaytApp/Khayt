import Foundation
import KhaytCore

/// A connector asking its service about open jobs on its own (`refresh`,
/// connectors v1.1), and the replies to events.
///
/// ── WHERE AND HOW OFTEN ─────────────────────────────────────────────────
///
/// Only on the Mac holding the book lock (`StoreLock.weOwnIt`), from the
/// integrations pass, with connectors switched on. A phone never holds the
/// lock and never runs this. Each connector runs at most once per its
/// `every` minutes and never more often than every 15
/// (`lib/plugin-host.js` refreshDue); one run asks about at most 50 open jobs
/// whose `when` field is filled in, least recently asked about first
/// (refreshJobs).
///
/// ── THE CLOCK STAYS OUT OF THE BOOK ─────────────────────────────────────
///
/// When each connector last ran is kept in this Mac's defaults, and when each
/// job was last asked about in memory. A time stamped into the synced book
/// every quarter hour would be a write every device syncs for nothing. A
/// relaunch therefore starts the job order over, which only means the first
/// run after it asks about the jobs nearest the front again.
///
/// ── WHAT IT SENDS AND WHAT IT WRITES ────────────────────────────────────
///
/// The request is `connectorSend`'s, the same builder a button uses, so it
/// carries only what the manifest declares and the shop agreed to. A reply
/// fills only the connector's own fields on that job (`applyResponse`, with
/// fields.write granted), all of one run's replies in ONE write.
@MainActor
extension Shop {

    /// Defaults key: connector id → when its refresh last ran (ms).
    nonisolated static let connectorRefreshRunsKey = "KhaytConnectorRefreshRuns"

    /// One refresh pass: every connector that is due, in turn.
    func refreshConnectors(now: Date = Date()) async {
        guard ConnectorsSwitch.isOn(), !connectorRefreshing else { return }
        guard let engine, let build = source.build, StoreLock.weOwnIt(build) else { return }
        connectorRefreshing = true
        defer { connectorRefreshing = false }

        for entry in await liveConnectors() {
            let e = Self.object(entry)
            guard let id = Shop.plainString(e["id"]),
                  case .object(let refresh)? = Self.object(e["manifest"])["refresh"] else { continue }
            var runs = devConnectorDefaults.dictionary(forKey: Self.connectorRefreshRunsKey) as? [String: Double] ?? [:]
            let nowMs = now.timeIntervalSince1970 * 1000
            guard (try? await engine.pluginRefreshDue(.object(refresh), lastRunMs: runs[id] ?? 0, nowMs: nowMs)) == true else {
                continue
            }
            // Stamped BEFORE anything is sent, so a run that dies half way is
            // not repeated at the next pass.
            runs[id] = nowMs
            devConnectorDefaults.set(runs, forKey: Self.connectorRefreshRunsKey)
            await refreshOne(entry: entry, id: id, engine: engine, build: build)
        }
    }

    /// One connector's run: ask about each chosen job, then write every reply at once.
    private func refreshOne(entry: JSONValue, id: String, engine: KhaytEngine, build: StoreReader.Build) async {
        guard let root = try? await BookWork.run({
            try JSONValue.decode([String: JSONValue].self, from: Data(contentsOf: build.storeURL))
        }) else { return }
        let printLog = root["printLog"] ?? .array([])
        let jobs = (try? await engine.pluginRefreshJobs(printLog, entry: entry,
                                                        checkedAt: connectorRefreshChecked[id] ?? [:])) ?? []
        guard !jobs.isEmpty else { return }
        var secrets: [String: String] = [:]
        for n in Self.connectorSecretsDeclared(Self.object(entry)["manifest"] ?? .null).map(\.name) {
            if let v = await connectorSecrets.value(pluginId: id, name: n), !v.isEmpty { secrets[n] = v }
        }
        var replies: [ConnectorReply] = []
        var checked = connectorRefreshChecked[id] ?? [:]
        for job in jobs {
            // Switched off, or the book handed to another computer, mid-run.
            guard ConnectorsSwitch.isOn(), StoreLock.weOwnIt(build) else { break }
            guard let jobId = Shop.plainString(Self.object(job)["id"]) else { continue }
            let customer = Shop.plainString(Self.object(job)["clientId"]).flatMap { Self.record(in: root, "clients", id: $0) }
            let outcome = await Self.connectorSend(entry: entry, trigger: .refresh, order: job, customer: customer,
                                                   secrets: secrets, engine: engine,
                                                   post: connectorPost ?? Self.realConnectorPost(engine),
                                                   now: Date(), delivery: Connectors.newDeliveryId())
            checked[jobId] = Date().timeIntervalSince1970 * 1000
            // A key or setting not filled in: every other job would be refused
            // the same way. The next run tries again.
            if case .refused = outcome { break }
            if case .sent(let values) = outcome, case .object(let v) = values, !v.isEmpty {
                replies.append(ConnectorReply(jobId: jobId, values: values))
            }
        }
        // Only jobs still in the book are remembered.
        var ids = Set<String>()
        if case .array(let rows) = printLog { for row in rows { if let i = Shop.plainString(Self.object(row)["id"]) { ids.insert(i) } } }
        connectorRefreshChecked[id] = checked.filter { ids.contains($0.key) }
        _ = await writeConnectorReplies(entry: entry, replies: replies)
    }

    /// The replies of one refresh run, or of one event, written into the
    /// connector's own fields on each job, in ONE write. `StoreWriter` raises
    /// each changed job's `rev`, so a phone's older copy cannot put the old
    /// value back.
    func writeConnectorReplies(entry: JSONValue, replies: [ConnectorReply]) async -> Bool {
        // lock: system — a connector's reply to a request the shop agreed to, filling only its own job fields
        guard !replies.isEmpty, let engine, let build = source.build else { return false }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                for reply in replies {
                    try await Self.withConnectorValues(&root, collection: "printLog", id: reply.jobId, entry: entry,
                                                       attach: "order", values: reply.values, engine: engine)
                }
            }
            await load(source)
            return true
        } catch {
            return false
        }
    }
}

/// What a reply fills in on one job.
struct ConnectorReply: Equatable, Sendable {
    let jobId: String
    let values: JSONValue
}
