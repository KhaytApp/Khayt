import SwiftUI
import KhaytCore

/// Online storage for the print library: which bucket, whether new models are
/// backed up to it, and whether old ones move there to free this Mac's disk.
///
/// Saves ITSELF, like the ntfy section: the secret is sealed on the way in, and
/// the buttons below act on what is saved, never on what is half-typed.
/// Providers, their endpoints and what each costs come from
/// `lib/storage-providers.js`, the list the other app shows.
struct CloudLibrarySettings: View {
    let shop: Shop

    struct Draft: Equatable {
        var provider = "r2"
        var vars: [String: String] = [:]
        var endpoint = ""
        var bucket = ""
        var region = ""
        var prefix = ""
        var accessKeyId = ""
        var secret = ""          // typed this session, never the stored one
        var backsUp = true
        var tierOn = false
        var keepDays = 90
        /// Google Drive rather than a bucket — the other app's `gdrive` block.
        var useDrive = false
        var driveClientId = ""
        var driveSecret = ""     // typed this session, never the stored one
        var driveFolder = ""

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            var d = Draft()
            guard case .object(let library)? = settings["printLibrary"] else { return d }
            if case .object(let s3)? = library["s3"] {
                d.provider = Shop.plainString(s3["provider"]).flatMap { $0.isEmpty ? nil : $0 } ?? "r2"
                d.endpoint = Shop.plainString(s3["endpoint"]) ?? ""
                d.bucket = Shop.plainString(s3["bucket"]) ?? ""
                d.region = Shop.plainString(s3["region"]) ?? ""
                d.prefix = Shop.plainString(s3["prefix"]) ?? ""
                d.accessKeyId = Shop.plainString(s3["accessKeyId"]) ?? ""
                d.backsUp = Shop.plainBool(s3["enabled"]) ?? false
            }
            if case .object(let gd)? = library["gdrive"] {
                d.driveClientId = Shop.plainString(gd["clientId"]) ?? ""
                d.driveFolder = Shop.plainString(gd["folderName"]) ?? ""
                // Drive is what is in use when it is on and the bucket is not
                // backing up: the bucket wins when both are, as in the other app.
                d.useDrive = (Shop.plainBool(gd["enabled"]) ?? false) && !d.backsUp
            }
            if case .object(let t)? = library["tier"] {
                d.tierOn = Shop.plainBool(t["enabled"]) ?? false
                if case .number(let n)? = t["keepDays"], n >= 1 { d.keepDays = Int(n) }
            }
            return d
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var storedSecret = false
    @State private var providers: [KhaytEngine.StorageProvider] = []
    @State private var summary: (count: Int, size: String, inCloud: Int)?
    @State private var driveConnected = false
    @State private var driveStatus: String?

    private var chosen: KhaytEngine.StorageProvider? { providers.first { $0.id == draft.provider } }
    private var saved: Bool {
        original.useDrive ? driveConnected
            : !original.bucket.isEmpty && !original.accessKeyId.isEmpty && storedSecret
    }

