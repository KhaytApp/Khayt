import AVKit
import Foundation
import SwiftUI
import KhaytCore

/// A finished print's timelapse, where the printer keeps it.
///
/// ── WHAT THE PRINTER RECORDS, AND WHEN ────────────────────────────────────
///
/// A Snapmaker U1 writes one video and one cover per print into Moonraker's
/// `camera` folder, named after the G-code file and the job's start time:
/// `Dark Knight_PLA_5h39m_20260626202455.mp4`. Its history does not point at
/// them (`auxiliary_data` is `[]` on every job on the bench), so the match is
/// by name and time — `lib/webcam.js matchTimelapse`, where both must agree.
///
/// The video is written AFTER the job ends: 35 s after, on the bench. So at
/// the finish edge it does not exist yet, and the look is retried a few times
/// rather than asked once and given up on.
///
/// ── THE BOOK KEEPS A NAME, NOT A COPY ────────────────────────────────────
///
/// These run to 100 MB. A job keeps the machine and the file names
/// (`printerTimelapse`), and "Watch timelapse" plays it from the printer.
/// Nothing is downloaded into the book, and no URL is stored: the address is
/// built from the machine's host at the moment it is opened, through the same
/// camera rules as every still (`timelapseLink`).
@MainActor
enum Timelapse {

    /// When to look after a print finishes. The first is past the 35 s the
    /// bench took; the later two are for a long print's longer encode.
    static let tries: [Duration] = [.seconds(45), .seconds(120), .seconds(300)]

    /// How many of its own jobs to ask the printer for. The one that just
    /// ended is the newest; five covers a queue that moved on meanwhile.
    static let historyLimit = 5

    /// One look: the job the printer just ran under `filename`, and its video.
    ///
    /// `get` is `PrinterWatch.get`, a seam so a test can answer with the U1's
    /// own replies.
    static func look(base: URL, filename: String, key: String, engine: KhaytEngine,
                     get: (URL, String, String) async throws -> [String: JSONValue]) async -> KhaytEngine.TimelapseMatch? {
        guard let history = try? await get(base, "/server/history/list?limit=\(historyLimit)", key),
              case .object(let result)? = history["result"],
              case .array(let jobs)? = result["jobs"] else { return nil }
        // The newest completed run of this file. Moonraker lists newest first.
        guard let job = jobs.first(where: { row in
            guard case .object(let o) = row else { return false }
            return o["filename"] == .string(filename) && o["status"] == .string("completed")
        }) else { return nil }
        guard let files = try? await get(base, "/server/files/list?root=camera", key) else { return nil }
        return (try? await engine.matchTimelapse(job: job, files: .object(files))) ?? nil
    }
}

extension Shop {

    /// After a finished Moonraker print on a job the book names: look for its
    /// timelapse, and note it on the job. Best-effort and silent, like the
    /// finish photo — a printer with timelapse switched off simply has none.
    func noteTimelapse(_ ended: FinishCamera.Ended, machine: Machine) async {
        guard ended.outcome == "finished", let jobId = ended.orderId, !ended.filename.isEmpty,
              machine.printerApi?.type == "moonraker", let engine else { return }
        for wait in Timelapse.tries {
            try? await Task.sleep(for: wait)
            if Task.isCancelled { return }
            // Re-read each time: the book may have been closed, the job
            // deleted, or a timelapse noted by the other app meanwhile.
            guard source.build != nil, canWrite,
                  case .object(let row)? = orderRows.first(where: { Self.recordId($0) == jobId }) else { return }
            if row["printerTimelapse"] != nil { return }
            guard let current = machines.first(where: { $0.id == machine.id }),
                  let base = try? await PrinterWatch.baseURL(current, engine: engine) else { return }
            var key = ""
            if let sealed = current.printerApi?.apiKey, !sealed.isEmpty, let build = source.build {
                key = (try? await Secrets.open(sealed, for: build)) ?? ""
            }
            let found = await Timelapse.look(base: base, filename: ended.filename, key: key, engine: engine) {
                try await PrinterWatch.get($0, path: $1, key: $2, type: "moonraker", timeout: 10)
            }
            guard let found else { continue }
            _ = await writeTimelapse(found, jobId: jobId, machineId: machine.id)
            return
        }
    }

