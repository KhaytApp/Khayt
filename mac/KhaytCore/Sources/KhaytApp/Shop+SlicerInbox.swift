import Foundation
import KhaytCore

/// The shop's end of "Khayt as a printer in the slicer": filing what the LAN
/// server received (`LanServer+SlicerUpload`), and the inbox's three answers —
/// into the library, a job, a quote — each through the path the app already
/// has for it.
@MainActor
extension Shop {

    /// The inbox beside this book, or nil for the sample (no folder of its own).
    var slicerInboxRoot: URL? { source.build.map { SlicerInbox.root(storeURL: $0.storeURL) } }

    /// Read the inbox again from disk.
    func refreshSlicerInbox() {
        guard let root = slicerInboxRoot else { slicerUploads = []; return }
        slicerUploads = SlicerInbox.list(root: root)
    }

    /// File one upload: its figures read by the library's own reader
    /// (`SlicerFigures`), then moved into the inbox off the main actor. Static
    /// and handed everything, so a test runs exactly this against a scratch
    /// folder.
    nonisolated static func fileSlicerUpload(_ file: URL, name: String, root: URL,
                                             engine: KhaytEngine?, now: Date = Date(),
                                             origin: SlicerOrigin? = nil) async throws -> SlicerUpload {
        var figures: [String: JSONValue]?
        if let engine { figures = await SlicerFigures.read(file, engine: engine) }
        let read = figures
        let filed: Result<SlicerUpload, Error> = await PinWork.run {
            Result { try SlicerInbox.file(file, name: name, figures: read, root: root, now: now, origin: origin) }
        }
        return try filed.get()
    }

    /// The server's `slicerReceive`. The same bytes already waiting are that
    /// item, not a second one (`SlicerInbox.Duplicate`): the slicer is told
    /// its file arrived, which it has.
    func receiveSlicerUpload(_ file: URL, name: String) async throws {
        guard let root = slicerInboxRoot else { throw CocoaError(.fileWriteNoPermission) }
        do {
            let item = try await Self.fileSlicerUpload(file, name: name, root: root, engine: engine)
            slicerUploads.removeAll { $0.id == item.id }
            slicerUploads.insert(item, at: 0)
        } catch is SlicerInbox.Duplicate {
            refreshSlicerInbox()
            slicerDuplicate = name
        }
    }

    /// The server's `connectorReceive`: a paired plugin's file, its hash
    /// already checked. Nothing in the book is written — not a job, a quote,
    /// a client or an activity row: the inbox is beside the book, and the
    /// shop decides there. Throws `SlicerInbox.Duplicate` / `Full` for the
    /// server to answer.
    func receiveConnectorUpload(_ file: URL, name: String, origin: SlicerOrigin) async throws -> SlicerUpload {
        guard let root = slicerInboxRoot else { throw CocoaError(.fileWriteNoPermission) }
        do {
            let item = try await Self.fileSlicerUpload(file, name: name, root: root, engine: engine, origin: origin)
            slicerUploads.removeAll { $0.id == item.id }
            slicerUploads.insert(item, at: 0)
            await logSlicerArrival(item, origin: origin)
            return item
        } catch let same as SlicerInbox.Duplicate {
            slicerDuplicate = name
            throw same
        }
    }

