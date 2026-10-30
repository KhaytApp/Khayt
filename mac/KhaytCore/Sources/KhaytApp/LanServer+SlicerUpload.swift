import Foundation
import Network
import KhaytCore

/// ── KHAYT AS A PRINTER IN THE SLICER ─────────────────────────────────────
///
/// OrcaSlicer, PrusaSlicer and Bambu Studio can "Send" a sliced plate to an
/// OctoPrint host: `GET /api/version` to test the connection, then a
/// multipart `POST /api/files/local` with the file in the field `file` and the
/// key in `X-Api-Key` — the shape `lib/printer-upload.js` sends to a printer
/// from the other side. Answering those two routes lets a shop add Khayt as a
/// "printer", and every file it sends lands in the "From slicer" inbox
/// (`SlicerInbox`) with the slicer's own grams and time, read by the reader
/// the library already uses (`SlicerFigures`).
///
/// ── WHAT IT NEVER DOES ───────────────────────────────────────────────────
///
/// Start a print. `print=true` and `select=true` are read and ignored, and
/// the answer says so (`effectivePrint: false`). There is no printer behind
/// these routes at all: the file goes to an inbox and waits for the shop.
///
/// ── OFF, AND THEN NOT HERE ───────────────────────────────────────────────
///
/// Until the shop switches "Accept files from slicers" on, `Host.slicerKey` is
/// nil and both routes are the ordinary 404 — nothing advertises that this
/// Mac could speak OctoPrint. On, the key is checked before a byte of body is
/// read: a missing key is 401, a wrong one 403 (OctoPrint's own pair), and
/// ten wrong ones from one visitor lock it out for a minute in its OWN bucket,
/// so a slicer holding a stale key cannot lock the owner's phone out of the
/// PIN.
///
/// ── TO DISK, NOT TO MEMORY ───────────────────────────────────────────────
///
/// A sliced plate is tens or hundreds of megabytes of movement. Every other
/// route reads its body into memory under a 1 MB cap (32 MB for a customer's
/// model); this one streams to a scratch file, capped at
/// `LanServer.maxInflate`, at most `maxSlicerUploads` at once, and with an
/// IDLE deadline rather than a total one — a 300 MB file over Wi-Fi takes
/// longer than fifteen seconds, and is only a stall when the bytes stop.
extension LanServer {

    /// How many slicer uploads may be arriving at once. A shop's slicer sends
    /// one plate at a time; two is a second computer.
    nonisolated static let maxSlicerUploads = 2

    /// What `GET /api/version` answers. PrusaSlicer (and its forks) accept a
    /// host whose `text` starts with "OctoPrint".
    nonisolated static let octoVersionBody = #"{"api":"0.1","server":"1.10.0","text":"OctoPrint 1.10.0 (Khayt)"}"#

