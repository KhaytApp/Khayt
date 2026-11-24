import Foundation
import KhaytCore

/// "Keep as proof": a finished print's time-lapse copied from the printer
/// into the job's own files, so it outlives the printer clearing its camera
/// folder (the Windows/Linux app's `lib/main/timelapse-keep.js`; iPhone frame
/// 7b, where the phone asks and the Mac copies).
///
/// ONLY WHEN ASKED. These run to a hundred megabytes; nothing here runs
/// after a print by itself.
///
/// WHAT GUARDS IT
///   who      at the Mac, whoever may edit jobs (orders/edit under the staff
///            lock), as the other app asks. From a phone, the LAN route takes
///            a signed device whose role allows `orders:write`.
///   whether  the shared rule (`lib/timelapse-attach.js`): a video the
///            printer says is over 150 MB, or of no stated size, is not
///            copied at all; it stays a link to the printer.
///   how much `CappedDownload`: the limit is on what is READ. A printer that
///            under-states its size is cut off and nothing is left behind.
///   from     the printer's own address only, pinned to the shop's network by
///            the rule every printer read goes through (`PrinterWatch.baseURL`),
///            no redirects; the file is named by the job's own record and
///            must be a plain name in the camera folder.
///   to       `order-files/`, beside the book, where the other app keeps a
///            job's files; a name the rule made (`<job>-timelapse-<stamp>.mp4`)
///            and nothing else, written as `.part` and renamed when whole.
///
/// The printer is sent one GET for the file. Nothing else.
extension Shop {

    /// The folder a job's attached files live in: `order-files/`, beside the
    /// store (`orderFilesDir()` in the other app).
    var filesFolder: URL? {
        timelapseFolderForTests ?? source.build.map { $0.storeURL.deletingLastPathComponent().appending(path: "order-files") }
    }

    enum TimelapseKept: Equatable {
        /// Copied, and on the job.
        case kept(filename: String, bytes: Int)
        /// Not copied: it stays on the printer. `over-budget` or `size-unknown`.
        case link(reason: String, bytes: Double?, maxBytes: Double)
        /// Already one of the job's files.
        case already
        /// The job has no time-lapse a copy could be made of (or there is no such job).
        case none
        /// Its printer is no longer one of the shop's Moonraker printers.
        case noMachine
        /// A copy for this job is running.
        case busy
        /// The person stopped it. Nothing was kept.
        case cancelled
        /// The printer did not hand the file over.
        case unreachable
        /// The sample book, or a book another computer holds.
        case readOnly
        /// The staff lock: this person may not edit jobs.
        case notPermitted
        case notSaved(String)
    }

    /// A name the shared rule makes for a kept video, and nothing else: no
    /// path, no dots but the last.
    nonisolated static func safeKeptName(_ name: String) -> Bool {
        name.count <= 240 && name.wholeMatch(of: /[A-Za-z0-9_-]{1,200}-timelapse-[A-Za-z0-9]{1,24}\.mp4/) != nil
    }

    /// The file's address in the printer's camera folder, or nil for a name
    /// that is not one plain file there. The rule has already refused these
    /// (`safeCameraFile`); asked again here, where the address is made.
    nonisolated static func cameraFile(_ base: URL, _ video: String) -> URL? {
        guard !video.isEmpty, video.count <= 255, !video.hasPrefix("."), video.lowercased().hasSuffix(".mp4"),
              !video.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        var plain = CharacterSet.alphanumerics
        plain.insert(charactersIn: "-_.~")
        guard let name = video.addingPercentEncoding(withAllowedCharacters: plain),
              let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/server/files/camera/" + name),
              url.host() == base.host(), url.port == base.port, url.scheme == base.scheme else { return nil }
        return url
    }

    /// Is this row the kept copy of that video from that printer?
    nonisolated static func isKept(_ file: JSONValue, video: String, machineId: String) -> Bool {
        guard case .object(let f) = file, f["kind"] == .string("timelapse"), case .object(let from)? = f["from"],
              from["video"] == .string(video) else { return false }
        if case .string(let m)? = from["machineId"] { return m == machineId }
        return machineId.isEmpty
    }

    /// The row onto the job. False, and nothing changed, when it is there already.
    nonisolated static func appendKept(_ row: [String: JSONValue], to job: inout [String: JSONValue], video: String, machineId: String) -> Bool {
        var files: [JSONValue] = []
        if case .array(let have)? = job["attachedFiles"] { files = have }
        guard !files.contains(where: { isKept($0, video: video, machineId: machineId) }) else { return false }
        files.append(.object(row))
        job["attachedFiles"] = .array(files)
        return true
    }

    private func timelapseMachine(_ id: String) -> Machine? {
        for row in machineRows where Self.recordId(row) == id {
            if let data = try? JSONEncoder().encode(row), let machine = try? JSONDecoder().decode(Machine.self, from: data) { return machine }
        }
        return nil
    }

