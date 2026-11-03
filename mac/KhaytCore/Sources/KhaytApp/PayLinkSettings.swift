import SwiftUI
import KhaytCore

/// Settings › Online › Payment link: the shop's own provider link, shown to
/// the customer on their tracking page as Pay deposit / Pay balance / Pay.
///
/// Anyone signed in sees it; the owner or a manager can change it (the cloud
/// answers 403 `role` to anyone else, and unknown is no here, as for the team).
/// The cloud's own `bad-pay-link` sentence is shown as it is.
///
/// Plain text fields, not pickers: a fixed-size control in a grouped Form
/// widens the whole pane.
struct PayLinkSettings: View {
    let shop: Shop

    @State private var url = ""
    @State private var label = ""
    /// What the cloud holds now, to know whether Save/Remove mean anything.
    @State private var saved: CloudPayLink.Link?
    @State private var loaded = false
    @State private var busy = false
    @State private var problem: String?
    @State private var note: String?

    private var mayWrite: Bool { shop.cloudCanManageEmbed }
    private var changed: Bool {
        url.trimmingCharacters(in: .whitespaces) != (saved?.url ?? "")
            || label.trimmingCharacters(in: .whitespaces) != (saved?.label ?? "")
    }

    var body: some View {
        Section(shop.words.callIt("mac.paylink_title")) {
            LabeledContent(shop.words.callIt("mac.paylink_url")) {
                TextField("", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .autocorrectionDisabled()
                    .disabled(!mayWrite || busy)
            }
            LabeledContent(shop.words.callIt("mac.paylink_label")) {
                TextField("", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .disabled(!mayWrite || busy)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(!mayWrite || busy || !changed
                              || url.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(shop.words.callIt("mac.team_remove"), role: .destructive) { Task { await remove() } }
                    .disabled(!mayWrite || busy || saved == nil)
                if busy { ProgressView().controlSize(.small) }
            }
            if !mayWrite && loaded {
                Text(shop.words.callIt("mac.paylink_role")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            Text(shop.words.callIt("mac.paylink_note"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await load() }
    }

    private func adopt(_ link: CloudPayLink.Link?) {
        saved = link
        url = link?.url ?? ""
        label = link?.label ?? ""
    }

    private func load() async {
        defer { loaded = true }
        guard let (c, t) = await shop.vaultSession() else { return }
        do {
            adopt(try await CloudPayLink.get(c, token: t, fetch: Shop.plansFetch))
            problem = nil
        } catch {
            problem = said(error)
        }
    }

    private func save() async {
        guard let (c, t) = await shop.vaultSession() else { return }
        busy = true; defer { busy = false }
        do {
            adopt(try await CloudPayLink.put(url: url, label: label, c, token: t, fetch: Shop.plansFetch))
            problem = nil
            note = shop.words.callIt("mac.paylink_saved")
        } catch {
            problem = said(error); note = nil
        }
    }

    private func remove() async {
        guard let (c, t) = await shop.vaultSession() else { return }
        busy = true; defer { busy = false }
        do {
            try await CloudPayLink.remove(c, token: t, fetch: Shop.plansFetch)
            adopt(nil)
            problem = nil
            note = shop.words.callIt("mac.paylink_removed")
        } catch {
            problem = said(error); note = nil
        }
    }

    /// The cloud's own sentence for a link it refused; a role refusal in the
    /// shop's language.
    private func said(_ error: Error) -> String {
        if let r = error as? CloudPayLink.Refusal {
            if r.reason == "role" { return shop.words.callIt("mac.paylink_role") }
            if !r.error.isEmpty { return r.error }
        }
        return ErrorText.plain(error)
    }
}
