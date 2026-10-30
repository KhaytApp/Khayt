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
                                             engine: KhaytEngine?, now: Date = Date()) async throws -> SlicerUpload {
        var figures: [String: JSONValue]?
        if let engine { figures = await SlicerFigures.read(file, engine: engine) }
        let read = figures
        let filed: Result<SlicerUpload, Error> = await PinWork.run {
            Result { try SlicerInbox.file(file, name: name, figures: read, root: root, now: now) }
        }
        return try filed.get()
    }

    /// The server's `slicerReceive`.
    func receiveSlicerUpload(_ file: URL, name: String) async throws {
        guard let root = slicerInboxRoot else { throw CocoaError(.fileWriteNoPermission) }
        let item = try await Self.fileSlicerUpload(file, name: name, root: root, engine: engine)
        slicerUploads.removeAll { $0.id == item.id }
        slicerUploads.insert(item, at: 0)
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
            slicerJobAfterSheet = (record, asQuote)
            showingSlicerInbox = false
        } else {
            slicerInboxSaid = words.callIt("mac.su_added", ["name": .string(record.title)])
        }
    }

    /// The inbox sheet went: open the job or quote it was asked for.
    func openSlicerJobAfterSheet() async {
        guard let pending = slicerJobAfterSheet else { return }
        slicerJobAfterSheet = nil
        shelf = .jobs(nil)
        await startJob(fromModels: [pending.file], asQuote: pending.asQuote)
    }
}