    /// Put the match on the job, through the write chain. False when nothing
    /// was written — the job already had one, or this Mac may not write.
    @discardableResult
    func writeTimelapse(_ found: KhaytEngine.TimelapseMatch, jobId: String, machineId: String,
                        now: Date = Date()) async -> Bool {
        guard let engine, let build = source.build, canWrite, permitted("orders", "edit") else { return false }
        let at = ISO8601DateFormatter().string(from: now)
        guard let record = try? await engine.timelapseRecord(machineId: machineId, match: found, at: at),
              record != .null else { return false }
        let wrote = (try? await StoreWriter.updateRecordOffMain(build, collection: "printLog", id: jobId) { job -> Bool in
            guard job["printerTimelapse"] == nil else { return false }
            job["printerTimelapse"] = record
            return true
        }) ?? nil
        guard wrote == true else { return false }
        await load(source)
        return true
    }

    /// Where to watch a job's timelapse, or nil when it has none or its
    /// machine has gone.
    func timelapseLink(_ jobId: String) async -> KhaytEngine.TimelapseLink? {
        guard let engine, case .object(let row)? = orderRows.first(where: { Self.recordId($0) == jobId }),
              case .object(let t)? = row["printerTimelapse"], case .string(let mid)? = t["machineId"],
              let machine = machineRows.first(where: { Self.recordId($0) == mid }) else { return nil }
        return (try? await engine.timelapseLink(order: .object(row), machine: machine)) ?? nil
    }

    /// The video's address, checked as a camera's is: the printer's own host
    /// by the shared rule, then the poller's LAN rule, aimed at the address
    /// that was checked. Nil when either refuses.
    func timelapsePlayable(_ link: KhaytEngine.TimelapseLink) async -> URL? {
        guard let engine, let machine = machines.first(where: { $0.id == link.machineId }),
              let api = await printerApiRow(machine),
              (try? await engine.assertWebcamHost(link.videoUrl, printerApi: api)) != nil,
              let url = URL(string: link.videoUrl) else { return nil }
        return await PrinterWatch.pinned(url, engine: engine)
    }
}

/// "Watch timelapse" on a finished job, and the size it is on the printer.
struct TimelapseLine: View {
    let shop: Shop
    let link: KhaytEngine.TimelapseLink
    @State private var playing: URL?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                Task {
                    problem = nil
                    if let url = await shop.timelapsePlayable(link) { playing = url }
                    else { problem = shop.words.callIt("mac.timelapse_gone") }
                }
            } label: {
                Label(shop.words.callIt("mac.timelapse_watch"), systemImage: "play.rectangle")
            }
            .buttonStyle(.link)
            .font(.callout)
            Text(shop.words.callIt("mac.timelapse_on_printer",
                                   ["size": .string(Self.size(link.bytes, shop.words)),
                                    "machine": .string(shop.machineName(forId: link.machineId))]))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
        }
        .shopSheet(item: Binding(get: { playing.map(Playing.init) }, set: { playing = $0?.url })) { p in
            TimelapsePlayer(url: p.url, words: shop.words) { playing = nil }
        }
    }

    private struct Playing: Identifiable { let url: URL; var id: String { url.absoluteString } }

    /// `59 MB`, in Western digits (`Words.locale`). Empty size reads as "—".
    static func size(_ bytes: Double?, _ words: Words) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let mb = Measurement(value: bytes / 1_000_000, unit: UnitInformationStorage.megabytes)
        return mb.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                         numberFormatStyle: .number.precision(.fractionLength(0)))
                            .locale(words.locale))
    }
}

/// The video, played from the printer. AVPlayer streams it by byte range
/// (Moonraker answers `Accept-Ranges: bytes`), so a 100 MB file starts at
/// once and nothing lands on disk.
private struct TimelapsePlayer: View {
    let url: URL
    let words: Words
    let close: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(words.callIt("mac.timelapse_title")).font(.headline)
                Spacer()
                Button(words.callIt("common.close"), action: close).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            VideoPlayer(player: player)
                .frame(minWidth: 560, minHeight: 360)
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause(); player = nil }
    }
}
