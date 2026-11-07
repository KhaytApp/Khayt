import Foundation
import AppKit
import CryptoKit

/// `khayt://job/new?name=…&file=…&sha256=…` — "send to Khayt as a job" from
/// bedready.io's converter (and anything else that converts a model).
///
/// ── THE ONE LINK THAT CAN LEAD TO A CHANGE, SO IT ASKS ──────────────────
///
/// Every other khayt:// address only navigates (`DeepLink`). This one ends
/// in New Job, and New Job from a file adds the file to the library first
/// (`newJob(fromDropped:)`). A web page can open a khayt:// link, so nothing
/// happens until the shop says so in a dialog that names the file — and even
/// then the job itself is only saved when the shop presses Save in the sheet.
///
/// The file cannot travel in a URL. The page downloads it first; the link
/// names it and carries its SHA-256, and only a file in this Mac's Downloads
/// folder with that exact name AND that exact content is used. A name with a
/// path in it, a hidden file, a kind Khayt does not read, or a missing hash
/// is refused when the URL is read. The other fields the converter knows
/// (printer, plates, toolhead filaments) are already inside the 3MF, which
/// is what New Job reads them from.
struct NewJobLink: Equatable {
    var name: String
    var file: String
    var sha256: String

    static let maxName = 120
    /// The largest file the link may name — the library's own read budget.
    static let maxBytes: Int64 = 1 << 30

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "khayt", url.host()?.lowercased() == "job",
              url.path() == "/new",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ key: String) -> String {
            (items.first { $0.name == key }?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let file = value("file"), hash = value("sha256").lowercased()
        guard !file.isEmpty, file.count <= 255, !file.hasPrefix("."),
              !file.contains("/"), !file.contains("\\"), !file.contains(":"),
              Shop.droppableModelKinds.contains((file as NSString).pathExtension.lowercased()),
              hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.file = file
        self.sha256 = hash
        self.name = String(value("name").prefix(Self.maxName))
    }

    /// The file in `folder` with this link's name and content, or nil. Reads
    /// the whole file to hash it — call off the main thread.
    func locate(in folder: URL) -> URL? {
        let url = folder.appending(path: file)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              size > 0, size <= Self.maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256 ? url : nil
    }
}

extension Shop {
    /// What the next New Job from a dropped file is called, from a
    /// `khayt://job/new` link. Taken once, by `newJob(fromDropped:)`.
    @MainActor static var pendingJobName: String?

    /// `khayt://job/new` links handed to the app, waiting for a book — taken
    /// with the widget links (`takeOpenedLinks`), and as stale as they are.
    @MainActor static var openedJobLinks: [NewJobLink] = [] {
        didSet {
            guard !openedJobLinks.isEmpty else { return }
            openedLinksArrived = Date()
            NotificationCenter.default.post(name: .khaytOpenedLinks, object: nil)
        }
    }

    /// A `khayt://job/new` link: find its file, ASK, and hand it to the
    /// Dock-drop path. Never saves anything itself; refused without a book,
    /// on the sample, or for someone who may not create jobs.
    func receive(_ link: NewJobLink) async {
        guard canMoveJobs, permitted("orders", "create") else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let found: URL? = if let downloads { await BookWork.run { link.locate(in: downloads) } } else { nil }
        let alert = NSAlert()
        guard let found else {
            alert.alertStyle = .warning
            alert.messageText = words.callIt("mac.joblink_missing_title")
            alert.informativeText = words.callIt("mac.joblink_missing", ["file": .string(link.file)])
            alert.addButton(withTitle: words.callIt("common.close"))
            alert.runModal()
            return
        }
        alert.messageText = words.callIt("mac.joblink_ask_title")
        alert.informativeText = words.callIt("mac.joblink_ask", ["file": .string(link.file)])
        alert.addButton(withTitle: words.callIt("mac.joblink_start"))
        alert.addButton(withTitle: words.callIt("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Self.pendingJobName = link.name.isEmpty ? nil : link.name
        _ = await newJob(fromDropped: [found])
    }
}