    /// One line in the team's activity log: "<file> · sent to the inbox by
    /// <plugin>". The only thing a plugin's file writes to the book, and only
    /// the log: no job, quote, client or spool. A book this Mac does not hold
    /// right now (another Mac has it) gets no line; the file is in the inbox
    /// either way.
    func logSlicerArrival(_ item: SlicerUpload, origin: SlicerOrigin) async {
        guard let build = source.build else { return }
        let actorName = ConnectedApps.name(origin.connectorName, words)
        try? await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
        ) { root in
            let snapshot = root
            Self.appendActivity(&root, text: Self.slicerArrivalText(item.name, plugin: actorName),
                                ref: item.id, settings: Self.settings(root), root: snapshot,
                                action: "slicer_inbox", actor: ("connector:" + origin.connectorId, actorName))
        }
    }

    /// The log line's detail: the file, then which plugin sent it.
    nonisolated static func slicerArrivalText(_ file: String, plugin: String) -> String {
        file + " · " + plugin
    }

    /// Throw one away — the file and its folder, nothing else.
    func discardSlicerUpload(_ item: SlicerUpload) {
        guard permitted("inventory", "create") else { slicerInboxProblem = moveProblem; return }
        guard let root = slicerInboxRoot else { return }
        SlicerInbox.remove(item, root: root)
        refreshSlicerInbox()
    }

    /// Into the library, through the import every other model takes
    /// (`addModelsToLibrary`), the inbox's copy kept until the library holds
    /// it; then, when asked, a job or a quote from that library model — the
    /// library's own "New job from model" (`startJob(fromModels:)`), which
    /// reads the slicer's grams and time off the record the import wrote.
    ///
    /// The job is not opened here: the inbox is a sheet, and the job is
    /// another. It waits in `slicerJobAfterSheet` for the inbox to close.
    func takeSlicerUpload(_ item: SlicerUpload, job asQuote: Bool?) async {
        slicerInboxProblem = nil
        slicerInboxSaid = nil
        guard let root = slicerInboxRoot else { return }
        guard permitted("inventory", "create") else { slicerInboxProblem = moveProblem; return }
        if asQuote != nil {
            guard canMoveJobs else { slicerInboxProblem = words.callIt("mac.move_sample"); return }
            guard permitted("orders", "create") else { slicerInboxProblem = moveProblem; return }
        }
        let url = SlicerInbox.file(of: item, root: root)
        guard let hash = await PinWork.run({ try? LibraryImport.contentHash(of: url) }) ?? nil else {
            slicerInboxProblem = words.callIt("mac.su_gone")
            refreshSlicerInbox()
            return
        }
        if !files.contains(where: { $0.contentHash == hash }) {
            await addModelsToLibrary([url], movesOriginals: false)
        }
        guard let record = files.first(where: { $0.contentHash == hash }) else {
            slicerInboxProblem = importProblem ?? moveProblem ?? words.callIt("mac.calc_model_none")
            return
        }
        SlicerInbox.remove(item, root: root)
        refreshSlicerInbox()
        if let asQuote {
            let carried = Self.slicerCarried(item)
            if showingSlicerInbox {
                slicerJobAfterSheet = (record, asQuote, carried)
                showingSlicerInbox = false
            } else {
                // From the Connected apps screen there is no sheet to close
                // first: the job opens now (it waited for a dismiss that never
                // came, so New Job did nothing there).
                await startJob(fromModels: [record], asQuote: asQuote, carried: carried)
            }
        } else {
            slicerInboxSaid = words.callIt("mac.su_added", ["name": .string(record.title)])
        }
    }

    /// The inbox sheet went: open the job or quote it was asked for.
    func openSlicerJobAfterSheet() async {
        guard let pending = slicerJobAfterSheet else { return }
        slicerJobAfterSheet = nil
        shelf = .jobs(nil)
        await startJob(fromModels: [pending.file], asQuote: pending.asQuote, carried: pending.carried)
    }

    /// What a job made from a paired plugin's file keeps of where it came
    /// from (`lib/order-new.js fromSlicer`): the plugin's own file name shows
    /// beside the job in that plugin's Khayt tab, and nowhere else. Nothing
    /// for a file the OctoPrint path sent.
    nonisolated static func slicerCarried(_ item: SlicerUpload) -> [String: JSONValue] {
        guard item.source == "connector", let id = item.connectorId else { return [:] }
        var origin: [String: JSONValue] = ["connectorId": .string(id), "name": .string(item.name)]
        if let sha = item.sha256 { origin["sha256"] = .string(sha) }
        if let slice = item.sliceId { origin["sliceId"] = .string(slice) }
        return ["fromSlicer": .object(origin)]
    }
}
