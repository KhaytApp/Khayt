import AppKit
import Foundation
import SwiftUI
import KhaytCore
import KhaytWebSave

/// ── A DOWNLOAD, ATTACHED TO THE PAGE IT CAME FROM ─────────────────────────
///
/// A page saved with Save to Khayt is a record with no file. When the shop
/// then downloads the model from that page, the download is put to the shop
/// — "Add it to that model?" — and added only on Add to Library:
///
/// * Chrome, Edge, Brave, Vivaldi, Firefox: the extension's background sees
///   the finished download (its `downloads` permission, for ten minutes after
///   a save) and sends an `attach` message through the browser host. That
///   arrives here as an inbox entry, is checked (`offerWebAttach`) and becomes
///   an OFFER — nothing is read but the file's size.
/// * Safari: no downloads API, so `SafariDownloadsWatch` looks in ~/Downloads
///   — only for ten minutes after a Safari save, and only for a model file
///   that was not there when the save came in.
///
/// Adding is an import (`LibraryImport.prepare` with the record's own id), so
/// the file is copied into the library, read back, measured and pictured like
/// any model — and the download is LEFT WHERE IT IS. The original is never
/// moved or put in the Trash: it is the browser's, in the shop's Downloads.
struct WebAttachOffer: Identifiable, Equatable, Sendable {
    let id: String
    /// The saved page's record.
    let recordId: String
    /// The record's title, as the shop sees it in the library.
    let title: String
    let path: String
    let name: String
    let size: Int
    /// `chrome`, `edge`, `brave`, `vivaldi`, `firefox` or `safari`.
    let browser: String

    var isArchive: Bool { WebDownloads.archiveKinds.contains((path as NSString).pathExtension.lowercased()) }

    init(recordId: String, title: String, path: String, size: Int, browser: String) {
        self.id = UUID().uuidString
        self.recordId = recordId; self.title = title; self.path = path
        // The REAL file's name, always — never the one an attach message
        // gives: whoever writes the inbox could label a client's part
        // "dragon.stl".
        self.name = (path as NSString).lastPathComponent
        self.size = size; self.browser = browser
    }
}

extension Shop {

    /// The user's home folder — where a download may be, and nowhere else.
    nonisolated static var webDownloadHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The kinds a download may be attached as: what the library files, and
    /// the archives a model site hands them out in.
    nonisolated static func webAttachable(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return WebSave.isModelFile(path) && (LibraryImport.kinds.contains(ext) || WebDownloads.archiveKinds.contains(ext))
    }

    /// The saved record a page address belongs to, saved recently enough for
    /// a download from it still to be its download.
    func webRecordForDownload(page: String, now: Date = Date()) -> (id: String, title: String)? {
        let probe = WebSave.Page(url: page, site: .of(host: URL(string: page)?.host), title: "-")
        guard let id = WebSaveRecord.existing(probe, in: libraryRows),
              let file = files.first(where: { $0.id == id }), file.isFromWeb,
              let at = file.savedFromWebAt.flatMap(Calendar.instant) else { return nil }
        // The extension's window, and a little more for the browser's clock.
        guard now.timeIntervalSince(at) <= WebSave.attachWindow + 300, at.timeIntervalSince(now) < 300 else { return nil }
        return (id, file.title)
    }