    var body: some View {
        Section(shop.words.callIt("mac.cloudlib_title")) {
            Text(shop.words.callIt("mac.cloudlib_why"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(shop.words.callIt("mac.gdrive_where"), selection: $draft.useDrive) {
                Text(shop.words.callIt("mac.gdrive_bucket")).tag(false)
                Text(verbatim: "Google Drive").tag(true)
            }
            .pickerStyle(.segmented)
            if draft.useDrive {
                driveFields
            } else {
            LabeledContent(shop.words.callIt("mac.cloudlib_provider")) {
                Picker("", selection: $draft.provider) {
                    ForEach(providers) { p in Text(verbatim: p.label).tag(p.id) }
                }.labelsHidden().frame(width: 240)
            }
            if let p = chosen {
                if let cost = p.cost, !cost.isEmpty {
                    Text(verbatim: [cost, p.egress ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(p.vars, id: \.key) { v in
                    LabeledContent(v.label) {
                        TextField("", text: Binding(get: { draft.vars[v.key] ?? "" },
                                                    set: { draft.vars[v.key] = $0; Task { await resolve() } }),
                                  prompt: v.hint.map { Text(verbatim: $0) })
                            .textFieldStyle(.roundedBorder).frame(width: 240)
                    }
                }
            }
            LabeledContent(shop.words.callIt("mac.cloudlib_endpoint")) {
                TextField("", text: $draft.endpoint, prompt: Text(verbatim: "https://…"))
                    .textFieldStyle(.roundedBorder).frame(width: 320)
            }
            LabeledContent(shop.words.callIt("mac.cloudlib_bucket")) {
                TextField("", text: $draft.bucket).textFieldStyle(.roundedBorder).frame(width: 240)
            }
            LabeledContent(shop.words.callIt("mac.cloudlib_region")) {
                TextField("", text: $draft.region, prompt: Text(verbatim: "auto"))
                    .textFieldStyle(.roundedBorder).frame(width: 240)
            }
            LabeledContent(shop.words.callIt("mac.cloudlib_prefix")) {
                TextField("", text: $draft.prefix, prompt: Text(verbatim: "khayt"))
                    .textFieldStyle(.roundedBorder).frame(width: 240)
            }
            LabeledContent(shop.words.callIt("mac.cloudlib_key_id")) {
                TextField("", text: $draft.accessKeyId).textFieldStyle(.roundedBorder).frame(width: 240)
            }
            LabeledContent(shop.words.callIt("mac.cloudlib_secret")) {
                SecureField(storedSecret ? "••••••••" : "", text: $draft.secret)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
            }
            Toggle(shop.words.callIt("mac.cloudlib_back_up"), isOn: $draft.backsUp)
            }
            Toggle(shop.words.callIt("mac.cloudlib_tier"), isOn: $draft.tierOn)
            if draft.tierOn {
                LabeledContent(shop.words.callIt("mac.cloudlib_keep_days")) {
                    HStack {
                        TextField("", value: $draft.keepDays, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing).frame(width: 70)
                        Text(shop.words.callIt("mac.cloudlib_days"))
                    }
                }
                Text(shop.words.callIt("mac.cloudlib_safety"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(shop.words.callIt("common.save")) { Task { await save() } }
                    .disabled(draft == original || !shop.canMoveJobs || shop.cloudLibraryBusy)
                Button(shop.words.callIt("mac.cloudlib_test")) { Task { await shop.testCloudLibrary() } }
                    .disabled(!saved || draft != original || shop.cloudLibraryBusy)
                Spacer()
            }
            if saved {
                HStack {
                    Button(shop.words.callIt("mac.cloudlib_back_up_all")) { Task { await shop.backUpWholeLibrary(); await refresh() } }
                    if original.tierOn {
                        Button(shop.words.callIt("mac.cloudlib_free_now")) { Task { await shop.freeUpSpace(); await refresh() } }
                    }
                    if (summary?.inCloud ?? 0) > 0 {
                        Button(shop.words.callIt("mac.cloudlib_bring_all")) { Task { await shop.bringEverythingBack(); await refresh() } }
                    }
                    Spacer()
                }
                .disabled(draft != original || shop.cloudLibraryBusy || !shop.canMoveJobs)
                if let summary, original.tierOn {
                    Text(shop.words.callIt("mac.cloudlib_could_move", ["n": .number(Double(summary.count)),
                                                             "size": .string(summary.size),
                                                             "cloud": .number(Double(summary.inCloud))]))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let p = shop.cloudProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                    Text(shop.words.callIt("mac.cloudlib_progress", ["name": .string(p.name), "done": .number(Double(p.done)),
                                                           "total": .number(Double(p.total))]))
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                }
            } else if shop.cloudLibraryBusy {
                ProgressView().controlSize(.small)
            }
            if let note = shop.cloudLibraryNote {
                Label(note, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Khayt.done)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = shop.cloudLibraryProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: shop.settingsValue) { reload(); await refresh() }
        .task { providers = (try? await shop.engine?.storageProviders()) ?? [] }
        .onChange(of: draft.provider) { Task { await resolve() } }
    }

    /// Google Drive: the shop's own OAuth client, a folder, and one button
    /// that signs in through the browser.
    @ViewBuilder private var driveFields: some View {
        Text(shop.words.callIt("mac.gdrive_why"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(shop.words.callIt("mac.gdrive_production"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent(shop.words.callIt("mac.gdrive_client_id")) {
            TextField("", text: $draft.driveClientId, prompt: Text(verbatim: "….apps.googleusercontent.com"))
                .textFieldStyle(.roundedBorder).frame(width: 320)
        }
        LabeledContent(shop.words.callIt("mac.gdrive_client_secret")) {
            SecureField("", text: $draft.driveSecret).textFieldStyle(.roundedBorder).frame(width: 240)
        }
        LabeledContent(shop.words.callIt("mac.gdrive_folder")) {
            TextField("", text: $draft.driveFolder, prompt: Text(verbatim: "Khayt print library"))
                .textFieldStyle(.roundedBorder).frame(width: 240)
        }
        HStack {
            Button(shop.words.callIt("mac.gdrive_connect")) {
                Task {
                    await shop.connectGoogleDrive(clientId: draft.driveClientId, typedSecret: draft.driveSecret,
                                                  folderName: draft.driveFolder)
                    reload(); await refresh()
                }
            }
            .disabled(shop.cloudLibraryBusy || !shop.canMoveJobs
                      || draft.driveClientId.trimmingCharacters(in: .whitespaces).isEmpty)
            if driveConnected {
                Button(shop.words.callIt("mac.gdrive_disconnect")) {
                    Task { await shop.disconnectGoogleDrive(); reload(); await refresh() }
                }
                .disabled(shop.cloudLibraryBusy || !shop.canMoveJobs)
                .help(shop.words.callIt("mac.gdrive_disconnect_warn"))
            }
            Spacer()
        }
        if let driveStatus {
            Label(driveStatus, systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The endpoint, filled in from the provider and the one or two things
    /// only the shop knows. A provider whose endpoint the shop types itself
    /// leaves the field alone.
    private func resolve() async {
        guard let engine = shop.engine, chosen != nil,
              let r = try? await engine.resolveEndpoint(provider: draft.provider, vars: draft.vars),
              r.ok, let endpoint = r.endpoint else { return }
        draft.endpoint = endpoint
        if let region = r.region, !region.isEmpty { draft.region = region }
    }

    private func reload() {
        original = Draft.read(shop.settingsDict)
        draft = original
        storedSecret = false
        driveConnected = false
        if case .object(let l)? = shop.settingsDict["printLibrary"], case .object(let gd)? = l["gdrive"],
           case .string(let t)? = gd["refreshToken"] { driveConnected = !t.isEmpty }
        if case .object(let l)? = shop.settingsDict["printLibrary"], case .object(let s3)? = l["s3"],
           case .string(let s)? = s3["secretAccessKey"] { storedSecret = !s.isEmpty }
    }

    private func refresh() async {
        summary = saved ? await shop.cloudTierSummary() : nil
        driveStatus = nil
        if original.useDrive, driveConnected, let st = await shop.googleDriveStatus() {
            driveStatus = st.limit.map {
                shop.words.callIt("mac.gdrive_connected_of", ["email": .string(st.email), "used": .string(st.used),
                                                              "limit": .string($0)])
            } ?? shop.words.callIt("mac.gdrive_connected_as", ["email": .string(st.email), "used": .string(st.used)])
        }
    }

    private func save() async {
        if draft.useDrive {
            await shop.saveDriveLibrary(folderName: draft.driveFolder, tierOn: draft.tierOn, keepDays: draft.keepDays)
            reload(); await refresh(); return
        }
        await shop.saveCloudLibrary(provider: draft.provider, endpoint: draft.endpoint, bucket: draft.bucket,
                                    region: draft.region, prefix: draft.prefix, accessKeyId: draft.accessKeyId,
                                    typedSecret: draft.secret.trimmingCharacters(in: .whitespaces),
                                    backsUp: draft.backsUp, tierOn: draft.tierOn, keepDays: draft.keepDays)
        reload()
        await refresh()
    }
}
