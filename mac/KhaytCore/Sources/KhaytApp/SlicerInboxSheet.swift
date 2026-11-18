import AppKit
import SwiftUI
import KhaytCore

/// The "From slicer" inbox: what a slicer sent through the OctoPrint upload
/// (`LanServer+SlicerUpload`), with the slicer's own grams and time, and the
/// three things a shop does with one — the shape of `OnlineOrdersSheet`.
struct SlicerInboxSheet: View {
    @Bindable var shop: Shop
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(width: 520) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.su_title")).font(.headline)
                Text(shop.words.callIt("mac.su_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = shop.slicerInboxProblem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let said = shop.slicerInboxSaid {
                Label(said, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Khayt.done)
            }
            if shop.slicerUploads.isEmpty {
                Text(shop.words.callIt("mac.su_none")).font(.callout).foregroundStyle(.secondary)
            } else {
                SlicerInboxRows(shop: shop)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .task {
            shop.slicerInboxProblem = nil
            shop.slicerInboxSaid = nil
            shop.refreshSlicerInbox()
        }
    }

    /// "146 g · 4h 32m · PLA · OrcaSlicer", or why there is nothing to say.
    @MainActor static func figures(_ item: SlicerUpload, words: Words) -> String {
        var bits: [String] = []
        if let g = item.grams { bits.append(PrintFigures.weight(g, words)) }
        if let m = item.minutes { bits.append(PrintFigures.duration(minutes: m, words)) }
        guard !bits.isEmpty else { return words.callIt("mac.su_no_figures") }
        if let material = item.material { bits.append(material) }
        if let slicer = item.slicer { bits.append(slicer) }
        return bits.joined(separator: " \u{00B7} ")
    }
}

/// The inbox's files and their four actions: the sheet and the Connected apps
/// section show the same rows (one list, one set of rules).
struct SlicerInboxRows: View {
    @Bindable var shop: Shop
    @State private var busy: String?

    var body: some View {
        ForEach(shop.slicerUploads) { item in
            row(item)
            if item.id != shop.slicerUploads.last?.id { Divider() }
        }
    }

    private func row(_ item: SlicerUpload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                // A file name is an identifier: kept in its own direction.
                Text(Figure.isolated(item.name)).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(shop.words.callIt("mac.su_arrived", ["when": .string(
                    shop.words.say(item.arrived, Date.FormatStyle(date: .abbreviated, time: .shortened)))]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Where it came from, and what a plugin ASKED for (never acted on).
            HStack(spacing: 6) {
                Text(Self.source(item, words: shop.words)).font(.caption).foregroundStyle(.secondary)
                if let asked = Self.asked(item, words: shop.words,
                                          machine: { id in shop.machines.first { $0.id == id }?.name }) {
                    Text(asked).font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Khayt.brand.opacity(0.12)))
                }
            }
            Text(SlicerInboxSheet.figures(item, words: shop.words))
                .font(.callout).foregroundStyle(item.grams == nil && item.minutes == nil ? .secondary : .primary)
                .monospacedDigit()
            HStack(spacing: 8) {
                Button(shop.words.callIt("mac.su_add")) { take(item, job: nil) }
                Button(shop.words.callIt("mac.su_job")) { take(item, job: false) }
                Button(shop.words.callIt("mac.su_quote")) { take(item, job: true) }
                Spacer()
                if busy == item.id { ProgressView().controlSize(.small) }
                Button(role: .destructive) {
                    shop.discardSlicerUpload(item)
                } label: {
                    Label(shop.words.callIt("mac.su_discard"), systemImage: "trash")
                }
            }
            .controlSize(.small)
            .disabled(busy != nil)
        }
        .padding(.vertical, 2)
    }

    private func take(_ item: SlicerUpload, job asQuote: Bool?) {
        busy = item.id
        Task {
            await shop.takeSlicerUpload(item, job: asQuote)
            busy = nil
        }
    }

    /// "From OrcaSlicer on Studio PC", or the OctoPrint path.
    @MainActor static func source(_ item: SlicerUpload, words: Words) -> String {
        guard item.source == "connector" else { return words.callIt("mac.su_from_octo") }
        let name = ConnectedApps.name(item.connectorName ?? "", words)
        return words.callIt("mac.su_from_app", ["name": .string(name)])
    }

    /// What a paired plugin asked for: shown, never done (inbox-first).
    /// `machine`: a machine's name by id, for "Asked: print on U1-01".
    @MainActor static func asked(_ item: SlicerUpload, words: Words,
                                 machine: (String) -> String? = { _ in nil }) -> String? {
        guard case .object(let s)? = item.suggested, case .string(let intent)? = s["intent"] else { return nil }
        switch intent {
        case "quote": return words.callIt("mac.su_asked_quote")
        case "job": return words.callIt("mac.su_asked_job")
        case "print":
            // The machine by the name the shop knows it; an id it no longer
            // has is left unsaid rather than shown as a code.
            if case .string(let id)? = s["machineId"], let name = machine(id), !name.isEmpty {
                return words.callIt("mac.su_asked_print_on", ["machine": .string(name)])
            }
            return words.callIt("mac.su_asked_print")
        case "attach":
            guard case .string(let job)? = s["jobId"] else { return nil }
            return words.callIt("mac.su_asked_attach", ["job": .string(job)])
        default: return nil
        }
    }
}

/// The switch, the address and the key a slicer is given — in the Online
/// pane, under the LAN server it rides on. Saves itself as it changes: the
/// switch and the key are this Mac's (`SlicerKey`), not the book's, so the
/// pane's Save bar is not their business.
struct SlicerUploadSection: View {
    let shop: Shop
    @State private var accepting = SlicerKey.accepting
    @State private var key: String?
    @State private var copied = false
    private var canEdit: Bool { shop.permitted("settings", "edit") }

    var body: some View {
        Section(shop.words.callIt("mac.su_settings_title")) {
            Toggle(shop.words.callIt("mac.su_accept"), isOn: $accepting)
                .disabled(!canEdit)
                .onChange(of: accepting) { _, on in
                    SlicerKey.accepting = on
                    if on { key = SlicerKey.current() }
                }
            Text(shop.words.callIt("mac.su_accept_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if accepting {
                if let url = shop.lanURL, shop.lanRunning?.bindLan == true {
                    LabeledContent(shop.words.callIt("mac.su_address")) {
                        Text(String(url.dropLast(url.hasSuffix("/") ? 1 : 0)))
                            .font(.body.monospaced()).textSelection(.enabled)
                    }
                } else {
                    Label(shop.words.callIt("mac.su_needs_lan"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The key lets anyone on the network send files into the
                // book: shown to those who may change settings, not to an
                // operator who may only look at them.
                if !canEdit {
                    EmptyView()
                } else if let key {
                    LabeledContent(shop.words.callIt("mac.su_key")) {
                        HStack(spacing: 8) {
                            Text(key).font(.body.monospaced()).textSelection(.enabled)
                                .accessibilityIdentifier("slicer-key")
                            Button(shop.words.callIt("mac.su_copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(key, forType: .string)
                                copied = true
                            }
                            if copied { Image(systemName: "checkmark").foregroundStyle(Khayt.done) }
                            Button(shop.words.callIt("mac.su_regenerate")) {
                                self.key = SlicerKey.regenerate()
                                copied = false
                            }
                        }
                        .controlSize(.small)
                    }
                    Text(shop.words.callIt("mac.su_regenerate_note"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(shop.words.callIt("mac.su_no_key"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Khayt.attention)
                }
            }
        }
        .task { if accepting, canEdit { key = SlicerKey.current() } }
    }
}