    /// An `attach` from the browser, checked and turned into an offer — or
    /// refused, with why. Nothing is added here: the shop is asked first.
    ///
    /// Refused as a save is (switched off, the staff lock, the sample), and
    /// also when no page saved in the last few minutes is the one the
    /// download came from, or the path is not a model file under this
    /// user's home folder.
    func offerWebAttach(_ entry: WebSave.Entry, accepting: Bool,
                        home: URL = Shop.webDownloadHome, now: Date = Date()) -> (WebInbox.Result, WebAttachOffer?) {
        guard accepting else { return (.init(id: entry.id, state: .refused, reason: "off"), nil) }
        guard entry.kind == .attach, let attach = entry.attach else {
            return (.init(id: entry.id, state: .invalid, reason: WebSave.Refusal.badKind.rawValue), nil)
        }
        guard lockAllows("inventory", "edit") else { return (.init(id: entry.id, state: .refused, reason: "not-allowed"), nil) }
        guard source.build != nil else { return (.init(id: entry.id, state: .refused, reason: "sample"), nil) }
        guard WebDownloads.isOfferable(attach.path, home: home), Self.webAttachable(attach.path) else {
            return (.init(id: entry.id, state: .invalid, reason: WebSave.Refusal.badPath.rawValue), nil)
        }
        guard let record = webRecordForDownload(page: attach.page, now: now) else {
            return (.init(id: entry.id, state: .refused, reason: "no-record"), nil)
        }
        let size = (try? URL(fileURLWithPath: attach.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let offer = WebAttachOffer(recordId: record.id, title: record.title, path: attach.path,
                                   size: size, browser: entry.browser)
        return (.init(id: entry.id, state: .offered, title: record.title), offer)
    }

    enum WebAttachFailure: Error, Equatable {
        case gone, notAllowed, noModel, failed(String)
    }

    /// Add the download the shop said yes to: copied into the library under
    /// the saved record (or beside it, when it already has a file), the
    /// download itself left where it is.
    func attachWebDownload(_ offer: WebAttachOffer, home: URL = Shop.webDownloadHome) async throws(WebAttachFailure)
        -> WebSaveRecord.Attached {
        guard lockAllows("inventory", "edit") else { throw .notAllowed }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            throw .failed(LibraryImport.Failure.notOurs.said(words))
        }
        guard let roots = libraryRoots else { throw .failed(LibraryImport.Failure.noLibrary.said(words)) }
        guard let engine else { throw .failed("the engine is not loaded") }
        guard WebDownloads.isOfferable(offer.path, home: home), Self.webAttachable(offer.path) else { throw .gone }
        guard let saved = WebSaveRecord.record(offer.recordId, in: libraryRows) else { throw .gone }

        let download = URL(fileURLWithPath: offer.path)
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "khayt-web-attach-scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) } // scratch
        let model: URL
        if offer.isArchive {
            let taken: Result<URL, Error> = await PinWork.run { Result { try Self.modelOut(of: download, into: scratch) } }
            guard case .success(let url) = taken else { throw .noModel }
            model = url
        } else {
            model = download
        }

        let id = WebSaveRecord.hasFile(saved) ? Self.uid("PF") : offer.recordId
        let made: LibraryImport.Prepared
        do {
            made = try await LibraryImport.prepare(model, libraryRoot: URL(fileURLWithPath: roots.primary),
                                                   knownHashes: Set(files.compactMap(\.contentHash)),
                                                   nameOfExisting: { [files] hash in files.first { $0.contentHash == hash }?.title },
                                                   engine: engine, analyseRisk: analysesRiskAtImport, id: id)
        } catch let failure as LibraryImport.Failure {
            throw .failed(failure.said(words))
        } catch {
            throw .failed(String(describing: error))
        }
        let imported = made.record, savedId = offer.recordId
        let attached: WebSaveRecord.Attached?
        do {
            attached = try await StoreWriter.updateOffMain(build) { root -> WebSaveRecord.Attached? in
                var rows = Self.rows(root, "printFiles")
                guard let done = WebSaveRecord.attach(imported, newId: id, to: savedId, in: &rows) else { return nil }
                root["printFiles"] = .array(rows)
                return done
            }
        } catch {
            attached = nil
        }
        guard let attached else {
            // The book would not take it: the copy has no record to belong to.
            // Only the library's own new folder goes — never the download.
            let dir = made.dir
            await PinWork.run { try? FileManager.default.removeItem(at: dir) }
            throw .failed(LibraryImport.Failure.failed("the book did not take the change").said(words))
        }
        await load(source)
        return attached
    }

    /// The model in a compressed download, taken out into `scratch`: a 3MF
    /// before an STL before anything else, the largest of a kind. Refused as
    /// any archive is (`ArchiveFolder.judge`): unsafe names, a listing that
    /// lies about its size, encrypted members.
    nonisolated static func modelOut(of archive: URL, into scratch: URL) throws -> URL {
        let members = try ArchiveMembers.list(archive)
        let bytes = ArchiveMembers.size(of: archive)
        guard case .open(let models) = ArchiveFolder.judge(members, archiveBytes: bytes, modelKinds: LibraryImport.kinds),
              let best = pickModel(models) else { throw WebAttachFailure.noModel }
        let dest = scratch.appending(path: best.leaf)
        try ArchiveMembers.extract(best, from: archive, to: dest, cap: ArchiveFolder.Limits().memberBytes)
        return dest
    }

    nonisolated static func pickModel(_ members: [ArchiveFolder.Member]) -> ArchiveFolder.Member? {
        let rank = ["3mf": 0, "stl": 1, "obj": 2, "step": 3, "stp": 3]
        return members.filter { !$0.encrypted && $0.type == .file }.min { a, b in
            let ra = rank[a.ext] ?? 9, rb = rank[b.ext] ?? 9
            return ra != rb ? ra < rb : (a.size ?? 0) > (b.size ?? 0)
        }
    }
}

/// ── SAFARI'S DOWNLOADS, LOOKED AT ONLY WHILE A SAVE IS FRESH ─────────────
///
/// Safari gives an extension no downloads API, so the app watches the
/// Downloads folder itself — and only then: from a Safari save until
/// `WebSave.attachWindow` after the latest one, never otherwise. What was in
/// the folder when the watch began is never offered; a file that appears
/// after, is a model kind, and has stopped growing is offered once, for the
/// page saved last. macOS asks the shop the first time Khayt looks in
/// Downloads (`NSDownloadsFolderUsageDescription`), which is the first
/// Safari save, not the first launch.
@MainActor
final class SafariDownloadsWatch {
    private weak var inbox: WebSaveInbox?
    /// The folder, when it is not ~/Downloads (tests).
    var folder: () -> URL? = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }
    var home: () -> URL = { Shop.webDownloadHome }

