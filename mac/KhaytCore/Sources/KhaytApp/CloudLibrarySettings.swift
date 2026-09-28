import SwiftUI
import AppKit
import KhaytCore

/// Settings › Preferences › Online storage: where the print library keeps its
/// copy online, and what it does with it.
///
/// ── THE EASY PATH FIRST ───────────────────────────────────────────────────
///
/// Asked for by the shop on alpha.54, after connecting Drive: "the gdrive tab
/// doesn't really look that good or understandable. The easy path should be
/// the default." So the screen is built around Google Drive:
///
/// * NOT CONNECTED: one sentence and one prominent Connect button.
/// * WAITING: the browser's sign-in, with Open / Copy link in case the
///   browser did not come up.
/// * CONNECTED: a status card (account, how full the Drive is, the folder,
///   Disconnect), then the two options, each applied the moment it changes.
///
/// A storage bucket, and the shop's own Google client, are under Advanced.
/// A bucket that is actually IN USE is shown in Drive's place, because hiding
/// the thing that holds a shop's models would be worse than any clutter.
///
/// Which remote is in use is `CloudLibrary.remoteInUse`, not worked out here:
/// this screen once decided it from its own form defaults and showed a
/// Drive-only shop "A storage bucket" straight after it connected.
struct CloudLibrarySettings: View {
    let shop: Shop

