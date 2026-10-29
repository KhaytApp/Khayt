import CryptoKit
import Foundation
import KhaytCore

/// The model a visitor uploaded through the shop's embedded quote form
/// (khayt-cloud #144), and how it gets from the cloud into the shop's library.
///
/// ── THE ORDER OF THE STEPS IS THE WHOLE DESIGN ────────────────────────────
///
/// `DELETE /intake/{id}` deletes the file on the cloud as well as the request.
/// So, for a request that carries a file:
///
///   1. download it (`CloudIntake.file`);
///   2. check it: its SHA-256 against BOTH the payload's `file.sha256` and the
///      `X-Content-SHA256` header, and its length against `file.bytes`;
///   3. put it in the library the way any imported model is put there
///      (`LibraryImport.prepare`: its own `PF-…` folder, copied, read back);
///   4. write the book — the job, and the library record it points at, in ONE
///      write;
///   5. and ONLY THEN drain the queue.
///
/// Anything that fails before 5 leaves the request in the queue, with its
/// file, for the next try. A file the cloud has already let expire (404
/// `no-file`) is the one exception: there is nothing left to lose, so the
/// request is imported without it, labelled as such, and then drained.
/// A 404 `no-route` is the feature switched off on the cloud: nothing is
/// written and nothing is drained.
enum QuoteFormFile {

    /// `payload.file`, as the cloud files it.
    struct Meta: Equatable, Sendable {
        let name: String
        let bytes: Int
        let sha256: String
        let type: String
        let expiresAt: Date?

        /// Nil when the payload carries no file object with a name.
        init?(_ payload: JSONValue) {
            guard case .object(let fields) = payload,
                  case .object(let f)? = fields["file"],
                  case .string(let name)? = f["name"], !name.isEmpty else { return nil }
            self.name = name
            if case .number(let n)? = f["bytes"], n.isFinite, n >= 0, n < 1e15 { bytes = Int(n) } else { bytes = -1 }
            if case .string(let s)? = f["sha256"] { sha256 = s.lowercased() } else { sha256 = "" }
            if case .string(let s)? = f["type"] { type = s } else { type = "" }
            if case .string(let s)? = f["expiresAt"] { expiresAt = QuoteFormFile.instant(s) } else { expiresAt = nil }
        }

        init(name: String, bytes: Int, sha256: String, type: String = "", expiresAt: Date? = nil) {
            self.name = name; self.bytes = bytes; self.sha256 = sha256.lowercased()
            self.type = type; self.expiresAt = expiresAt
        }