    private(set) var target: (recordId: String, title: String)?
    private(set) var until: Date?
    private var baseline: Set<String> = []
    private var sizes: [String: Int] = [:]
    private var offered: Set<String> = []
    private var timer: Timer?
    private var source: DispatchSourceFileSystemObject?

    init(inbox: WebSaveInbox) { self.inbox = inbox }

    var isWatching: Bool { until.map { $0 > Date() } ?? false }

    /// Watch for the download of the page just saved (`recordId`), for
    /// `attachWindow` from now. A second save moves the window and the page.
    func watch(recordId: String, title: String, site: WebSave.Site, now: Date = Date()) {
        guard let dir = folder() else { return }
        if !isWatching {
            baseline = Set(Self.list(dir).map(\.name))
            sizes = [:]
            offered = []
            start(dir)
        }
        target = (recordId, title)
        until = now.addingTimeInterval(WebSave.attachWindow)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        source?.cancel(); source = nil
        target = nil; until = nil
        baseline = []; sizes = [:]; offered = []
    }

    private func start(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.look() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        }
        // A file still being written changes size without a folder event:
        // look again every couple of seconds until the window closes.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    /// One look at the folder: anything new and finished is offered.
    func look(now: Date = Date()) {
        guard let until, now <= until, let target, let dir = folder() else { stop(); return }
        let ready = WebDownloads.newModels(Self.list(dir), baseline: baseline, sizes: &sizes, offered: offered)
        for name in ready {
            offered.insert(name)
            let path = dir.appending(path: name).path
            guard WebDownloads.isOfferable(path, home: home()), Shop.webAttachable(path) else { continue }
            let size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            inbox?.enqueue(WebAttachOffer(recordId: target.recordId, title: target.title, path: path,
                                          size: size, browser: "safari"))
        }
    }

    static func list(_ dir: URL) -> [WebDownloads.Listed] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return items.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return WebDownloads.Listed(name: u.lastPathComponent,
                                       isRegularFile: v?.isRegularFile == true && v?.isSymbolicLink != true,
                                       size: v?.fileSize ?? 0)
        }
    }
}

/// "Add the download to the library?" — the window's question.
struct WebAttachPrompt: View {
    let shop: Shop
    let offer: WebAttachOffer
    @Bindable var inbox = WebSaveInbox.shared

