import SwiftUI
import KhaytCore

/// Settings › Online › Team and Devices: who is on the shop's Khayt Cloud
/// account, and which signed-in devices hold a token for it.
///
/// Asked for after a leaked store token (Oct 2026): replacing it needs a new
/// viewer account, and seeing whether the old token is still used needs the
/// device list. Both lived only in the desktop's Team dialog
/// (`renderer/settings.js openTeamModal`) and the web dashboard.
///
/// Everyone signed in sees the team. Inviting, removing and the device list
/// are the owner's and a manager's, as the cloud allows; the cloud still
/// decides, and its refusal is shown in its own words.
struct TeamSettings: View {
    let shop: Shop

    @State private var members: [CloudTeam.Member] = []
    @State private var devices: [CloudTeam.Device] = []
    @State private var loaded = false
    /// Signed in to Khayt Cloud: without it, inviting can only fail.
    @State private var connected = false
    @State private var problem: String?
    @State private var note: String?
    @State private var busy = false
    @State private var email = ""
    @State private var role = "operator"
    @State private var removing: CloudTeam.Member?
    @State private var signingOut: CloudTeam.Device?

    private var manages: Bool { shop.cloudCanManageTeam }

    var body: some View {
        Group { sections }
            // On the Group: the task loads both sections at once.
            .task { await load() }
            .confirmationDialog(shop.words.callIt("mac.team_remove_title"),
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                presenting: removing) { m in
                Button(shop.words.callIt("mac.team_remove"), role: .destructive) { Task { await remove(m) } }
                Button(shop.words.callIt("common.cancel"), role: .cancel) {}
            } message: { m in
                Text(shop.words.callIt("mac.team_remove_body", ["email": .string(m.email)]))
            }
            .confirmationDialog(shop.words.callIt("mac.devices_sign_out_title"),
                                isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }),
                                presenting: signingOut) { d in
                Button(shop.words.callIt("mac.devices_sign_out"), role: .destructive) { Task { await signOut(d) } }
                Button(shop.words.callIt("common.cancel"), role: .cancel) {}
            } message: { _ in
                Text(shop.words.callIt("mac.devices_sign_out_body"))
            }
    }

    @ViewBuilder
    private var sections: some View {
        Section(shop.words.callIt("mac.team_title")) {
            if !loaded {
                ProgressView().controlSize(.small)
            }
            ForEach(members) { m in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: m.email).lineLimit(1).truncationMode(.middle)
                        Text(roleName(m.role) + (m.verified == false ? " · " + shop.words.callIt("mac.team_unverified") : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if manages && m.role != "owner" {
                        Button(shop.words.callIt("mac.team_remove"), role: .destructive) { removing = m }
                            .disabled(busy)
                    }
                }
            }
            if manages && connected {
                HStack {
                    TextField(shop.words.callIt("mac.team_email"), text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                    Picker("", selection: $role) {
                        ForEach(CloudTeam.invitableRoles, id: \.self) { Text(roleName($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button(shop.words.callIt("mac.team_invite")) { Task { await invite() } }
                        .disabled(busy || !email.contains("@"))
                }
                Text(shop.words.callIt("mac.team_invite_hint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if manages && !devices.isEmpty {
            Section(shop.words.callIt("mac.devices_title")) {
                Text(shop.words.callIt("mac.devices_explain")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(devices) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: d.isShopKey ? shop.words.callIt("mac.devices_shop_key")
                                                       : (d.account ?? shop.words.callIt("mac.devices_owner")))
                                .lineLimit(1).truncationMode(.middle)
                            Text(deviceLine(d)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if d.current == true {
                            Text(shop.words.callIt("mac.devices_this_mac")).font(.caption).foregroundStyle(.secondary)
                        } else if !d.isShopKey {
                            Button(shop.words.callIt("mac.devices_sign_out"), role: .destructive) { signingOut = d }
                                .disabled(busy)
                        }
                    }
                }
            }
        }
    }

    private func roleName(_ role: String) -> String {
        ["owner", "manager", "operator", "viewer"].contains(role) ? shop.words.callIt("mac.team_role_" + role) : role
    }

    private func deviceLine(_ d: CloudTeam.Device) -> String {
        var parts: [String] = []
        if let r = d.role { parts.append(roleName(r)) }
        if let c = d.createdAt, !c.isEmpty {
            parts.append(shop.words.callIt("mac.devices_since", ["day": .string(Calendar.localDay(ofInstant: c))]))
        }
        parts.append(d.lastUsedOn.map { shop.words.callIt("mac.devices_last_used", ["day": .string($0)]) }
                     ?? shop.words.callIt("mac.devices_never_used"))
        return parts.joined(separator: " · ")
    }

    // MARK: - Asking the cloud

    private func session() async -> (CloudReader.Connection, String)? {
        guard let s = await shop.vaultSession() else {
            connected = false
            problem = shop.words.callIt("mac.team_sign_in"); return nil
        }
        connected = true
        return s
    }

    private func load() async {
        defer { loaded = true }
        guard let (c, t) = await session() else { return }
        do {
            members = try await CloudTeam.members(c, token: t, fetch: Shop.plansFetch)
            devices = manages ? try await CloudTeam.devices(c, token: t, fetch: Shop.plansFetch) : []
            problem = nil
        } catch {
            // Cleared, not kept: a list from before a removal or a sign-out
            // would show someone as still there.
            members = []; devices = []
            problem = said(error)
        }
    }

    private func invite() async {
        guard let (c, t) = await session() else { return }
        busy = true; defer { busy = false }
        let address = email.trimmingCharacters(in: .whitespaces)
        do {
            let emailed = try await CloudTeam.invite(address, role: role, c, token: t, fetch: Shop.plansFetch)
            note = shop.words.callIt(emailed ? "mac.team_invited" : "mac.team_invited_no_mail", ["email": .string(address)])
            email = ""
            problem = nil
            await load()
        } catch {
            problem = said(error)
        }
    }

    private func remove(_ m: CloudTeam.Member) async {
        guard let (c, t) = await session() else { return }
        busy = true; defer { busy = false }
        do {
            try await CloudTeam.remove(m.email, c, token: t, fetch: Shop.plansFetch)
            note = nil
            await load()
        } catch {
            problem = said(error)
        }
    }

    private func signOut(_ d: CloudTeam.Device) async {
        guard let (c, t) = await session() else { return }
        busy = true; defer { busy = false }
        do {
            try await CloudTeam.signOut(device: d.id, c, token: t, fetch: Shop.plansFetch)
            await load()
        } catch {
            problem = said(error)
        }
    }

    private func said(_ error: Error) -> String {
        if let r = error as? CloudTeam.Refusal {
            if r.status == 403 { return r.error.isEmpty ? shop.words.callIt("mac.team_not_allowed") : r.error }
            if !r.error.isEmpty { return r.error }
        }
        return (error as? CustomStringConvertible)?.description ?? String(describing: error)
    }
}

extension Shop {
    /// The owner or a manager: who the cloud lets invite, remove and see devices.
    /// Unknown is no, as for the plan — the cost is a hidden button, and the
    /// cloud decides anyway.
    var cloudCanManageTeam: Bool {
        guard case .object(let cloud)? = settingsDict["cloud"],
              case .string(let role)? = cloud["role"] else { return false }
        return ["owner", "manager"].contains(role.lowercased())
    }
}