        /// The visitor's file name, made safe to put on disk: the last path
        /// component only, no separators or control characters, bounded.
        /// The name is from a stranger and is never trusted as a path.
        var safeName: String {
            var leaf = name.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").last.map(String.init) ?? ""
            leaf = String(leaf.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && $0 != ":"
            }.map(Character.init))
            leaf = leaf.trimmingCharacters(in: .whitespaces)
            while leaf.hasPrefix(".") { leaf.removeFirst() }
            if leaf.count > 120 {
                let ext = (leaf as NSString).pathExtension
                let stem = String((leaf as NSString).deletingPathExtension.prefix(100))
                leaf = ext.isEmpty ? stem : stem + "." + ext
            }
            return leaf.isEmpty ? "model" : leaf
        }
    }

    /// Why a request with a file was left in the queue.
    enum Refusal: Error, Equatable, Sendable {
        /// 404 `no-route`: the cloud has the quote form switched off.
        case notOffered
        /// The download did not happen.
        case download(String)
        /// The payload did not say what the bytes should hash to.
        case noChecksum
        /// The bytes did not hash to what the payload and the header said.
        case checksum
        /// Not as many bytes as the payload said.
        case size(expected: Int, got: Int)
        /// This Mac has no library folder to put the file in.
        case noLibrary
        /// The library would not take the file (an unknown kind, a copy that
        /// did not arrive intact…).
        case library(LibraryImport.Failure)
        /// The book would not take the write.
        case write(String)
    }

    /// The bytes, checked. Nil when they are what the cloud said they are.
    ///
    /// The payload's hash is required: it is what the visitor's upload hashed
    /// to when the cloud filed it, and without it nothing can be checked. The
    /// header is checked whenever it is there, but its absence alone is not a
    /// refusal — a proxy that strips an unknown response header would
    /// otherwise strand every quote-form request in the queue for good.
    static func verify(_ data: Data, meta: Meta, header: String?) -> Refusal? {
        let expected = meta.sha256.trimmingCharacters(in: .whitespaces).lowercased()
        guard expected.count == 64 else { return .noChecksum }
        if meta.bytes >= 0, data.count != meta.bytes { return .size(expected: meta.bytes, got: data.count) }
        let sent = (header ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected, sent.isEmpty || sent == expected else { return .checksum }
        return nil
    }

    /// What the book is told about the file, inside the job write.
    struct Attach: Sendable {
        enum State: Sendable {
            /// In the library as `printFileId`. `newRecord` is the library
            /// record to add in the same write; nil when the library already
            /// held these exact bytes and the job just points at that model.
            case filed(printFileId: String, newRecord: [String: JSONValue]?)
            /// The cloud had already deleted it. `note` goes on the job, in
            /// the shop's words, so nobody goes looking for a model.
            case expired(note: String)
        }
        let meta: Meta
        let state: State
    }

    /// Put the file's facts on a job record — and, for a filed one, point
    /// the job's parts at it. Called inside the write (`putOnlineOrder`).
    static func stamp(_ attach: Attach, on record: inout [String: JSONValue]) {
        var facts: [String: JSONValue] = [
            "name": .string(attach.meta.name),
            "bytes": .number(Double(max(0, attach.meta.bytes))),
            "sha256": .string(attach.meta.sha256),
        ]
        if !attach.meta.type.isEmpty { facts["type"] = .string(attach.meta.type) }
        switch attach.state {
        case .filed(let id, _):
            facts["printFileId"] = .string(id)
            facts["expired"] = .bool(false)
            // A quote-form request is one line (the visitor's request), so it
            // is one part; every part not already pointing at a model points
            // at this one.
            if case .array(var parts)? = record["parts"] {
                for i in parts.indices {
                    guard case .object(var p) = parts[i] else { continue }
                    if case .string(let had)? = p["printFileId"], !had.isEmpty { continue }
                    p["printFileId"] = .string(id)
                    parts[i] = .object(p)
                }
                record["parts"] = .array(parts)
            }
        case .expired(let note):
            facts["expired"] = .bool(true)
            let notes = Shop.plainString(record["notes"]) ?? ""
            record["notes"] = .string(notes.isEmpty ? note : notes + "\n" + note)
        }
        record["quoteFile"] = .object(facts)
    }

    nonisolated static func instant(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - The import, step by step

@MainActor
extension Shop {

    /// What importing one quote-form request did.
    struct QuoteFormResult: Sendable {
        /// What the book write did; nil when nothing was written.
        var recorded: Recorded?
        /// Why the request stayed in the queue (nothing written, nothing
        /// drained). Nil when the import went ahead.
        var refusal: QuoteFormFile.Refusal?
        /// The file was gone (404 `no-file`): imported without it.
        var expired = false
        /// The library model the job points at, when the file was filed.
        var printFileId: String?
        var drained = false
        /// The drain's failure, after a successful write.
        var drainProblem: String?
        var webhooks: [KhaytEngine.WebhookDelivery] = []
    }

    /// Download → verify → into the library → write the book → drain.
    ///
    /// Static and handed everything, so a test can run the whole sequence
    /// against a scratch book and library with the cloud answered by a seam.
    /// See `QuoteFormFile` for why the steps are in this order.
    static func recordQuoteForm(_ order: OnlineOrder, meta: QuoteFormFile.Meta,
                                input: [String: JSONValue], paid: Bool,
                                engine: KhaytEngine, now: Date = Date(),
                                storeURL: URL, libraryRoot: URL?,
                                existingModel: (String) -> String?,
                                analyseRisk: Bool = false,
                                expiredNote: String,
                                owns: @escaping @Sendable () -> Bool,
                                whoHasIt: @escaping @Sendable () -> String?,
                                download: () async throws -> CloudIntake.FileAnswer,
                                drain: () async throws -> Void) async -> QuoteFormResult {
        // lock: callers — recordQuoteFormOrder
        var result = QuoteFormResult()

        // 1. DOWNLOAD.
        let answer: CloudIntake.FileAnswer
        do {
            answer = try await download()
        } catch CloudIntake.Failure.notOffered {
            result.refusal = .notOffered
            return result
        } catch {
            result.refusal = .download((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return result
        }

        // 2. VERIFY, and 3. INTO THE LIBRARY.
        let attach: QuoteFormFile.Attach
        var preparedDir: URL?
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "khayt-quote-form-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) } // scratch
        switch answer {
        case .expired:
            result.expired = true
            attach = .init(meta: meta, state: .expired(note: expiredNote))
        case .file(let data, let header):
            if let refusal = QuoteFormFile.verify(data, meta: meta, header: header) {
                result.refusal = refusal
                return result
            }
            // The same bytes already in the library: the job points at that
            // model rather than adding a second copy — what any import does.
            if let existing = existingModel(meta.sha256) {
                attach = .init(meta: meta, state: .filed(printFileId: existing, newRecord: nil))
                result.printFileId = existing
                break
            }
            guard let libraryRoot else {
                result.refusal = .noLibrary
                return result
            }
            let file = scratch.appending(path: meta.safeName)
            let wrote: String? = await PinWork.run {
                do {
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                    return nil
                } catch { return error.localizedDescription }
            }
            if let wrote {
                result.refusal = .library(.failed(wrote))
                return result
            }
            do {
                let made = try await LibraryImport.prepare(
                    file, libraryRoot: libraryRoot, knownHashes: [], nameOfExisting: { _ in nil },
                    engine: engine, analyseRisk: analyseRisk)
                preparedDir = made.dir
                let id = made.added.id
                attach = .init(meta: meta, state: .filed(printFileId: id, newRecord: made.record))
                result.printFileId = id
            } catch let failure as LibraryImport.Failure {
                result.refusal = .library(failure)
                return result
            } catch {
                result.refusal = .library(.failed(String(describing: error)))
                return result
            }
        }

        // 4. THE BOOK.
        var put: PutOnline?
        do {
            try await StoreWriter.update(storeURL: storeURL, owns: owns, whoHasIt: whoHasIt) { root in
                put = try await Self.putOnlineOrder(order, input: input, paid: paid, into: &root,
                                                    engine: engine, now: now, file: attach)
            }
        } catch {
            if let preparedDir { await PinWork.run { try? FileManager.default.removeItem(at: preparedDir) } }
            result.refusal = .write((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return result
        }
        guard let put else {
            if let preparedDir { await PinWork.run { try? FileManager.default.removeItem(at: preparedDir) } }
            result.refusal = .write("the book did not take the change")
            return result
        }
        // Already in the book (an earlier import whose drain failed): the
        // copy made just now belongs to nothing, so it goes.
        if !put.fileFiled, let preparedDir {
            await PinWork.run { try? FileManager.default.removeItem(at: preparedDir) }
            if case .filed(_, .some) = attach.state { result.printFileId = nil }
        }
        result.recorded = put.recorded
        result.webhooks = put.webhooks

        // 5. ONLY NOW, THE DRAIN.
        do {
            try await drain()
            result.drained = true
        } catch {
            result.drainProblem = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        return result
    }

    /// The button, for a request that carries a file. `recordOnlineOrder`
    /// hands over to this; the caller holds the busy flag.
    func recordQuoteFormOrder(_ order: OnlineOrder, meta: QuoteFormFile.Meta,
                              fetch: CloudIntake.Fetch?) async {
        guard permitted("orders", "create") else { return }
        guard case .store(let build) = source, let engine else { return }
        let connection: CloudReader.Connection
        let token: String
        do {
            connection = try CloudReader.connection(settingsDict)
            token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudIntake.Failure.notConnected }
        } catch {
            onlineProblem = words.callIt("mac.qfe_kept") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return
        }
        let network = fetch ?? Self.quoteFormNetwork
        let input = await onlineJobInput(order)
        let files = self.files
        let result = await Self.recordQuoteForm(
            order, meta: meta, input: input, paid: order.decision?.paid ?? false,
            engine: engine, storeURL: build.storeURL,
            libraryRoot: libraryRoots.map { URL(fileURLWithPath: $0.primary) },
            existingModel: { hash in files.first { $0.contentHash == hash }?.id },
            analyseRisk: analysesRiskAtImport,
            expiredNote: words.callIt("mac.qfe_file_expired_note", ["name": .string(meta.name)]),
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            download: { try await CloudIntake.file(connection, token: token, id: order.id, maxBytes: meta.bytes, fetch: network) },
            drain: { try await CloudIntake.drain(connection, token: token, id: order.id, fetch: network) })

        if let refusal = result.refusal {
            onlineProblem = words.callIt("mac.qfe_kept") + " " + saidRefusal(refusal)
            return
        }
        if !result.webhooks.isEmpty { await fire(result.webhooks) }
        switch result.recorded {
        case .made(let jobId, _, _, _)?:
            webStoreArrived.append(WebStoreArrival(
                intakeId: order.id, reference: order.item.reference, jobId: jobId,
                customer: order.customer, automatic: false))
            if result.expired { onlineProblem = words.callIt("mac.qfe_imported_expired") }
        case .alreadyThere?:
            onlineProblem = words.callIt("mac.online_already_recorded")
        case nil:
            break
        }
        if result.drained {
            onlineOrders.removeAll { $0.id == order.id }
        } else if let problem = result.drainProblem {
            onlineProblem = words.callIt("mac.online_kept_in_queue") + " " + problem
        }
        await load(source)
    }

    /// A refusal in the shop's words.
    func saidRefusal(_ refusal: QuoteFormFile.Refusal) -> String {
        switch refusal {
        case .notOffered: words.callIt("mac.qfe_err_not_offered")
        case .download(let why): words.callIt("mac.qfe_err_download", ["why": .string(why)])
        case .noChecksum, .checksum: words.callIt("mac.qfe_err_checksum")
        case .size(let expected, let got):
            words.callIt("mac.qfe_err_size", ["expected": .string(Format.fileSize(Int64(expected))),
                                              "got": .string(Format.fileSize(Int64(got)))])
        case .noLibrary: LibraryImport.Failure.noLibrary.said(words)
        case .library(let failure): failure.said(words)
        case .write(let why): words.callIt("mac.qfe_err_write", ["why": .string(why)])
        }
    }

    private static let quoteFormNetwork: CloudIntake.Fetch = { request in
        try await CloudReader.session.data(for: request)
    }
}
