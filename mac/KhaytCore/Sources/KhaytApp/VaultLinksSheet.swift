import SwiftUI
import KhaytCore

/// Every private share link the shop has made: what it shares, how many
/// downloads are used and left, when it ends, whether it was revoked, and who
/// opened it lately (a country and a kind of device; the cloud keeps no
/// address and no browser name).
///
/// ── ONE ROW, ONE OVERFLOW ─────────────────────────────────────────────────
///
/// The library's action pattern: the one thing a shop does most (Copy link)
/// stands in the row, everything else is in one menu beside it, and the one
/// thing that cannot be undone — Revoke — is last in that menu, after a
/// divider, and asks first.
///
/// "Copy link" is offered only on the Mac that made the link, because only
/// that Mac's Keychain holds its secret (`VaultLinkSecret`). Everything else
/// works from any device of the shop.
struct VaultLinksSheet: View {
    let shop: Shop

    @State private var grants: [VaultClient.Grant] = []
    @State private var names: [String: String] = [:]
    @State private var notes: [String: String] = [:]
    @State private var local: [String: VaultLinks.Local] = [:]
    @State private var loading = true
    @State private var problem: String?

    private var words: Words { shop.words }

    /// `preloaded` draws these grants without asking the cloud: for a
    /// photograph, where no `.task` runs.
    init(shop: Shop, preloaded: [VaultClient.Grant]? = nil, names: [String: String] = [:]) {
        self.shop = shop
        _grants = State(initialValue: preloaded ?? [])
        _names = State(initialValue: names)
        _loading = State(initialValue: preloaded == nil)
    }