    /// Copy the job's time-lapse from its printer and put it on the job.
    ///
    /// `maxBytes`: nil for the rule's own ceiling (150 MB). Never raised by a
    /// caller in the app; a test lowers it.
    func keepTimelapse(_ jobId: String, gate: LockGate = .person("orders", "edit"), maxBytes: Double? = nil,
                       now: Date = Date()) async -> TimelapseKept {
        guard permitted(gate) else { return .notPermitted }
        guard let engine else { return .unreachable }
        let testing = timelapseWriteForTests != nil
        guard testing || (source.build != nil && canWrite), let folder = filesFolder else { return .readOnly }
        guard !timelapseCopying.contains(jobId) else { return .busy }
        guard let job = orderRow(jobId) else { return .none }
        let stamp = String(Int64((now.timeIntervalSince1970 * 1000).rounded()), radix: 36)
        guard let plan = try? await engine.timelapseKeepPlan(order: job, stamp: stamp, maxBytes: maxBytes) else { return .none }
        switch plan.action {
        case "already": return .already
        case "link": return .link(reason: plan.reason ?? "size-unknown", bytes: plan.bytes, maxBytes: plan.maxBytes ?? 0)
        case "attach": break
        default: return .none
        }
        guard let name = plan.filename, Self.safeKeptName(name), let most = plan.maxBytes, most >= 1, most <= 4_000_000_000,
              let video = plan.video, let machineId = plan.machineId, case .object(var row)? = plan.row else { return .none }
        guard let machine = timelapseMachine(machineId), !machine.isRetired, machine.printerApi?.type == "moonraker" else { return .noMachine }
        let dest = folder.appending(path: name)
        guard dest.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return .none }

        timelapseCopying.insert(jobId)
        defer { timelapseCopying.remove(jobId) }
        let base: URL
        if let stand = timelapseBaseForTests { base = stand } else {
            guard let real = try? await PrinterWatch.baseURL(machine, engine: engine) else { return .unreachable }
            base = real
        }
        guard let url = Self.cameraFile(base, video) else { return .none }
        // Asked HERE, where the request is built (the ratchet's rule), as well
        // as where the address was made and where the bytes are read.
        guard (try? OutboundGate.shared.require(.lan, url: url)) != nil else { return .unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = CappedDownload.idle
        if let sealed = machine.printerApi?.apiKey, !sealed.isEmpty {
            var key = sealed
            if let build = source.build { key = (try? await Secrets.open(sealed, for: build)) ?? "" }
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        }
        let part = folder.appending(path: name + ".part")
        let files = FileManager.default
        func discard() { try? files.removeItem(at: part) }
        let got: Int
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let total = plan.bytes
            timelapseProgress[jobId] = TimelapseProgress(got: 0, total: total)
            got = try await CappedDownload.run(request, to: part, cap: Int(most)) { [weak self] bytes in
                Task { @MainActor in
                    guard let self, self.timelapseCopying.contains(jobId) else { return }
                    self.timelapseProgress[jobId] = TimelapseProgress(got: bytes, total: total)
                }
            }
        } catch CappedDownload.Failure.overBudget(let seen) {
            discard()
            timelapseProgress[jobId] = nil
            return .link(reason: "over-budget", bytes: Double(seen), maxBytes: most)
        } catch {
            discard()
            timelapseProgress[jobId] = nil
            return Task.isCancelled ? .cancelled : .unreachable
        }
        timelapseProgress[jobId] = nil
        guard got > 0 else { discard(); return .unreachable }
        do {
            try? files.removeItem(at: dest)
            try files.moveItem(at: part, to: dest)
        } catch { discard(); return .notSaved(said(error)) }