    /// A file a slicer may send here: G-code, binary G-code, and a sliced
    /// Bambu/Orca plate. A bare model is not a sliced file and has no figures
    /// to read.
    nonisolated static func slicerFileTaken(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".gcode.3mf") { return true }
        return ["gcode", "gco", "g", "bgcode"].contains((lower as NSString).pathExtension)
    }

    /// Is this the slicer upload, from the request line alone.
    nonisolated static func isSlicerUpload(method: String, target: String) -> Bool {
        guard method.uppercased() == "POST" else { return false }
        var path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path == "/api/files/local" || path == "/v1/files/local"
    }

    /// Nil when this request carries the right key; the refusal otherwise —
    /// the ordinary 404 while the feature is off.
    func slicerGate(headers: [String: String], remote: String) async -> Response? {
        guard let key = host.slicerKey(), !key.isEmpty else {
            let body = (try? await host.engine.lanNotFoundBody(endpoints: Self.endpoints)) ?? #"{"error":"Not found"}"#
            return .json(404, body)
        }
        let provided = (headers["x-api-key"] ?? "").trimmingCharacters(in: .whitespaces)
        await lockCounters()
        defer { unlockCounters() }
        let now = Date(timeIntervalSince1970: host.lockoutClock())
        let visitor = Self.throttleKey(remote)
        if (try? await host.engine.lanIsLockedOut(slicerFailures[visitor], now: now)) == true {
            return .json(429, #"{"error":"Too many attempts — try again in 1 minute"}"#)
        }
        guard !provided.isEmpty else {
            return .json(401, #"{"error":"No API key provided"}"#)
        }
        guard Self.constantTimeEqual(provided, key) else {
            if let bumped = try? await host.engine.lanBumpFailure(slicerFailures[visitor], now: now) {
                slicerFailures[visitor] = bumped
            }
            if slicerFailures.count > Self.maxFailureKeys {
                let ms = now.timeIntervalSince1970 * 1000
                slicerFailures = slicerFailures.filter { $0.value.resetAt > ms }
            }
            return .json(403, #"{"error":"Invalid API key"}"#)
        }
        slicerFailures.removeValue(forKey: visitor)
        return nil
    }

    /// `GET /api/version` — the slicer's "Test".
    func slicerVersion(_ request: Request) async -> Response {
        if let refused = await slicerGate(headers: request.headers, remote: request.remote) { return refused }
        return .json(200, Self.octoVersionBody)
    }

    // MARK: - Reading the upload

    /// The upload's head was read; judge it, then stream the body to disk.
    func readSlicerUpload(_ connection: NWConnection, on queue: DispatchQueue, requestLine: [String],
                          headers: [String: String], start: Data, length: Int, remote: String,
                          slot: LargeBodySlot) async throws -> Request {
        if let refused = await slicerGate(headers: headers, remote: remote) { throw ReadRefusal.refused(refused) }
        guard Multipart.boundary(headers["content-type"]) != nil, length > 0 else {
            throw ReadRefusal.refused(.json(400, #"{"error":"No file included"}"#))
        }
        guard length <= host.slicerMaxBytes else {
            throw ReadRefusal.refused(.json(413, #"{"error":"File too large"}"#))
        }
        guard slicerUploads < Self.maxSlicerUploads else { throw ReadRefusal.busy }
        slicerUploads += 1
        slot.slicer = true
        // curl (PrusaSlicer, Orca) asks before sending a large body and waits
        // a second for leave when nobody answers. Answered: the key is good.
        if (headers["expect"] ?? "").lowercased() == "100-continue" {
            try await Self.sendRaw(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection)
        }
        try? FileManager.default.createDirectory(at: host.slicerScratch, withIntermediateDirectories: true)
        let file = host.slicerScratch.appending(path: "khayt-slicer-\(UUID().uuidString).part")
        try await Self.spool(connection, on: queue, start: start, length: length, to: file, idle: readTimeout)
        let target = requestLine[1]
        let components = URLComponents(string: target.hasPrefix("/") ? "http://localhost\(target)" : target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: requestLine[0].uppercased(), path: components?.path ?? target, query: query,
                       headers: headers, body: Data(), remote: remote, target: target, bodyFile: file)
    }

    nonisolated static func sendRaw(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Write `length` bytes of body to `file`: what already arrived with the
    /// head, then the rest as it comes. The deadline is IDLE time — it is
    /// re-armed by every chunk — and it works the one way a deadline works
    /// here (see `serve`): by cancelling the connection. A failed or short
    /// read leaves no file behind.
    nonisolated static func spool(_ connection: NWConnection, on queue: DispatchQueue, start: Data,
                                  length: Int, to file: URL, idle: TimeInterval) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let first = start.prefix(length)
            if !first.isEmpty { try handle.write(contentsOf: first) }
            if first.count < length {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    Spool(connection: connection, queue: queue, handle: handle,
                          remaining: length - first.count, idle: idle, cont: cont).start()
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file) // scratch
            throw error
        }
    }

    /// One `spool`'s state, touched only on the connection's serial queue.
    private final class Spool: @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let handle: FileHandle
        private var remaining: Int
        private let idle: TimeInterval
        private var cont: CheckedContinuation<Void, Error>?
        private var deadline: DispatchWorkItem?

        init(connection: NWConnection, queue: DispatchQueue, handle: FileHandle, remaining: Int,
             idle: TimeInterval, cont: CheckedContinuation<Void, Error>) {
            self.connection = connection
            self.queue = queue
            self.handle = handle
            self.remaining = remaining
            self.idle = idle
            self.cont = cont
        }

        func start() { queue.async { [self] in arm(); step() } }

        private func arm() {
            deadline?.cancel()
            let connection = self.connection
            let item = DispatchWorkItem { connection.cancel() }
            deadline = item
            queue.asyncAfter(deadline: .now() + idle, execute: item)
        }

        private func step() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(1 << 20, remaining)) { [self] data, _, complete, error in
                if let error { return finish(error) }
                if let data, !data.isEmpty {
                    let take = data.prefix(remaining)
                    do { try handle.write(contentsOf: take) } catch { return finish(error) }
                    remaining -= take.count
                    arm()
                }
                if remaining <= 0 { return finish(nil) }
                if complete { return finish(URLError(.networkConnectionLost)) }
                step()
            }
        }

        private func finish(_ error: Error?) {
            deadline?.cancel()
            deadline = nil
            guard let cont else { return }
            self.cont = nil
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        }
    }

    // MARK: - The route

    /// Why an upload's body was not a file the inbox takes.
    enum SlicerUploadRefusal: Error, Equatable { case noFile, wrongKind(String), unreadable }

    /// Where an upload is taken apart: dispatch's threads, never the
    /// cooperative pool — a mapped gigabyte is blocking I/O.
    nonisolated static let slicerQueue = DispatchQueue(label: "khayt.lan.slicer", qos: .utility)

    /// The file part of a multipart body, written to its own file under
    /// `scratch`. The body is mapped, not read: a plate is not held in memory.
    nonisolated static func extractSlicerFile(body: Data, bodyFile: URL?, contentType: String?,
                                              scratch: URL) -> Result<(url: URL, name: String), SlicerUploadRefusal> {
        guard let boundary = Multipart.boundary(contentType) else { return .failure(.noFile) }
        let data: Data
        if let bodyFile {
            guard let mapped = try? Data(contentsOf: bodyFile, options: .alwaysMapped) else { return .failure(.unreadable) }
            data = mapped
        } else {
            data = body
        }
        guard let parts = Multipart.parts(data, boundary: boundary),
              let part = parts.first(where: { $0.name == "file" && $0.filename != nil }),
              !part.range.isEmpty else { return .failure(.noFile) }
        var name = QuoteFormFile.Meta(name: part.filename ?? "", bytes: 0, sha256: "").safeName
        if name.isEmpty || name == "model" { name = "upload.gcode" }
        guard slicerFileTaken(name) else { return .failure(.wrongKind(name)) }
        let dir = scratch.appending(path: "khayt-slicer-\(UUID().uuidString)", directoryHint: .isDirectory)
        let out = dir.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data[part.range].write(to: out)
        } catch {
            try? FileManager.default.removeItem(at: dir) // scratch
            return .failure(.unreadable)
        }
        return .success((out, name))
    }

    /// `POST /api/files/local` — the slicer's "Send".
    func slicerUpload(_ request: Request) async -> Response {
        if let refused = await slicerGate(headers: request.headers, remote: request.remote) { return refused }
        let body = request.body, bodyFile = request.bodyFile
        let contentType = request.headers["content-type"], scratch = host.slicerScratch
        let taken = await withCheckedContinuation { (done: CheckedContinuation<Result<(url: URL, name: String), SlicerUploadRefusal>, Never>) in
            Self.slicerQueue.async {
                done.resume(returning: Self.extractSlicerFile(body: body, bodyFile: bodyFile,
                                                             contentType: contentType, scratch: scratch))
            }
        }
        let file: URL, name: String
        switch taken {
        case .failure(.noFile):
            return .json(400, #"{"error":"No file included"}"#)
        case .failure(.wrongKind(let n)):
            return .json(415, Self.jsonText(["error": .string("Could not upload the file \"\(n)\", invalid type")]))
        case .failure(.unreadable):
            return .json(500, #"{"error":"Could not store the file"}"#)
        case .success(let got):
            (file, name) = (got.url, got.name)
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } // scratch
        do {
            try await host.slicerReceive(file, name)
        } catch let full as SlicerInbox.Full {
            return .json(409, Self.jsonText(["error": .string(full.description)]))
        } catch {
            return .json(500, #"{"error":"Could not store the file"}"#)
        }
        // OctoPrint's own answer. `print=true` is never acted on, and said so.
        let base = request.headers["host"].map { "http://\($0)" } ?? ""
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let resource = "\(base)/api/files/local/\(encoded)"
        let answer: JSONValue = .object([
            "done": .bool(true),
            "effectivePrint": .bool(false),
            "effectiveSelect": .bool(false),
            "files": .object(["local": .object([
                "name": .string(name), "display": .string(name), "path": .string(name),
                "origin": .string("local"),
                "refs": .object(["resource": .string(resource),
                                 "download": .string("\(base)/downloads/files/local/\(encoded)")]),
            ])]),
        ])
        var response = Response.json(201, Self.jsonText(answer))
        response.headers["Location"] = resource
        return response
    }

    nonisolated static func jsonText(_ value: JSONValue) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "{}"
    }
    nonisolated static func jsonText(_ object: [String: JSONValue]) -> String { jsonText(.object(object)) }
}

/// `multipart/form-data`, as a slicer sends it (RFC 7578). Parts are found by
/// their byte ranges in the body, which is usually a mapped file, so nothing
/// is copied until the one wanted part is written out.
enum Multipart {
    struct Part: Equatable, Sendable {
        var name: String
        var filename: String?
        var range: Range<Int>
    }

    /// The boundary from a `Content-Type` header, or nil when it is not
    /// multipart form data or names no usable boundary.
    static func boundary(_ contentType: String?) -> String? {
        guard let ct = contentType, ct.lowercased().hasPrefix("multipart/form-data") else { return nil }
        for param in ct.split(separator: ";").dropFirst() {
            let kv = param.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].lowercased() == "boundary" else { continue }
            var value = kv[1]
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return (1...200).contains(value.utf8.count) ? value : nil
        }
        return nil
    }

    /// Every part, in order, up to `maxParts`; nil when the body is not
    /// well-formed multipart for this boundary.
    static func parts(_ data: Data, boundary: String, maxParts: Int = 32) -> [Part]? {
        let dash = Array("--\(boundary)".utf8)
        let next = Array("\r\n--\(boundary)".utf8)
        let blank = Array("\r\n\r\n".utf8)
        let end = data.endIndex
        guard var cursor = find(dash, in: data, from: data.startIndex, to: end).map({ $0 + dash.count }) else { return nil }
        var out: [Part] = []
        while out.count < maxParts {
            guard cursor + 2 <= end else { return nil }
            if data[cursor] == UInt8(ascii: "-"), data[cursor + 1] == UInt8(ascii: "-") { return out }
            // Transport padding, then the line break that ends the delimiter.
            while cursor < end, data[cursor] == UInt8(ascii: " ") || data[cursor] == UInt8(ascii: "\t") { cursor += 1 }
            guard cursor + 2 <= end, data[cursor] == 13, data[cursor + 1] == 10 else { return nil }
            let headStart = cursor + 2
            // A part's own headers are a few lines; a megabyte of them is not.
            guard let headEnd = find(blank, in: data, from: headStart, to: min(end, headStart + 16_384)) else { return nil }
            let head = String(decoding: data[headStart..<headEnd], as: UTF8.self)
            let bodyStart = headEnd + blank.count
            guard let close = find(next, in: data, from: bodyStart, to: end) else { return nil }
            let (name, filename) = disposition(head)
            out.append(Part(name: name, filename: filename, range: bodyStart..<close))
            cursor = close + next.count
        }
        return out
    }

    /// `name` and `filename` from a part's `Content-Disposition`.
    static func disposition(_ head: String) -> (name: String, filename: String?) {
        var name = "", filename: String?, starred: String?
        for line in head.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-disposition" else { continue }
            for param in params(String(line[line.index(after: colon)...])) {
                switch param.key {
                case "name": name = param.value
                case "filename": filename = param.value
                case "filename*":
                    // RFC 5987: charset'lang'percent-encoded.
                    let pieces = param.value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if pieces.count == 3 { starred = String(pieces[2]).removingPercentEncoding }
                default: break
                }
            }
        }
        return (name, starred ?? filename)
    }

    /// `; key=value` pairs, values quoted or not, `;` inside quotes kept.
    private static func params(_ text: String) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        var pieces: [String] = [], current = "", quoted = false, escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quoted { escaped = true; current.append(ch); continue }
            if ch == "\"" { quoted.toggle() }
            if ch == ";" && !quoted { pieces.append(current); current = ""; continue }
            current.append(ch)
        }
        pieces.append(current)
        for piece in pieces {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            out.append((key, value))
        }
        return out
    }

    /// The first index of `needle` in `data[from..<to]` — `memmem`, because a
    /// plate is hundreds of megabytes and a byte-at-a-time search over it is
    /// seconds on the shop's machine.
    static func find(_ needle: [UInt8], in data: Data, from: Int, to: Int) -> Int? {
        guard !needle.isEmpty, from >= data.startIndex, to <= data.endIndex, to - from >= needle.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            let offset = from - data.startIndex
            return needle.withUnsafeBytes { n -> Int? in
                guard let hit = memmem(base + offset, to - from, n.baseAddress, needle.count) else { return nil }
                return data.startIndex + (base.distance(to: UnsafeRawPointer(hit)))
            }
        }
    }
}
