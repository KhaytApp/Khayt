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
            Text(shop.words.callIt("mac.libmove_hint"))
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
                            Button(shop.words.callIt("mac.linked_unlink")) { Task { await shop.unlinkFolder(path) } }
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
