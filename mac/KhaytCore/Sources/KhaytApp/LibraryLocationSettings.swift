import SwiftUI
import AppKit
import KhaytCore

/// Where the print library lives: this Mac's own folder, a folder the shop
/// chooses, or iCloud Drive — and the files already here moved along with it.
///
/// iCloud Drive is a folder on this Mac, synced by macOS. With "Optimize Mac
/// Storage" on, macOS moves models nobody has opened to iCloud by itself and
/// brings each one back when it is opened — the free-up-space feature, done by
/// the system. Saves ITSELF, because moving files is not a draft.
struct LibraryLocationSettings: View {
    let shop: Shop
    @State private var pending: URL?
    /// `Shop.importMovesOriginals` — the same default the Add panel asks.
    @AppStorage(Shop.importMovesOriginalsKey) private var movesOriginals = false
    /// The linked folder chosen for Unlink, held until the shop answers.
    @State private var unlinking: String?

    private var here: String { shop.libraryRoots?.primary ?? "" }
    private var inICloud: Bool {
        guard let cloud = Shop.iCloudDrive else { return false }
        return LibraryMove.under(here, cloud.path)
    }

    var body: some View {
        Section(shop.words.callIt("mac.libmove_title")) {
            LabeledContent(shop.words.callIt("mac.libmove_now")) {
                Text(verbatim: (here as NSString).abbreviatingWithTildeInPath)
                    .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if inICloud {
                Label(shop.words.callIt("mac.libmove_in_icloud"), systemImage: "icloud")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let cloud = Shop.iCloudDrive, !inICloud {
                    Button(shop.words.callIt("mac.libmove_use_icloud")) {
                        pending = cloud.appending(path: "Khayt print library")
                    }
                }
                Button(shop.words.callIt("mac.libmove_choose") + "\u{2026}") { choose() }
                if shop.libraryRoots?.isCustom == true, case .store(let build) = shop.source {
                    Button(shop.words.callIt("mac.libmove_back_home")) {
                        pending = URL(fileURLWithPath: LibraryLocation.defaultRoot(for: build))
                    }
                }
                Spacer()
            }
            .disabled(shop.libraryMoveBusy || !shop.canMoveJobs)
            if !shop.canMoveJobs { BookLockedNote(shop: shop) }
            Text(shop.words.callIt("mac.libmove_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // ── WHAT ADDING A MODEL DOES TO THE ORIGINAL ─────────────────
            Picker(shop.words.callIt("mac.import_originals_title"), selection: $movesOriginals) {
                Text(shop.words.callIt("mac.import_keep_originals")).tag(false)
                Text(shop.words.callIt("mac.import_move_originals")).tag(true)
            }
            Text(shop.words.callIt("mac.import_originals_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // ── FOLDERS INDEXED WHERE THEY ARE ───────────────────────────
            LabeledContent(shop.words.callIt("mac.linked_title")) {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(shop.linkedFolders, id: \.self) { path in
                        HStack(spacing: 6) {
                            let here = FileManager.default.fileExists(atPath: path)
                            Image(systemName: here ? "folder" : "externaldrive.badge.exclamationmark")
                                .foregroundStyle(here ? AnyShapeStyle(.secondary) : AnyShapeStyle(Khayt.attention))
                            Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                                .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Button(shop.words.callIt("mac.linked_unlink") + "\u{2026}") { unlinking = path }
                                .controlSize(.small)
                        }
                    }
                    HStack {
                        Button(shop.words.callIt("mac.linked_link") + "\u{2026}") { chooseLinked() }
                        if !shop.linkedFolders.isEmpty {
                            Button(shop.words.callIt("mac.linked_rescan")) { Task { await shop.rescanLinkedFolders() } }
                        }
                    }
                    .disabled(shop.libraryMoveBusy || !shop.canMoveJobs)
                }
            }
            Text(shop.words.callIt("mac.linked_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let p = shop.libraryMoveProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                    Text(shop.words.callIt("mac.cloudlib_progress", ["name": .string(p.name), "done": .number(Double(p.done)),
                                                                     "total": .number(Double(p.total))]))
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                }
            } else if shop.libraryMoveBusy {
                ProgressView().controlSize(.small)
            }
            if let note = shop.libraryMoveNote {
                Label(note, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Khayt.done)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = shop.libraryMoveProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(shop.words.callIt("mac.libmove_confirm_title"),
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(shop.words.callIt("mac.libmove_confirm")) {
                if let to = pending { Task { await shop.moveLibrary(to: to) } }
                pending = nil
            }
            Button(shop.words.callIt("common.cancel"), role: .cancel) { pending = nil }
        } message: {
            Text(shop.words.callIt("mac.libmove_confirm_body",
                                   ["path": .string(((pending?.path ?? "") as NSString).abbreviatingWithTildeInPath)]))
        }
        // Unlinking drops every model indexed from the folder — with the tags,
        // notes and pictures the shop gave them — and there is no undo.
        .askFirst($unlinking,
                  title: { shop.words.callIt("mac.unlink_folder_q",
                                             ["name": .string(($0 as NSString).abbreviatingWithTildeInPath)]) },
                  message: { _ in shop.words.callIt("mac.unlink_folder_note") + " "
                                  + shop.words.callIt("mac.no_undo") },
                  confirm: shop.words.callIt("mac.linked_unlink"),
                  cancel: shop.words.callIt("common.cancel")) { path in
            Task { await shop.unlinkFolder(path) }
        }
    }

    private func chooseLinked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = shop.words.callIt("mac.linked_link")
        if panel.runModal() == .OK, let url = panel.url { Task { await shop.linkFolder(url) } }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = shop.words.callIt("mac.libmove_choose_prompt")
        if panel.runModal() == .OK, let url = panel.url { pending = url }
    }
}

/// Why the buttons above it are grey, when it is because this Mac may not
/// change the book: another app has it open, or it is the sample shop.
/// Disabled with no reason given, a shop reads a broken screen.
struct BookLockedNote: View {
    let shop: Shop

    var body: some View {
        Label(shop.words.callIt(shop.source.isReal ? "mac.group_locked" : "mac.settings_sample"),
              systemImage: "lock")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
