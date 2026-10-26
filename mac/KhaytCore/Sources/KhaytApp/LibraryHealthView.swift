import AppKit
import SwiftUI
import KhaytCore

/// ── LIBRARY HEALTH ───────────────────────────────────────────────────────
///
/// Manyfold's Troubleshoot page, for a print shop: what is wrong with the
/// library, a group at a time, each with how many, one plain sentence, and
/// the fix — a button that goes through a door the app already has
/// (`Shop+LibraryHealth.swift`). Drawn IN the library screen, over the grid
/// and its filter row, so the inspector beside it still shows a model, and
/// Back to Library returns to the grid as it was. Reached from View ▸ Library
/// Health and from the bottom of the Show menu.
///
/// Nothing is changed by looking. Nothing is ever merged.
struct LibraryHealthView: View {
    @Bindable var shop: Shop
    @State private var askMeasureOnline = false
    /// A group's model list opened past its first few.
    @State private var opened: Set<LibraryHealth.Kind> = []

    static let shown = 5

    private var w: Words { shop.words }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let note = shop.libraryHealthNote {
                    Label(note, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let groups = shop.libraryHealthGroups {
                    if groups.isEmpty {
                        allGood
                    } else {
                        ForEach(groups, id: \.kind) { card($0) }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(w.callIt("mac.lh_checking")).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Metric.screen + 6)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Again whenever the book changes: `files` is observed, and its
        // revision (not observed itself) tells one load from the next.
        .task(id: "\(shop.files.count)|\(shop.filesRevision)") { await shop.checkLibraryHealth() }
        // And when a drive, share or card comes or goes: a model on it is
        // unreachable while it is away and back where it was once it returns.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await shop.checkLibraryHealth() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await shop.checkLibraryHealth() }
        }
        .confirmationDialog(w.callIt("mac.measure_online_q"), isPresented: $askMeasureOnline) {
            Button(w.callIt("mac.measure_online")) { Task { await shop.measureOnlineFromHealth() } }
            Button(w.callIt("common.cancel"), role: .cancel) {}
        } message: {
            let due = shop.onlineUnmeasured
            Text(w.callIt(due.count == 1 ? "mac.measure_online_body_single" : "mac.measure_online_body",
                          ["n": .number(Double(due.count)), "size": .string(Format.bytes(Double(due.bytes)))]))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(w.callIt("mac.lh_title"), systemImage: "stethoscope")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 8)
                if shop.libraryHealthBusy || shop.libraryMoveBusy { ProgressView().controlSize(.small) }
                Button(w.callIt("mac.lh_check_again")) { Task { await shop.checkLibraryHealth() } }
                    .disabled(shop.libraryHealthBusy)
                Button(w.callIt("mac.lh_back")) { shop.libraryHealthOpen = false }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            Text(w.callIt("mac.lh_intro"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allGood: some View {
        Label(w.callIt("mac.lh_all_good"), systemImage: "checkmark.seal")
            .font(.callout)
            .foregroundStyle(Khayt.done)
            .fixedSize(horizontal: false, vertical: true)
            .card(rail: Khayt.done)
    }

    // MARK: One group

    private func card(_ group: LibraryHealth.Group) -> some View {
        let look = Self.look(group.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: look.symbol).foregroundStyle(look.rail ?? Color.secondary)
                Text(w.callIt(look.title)).font(.headline)
                Text(w.numeral(group.count))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Khayt.recessed, in: Capsule())
                Spacer(minLength: 0)
            }
            Text(w.callIt(look.sentence))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if group.kind == .looksSame {
                Label(w.callIt("mac.lh_mirror_note"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            contents(group)
            fixes(group)
        }
        // A neutral rail for a group with no colour of its own, so every card
        // starts its text on the same line.
        .card(rail: look.rail ?? Color(nsColor: .separatorColor))
    }

    /// What is in the group: models by name, copies by set, products by name.
    @ViewBuilder private func contents(_ group: LibraryHealth.Group) -> some View {
        let all = opened.contains(group.kind)
        switch group.kind {
        case .orphanProducts:
            let ids = all ? group.productIds : Array(group.productIds.prefix(Self.shown))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        Text(shop.healthProductName(id)).font(.callout).lineLimit(1)
                        Spacer(minLength: 8)
                        Button(w.callIt("mac.lh_open")) { Task { await shop.openHealthProduct(id) } }
                            .controlSize(.small)
                            .disabled(!shop.canWrite)
                    }
                }
            }
            more(group, total: group.productIds.count)
        case .sameFile, .looksSame:
            let titles = Dictionary(shop.healthFiles(group).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            let sets = all ? group.clusters : Array(group.clusters.prefix(Self.shown))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sets.enumerated()), id: \.offset) { _, set in
                    Text(set.map { titles[$0] ?? $0 }.joined(separator: "  \u{2194}  "))
                        .font(.callout).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            more(group, total: group.clusters.count)
        default:
            // A missing COMPRESSED FILE is one line, however many models it
            // held — its Locate finds the archive and moves them all.
            let held = Set(group.archives.flatMap(\.modelIds))
            let byId = Dictionary(shop.healthFiles(group).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if !group.archives.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.archives, id: \.path) { gone in
                        HStack(spacing: 8) {
                            Label(w.callIt("mac.lh_arc_row",
                                           ["name": .string((gone.path as NSString).lastPathComponent),
                                            "models": .string(w.counting(gone.modelIds.count, "mac.n_models"))]),
                                  systemImage: "doc.zipper")
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            if let first = gone.modelIds.first.flatMap({ byId[$0] }) {
                                Button(w.callIt("mac.lh_locate") + "\u{2026}") { Task { await shop.locateMissing(first) } }
                                    .controlSize(.small)
                                    .disabled(!shop.canWrite)
                            }
                        }
                    }
                }
            }
            let files = shop.healthFiles(group).filter { !held.contains($0.id) }
            let rows = all ? files : Array(files.prefix(Self.shown))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { file in
                    HStack(spacing: 8) {
                        Text(file.title).font(.callout).lineLimit(1).truncationMode(.middle)
                        if let folder = file.groupName {
                            Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if group.kind == .missing {
                            Button(w.callIt("mac.lh_locate") + "\u{2026}") { Task { await shop.locateMissing(file) } }
                                .controlSize(.small)
                                .disabled(!shop.canWrite)
                        }
                    }
                }
            }
            more(group, total: files.count)
        }
    }

    @ViewBuilder private func more(_ group: LibraryHealth.Group, total: Int) -> some View {
        if total > Self.shown {
            let open = opened.contains(group.kind)
            Button(open ? w.callIt("mac.lh_fewer")
                        : w.callIt("mac.delete_and_more", ["n": .number(Double(total - Self.shown))])) {
                if open { opened.remove(group.kind) } else { opened.insert(group.kind) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    /// The one-click fixes. Every one is a door the app already had.
    @ViewBuilder private func fixes(_ group: LibraryHealth.Group) -> some View {
        HStack(spacing: 8) {
            switch group.kind {
            case .missing, .deletedByPlan:
                // Deleted by the plan limit: no Locate anywhere on the card —
                // there are no bytes left to find. Remove is the fix.
                Button(w.callIt("mac.lh_show")) { shop.showHealthGroup(group) }
                Button(w.callIt("mac.lh_remove") + "\u{2026}", role: .destructive) {
                    shop.askToRemoveHealthGroup(group)
                }
                .disabled(!shop.canWrite)
            case .unreachable:
                // Never Remove: the files are very likely all there, on a
                // drive that is not plugged in.
                Button(w.callIt("mac.lh_show")) { shop.showHealthGroup(group) }
                Button(w.callIt("mac.lh_check_again")) { Task { await shop.checkLibraryHealth() } }
                    .disabled(shop.libraryHealthBusy)
            case .onlineUnmeasured:
                if shop.onlineUnmeasured.count == 0 {
                    // In the bucket, not a linked drive: nothing here can
                    // measure them without bringing them back first.
                    Text(w.callIt("mac.lh_online_bring"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button(w.callIt("mac.measure_online") + "\u{2026}") { askMeasureOnline = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!shop.canWrite || shop.libraryMoveBusy)
                }
                Button(w.callIt("mac.lh_show")) { shop.showHealthGroup(group) }
            case .noFigures:
                Button(w.callIt("mac.lh_measure")) { Task { await shop.measureHealthModels(shop.healthFiles(group)) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!shop.canWrite || shop.libraryHealthBusy)
                Button(w.callIt("mac.lh_show")) { shop.showHealthGroup(group) }
            case .sameFile, .looksSame:
                Button(w.callIt("mac.lh_side_by_side")) { shop.showHealthGroup(group) }
            case .tooBig:
                Button(w.callIt("mac.lh_show")) { shop.showHealthGroup(group) }
            case .unorganised:
                Button(w.callIt("mac.lh_show_select")) { shop.showHealthGroup(group, select: true) }
                    .buttonStyle(.borderedProminent)
            case .orphanProducts:
                Button(w.callIt("mac.lh_catalogue")) { shop.libraryHealthOpen = false; shop.shelf = .catalogue }
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    // MARK: How each group looks

    struct Look {
        let symbol: String
        let title: String
        let sentence: String
        let rail: Color?
    }

    static func look(_ kind: LibraryHealth.Kind) -> Look {
        switch kind {
        case .deletedByPlan:
            Look(symbol: "xmark.icloud", title: "mac.lh_plan_deleted", sentence: "mac.lh_plan_deleted_says",
                 rail: Khayt.late)
        case .missing:
            Look(symbol: "questionmark.folder", title: "mac.lh_missing", sentence: "mac.lh_missing_says", rail: Khayt.late)
        case .unreachable:
            Look(symbol: "externaldrive.badge.xmark", title: "mac.lh_unreachable", sentence: "mac.lh_unreachable_says",
                 rail: Khayt.attention)
        case .onlineUnmeasured:
            Look(symbol: "icloud.slash", title: "mac.lh_online", sentence: "mac.lh_online_says", rail: Khayt.attention)
        case .noFigures:
            Look(symbol: "ruler", title: "mac.lh_no_figures", sentence: "mac.lh_no_figures_says", rail: Khayt.attention)
        case .sameFile:
            Look(symbol: "doc.on.doc", title: "mac.lh_same_file", sentence: "mac.lh_same_file_says", rail: Khayt.note)
        case .looksSame:
            Look(symbol: "square.on.square.dashed", title: "mac.lh_looks_same", sentence: "mac.lh_looks_same_says", rail: Khayt.note)
        case .tooBig:
            Look(symbol: "arrow.up.left.and.arrow.down.right", title: "mac.lh_too_big", sentence: "mac.lh_too_big_says", rail: Khayt.hot)
        case .unorganised:
            Look(symbol: "tag.slash", title: "mac.lh_unorganised", sentence: "mac.lh_unorganised_says", rail: nil)
        case .orphanProducts:
            Look(symbol: "shippingbox", title: "mac.lh_orphans", sentence: "mac.lh_orphans_says", rail: Khayt.late)
        }
    }
}
