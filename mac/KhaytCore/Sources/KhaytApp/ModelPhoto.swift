import Foundation

/// The photograph that came WITH a model file — found on the disk beside it.
///
/// Asked for by the shop (Oct 2026): "add a photo if that file has a photo".
/// A model downloaded from Printables, MakerWorld or Thingiverse arrives with
/// pictures of the printed thing, and a model the shop keeps in its own
/// folders often sits beside `dragon.jpg`. The library drew a grey render
/// instead, while the better picture was one folder away.
///
/// ── WHAT COUNTS AS THE MODEL'S PHOTO ─────────────────────────────────────
///
/// 1. An image with the model's own name: `dragon.stl` + `dragon.jpg`. Looked
///    for beside the model and in the gallery folders (`images/`, `photos/`,
///    `renders/`…) of its folder — and of the project folder above, when the
///    model sits in a container like `files/` or `stl/`.
/// 2. Otherwise, only when that folder holds ONE model: any image in its
///    gallery folders, then any image loose beside it. That is the download
///    shape — `Dragon/files/dragon.stl` + `Dragon/images/1.jpg`.
///
/// A folder of several models does NOT hand one picture to all of them. A
/// project's cover photo on forty parts would replace forty different renders
/// with forty copies of the same picture, which is less information, not more.
///
/// Read only. Nothing is moved, copied or renamed; the caller turns the image
/// into the record's `userPhoto` (`LibraryPhoto.dataURI`), and an image that
/// will not decode is simply passed over.
enum ModelPhoto {

    /// What a picture is, by extension. Never a model: none of these is in
    /// `LibraryImport.kinds`, and `ModelPhotoTests` holds that.
    nonisolated static let kinds: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "tif", "tiff", "bmp",
    ]

    /// The folder names a model site puts its pictures in.
    nonisolated static let galleries: Set<String> = [
        "images", "image", "photos", "photo", "pictures", "pics", "renders", "render", "gallery",
    ]

    /// How many candidates are kept per model. The first that decodes wins;
    /// more than a few is a folder of screenshots, not a model's photo.
    nonisolated static let keep = 3

    nonisolated static func isImage(_ url: URL) -> Bool {
        kinds.contains(url.pathExtension.lowercased())
    }

    private nonisolated static func stem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private nonisolated static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The photo candidates of every model, best first.
    ///
    /// - Parameters:
    ///   - models: the models to find photos for.
    ///   - everyModel: every model in the same walk, including ones already in
    ///     the library — what "a folder holding one model" is counted against.
    ///   - boundary: the folder the walk started at, never climbed above. Nil
    ///     for a file picked on its own: then only a same-named image counts,
    ///     because the folder it sits in (Downloads) is nobody's project.
    nonisolated static func candidates(for models: [URL], everyModel: [URL],
                                       boundary: URL?) -> [URL: [URL]] {
        let fm = FileManager.default
        var listed: [String: [URL]] = [:]
        // Images directly in a folder, by name. Hidden files skipped, regular
        // files only — a symlink named `cover.jpg` is a pointer elsewhere.
        func images(in dir: URL) -> [URL] {
            let key = path(dir)
            if let hit = listed[key] { return hit }
            let found = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: LibraryImport.fileKeys,
                                                      options: [.skipsHiddenFiles])) ?? [])
                .filter { isImage($0) && LibraryImport.isRegularFile($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            listed[key] = found
            return found
        }
        var subdirs: [String: [URL]] = [:]
        func galleryImages(of dir: URL) -> [URL] {
            let key = path(dir)
            let folders = subdirs[key] ?? {
                let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles])) ?? [])
                    .filter {
                        let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        return v?.isDirectory == true && v?.isSymbolicLink != true
                            && galleries.contains($0.lastPathComponent.lowercased())
                    }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                subdirs[key] = all
                return all
            }()
            return folders.flatMap(images(in:))
        }
        let bound = boundary.map(path)
        let allPaths = everyModel.map(path)
        func modelsUnder(_ dir: URL) -> Int {
            let prefix = path(dir) + "/"
            return allPaths.filter { $0.hasPrefix(prefix) }.count
        }
        func inside(_ dir: URL) -> Bool {
            guard let bound else { return false }
            let p = path(dir)
            return p == bound || p.hasPrefix(bound + "/")
        }

        var out: [URL: [URL]] = [:]
        for model in models {
            let dir = model.deletingLastPathComponent()
            let own = stem(model)
            var picks: [URL] = []
            func add(_ urls: [URL]) {
                for u in urls where picks.count < keep && !picks.contains(u) { picks.append(u) }
            }

            // Where this model's project is: its folder, and the folder above
            // when its own is only a container (`files/`, `stl/`, `3mf/`).
            var homes: [URL] = []
            if boundary != nil, inside(dir) {
                homes.append(dir)
                let parent = dir.deletingLastPathComponent()
                if path(dir) != bound, ImportGrouping.meaningful(dir.lastPathComponent) == nil, inside(parent) {
                    homes.append(parent)
                }
            }

            // 1. Its own name, beside it — even for a file picked on its own.
            add(images(in: dir).filter { stem($0) == own })
            // …and in the project's gallery folders.
            for home in homes { add(galleryImages(of: home).filter { stem($0) == own }) }

            // 2. A folder of ONE model: its pictures are of that model.
            if picks.isEmpty {
                for home in homes where modelsUnder(home) == 1 {
                    add(galleryImages(of: home))
                    add(images(in: home))
                    if !picks.isEmpty { break }
                }
            }
            if !picks.isEmpty { out[model] = picks }
        }
        return out
    }
}
