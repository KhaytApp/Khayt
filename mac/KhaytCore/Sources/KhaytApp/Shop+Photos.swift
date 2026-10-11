import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - Photographs of finished work

    /// One photograph on one job.
    ///
    /// Flattened out of `printLog[].printPhotos[]`, which is where Khayt keeps
    /// them: a thumbnail inline in the record as a data URI, and the full-size
    /// file by name in `order-photos/` beside the store.
    struct Snapshot: Identifiable, Hashable, Sendable {
        let orderId: String
        let project: String
        let date: String
        let index: Int
        let thumb: String?
        let filename: String?
        var id: String { "\(orderId)#\(index)" }

        /// Where the full-size photo is, when it is on this Mac at all.
        var file: URL?
    }

    /// The folder Khayt writes order photos into: `order-photos/`, beside the
    /// store, which is `userData` in Electron's terms.
    var photoFolder: URL? {
        source.build.map { $0.storeURL.deletingLastPathComponent().appending(path: "order-photos") }
    }

    /// The seam the portfolio's tests use: the flattening on a book in memory,
    /// without a file, a lock or an engine.
    func readSnapshotsForTests(_ root: [String: JSONValue]) { readSnapshots(root) }

    func readSnapshots(_ root: [String: JSONValue]) {
        guard case .array(let jobs)? = root["printLog"] else { snapshots = []; return }
        let folder = photoFolder
        var out: [Snapshot] = []
        for job in jobs {
            guard case .object(let record) = job,
                  case .array(let photos)? = record["printPhotos"] else { continue }
            let id = Self.plainString(record["id"]) ?? ""
            let project = Self.plainString(record["project"]) ?? ""
            let date = Self.plainString(record["date"]) ?? ""
            for (i, photo) in photos.enumerated() {
                guard case .object(let p) = photo else { continue }
                let name = Self.plainString(p["filename"])
                out.append(Snapshot(
                    orderId: id, project: project, date: date, index: i,
                    thumb: Self.plainString(p["thumb"]),
                    filename: name,
                    // Only when it is actually there. A record whose file was
                    // never copied to this Mac still shows in the grid — the
                    // thumbnail is in the book — and simply cannot be opened.
                    file: name.flatMap { n in
                        folder.map { $0.appending(path: n) }
                            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    }))
            }
        }
        snapshots = out
    }

    func openPhoto(_ snap: Snapshot) { if let file = snap.file { FileActions.open(file) } }
    func revealPhoto(_ snap: Snapshot) { if let file = snap.file { FileActions.reveal(file) } }
    func revealPhotoFolder() { if let folder = photoFolder { FileActions.reveal(folder) } }

    /// Whether a photo can be added to this job at all.
    ///
    /// A finished job only. A photograph of the finished print is a record of
    /// what came off the bed, and one attached to a quote is a picture of
    /// something that has not been made.
    func canPhotograph(_ job: Order) -> Bool {
        canWrite && ["completed", "delivered"].contains(job.status)
    }

    /// Add a photograph of the finished print to a job.
    ///
    /// ── THE RECORD IS THE OTHER APP'S, EXACTLY ────────────────────────────
    ///
    /// Portfolio has always read `printLog[].printPhotos[]` and nothing here
    /// could write one, so the screen told a shop to add a photo to a completed
    /// order and offered no way to do it. Both apps read these back, so the
    /// sizes, the folder and the filename are `hub:save-order-photo`'s — see
    /// `OrderPhoto`.
    ///
    /// The file is written BEFORE the record, and the record only if the file
    /// was written: a row naming a file that is not there draws an empty cell
    /// with no way to fix it, whereas a file with no row is invisible and
    /// harmless.
    func addPhoto(to job: Order, from data: Data) async {
        guard let build = source.build, canPhotograph(job) else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        guard data.count <= OrderPhoto.maxBytes else {
            writeProblem = words.callIt("pe.image_too_big"); return
        }
        guard let made = OrderPhoto.encode(data) else {
            writeProblem = words.callIt("pe.upload_failed"); return
        }
        guard let folder = photoFolder else { return }
        if let problem = attachJobPhoto(made, jobId: job.id, build: build, folder: folder) {
            writeProblem = problem; return
        }
        writeProblem = nil
        await load(source)
    }

    /// The one path a job photo is written by, whoever took it — the shop by
    /// hand, or the printer's own camera at the end of a print.
    ///
    /// The file goes down BEFORE the record, and the record only if the file
    /// was written (`OrderPhoto.attach`). `updateRecord` stamps the job:
    /// without the stamp the other machine's older copy wins the next merge
    /// and the photograph disappears again. Nil when it worked, else why not.
    private func attachJobPhoto(_ made: (thumb: String, full: Data), jobId: String,
                                build: StoreReader.Build, folder: URL) -> String? {
        guard permitted("orders", "edit") else { return moveProblem }
        do {
            // The index the other app uses is the position in the job's own
            // list, so it is read from the record rather than counted from the
            // screen.
            _ = try OrderPhoto.attach(made, jobId: jobId, job: orderRow(jobId), folder: folder) { change in
                try StoreWriter.updateRecord(build, collection: "printLog", id: jobId, change: change)
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: - The printer's own photo at the end of a print

    /// Called by `PrinterWatch` on EVERY edge out of a print — finished,
    /// failed or cancelled — once per print (`lib/print-finish-photo.js`).
    ///
    /// Takes the printer's photo when the print finished, then hands the
    /// event to `printFinished`. Best-effort in every step, and silent about
    /// it: no camera, no frame, no job the book can name without guessing, or
    /// a book this Mac does not hold are all ordinary, and none of them is the
    /// shop's to fix at the moment a print ends. The photo can always be added
    /// by hand.
    func printEnded(_ machine: Machine, edge: KhaytEngine.FinishTrack) async {
        let (ended, photo) = await FinishCamera.finish(machine, edge: edge, printLog: orderRows,
                                                       shop: self) { jobId, data in
            await self.attachFinishPhoto(jobId: jobId, data: data)
        }
        FinishCamera.lastOutcome[machine.id] = photo
        await printFinished(ended)
    }

    /// ── THE FINISH SEAM ───────────────────────────────────────────────────
    ///
    /// The ONE function called when a print ends, with everything known about
    /// it: the machine, the job (only when the book names it unambiguously),
    /// how it ended ("finished" | "failed" | "cancelled"), how long it ran by
    /// the printer's own counter, and whether the printer's photo was put on
    /// the job. Called once per print, after the photo step has finished, on
    /// the main actor, off the poll loop.
    ///
    /// Deliberately empty today. Posting a print-finished event to Khayt
    /// Cloud belongs HERE, as does anything else that wants to react to the
    /// end of a print — rather than a second edge detector somewhere else
    /// that disagrees with this one about what "finished" means.
    func printFinished(_ ended: FinishCamera.Ended) async {
        lastPrintEnded[ended.machineId] = ended
        await settleEnergy(ended)
        await sendPrintFinishedEvent(ended)
    }

    /// Tell the shop's iPhones (and any open `/live` stream) that a print
    /// ended, sealed with the shop's key. Only a signed-in owner or member Mac
    /// with the key open sends it; everything else is a quiet no.
    @discardableResult
    func sendPrintFinishedEvent(_ ended: FinishCamera.Ended, now: Date = Date()) async -> ShopEventPublisher.Outcome? {
        guard let build = source.build, let dek = cloudDek,
              Self.cloudConnected(settingsDict), cloudRoleCanWrite, !eventsNotOffered else { return nil }
        let order = ended.orderId.flatMap { id in orders.first { $0.id == id } }
        let at = ShopEventPublisher.stamp(now)
        let payload = ShopEventPublisher.printFinishedPayload(
            ended, at: at, project: order?.project, client: order?.client)
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { return nil }
            let session = CloudReader.session
            let outcome = try await ShopEventPublisher.send(
                connection, token: token, dek: dek, kind: "print-finished", at: at, payload: payload) {
                try await session.data(for: $0)
            }
            if outcome == .notOffered { eventsNotOffered = true }
            FileHandle.standardError.write(Data("khayt: print-finished event — \(outcome)\n".utf8))
            return outcome
        } catch {
            FileHandle.standardError.write(Data("khayt: print-finished event — \(error)\n".utf8))
            return .failed(0)
        }
    }

    /// Send a sample print-finished alert to the shop's iPhones, from THIS
    /// app — the only one the Keychain releases the shop's sign-in to. Linked
    /// to no job, so nothing on the phone can move a real order.
    func sendTestAlert() async {
        guard cloudDek != nil else { testAlertSaid = words.callIt("mac.alert_test_locked"); return }
        let machine = machines.first
        let ended = FinishCamera.Ended(machineId: machine?.id ?? "test", machineName: machine?.name ?? "Khayt",
                                       orderId: nil, outcome: "finished", durationS: 3720,
                                       photoTaken: false, filename: "test.gcode")
        let outcome = await sendPrintFinishedEvent(ended)
        switch outcome {
        case .sent?: testAlertSaid = words.callIt("mac.alert_test_sent")
        case .rateLimited?: testAlertSaid = words.callIt("mac.alert_test_limit")
        case .notOffered?: testAlertSaid = words.callIt("mac.alert_test_not_offered")
        case .readOnly?: testAlertSaid = words.callIt("mac.ws_err_readonly")
        case nil: testAlertSaid = words.callIt("mac.qs_needs_cloud")
        default: testAlertSaid = words.callIt("mac.alert_test_failed")
        }
    }

    /// The most recent print that FAILED or was cancelled on a job the book
    /// could name — what the waste sheet offers first.
    func lastFailedJob() -> (orderId: String, machineId: String)? {
        let failed = lastPrintEnded.values.filter { $0.outcome != "finished" && $0.orderId != nil }
        guard let one = failed.first, failed.count == 1, let id = one.orderId else { return nil }
        return (id, one.machineId)
    }

    /// Put a camera frame on a job, whatever the job's status.
    ///
    /// NOT `canPhotograph`: that asks for a finished JOB, and at the edge of a
    /// print the job is usually still `printing` in the book — the frame is a
    /// picture of what came off the bed, which is the whole point of it.
    func attachFinishPhoto(jobId: String, data: Data) async -> Bool {
        guard let build = source.build, canWrite, let folder = photoFolder,
              data.count <= OrderPhoto.maxBytes, let made = OrderPhoto.encode(data) else { return false }
        guard attachJobPhoto(made, jobId: jobId, build: build, folder: folder) == nil else { return false }
        await load(source)
        return true
    }
}
