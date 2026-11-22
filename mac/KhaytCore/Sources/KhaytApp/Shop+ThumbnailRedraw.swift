import Darwin
import Foundation
import KhaytCore

/// ── THUMBNAILS THE OLD PROJECTION DREW, REDRAWN WHEN NEXT SEEN ───────────
///
/// `MeshPreview` drew every STL/OBJ thumbnail as a mirror image until stage
/// 3b (its screen axis ran the wrong way for its depth axis). The pictures it
/// left are files in each model's folder, and a library of thousands holds
/// thousands of them. So nothing walks the library: a picture is looked at
/// when its tile is drawn (`cachedThumbnail`), and only then is it checked
/// and, if the old projection drew it, drawn again — one at a time, off the
/// main thread, never writing the book.
///
/// WHICH PICTURES: only ones this app's renderer drew — `thumb.png`, for an
/// STL or OBJ, with `thumbSource` "mesh" (the `--thumbnails` pass) or
/// "embedded" (what an import writes for any picture it made; for an STL that
/// can only be a drawing, since an STL embeds nothing). A shop's photo, a
/// 3MF's own preview and Electron's renders (`thumbSource` "render") are
/// never touched.
///
/// THE VERSION is on the FILE, as an extended attribute
/// (`MeshPreview.renderAttribute`), not in the book: stamping a record per
/// picture would be thousands of synced writes for a thumbnail. A copy that
/// arrives without the attribute (a bucket, another Mac) is checked once and
/// drawn again — the same picture, at the cost of one draw.
extension MeshPreview {
    /// Raised when the drawing changes enough to redraw what is on disk.
    /// 2: the right-handed camera (stage 3b).
    static let renderVersion = 2
    static let renderAttribute = "app.khayt.thumb-render"

    /// The render version a picture on disk says it was drawn at; 0 for one
    /// that says nothing.
    nonisolated static func renderVersion(of url: URL) -> Int {
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = getxattr(url.path, renderAttribute, &buffer, buffer.count, 0, 0)
        guard n > 0 else { return 0 }
        return Int(String(decoding: buffer.prefix(n), as: UTF8.self)) ?? 0
    }

    /// Say on the file that this renderer, today, drew it.
    nonisolated static func markCurrent(_ url: URL) {
        let value = Array(String(renderVersion).utf8)
        _ = setxattr(url.path, renderAttribute, value, value.count, 0, 0)
    }
}

extension Shop {

    /// Could this record's picture have been drawn by the old projection?
    /// Read off the record alone — no disk.
    nonisolated static func mayBeMeshDrawn(_ file: LibraryFile) -> Bool {
        guard file.thumbFile == "thumb.png" else { return false }
        let name = file.sourceFile?.filename ?? file.originalName ?? ""
        let ext = (file.sourceFile?.ext ?? (name as NSString).pathExtension).lowercased()
        guard ext == "stl" || ext == "obj" else { return false }
        return file.thumbSource == "mesh" || file.thumbSource == "embedded"
    }

    /// Redraw one picture now if the old projection drew it. Off the main
    /// thread: reads the attribute, and only when it is old reads the model
    /// and writes a new `thumb.png` beside the old one, then swaps it in.
    /// True when it drew.
    nonisolated static func redrawIfOld(thumbnail: URL, model: URL) -> Bool {
        guard MeshPreview.renderVersion(of: thumbnail) < MeshPreview.renderVersion else { return false }
        guard let png = try? MeshPreview.png(of: model) else {
            // Nothing to draw from: leave the picture, and stop asking.
            MeshPreview.markCurrent(thumbnail)
            return false
        }
        let scratch = thumbnail.deletingLastPathComponent().appending(path: ".thumb-redraw-\(UUID().uuidString).png")
        do {
            try png.write(to: scratch)
            _ = try FileManager.default.replaceItemAt(thumbnail, withItemAt: scratch)
            MeshPreview.markCurrent(thumbnail)
            return true
        } catch {
            try? FileManager.default.removeItem(at: scratch)   // the scratch copy of a redraw that did not land
            return false
        }
    }

    /// Asked by `cachedThumbnail` for a picture it found on disk: queue a
    /// check of it, once per model per run of the app. Nothing is asked of
    /// the disk here.
    func considerRedraw(_ file: LibraryFile, thumbnail: URL) {
        guard Self.mayBeMeshDrawn(file) else { return }
        let memo = libraryMemo
        guard memo.thumbChecked.insert(file.id).inserted else { return }
        guard let model = modelFile(for: file) else { return }
        memo.thumbQueue.append((file.id, thumbnail, model))
        guard !memo.thumbRedrawing else { return }
        memo.thumbRedrawing = true
        Task { await drainThumbnailRedraws() }
    }

    /// One at a time, so a scroll through a thousand old tiles is a queue,
    /// never a thousand draws at once.
    func drainThumbnailRedraws() async {
        let memo = libraryMemo
        while !memo.thumbQueue.isEmpty {
            let (id, thumbnail, model) = memo.thumbQueue.removeFirst()
            let drew = await PinWork.run { Self.redrawIfOld(thumbnail: thumbnail, model: model) }
            guard drew else { continue }
            memo.work.thumbRedraws += 1
            memo.thumbGeneration[id, default: 0] += 1
            memo.thumbs[id] = nil
            libraryDiskEpoch &+= 1
        }
        memo.thumbRedrawing = false
    }

    /// A redrawn picture's source: the same file under a new name for the
    /// picture cache, so the tile decodes the new bytes.
    func redrawnSource(_ url: URL, id: LibraryFile.ID) -> ThumbnailSource {
        guard let n = libraryMemo.thumbGeneration[id], n > 0,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .file(url) }
        parts.fragment = String(n)
        return .file(parts.url ?? url)
    }
}