    var body: some View {
        let w = shop.words
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: offer.isArchive ? "doc.zipper" : "cube.transparent")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.callIt("mac.sfw_attach_title"))
                        .font(.headline)
                    Text(w.callIt("mac.sfw_attach_body", ["file": .string(offer.name), "title": .string(offer.title)]))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(w.callIt("mac.sfw_attach_file")) {
                    Text(offer.name).lineLimit(1).truncationMode(.middle)
                }
                LabeledContent(w.callIt("mac.sfw_attach_size")) {
                    Text(Format.fileSize(Int64(offer.size)))
                }
                LabeledContent(w.callIt("mac.sfw_attach_model")) {
                    Text(offer.title).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text(w.callIt(offer.isArchive ? "mac.sfw_attach_note_archive" : "mac.sfw_attach_note"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = inbox.attachProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(w.callIt("mac.sfw_attach_show")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: offer.path)])
                }
                Spacer()
                if inbox.attaching { ProgressView().controlSize(.small) }
                Button(w.callIt("mac.sfw_attach_not_now")) { inbox.dismissOffer() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(inbox.attaching)
                Button(w.callIt("mac.sfw_attach_add")) { Task { await inbox.accept(offer, shop: shop) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(inbox.attaching)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

extension WebSaveInbox {
    /// The shop's Add to Library: the download imported into the saved
    /// record, the question closed — or the reason it could not be, said in
    /// the sheet, which stays open.
    func accept(_ offer: WebAttachOffer, shop: Shop) async {
        guard !attaching else { return }
        attaching = true
        attachProblem = nil
        defer { attaching = false }
        do {
            let done = try await shop.attachWebDownload(offer)
            lastAttached = (offer.name, done.id)
            dismissOffer()
        } catch {
            attachProblem = switch error {
            case .gone: shop.words.callIt("mac.sfw_attach_gone")
            case .notAllowed: shop.words.callIt("mac.sfw_attach_not_allowed")
            case .noModel: shop.words.callIt("mac.sfw_attach_no_model")
            case .failed(let why): why
            }
        }
    }
}

/// The words of attaching a download, in both languages. Merged with
/// `WebSaveWords.table`.
enum WebAttachWords {
    nonisolated static let table: [String: [String: String]] = [
        "mac.sfw_attach_title": ["en": "Add the download to your library?", "ar": "إضافة الملف المُنزَّل إلى مكتبتك؟"],
        "mac.sfw_attach_body": ["en": "“{file}” has finished downloading from the page you saved as “{title}”. Add it to that model?",
                               "ar": "اكتمل تنزيل «{file}» من الصفحة التي حفظتها باسم «{title}». هل تريد إضافته إلى هذا النموذج؟"],
        "mac.sfw_attach_file": ["en": "File", "ar": "الملف"],
        "mac.sfw_attach_size": ["en": "Size", "ar": "الحجم"],
        "mac.sfw_attach_model": ["en": "Model", "ar": "النموذج"],
        "mac.sfw_attach_note": ["en": "Khayt copies the file into the library and measures it. The download stays where it is.",
                               "ar": "ينسخ خيط الملف إلى المكتبة ويقيسه. يبقى الملف المُنزَّل في مكانه."],
        "mac.sfw_attach_note_archive": ["en": "Khayt takes the model out of the compressed file and copies it into the library. The download stays where it is.",
                                       "ar": "يستخرج خيط النموذج من الملف المضغوط وينسخه إلى المكتبة. يبقى الملف المُنزَّل في مكانه."],
        "mac.sfw_attach_show": ["en": "Show in Finder", "ar": "إظهار في Finder"],
        "mac.sfw_attach_not_now": ["en": "Not Now", "ar": "ليس الآن"],
        "mac.sfw_attach_add": ["en": "Add to Library", "ar": "إضافة إلى المكتبة"],
        "mac.sfw_attach_gone": ["en": "The download or the saved model is no longer there.",
                               "ar": "لم يعد الملف المُنزَّل أو النموذج المحفوظ موجودًا."],
        "mac.sfw_attach_not_allowed": ["en": "The person signed in may not change the library.",
                                      "ar": "لا يُسمح للشخص المسجّل بتعديل المكتبة."],
        "mac.sfw_attach_no_model": ["en": "Khayt found no model it can read in the compressed file.",
                                   "ar": "لم يجد خيط في الملف المضغوط نموذجًا يمكنه قراءته."],
        "mac.sfw_last_attached": ["en": "Last added from a download: {name}", "ar": "آخر ما أُضيف من التنزيلات: {name}"],
    ]
}