    var body: some View {
        SheetFrame(width: 560) {
            HStack {
                Text(words.callIt("mac.vl_links_title")).font(.headline)
                Spacer()
                Button(words.callIt("mac.vl_refresh")) { Task { await load() } }
                    .disabled(loading)
            }
            if loading && grants.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if grants.isEmpty && problem == nil {
                Text(words.callIt("mac.vl_none"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(grants) { g in
                VaultGrantRow(shop: shop, grant: g, names: names, note: notes[g.grantId],
                              local: local[g.grantId] ?? .none) { updated in
                    if let i = grants.firstIndex(where: { $0.grantId == updated.grantId }) { grants[i] = updated }
                    if updated.state != .ok { local[updated.grantId] = VaultLinks.Local.none }
                }
                Divider()
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack {
                Spacer()
                Button(words.callIt("common.close")) { shop.showingVaultLinks = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        // Not when it was handed its grants (a photograph).
        .task { if loading { await load() } }
    }

    private func load() async {
        loading = true
        problem = nil
        defer { loading = false }
        guard let engine = await shop.vaultLinkEngine() else {
            problem = words.callIt("mac.vl_err_vault_off")
            return
        }
        do {
            // `tidy`: a link no longer live has its secret forgotten, and a
            // half-made one left pending too long is revoked.
            let (list, states) = await engine.links.tidy(try await engine.links.list())
            try? await engine.remote.sync.pull()
            names = await shop.vaultFileNames(engine.remote)
            var n: [String: String] = [:]
            for g in list {
                if let text = engine.links.note(g) { n[g.grantId] = text }
            }
            grants = list; notes = n; local = states
        } catch {
            problem = shop.linkProblem(error)
        }
    }
}

/// One link in the list.
struct VaultGrantRow: View {
    let shop: Shop
    let grant: VaultClient.Grant
    let names: [String: String]
    let note: String?
    /// What this Mac knows: Copy Link only when `.copyable`; `.incomplete` is
    /// a half-made link, shown as such, with Revoke.
    let local: VaultLinks.Local
    let changed: (VaultClient.Grant) -> Void

    @State private var showingActivity = false
    @State private var events: [VaultClient.GrantEvent]?
    @State private var askingRevoke = false
    @State private var working = false
    @State private var problem: String?
    @State private var told: String?

    private var words: Words { shop.words }
    private var live: Bool { grant.state == .ok }
    private var incomplete: Bool { live && local == .incomplete }

    /// The note the shop wrote, else the first files' names.
    private var title: String {
        if let note, !note.isEmpty { return note }
        let files = grant.items.compactMap { names[$0.fileId] }
        guard let first = files.first else { return Shop.say(words, "mac.vl_n_files", grant.items.count) }
        return files.count == 1 ? first
            // The name ISOLATED: a Latin file name at the start of an
            // Arabic sentence otherwise turns the whole line left to right.
            : words.callIt("mac.vl_and_more", ["name": .string("\u{2068}" + first + "\u{2069}"),
                                               "n": .number(Double(files.count - 1))])
    }

    private var stateWord: String {
        if incomplete { return words.callIt("mac.vl_state_incomplete") }
        switch grant.state {
        case .ok: return words.callIt("mac.vl_state_ok")
        case .revoked: return words.callIt("mac.vl_state_revoked")
        case .expired: return words.callIt("mac.vl_state_expired")
        case .usedUp: return words.callIt("mac.vl_state_used_up")
        case .unknown: return words.callIt("mac.vl_state_unknown")
        }
    }

    private func date(_ iso: String?) -> String? {
        iso.flatMap(Calendar.instant).map { words.say($0, .dateTime.day().month().year().hour().minute()) }
    }

    private var downloadsLine: String {
        guard grant.limits.maxDownloads != nil, let left = grant.remaining else {
            return words.callIt("mac.vl_used_no_limit", ["used": .number(Double(grant.used))])
        }
        return words.callIt("mac.vl_used_left", ["used": .number(Double(grant.used)), "left": .number(Double(left))])
    }

    private var endLine: String {
        if let revoked = date(grant.revokedAt) { return words.callIt("mac.vl_revoked_on", ["date": .string(revoked)]) }
        if let end = date(grant.expiresAt) { return words.callIt("mac.vl_ends_on", ["date": .string(end)]) }
        if grant.limits.validForSec != nil, grant.firstOpenAt == nil { return words.callIt("mac.vl_ends_after_open") }
        return words.callIt("mac.vl_no_end")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                if grant.password {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(words.callIt("mac.vl_has_password"))
                }
                Spacer()
                Text(stateWord)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(incomplete ? Khayt.attention.opacity(0.15)
                                               : live ? Khayt.done.opacity(0.15) : Color.secondary.opacity(0.15)))
                    .foregroundStyle(incomplete ? Khayt.attention : live ? Khayt.done : .secondary)
            }
            Text([Shop.say(words, "mac.vl_n_files", grant.items.count), downloadsLine, endLine].joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if incomplete {
                Text(words.callIt("mac.vl_incomplete_explain"))
                    .font(.caption).foregroundStyle(Khayt.attention).fixedSize(horizontal: false, vertical: true)
            }
            // The row's actions: one primary, then one overflow.
            HStack(spacing: 8) {
                if live && local == .copyable {
                    Button(words.callIt("mac.vl_copy_link")) { Task { await copy() } }
                }
                Button(words.callIt(showingActivity ? "mac.vl_hide_activity" : "mac.vl_activity")) {
                    showingActivity.toggle()
                    if showingActivity && events == nil { Task { await loadEvents() } }
                }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                if live {
                    Menu {
                        // A half-made link is only for revoking.
                        if !incomplete {
                            Button(Shop.say(words, "mac.vl_add_downloads", 5)) { Task { await addDownloads(5) } }
                            Button(Shop.say(words, "mac.vl_add_downloads", 25)) { Task { await addDownloads(25) } }
                            Divider()
                            Button(Shop.say(words, "mac.vl_extend_days", 7)) { Task { await extend(days: 7) } }
                            Button(Shop.say(words, "mac.vl_extend_days", 30)) { Task { await extend(days: 30) } }
                            Button(words.callIt("mac.vl_remove_end")) { Task { await extend(days: nil) } }
                            Divider()
                        }
                        Button(words.callIt("mac.vl_revoke") + "\u{2026}", role: .destructive) { askingRevoke = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(working || !shop.canWrite)
                    .help(words.callIt("mac.vl_more"))
                    .accessibilityLabel(words.callIt("mac.vl_more"))
                }
            }
            if let told {
                Text(told).font(.caption).foregroundStyle(Khayt.done)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showingActivity { activity }
        }
        .padding(.vertical, 4)
        .confirmationDialog(words.callIt("mac.vl_revoke_title"), isPresented: $askingRevoke) {
            Button(words.callIt("mac.vl_revoke"), role: .destructive) { Task { await revoke() } }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        } message: {
            Text(words.callIt("mac.vl_revoke_explain"))
        }
    }

    @ViewBuilder private var activity: some View {
        if let events {
            if events.isEmpty {
                Text(words.callIt("mac.vl_no_activity")).font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events.prefix(10)) { e in
                        Text(eventLine(e)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 8)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func eventLine(_ e: VaultClient.GrantEvent) -> String {
        let kind = ["open", "ticket", "refused"].contains(e.kind) ? e.kind : "other"
        var parts = [words.callIt("mac.vl_event_" + kind)]
        if let f = e.fileId, let name = names[f] { parts.append(name) }
        if let d = e.deviceClass {
            parts.append(words.callIt("mac.vl_device_" + (["phone", "tablet", "computer"].contains(d) ? d : "other")))
        }
        if let c = e.country, c.count == 2 {
            parts.append(words.locale.localizedString(forRegionCode: c) ?? c)
        }
        if let when = date(e.at) { parts.append(when) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Acting

    private func run(_ body: (VaultLinks) async throws -> VaultClient.Grant?) async {
        working = true; problem = nil; told = nil
        defer { working = false }
        guard let engine = await shop.vaultLinkEngine() else {
            problem = words.callIt("mac.vl_err_vault_off")
            return
        }
        do { if let g = try await body(engine.links) { changed(g) } }
        catch { problem = shop.linkProblem(error) }
    }

    private func copy() async {
        await run { links in
            if let link = await links.link(grant.grantId) {
                shop.copyLink(link)
                told = words.callIt("mac.copied")
            } else {
                problem = words.callIt("mac.vl_err_other_mac")
            }
            return nil
        }
    }

    private func addDownloads(_ n: Int) async {
        await run { try await $0.addDownloads(grant.grantId, n) }
    }

    /// From the later of now and the current end, so extending never shortens.
    private func extend(days: Int?) async {
        await run { links in
            guard let days else { return try await links.extend(grant.grantId, to: nil) }
            let now = Date()
            let base = max(now, grant.expiresAt.flatMap(Calendar.instant) ?? now)
            guard let end = Calendar.book.date(byAdding: .day, value: days, to: base) else { return nil }
            return try await links.extend(grant.grantId, to: end)
        }
    }

    private func revoke() async {
        await run { try await $0.revoke(grant.grantId) }
    }

    private func loadEvents() async {
        guard let engine = await shop.vaultLinkEngine() else { events = []; return }
        do { events = try await engine.links.events(grant.grantId) }
        catch { events = []; problem = shop.linkProblem(error) }
    }
}