        // The size on the job is what was written, not what the printer said.
        row["size"] = .number(Double(got))
        let kept = row
        let wrote: Bool?
        do {
            if let stand = timelapseWriteForTests { wrote = try await stand(jobId, kept) } else if let build = source.build {
                wrote = try await StoreWriter.updateRecordOffMain(build, collection: "printLog", id: jobId) { record -> Bool in
                    Self.appendKept(kept, to: &record, video: video, machineId: machineId)
                }
            } else { wrote = nil }
        } catch {
            try? files.removeItem(at: dest)
            return .notSaved(said(error))
        }
        guard let wrote else { try? files.removeItem(at: dest); return .none }      // the job left the book meanwhile
        guard wrote else { try? files.removeItem(at: dest); return .already }       // the other app kept it meanwhile
        if !testing { await load(source) }
        return .kept(filename: name, bytes: got)
    }

    // MARK: - From a paired phone

    /// `GET /api/orders/{id}/timelapse`:
    /// `{"ok":true,"state":"none"|"available"|"kept"|"link", "bytes"?, "maxBytes"?, "reason"?, "url"?, "copying"?}`.
    func phoneTimelapse(_ jobId: String) async -> (Int, String) {
        // lock: system — a paired phone asking whether a job has a time-lapse; the LAN route takes a signed enrolled device whose role allows orders:read, and nothing is written.
        guard let engine else { return Self.lapseAnswer(503, ["ok": .bool(false), "reason": .string("busy")]) }
        guard let job = orderRow(jobId) else { return Self.lapseAnswer(404, ["ok": .bool(false), "reason": .string("not-found")]) }
        var out: [String: JSONValue] = ["ok": .bool(true), "state": .string("none")]
        guard let plan = try? await engine.timelapseKeepPlan(order: job, stamp: "0") else { return Self.lapseAnswer(200, out) }
        if plan.action == "already" {
            out["state"] = .string("kept")
            if let bytes = plan.bytes { out["bytes"] = .number(bytes) }
            return Self.lapseAnswer(200, out)
        }
        guard plan.action == "attach" || plan.action == "link", let machineId = plan.machineId,
              let machine = machineRows.first(where: { Self.recordId($0) == machineId }),
              let link = (try? await engine.timelapseLink(order: job, machine: machine)) ?? nil else { return Self.lapseAnswer(200, out) }
        out["state"] = .string(plan.action == "attach" ? "available" : "link")
        if let bytes = plan.bytes { out["bytes"] = .number(bytes) }
        if let most = plan.maxBytes { out["maxBytes"] = .number(most) }
        if plan.action == "link", let reason = plan.reason { out["reason"] = .string(reason) }
        // Where the printer serves it, for "Open on the printer": the
        // printer's own address on the shop's network, by the camera rule.
        out["url"] = .string(link.videoUrl)
        if timelapseCopying.contains(jobId) { out["copying"] = .bool(true) }
        return Self.lapseAnswer(200, out)
    }

    /// `POST /api/orders/{id}/timelapse/keep`: the Mac copies it now, and
    /// answers when it has (a hundred megabytes over the shop's network can
    /// take a minute).
    func phoneKeepTimelapse(_ jobId: String) async -> (Int, String) {
        // lock: system — a paired phone's "Keep as proof"; the LAN route takes a signed enrolled device whose role allows orders:write (the phone's orders/edit), and the copy is keepTimelapse's, with its limits.
        func refuse(_ status: Int, _ reason: String, _ more: [String: JSONValue] = [:]) -> (Int, String) {
            Self.lapseAnswer(status, ["ok": .bool(false), "reason": .string(reason)].merging(more) { a, _ in a })
        }
        guard engine != nil else { return refuse(503, "busy") }
        guard orderRow(jobId) != nil else { return refuse(404, "not-found") }
        switch await keepTimelapse(jobId, gate: .system("a paired phone's Keep as proof, over the signed LAN route")) {
        case .kept(let filename, let bytes):
            return Self.lapseAnswer(201, ["ok": .bool(true), "state": .string("kept"), "bytes": .number(Double(bytes)), "filename": .string(filename)])
        case .already:
            return Self.lapseAnswer(200, ["ok": .bool(true), "state": .string("kept")])
        case .link(let reason, let bytes, let most):
            var out: [String: JSONValue] = ["ok": .bool(true), "state": .string("link"), "reason": .string(reason), "maxBytes": .number(most)]
            if let bytes { out["bytes"] = .number(bytes) }
            return Self.lapseAnswer(200, out)
        case .none: return refuse(409, "no-timelapse")
        case .noMachine: return refuse(409, "no-machine")
        case .busy: return refuse(409, "copying")
        case .cancelled: return refuse(409, "cancelled")
        case .unreachable: return refuse(502, "printer-unreachable")
        case .readOnly: return refuse(409, "read-only")
        case .notPermitted: return refuse(403, "not-permitted")
        case .notSaved(let why): return refuse(500, "not-saved", ["message": .string(why)])
        }
    }

    nonisolated private static func lapseAnswer(_ status: Int, _ object: [String: JSONValue]) -> (Int, String) {
        (status, (try? String(decoding: JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)) ?? #"{"ok":false,"reason":"encode"}"#)
    }
}

extension LanServer {
    /// `/api/orders/{id}/timelapse` → the job, for the path that READS; nil
    /// for any other. (Two functions, each nil for the other's path: asked as
    /// one function's optional member, "not this path at all" and "this path,
    /// no member" read the same.)
    nonisolated static func timelapseReadPath(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "orders", parts[4] == "timelapse",
              let id = String(parts[3]).removingPercentEncoding, !id.isEmpty else { return nil }
        return id
    }

    /// `/api/orders/{id}/timelapse/keep` → the job; nil for any other.
    nonisolated static func timelapseKeepPath(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0].isEmpty, parts[1] == "api", parts[2] == "orders", parts[4] == "timelapse", parts[5] == "keep",
              let id = String(parts[3]).removingPercentEncoding, !id.isEmpty else { return nil }
        return id
    }
}