    /// What is typed on this screen and not yet saved: the bucket's form, the
    /// shop's own Google client, and the Drive folder before connecting.
    struct Draft: Equatable {
        var provider = "r2"
        var vars: [String: String] = [:]
        var endpoint = ""
        var bucket = ""
        var region = ""
        var prefix = ""
        var accessKeyId = ""
        var secret = ""          // typed this session, never the stored one
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
            }
            if case .object(let gd)? = library["gdrive"] {
                d.driveClientId = Shop.plainString(gd["clientId"]) ?? ""
                d.driveFolder = Shop.plainString(gd["folderName"]) ?? ""
            }
            return d
        }
    }

    /// Whether the screen opens on the bucket rather than on Google Drive:
    /// only when a bucket is what the library is actually using.
    @MainActor static func opensOnBucket(_ settings: [String: JSONValue]) -> Bool {
        CloudLibrary.remoteInUse(settings) == .bucket
    }

    @State private var draft: Draft
    @State private var original: Draft
    @State private var options: CloudLibrary.Options
    @State private var showsBucket: Bool
    @State private var remote: CloudLibrary.Remote
    @State private var storedSecret = false
    @State private var driveConnected: Bool
    @State private var driveStatus: CloudLibrary.DriveStatus?
    /// Use the shop's own Google client rather than Khayt's built-in one.
    @State private var ownClient = false
    @State private var advanced = false
    @State private var connecting = false
    @State private var providers: [KhaytEngine.StorageProvider] = []
    @State private var summary: (count: Int, size: String, inCloud: Int)?

    /// Read from the book on the first frame, not in `.task`: the screen must
    /// not open on the wrong state and then jump. `status` is for pictures of
    /// the connected card, which cannot ask Google.
    init(shop: Shop, status: CloudLibrary.DriveStatus? = nil) {
        self.shop = shop
        let settings = shop.settingsDict
        let d = Draft.read(settings)
        _draft = State(initialValue: d)
        _original = State(initialValue: d)
        _options = State(initialValue: CloudLibrary.options(settings))
        _showsBucket = State(initialValue: Self.opensOnBucket(settings))
        _remote = State(initialValue: CloudLibrary.remoteInUse(settings))
        _driveConnected = State(initialValue: CloudLibrary.driveConnected(settings))
        _driveStatus = State(initialValue: status)
    }

    private var chosen: KhaytEngine.StorageProvider? { providers.first { $0.id == draft.provider } }
    private var bucketSaved: Bool { !original.bucket.isEmpty && !original.accessKeyId.isEmpty && storedSecret }
    private var usesOwnClient: Bool { Shop.builtInGoogleClient == nil || ownClient }
    private var waiting: Bool { connecting || shop.googleSignInURL != nil }
    /// The options apply to whatever the library is using, once it can.
    private var ready: Bool { showsBucket ? bucketSaved : driveConnected }
    /// A picture is taken of the sample shop, which cannot be written; its
    /// buttons are drawn as a real shop sees them rather than greyed.
    @Environment(\.photographFlat) private var photographing
    private var locked: Bool { shop.cloudLibraryBusy || (!shop.canMoveJobs && !photographing) }

    var body: some View {
        Group {
            Section(shop.words.callIt("mac.cloudlib_title")) {
                if showsBucket { bucketBlock } else { driveBlock }
                feedback
                DisclosureGroup(shop.words.callIt("mac.cloudlib_advanced"), isExpanded: $advanced) {
                    advancedBlock
                }
            }
            if ready {
                Section(shop.words.callIt("mac.cloudlib_options")) { optionsBlock }
            }
        }
        .task(id: shop.settingsValue) { reload(); await refresh() }
        .task { providers = (try? await shop.engine?.storageProviders()) ?? [] }
        .onChange(of: draft.provider) { Task { await resolve() } }
    }

    // MARK: - Google Drive

    @ViewBuilder private var driveBlock: some View {
        if driveConnected && !waiting {
            statusCard
        } else if waiting {
            waitingBlock
        } else {
            HStack(alignment: .top, spacing: Space.md) {
                driveMark
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        Text(verbatim: "Google Drive").font(TypeScale.title())
                        CapsLabel(shop.words.callIt("mac.gdrive_recommended"), tint: Role.ok)
                    }
                    Text(shop.words.callIt("mac.gdrive_pitch"))
                        .font(TypeScale.body()).foregroundStyle(Role.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(shop.words.callIt("mac.gdrive_connect")) { connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(locked || (Shop.builtInGoogleClient == nil
                                             && draft.driveClientId.trimmingCharacters(in: .whitespaces).isEmpty))
                        .padding(.top, Space.xs)
                    if Shop.builtInGoogleClient == nil
                        && draft.driveClientId.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A build with no Google client of its own: the shop's
                        // is the only way, and it lives under Advanced.
                        Text(shop.words.callIt("mac.gdrive_need_client"))
                            .font(.caption).foregroundStyle(Khayt.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.xs)
        }
    }

    private var driveMark: some View {
        Image(systemName: "externaldrive.badge.icloud")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Khayt.brand)
            .frame(width: 30)
    }

    /// Connected: who, how full, which folder — and the way out.
    private var statusCard: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Khayt.done)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(shop.words.callIt("mac.gdrive_is_connected")).font(TypeScale.title())
                if let st = driveStatus {
                    if !st.email.isEmpty {
                        Label { Text(verbatim: st.email).textSelection(.enabled) } icon: {
                            Image(systemName: "person.crop.circle")
                        }
                        .font(TypeScale.body())
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        if let f = st.fraction { usageBar(f) }
                        Text(st.limit.map {
                            shop.words.callIt("mac.gdrive_usage_of", ["used": .string(st.used), "limit": .string($0)])
                        } ?? shop.words.callIt("mac.gdrive_usage", ["used": .string(st.used)]))
                            .font(.caption).foregroundStyle(Role.text2)
                    }
                } else {
                    Text(shop.words.callIt("mac.gdrive_checking"))
                        .font(.caption).foregroundStyle(Role.text2)
                }
                Label {
                    Text(shop.words.callIt("mac.gdrive_card_folder",
                                           ["folder": .string(CloudLibrary.driveFolder(shop.settingsDict))]))
                } icon: { Image(systemName: "folder") }
                .font(TypeScale.body())
                .foregroundStyle(Role.text2)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(shop.words.callIt("mac.gdrive_disconnect")) {
                Task { await shop.disconnectGoogleDrive(); reload(); await refresh() }
            }
            .disabled(locked)
            .help(shop.words.callIt("mac.gdrive_disconnect_warn"))
        }
        .padding(.vertical, Space.xs)
    }

    /// Drawn, not a `ProgressView`: the bar is a figure, not a task, and it
    /// turns the attention colour when the Drive is nearly full.
    private func usageBar(_ fraction: Double) -> some View {
        Capsule().fill(Role.line2)
            .frame(width: 220, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(fraction > 0.9 ? Khayt.attention : Khayt.brand)
                    .frame(width: max(6, 220 * fraction), height: 6)
                    .growsToItsReading(fraction, from: .leading)
            }
    }

    /// Waiting for Google: the page, in case the browser did not come up.
    @ViewBuilder private var waitingBlock: some View {
        HStack(alignment: .top, spacing: Space.md) {
            // A mark, not a spinner: the wait is on the shop, in another app,
            // and may be minutes — a spinner says Khayt is the one working.
            Image(systemName: "hourglass")
                .font(.system(size: 20))
                .foregroundStyle(Khayt.brand)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(shop.words.callIt("mac.gdrive_waiting_title")).font(TypeScale.title())
                Text(shop.words.callIt("mac.gdrive_no_page_hint"))
                    .font(TypeScale.body()).foregroundStyle(Role.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = shop.googleSignInURL {
                    HStack {
                        Button(shop.words.callIt("mac.gdrive_open_page")) { Shop.openInBrowser(url) }
                        Button(shop.words.callIt("mac.gdrive_copy_link")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
    }

    private func connect() {
        connecting = true
        Task {
            // Khayt's own client unless the shop chose its own: an id
            // left in the book from before must not be used silently.
            let own = usesOwnClient
            await shop.connectGoogleDrive(clientId: own ? draft.driveClientId : "",
                                          typedSecret: own ? draft.driveSecret : "",
                                          folderName: draft.driveFolder)
            connecting = false
            reload(); await refresh()
        }
    }

    // MARK: - Advanced

    @ViewBuilder private var advancedBlock: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if showsBucket {
                Button(shop.words.callIt("mac.cloudlib_use_drive")) { showsBucket = false }
                    .buttonStyle(.link)
            } else {
                Button(shop.words.callIt("mac.cloudlib_use_bucket")) { showsBucket = true }
                    .buttonStyle(.link)
                if !driveConnected {
                    LabeledContent(shop.words.callIt("mac.gdrive_folder")) {
                        TextField("", text: $draft.driveFolder,
                                  prompt: Text(verbatim: CloudLibrary.defaultDriveFolder))
                            .textFieldStyle(.roundedBorder).frame(width: 240)
                    }
                    if Shop.builtInGoogleClient != nil {
                        Toggle(shop.words.callIt("mac.gdrive_own_client"), isOn: $ownClient)
                    }
                    // The shop's own client, and only then what it needs.
                    if usesOwnClient {
                        Text(shop.words.callIt("mac.gdrive_own_client_why"))
                            .font(.caption).foregroundStyle(Role.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        LabeledContent(shop.words.callIt("mac.gdrive_client_id")) {
                            TextField("", text: $draft.driveClientId,
                                      prompt: Text(verbatim: "….apps.googleusercontent.com"))
                                .textFieldStyle(.roundedBorder).frame(width: 300)
                        }
                        LabeledContent(shop.words.callIt("mac.gdrive_client_secret")) {
                            SecureField("", text: $draft.driveSecret).textFieldStyle(.roundedBorder).frame(width: 240)
                        }
                        Text(shop.words.callIt("mac.gdrive_production"))
                            .font(.caption).foregroundStyle(Role.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(shop.words.callIt("mac.gdrive_folder_fixed"))
                        .font(.caption).foregroundStyle(Role.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, Space.xs)
    }

    // MARK: - A storage bucket

    @ViewBuilder private var bucketBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(shop.words.callIt("mac.cloudlib_bucket_title")).font(TypeScale.title())
            Text(shop.words.callIt("mac.cloudlib_bucket_why"))
                .font(.caption).foregroundStyle(Role.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                .textFieldStyle(.roundedBorder).frame(width: 300)
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
        HStack {
            Button(shop.words.callIt("common.save")) { Task { await saveBucket() } }
                .disabled(draft == original || locked)
            Button(shop.words.callIt("mac.cloudlib_test")) { Task { await shop.testCloudLibrary() } }
                .disabled(!bucketSaved || draft != original || shop.cloudLibraryBusy)
            Spacer()
        }
    }

    // MARK: - The options, applied as they change

    @ViewBuilder private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Toggle(shop.words.callIt("mac.cloudlib_opt_copy"),
                   isOn: Binding(get: { options.backsUp }, set: { apply(\.backsUp, $0) }))
            Text(shop.words.callIt("mac.cloudlib_opt_copy_why"))
                .font(.caption).foregroundStyle(Role.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(locked)
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Toggle(shop.words.callIt("mac.cloudlib_opt_move"),
                       isOn: Binding(get: { options.tierOn }, set: { apply(\.tierOn, $0) }))
                Spacer()
                Picker("", selection: Binding(get: { options.keepDays }, set: { apply(\.keepDays, $0) })) {
                    ForEach(dayChoices, id: \.self) { n in
                        Text(shop.words.callIt("mac.cloudlib_n_days", ["n": .number(Double(n))])).tag(n)
                    }
                }
                .labelsHidden().fixedSize()
                .disabled(!options.tierOn)
            }
            Text(shop.words.callIt("mac.cloudlib_opt_move_why"))
                .font(.caption).foregroundStyle(Role.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(locked)
        HStack {
            Button(shop.words.callIt("mac.cloudlib_back_up_all")) { Task { await shop.backUpWholeLibrary(); await refresh() } }
            if options.tierOn {
                Button(shop.words.callIt("mac.cloudlib_free_now")) { Task { await shop.freeUpSpace(); await refresh() } }
            }
            if (summary?.inCloud ?? 0) > 0 {
                Button(shop.words.callIt("mac.cloudlib_bring_all")) { Task { await shop.bringEverythingBack(); await refresh() } }
            }
            Spacer()
        }
        .disabled(locked)
        if let summary, options.tierOn {
            Text(shop.words.callIt("mac.cloudlib_could_move", ["n": .number(Double(summary.count)),
                                                              "size": .string(summary.size),
                                                              "cloud": .number(Double(summary.inCloud))]))
                .font(.caption).foregroundStyle(Role.text2)
        }
        if let p = shop.cloudProgress {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                Text(shop.words.callIt("mac.cloudlib_progress", ["name": .string(p.name), "done": .number(Double(p.done)),
                                                               "total": .number(Double(p.total))]))
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// A few plain lengths, plus whatever the shop already has.
    private var dayChoices: [Int] {
        Array(Set([30, 60, 90, 180, 365, options.keepDays])).sorted()
    }

    private func apply<V>(_ key: WritableKeyPath<CloudLibrary.Options, V>, _ value: V) {
        var next = options
        next[keyPath: key] = value
        guard next != options else { return }
        options = next
        Task { await shop.setLibraryOptions(next) }
    }

    /// Notes and problems from the last thing pressed, once, under the block.
    @ViewBuilder private var feedback: some View {
        if shop.cloudLibraryBusy, shop.cloudProgress == nil, !waiting {
            ProgressView().controlSize(.small)
        }
        if let note = shop.cloudLibraryNote, !waiting {
            Label(note, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Khayt.done)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let problem = shop.cloudLibraryProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Khayt.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Reading and saving

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
        let settings = shop.settingsDict
        original = Draft.read(settings)
        draft = original
        options = CloudLibrary.options(settings)
        // Follow the book when what it is USING changes — connecting Drive,
        // saving a bucket — and otherwise leave the shop's own choice of form
        // alone, so a settings change elsewhere does not snap it back.
        let now = CloudLibrary.remoteInUse(settings)
        if now != remote {
            remote = now
            showsBucket = now == .bucket
        }
        // A client already saved that is not Khayt's is the shop's own choice.
        if let builtIn = Shop.builtInGoogleClient {
            let saved = draft.driveClientId.trimmingCharacters(in: .whitespaces)
            ownClient = !saved.isEmpty && saved != builtIn.id
        }
        driveConnected = CloudLibrary.driveConnected(settings)
        storedSecret = false
        if case .object(let l)? = settings["printLibrary"], case .object(let s3)? = l["s3"],
           case .string(let s)? = s3["secretAccessKey"] { storedSecret = !s.isEmpty }
    }

    private func refresh() async {
        summary = ready ? await shop.cloudTierSummary() : nil
        if driveConnected, !showsBucket {
            // Kept when Google cannot be asked: the problem line says why,
            // and the card does not blank itself on every settings change.
            if let st = await shop.googleDriveStatus() { driveStatus = st }
        } else {
            driveStatus = nil
        }
    }

    private func saveBucket() async {
        await shop.saveCloudLibrary(provider: draft.provider, endpoint: draft.endpoint, bucket: draft.bucket,
                                    region: draft.region, prefix: draft.prefix, accessKeyId: draft.accessKeyId,
                                    typedSecret: draft.secret.trimmingCharacters(in: .whitespaces))
        reload()
        await refresh()
    }
}
