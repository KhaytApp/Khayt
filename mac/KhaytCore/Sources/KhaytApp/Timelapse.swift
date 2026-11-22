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
    /// Links the snapshot runner puts in place, by job id. Empty outside it.
    static var pretend: [String: KhaytEngine.TimelapseLink] = [:]


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
        if let pretend = Timelapse.pretend[jobId] { return pretend }
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
            TimelapsePlayer(url: p.url, bytes: link.bytes, words: shop.words) { playing = nil }
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

/// The video, played from the printer, by byte range (Moonraker's file route
/// answers `Accept-Ranges: bytes`), so a 100 MB file starts at once and
/// nothing lands on disk.
///
/// ── THE PLAYER NEVER DIALS THE PRINTER ITSELF ────────────────────────────
///
/// `AVPlayer` given an http URL follows a redirect wherever it points, after
/// every check this app made — so a printer (or whatever answers at its
/// address) could bounce the player onto loopback or anywhere else. Instead
/// the player is handed a private scheme, and every byte it asks for is
/// fetched by `PinnedVideoLoader` from the address that was checked, with
/// redirects refused and no cache, exactly as a still is.
private struct TimelapsePlayer: View {
    let url: URL
    /// What the printer said the video weighed when the job was noted.
    let bytes: Double?
    let words: Words
    let close: () -> Void
    @State private var player: AVPlayer?
    /// Held here: an asset keeps its loader delegate weakly.
    @State private var loader: PinnedVideoLoader?

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
            let made = PinnedVideoLoader(real: url, cap: PinnedVideoLoader.cap(recorded: bytes))
            // No reference the movie makes may be followed — local or remote.
            let asset = AVURLAsset(url: PinnedVideoLoader.playerURL, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            ])
            asset.resourceLoader.setDelegate(made, queue: made.queue)
            loader = made
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            // Not handed to AirPlay: another device would fetch it itself.
            p.allowsExternalPlayback = false
            player = p
            p.play()
        }
        .onDisappear { player?.pause(); player = nil; loader = nil }
    }
}

