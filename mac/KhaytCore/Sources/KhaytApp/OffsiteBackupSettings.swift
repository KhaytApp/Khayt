import SwiftUI
import AppKit
import KhaytCore

/// Settings → Preferences → Off-site backup.
///
/// Saves ITSELF, like the online storage section above it: every choice
/// here is this Mac's (see `OffsiteBackupState`), so there is no draft of the
/// book to save. What it SAYS matters more than what it sets: where the book
/// would go, by name; whether it can be encrypted, and why not; and when it
/// last went, how big it was, and whether it is failing.
struct OffsiteBackupSettings: View {
    let shop: Shop
    @State private var summary: (ready: Bool, text: String)?
    @State private var restoring = false

    private struct SummaryKey: Equatable {
        let settings: OffsiteBackupState.Settings
        let book: JSONValue
    }

    var body: some View {
        @Bindable var state = shop.offsite
        Section(shop.words.callIt("mac.offsite_title")) {
            Text(shop.words.callIt("mac.offsite_why"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(shop.words.callIt("mac.offsite_on"), isOn: $state.settings.enabled)
            Picker(shop.words.callIt("mac.offsite_where"), selection: $state.settings.destination) {
                Text(shop.words.callIt("mac.offsite_dest_folder")).tag(OffsiteBackupState.Destination.folder)
                Text(shop.words.callIt("mac.offsite_dest_bucket")).tag(OffsiteBackupState.Destination.bucket)
                Text(verbatim: "Google Drive").tag(OffsiteBackupState.Destination.drive)
            }
            if state.settings.destination == .folder {
                HStack {
                    Button(shop.words.callIt("mac.offsite_choose")) { choose() }
                    Button(shop.words.callIt("mac.offsite_icloud")) {
                        state.settings.folderPath = OffsiteBackupState.iCloudFolder.path
                    }
                }
            }
            if let summary {
                Label(summary.text, systemImage: summary.ready ? "externaldrive" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(summary.ready ? AnyShapeStyle(.secondary) : AnyShapeStyle(Khayt.attention))
                    .lineLimit(3).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // THE REFUSAL, SAID WHERE THE SWITCH IS. Nothing leaves this Mac
            // unencrypted, and a switch that is on and silently does nothing
            // is the worst kind of backup.
            if let why = shop.offsiteKeyProblem {
                Label(why, systemImage: "lock.slash")
                    .font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(shop.words.callIt("mac.offsite_encrypted"), systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            lastLine(state.status)
            if let problem = state.problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = state.note {
                Text(note).font(.callout).foregroundStyle(Khayt.done)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(shop.words.callIt("mac.offsite_now")) {
                    Task { await shop.runOffsiteBackup() }
                }
                .disabled(state.busy || shop.offsiteKeyProblem != nil || summary?.ready != true)
                Button(shop.words.callIt("mac.offsite_restore")) { restoring = true }
                    .disabled(state.busy || shop.offsiteKeyProblem != nil || summary?.ready != true)
                if state.busy { ProgressView().controlSize(.small) }
            }
        }
        // Asked again when the choice changes AND when the book's settings do
        // — setting up the library's bucket above makes it ready here.
        .task(id: SummaryKey(settings: state.settings, book: shop.settingsValue)) {
            summary = await shop.offsiteDestinationSummary()
        }
        .sheet(isPresented: $restoring) { OffsiteRestoreSheet(shop: shop) }
    }

    @ViewBuilder
    private func lastLine(_ status: OffsiteBackup.Status) -> some View {
        if let at = status.lastAt {
            Label(shop.words.callIt("mac.offsite_last", [
                    "when": .string(shop.words.say(at, Date.FormatStyle(date: .abbreviated, time: .shortened))),
                    "size": .string(ByteCountFormatter.string(fromByteCount: Int64(status.lastBytes ?? 0),
                                                              countStyle: .file))]),
                  systemImage: "clock.arrow.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Label(shop.words.callIt("mac.offsite_never"), systemImage: "clock.arrow.circlepath")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let since = status.failingSince, let why = status.lastError {
            Label(shop.words.callIt("mac.offsite_failing", [
                    "when": .string(shop.words.say(since, Date.FormatStyle(date: .abbreviated, time: .shortened))),
                    "why": .string(why)]),
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Khayt.attention)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = shop.words.callIt("mac.offsite_choose_prompt")
        if panel.runModal() == .OK, let url = panel.url {
            shop.offsite.settings.folderPath = url.standardizedFileURL.path
        }
    }
}

/// Choosing an off-site backup to put back.
///
/// The list comes from the destination, so this is also the sheet a NEW Mac
/// uses: sign in to Khayt Cloud with the passphrase, point this at the same
/// bucket, Drive or folder, and the book comes back. What happens on Restore
/// is `Restore`'s — it validates the file and copies the book as it stands
/// first — and the sheet says so, as the local restore sheet does.
struct OffsiteRestoreSheet: View {
    let shop: Shop
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [OffsiteBackup.Entry] = []
    @State private var loading = true
    @State private var chosen: OffsiteBackup.Entry.ID?
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.offsite_restore_title")).font(.headline)
            Text(shop.words.callIt("mac.offsite_restore_explain"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text(shop.words.callIt("mac.offsite_loading")) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    Text(shop.words.callIt("mac.offsite_none"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(entries, selection: $chosen) { entry in
                        HStack {
                            Text(verbatim: entry.day ?? entry.name).monospacedDigit()
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(entry.id)
                    }
                    .listStyle(.bordered)
                }
            }
            // Fixed: a sheet cannot be moved, so its buttons must stay on a
            // small screen however many backups there are.
            .frame(height: 220)

            Text(shop.words.callIt("mac.restore_what"))
                .fixedSize(horizontal: false, vertical: true)
            Text(shop.words.callIt("mac.restore_safety"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.restore_do"), role: .destructive) {
                    guard let entry = entries.first(where: { $0.id == chosen }) else { return }
                    working = true
                    Task {
                        if await shop.restoreOffsite(entry) { dismiss() }
                        problem = shop.offsite.problem
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { entries = try await shop.offsiteBackups() }
        catch { problem = shop.offsiteSay(error) }
    }
}
