import Foundation
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import KhaytCore

/// A group's own picture, chosen by the shop.
///
/// ── WHY A GROUP NEEDED ONE ────────────────────────────────────────────────
///
/// A group tile borrowed its picture: the first model inside with a thumbnail
/// (`LibraryEntry.cover`). Right most of the time, and with no way out when it
/// was wrong — the seven Saudi Kings wore whichever king sorted first, a
/// figure in eight parts wore its left foot. Reported: *"I can't seem able to
/// add a photo for a group."* Now the shop can pick a picture file, or one of
/// the group's own models, and take it off again to go back to the borrowed
/// one. Where it is kept is `GroupCover`'s note.
enum GroupPictures {
    /// The folder in the library vault the pictures go in.
    nonisolated static let folderName = "group-pictures"

    /// A tile is 176pt wide; at 2x that is 352 pixels, and 600 leaves room
    /// for a wider window without carrying a phone photo's twelve megapixels
    /// around for a thumbnail.
    nonisolated static let maxDim = 600
    nonisolated static let quality = 0.85

    /// The file name inside the folder, from whatever a record said — never a
    /// path. Settings sync, and a value arriving from another machine could
    /// say anything; only a plain name is taken, and only one this app could
    /// have written.
    nonisolated static func leaf(of rel: String) -> String? {
        let leaf = (rel as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.hasPrefix("."),
              leaf == ProductPhotos.safe((leaf as NSString).deletingPathExtension)
                + "." + (leaf as NSString).pathExtension,
              (leaf as NSString).pathExtension.lowercased() == "jpg" else { return nil }
        return leaf
    }

    /// A new name for a group's picture: the group's last level, made safe,
    /// and the moment — NEW EACH TIME, so a replaced picture is a different
    /// file and nothing that has drawn the old one (`ThumbnailStore` keeps
    /// images by URL) shows it again.
    nonisolated static func filename(for path: String, at: Date = Date()) -> String {
        let base = String(ProductPhotos.safe(Shop.groupLeaf(path)).prefix(40))
        let stamp = String(Int(at.timeIntervalSince1970 * 1000), radix: 36)
        return (base.isEmpty ? "group" : base) + "-" + stamp + ".jpg"
    }

    /// Where a cover's file is, in whichever of the library's folders holds
    /// it — the current one first, then the ones it used to be in, as a
    /// model's own folder is found (`LibraryLocation.directory`).
    nonisolated static func url(of rel: String, roots: [String]) -> URL? {
        guard let leaf = leaf(of: rel) else { return nil }
        for root in roots {
            let url = URL(fileURLWithPath: root).appending(path: folderName).appending(path: leaf)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// A picked file as the JPEG a group wears: UPRIGHT (`ProductPhotos
    /// .upright` — a phone photo is otherwise sideways), at most `maxDim`,
    /// flattened onto white.
    nonisolated static func encode(_ url: URL) throws -> Data {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        if let size, size > ProductPhotos.maxSourceBytes { throw ProductPhotos.Failure.tooBig(size) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              // Decoded at no more than the size it is written at: a group
              // picture is 600 px, and nothing bigger is ever needed of it.
              let image = ProductPhotos.upright(source, maxPixel: maxDim) else {
            throw ProductPhotos.Failure.notAnImage
        }
        guard let jpeg = ProductPhotos.jpeg(image, maxDim: maxDim, quality: quality) else {
            throw ProductPhotos.Failure.couldNotEncode
        }
        return jpeg
    }

    /// Write a picture into `root`'s folder; returns its vault-relative path.
    nonisolated static func write(_ data: Data, for path: String, under root: String) throws -> String {
        let dir = URL(fileURLWithPath: root).appending(path: folderName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = filename(for: path)
        try data.write(to: dir.appending(path: name), options: .atomic)
        return folderName + "/" + name
    }
}

extension Shop {

    /// The groups' chosen pictures, by path — read with the kinds on load.
    func groupCover(_ path: String) -> GroupCover? { libraryGroupCovers[path] }

    /// What a group tile draws: the shop's choice when there is one that can
    /// still be shown, else the picture it borrows (`automatic`).
    ///
    /// A chosen model that has left the group, or a picture file not on this
    /// Mac, falls back rather than drawing a blank: the shop chose a picture,
    /// not an empty square.
    func groupThumbnail(_ path: String, automatic: LibraryFile?) -> ThumbnailSource? {
        switch groupCover(path) {
        case .image(let rel)?:
            if let roots = libraryRoots?.roots, let url = GroupPictures.url(of: rel, roots: roots) {
                return .file(url)
            }
        case .model(let id)?:
            if let model = files.first(where: { $0.id == id && Self.isUnder($0.groupName, path) }),
               let shown = thumbnail(for: model) {
                return shown
            }
        case nil:
            break
        }
        return automatic.flatMap { thumbnail(for: $0) }
    }

    /// The models in a group that have a picture to lend it, for the menu.
    func groupPictureCandidates(_ path: String, limit: Int = 20) -> [LibraryFile] {
        files.filter { Self.isUnder($0.groupName, path)
                       && ($0.userPhoto?.hasPrefix("data:") == true || $0.thumbFile?.isEmpty == false) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .prefix(limit)
            .filter { thumbnail(for: $0) != nil }
    }

    /// Ask for a picture file, then make it the group's.
    func chooseGroupPicture(_ path: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = LibraryPhoto.kinds
        panel.prompt = words.callIt("mac.group_picture_choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setGroupPicture(path, from: url) }
    }

    /// Make a picture file the group's picture.
    ///
    /// The file is made (upright, scaled) and written into the library's
    /// CURRENT folder before the setting names it — a setting naming a file
    /// that was never written is a broken tile; a file written for a setting
    /// that failed is a few kilobytes nobody sees.
    func setGroupPicture(_ path: String, from url: URL) async {
        writeProblem = nil
        guard let build = source.build, let primary = libraryRoots?.primary, !path.isEmpty else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let made: Result<String, Error> = await ProductPhotos.offMain {
            Result { try GroupPictures.write(GroupPictures.encode(url), for: path, under: primary) }
        }
        switch made {
        case .failure(let error):
            writeProblem = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        case .success(let rel):
            await writeGroupCover(.image(rel), for: path, in: build)
        }
    }

    /// Wear one of the group's own models' pictures.
    func useModelPicture(_ path: String, model id: String) async {
        writeProblem = nil
        guard let build = source.build else { writeProblem = words.callIt("mac.move_sample"); return }
        await writeGroupCover(.model(id), for: path, in: build)
    }

    /// Back to the borrowed picture.
    func removeGroupPicture(_ path: String) async {
        writeProblem = nil
        guard let build = source.build, groupCover(path) != nil else { return }
        await writeGroupCover(nil, for: path, in: build)
    }

    private func writeGroupCover(_ cover: GroupCover?, for path: String, in build: StoreReader.Build) async {
        var covers = GroupCoverChange()
        var undo = LibraryUndo()
        do {
            try StoreWriter.update(build) { root in
                let entriesBefore = GroupKinds.entries(root)
                covers.before = GroupKinds.covers(Self.settings(root))
                GroupKinds.setCover(cover, for: path, into: &root)
                covers.after = GroupKinds.covers(Self.settings(root))
                let entriesAfter = GroupKinds.entries(root)
                undo.groupEntries = Self.groupEntriesChanged(from: entriesBefore, to: entriesAfter)
                for key in undo.groupEntries.keys { undo.groupAfter[key] = .some(entriesAfter[key]) }
            }
        } catch {
            writeProblem = String(describing: error); return
        }
        // The picture it wore before, to the Trash — only when no group
        // wears it any more (a folder moved and moved back can leave two
        // entries naming one file) — and Undo puts both back: the entry
        // through `LibraryUndo`, the file through `settleGroupPictures`.
        settleGroupPictures(covers)
        registerUndo(of: undo, named: words.callIt(cover == nil ? "mac.group_picture_remove"
                                                                : "mac.group_picture_set"))
        await load(source)
    }

    /// After any write of the group map: a picture file no entry names any
    /// more goes to the Trash, and one an entry names again (an Undo) comes
    /// back out of it.
    ///
    /// ── WHY EVERY WRITE, NOT ONLY "REMOVE PICTURE" ────────────────────────
    ///
    /// The map is pruned on every write (`GroupKinds.prune`), and a move into
    /// an existing group settles two entries into one. Each of those can drop
    /// a cover, and a dropped cover's file used to stay in `group-pictures/`
    /// for nobody. A file is only ever trashed when NO entry names it, and
    /// the Trash is the Finder's own way back.
    func settleGroupPictures(_ change: GroupCoverChange) {
        guard let roots = libraryRoots else { return }
        GroupPictures.settle(change, roots: roots.roots, primary: roots.primary)
    }
}

/// The group map's pictures either side of one write.
struct GroupCoverChange {
    var before: [String: GroupCover] = [:]
    var after: [String: GroupCover] = [:]

    static func images(_ covers: [String: GroupCover]) -> Set<String> {
        Set(covers.values.compactMap { if case .image(let rel) = $0 { return rel } else { return nil } })
    }

    /// Picture files no entry names after the write.
    var dropped: Set<String> { Self.images(before).subtracting(Self.images(after)) }
}

extension GroupPictures {
    /// Where each picture this run put in the Trash went, by its vault path,
    /// so an Undo can bring it back. This Mac's run only: a picture trashed
    /// before a relaunch is brought back from the Finder, like any other.
    @MainActor static var inTrash: [String: URL] = [:]

    @MainActor static func settle(_ change: GroupCoverChange, roots: [String], primary: String) {
        for rel in change.dropped {
            guard let url = url(of: rel, roots: roots) else { continue }
            var landed: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &landed)) != nil,
               let landed = landed as URL? {
                inTrash[rel] = landed
            }
        }
        for rel in GroupCoverChange.images(change.after) where url(of: rel, roots: roots) == nil {
            guard let from = inTrash[rel], let leaf = leaf(of: rel) else { continue }
            let dir = URL(fileURLWithPath: primary).appending(path: folderName)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: from, to: dir.appending(path: leaf))) != nil {
                inTrash[rel] = nil
            }
        }
    }
}

/// "Group Picture" — chosen, borrowed from a model inside, or taken off —
/// from a group tile's right-click and from the crumb above an open group.
struct GroupPictureItems: View {
    let shop: Shop
    let path: String

    var body: some View {
        Button(shop.words.callIt("mac.group_picture_set")) { shop.chooseGroupPicture(path) }
            .disabled(!shop.canWrite)
        let models = shop.groupPictureCandidates(path)
        Menu(shop.words.callIt("mac.group_picture_use_model")) {
            ForEach(models) { model in
                Button {
                    Task { await shop.useModelPicture(path, model: model.id) }
                } label: {
                    if shop.groupCover(path) == .model(model.id) {
                        Label(model.title, systemImage: "checkmark")
                    } else {
                        Text(model.title)
                    }
                }
            }
        }
        .disabled(!shop.canWrite || models.isEmpty)
        Button(shop.words.callIt("mac.group_picture_remove")) {
            Task { await shop.removeGroupPicture(path) }
        }
        .disabled(!shop.canWrite || shop.groupCover(path) == nil)
    }
}