/// Every byte a timelapse player reads, fetched from the checked address in
/// ranged chunks, with redirects refused and no cache.
///
/// A reply is held to the range that was ASKED for, before its body is
/// buffered: `206 Partial Content`, a `Content-Range` starting at the asked
/// offset and ending inside the asked range, and a declared length no larger
/// than it. A body that runs past the range anyway is cut off as it arrives.
/// The total the printer claims is clamped (`cap`), and every sum here
/// saturates instead of overflowing.
final class PinnedVideoLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let playerURL = URL(string: "khayt-timelapse://printer/timelapse.mp4")!
    /// Two megabytes a request: a few seconds of a timelapse.
    static let chunk: Int64 = 2 * 1024 * 1024
    /// The largest video believed when the job did not record a size.
    static let defaultCap: Int64 = 8 * 1024 * 1024 * 1024

    /// The job's recorded size when it has one, else 8 GB.
    static func cap(recorded: Double?) -> Int64 {
        guard let b = recorded, b.isFinite, b >= 1, b < Double(defaultCap) else { return defaultCap }
        return Int64(b)
    }

    let real: URL
    let cap: Int64
    let queue = DispatchQueue(label: "app.khayt.timelapse-loader")
    private var session: URLSession!

    /// One ranged read in flight. Touched on `queue` only.
    private final class Read: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        let from: Int64, to: Int64, end: Int64?
        var body = Data()
        var total: Int64?
        var refused = false
        init(_ r: AVAssetResourceLoadingRequest, from: Int64, to: Int64, end: Int64?) {
            request = r; self.from = from; self.to = to; self.end = end
        }
    }
    private var reads: [Int: Read] = [:]
    private var byRequest: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(real: URL, cap: Int64 = PinnedVideoLoader.defaultCap) {
        self.real = real
        self.cap = max(1, cap)
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: Wire(self), delegateQueue: callbacks)
    }

    deinit { session.invalidateAndCancel() }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        fetch(request)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        if let task = byRequest.removeValue(forKey: ObjectIdentifier(request)) {
            reads[task.taskIdentifier] = nil
            task.cancel()
        }
    }

    // MARK: - The arithmetic, overflow-safe and testable

    /// `a + b`, stopping at `Int64.max` instead of trapping.
    static func plus(_ a: Int64, _ b: Int64) -> Int64 {
        let (v, over) = a.addingReportingOverflow(b)
        return over ? (b > 0 ? .max : .min) : v
    }

    /// The range this read wants next, inclusive: at most one chunk, never
    /// past the asked end, never past the last byte of a known total.
    static func range(offset: Int64, end: Int64?, total: Int64? = nil) -> (Int64, Int64) {
        var last = plus(offset, chunk - 1)
        if let end { last = min(last, end) }
        if let total, total > 0 { last = min(last, total - 1) }
        return (offset, max(offset, last))
    }

    /// `bytes 0-1/59481447` → (0, 1, 59481447); `*` total → nil total.
    static func contentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = h.dropFirst(6)
        let halves = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard halves.count == 2 else { return nil }
        let ends = halves[0].split(separator: "-", maxSplits: 1).map { Int64($0.trimmingCharacters(in: .whitespaces)) }
        guard ends.count == 2, let a = ends[0], let b = ends[1], a >= 0, b >= a else { return nil }
        let t = halves[1].trimmingCharacters(in: .whitespaces)
        if t == "*" { return (a, b, nil) }
        guard let total = Int64(t), total > b else { return nil }
        return (a, b, total)
    }

    /// `bytes 0-1/59481447` → 59481447.
    static func total(_ header: String?) -> Int64? { contentRange(header)?.total }

    /// Is this response the range that was asked for? The total it may be
    /// trusted with, clamped to `cap`; nil when it is refused. Asked BEFORE
    /// the body is read. `expectedLength` is -1 when the reply did not say.
    static func admit(status: Int, contentRange header: String?, expectedLength: Int64,
                      from: Int64, to: Int64, cap: Int64) -> (total: Int64?, ok: Bool) {
        guard status == 206, let r = contentRange(header), r.start == from, r.end <= to else { return (nil, false) }
        let room = plus(to - from, 1)
        if expectedLength > room { return (nil, false) }
        let total = r.total.map { min($0, cap) }
        if let total, r.end >= total { return (nil, false) }
        return (total, true)
    }

    // MARK: - The reads

    /// On `queue`.
    private func fetch(_ r: AVAssetResourceLoadingRequest, total: Int64? = nil) {
        let offset: Int64
        var end: Int64?
        if let d = r.dataRequest {
            offset = d.currentOffset > 0 ? d.currentOffset : d.requestedOffset
            if !d.requestsAllDataToEndOfResource {
                end = Self.plus(d.requestedOffset, Int64(max(1, d.requestedLength)) - 1)
            }
        } else {
            offset = 0; end = 1
        }
        let (from, to) = Self.range(offset: offset, end: end, total: total)
        var q = URLRequest(url: real)
        q.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        q.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: q)
        let read = Read(r, from: from, to: to, end: end)
        read.total = total
        reads[task.taskIdentifier] = read
        byRequest[ObjectIdentifier(r)] = task
        task.resume()
    }

    /// The headers, before any of the body. On `queue`.
    fileprivate func received(_ task: URLSessionDataTask, _ response: URLResponse) -> URLSession.ResponseDisposition {
        guard let read = reads[task.taskIdentifier] else { return .cancel }
        let http = response as? HTTPURLResponse
        let verdict = Self.admit(status: http?.statusCode ?? 0,
                                 contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                                 expectedLength: response.expectedContentLength,
                                 from: read.from, to: read.to, cap: cap)
        guard verdict.ok else { read.refused = true; return .cancel }
        if let t = verdict.total { read.total = t }
        return .allow
    }

    /// Body bytes as they arrive; a body past the asked range is cut off.
    fileprivate func got(_ task: URLSessionDataTask, _ data: Data) {
        guard let read = reads[task.taskIdentifier], !read.refused else { return }
        if Int64(read.body.count + data.count) > Self.plus(read.to - read.from, 1) {
            read.refused = true
            task.cancel()
            return
        }
        read.body.append(data)
    }

    /// The read is over, one way or another. On `queue`.
    fileprivate func done(_ task: URLSessionTask, _ error: Error?) {
        guard let read = reads.removeValue(forKey: task.taskIdentifier) else { return }
        let r = read.request
        guard byRequest.removeValue(forKey: ObjectIdentifier(r)) != nil else { return }   // cancelled
        guard !read.refused, error == nil else {
            r.finishLoading(with: error ?? URLError(.badServerResponse)); return
        }
        if let info = r.contentInformationRequest {
            info.contentType = "public.mpeg-4"
            info.isByteRangeAccessSupported = true
            if let t = read.total { info.contentLength = t }
        }
        guard let d = r.dataRequest else { r.finishLoading(); return }
        d.respond(with: read.body)
        let reached = Self.plus(read.from, Int64(read.body.count))
        let wanted = read.end.map { Self.plus($0, 1) } ?? read.total ?? reached
        let ceiling = read.total ?? .max
        if read.body.isEmpty || reached >= wanted || reached >= ceiling { r.finishLoading() }
        else { fetch(r, total: read.total) }
    }

    /// The session's delegate. Holds the loader weakly, so the session (which
    /// keeps its delegate) does not keep the loader alive.
    private final class Wire: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: PinnedVideoLoader?
        init(_ owner: PinnedVideoLoader) { self.owner = owner }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)   // a 3xx then fails `admit`
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            completionHandler(owner?.received(dataTask, response) ?? .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.got(dataTask, data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            owner?.done(task, error)
        }
    }
}
