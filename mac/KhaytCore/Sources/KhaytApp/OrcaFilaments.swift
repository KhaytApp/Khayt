import SwiftUI
import AppKit
import KhaytCore

/// An Orca-family slicer's config folder, walked the way
/// `lib/orca-filament-install.js` walks it.
///
/// The walking is Swift's because JavaScriptCore has no file system; every
/// decision about what was found — which printers, which version, which file
/// name — is `lib/orca-presets.js` through `StudioEngine`, the module the
/// desktop's installer now calls too. So a profile installed from this Mac
/// lands at the same path, with the same printers and version, as one
/// installed from the desktop.
///
/// Writing into `~/Library/Application Support/<slicer>/user/…/filament` is
/// the point of the feature, and the app is not sandboxed (`make-app.sh`). The
/// screens ask before every write.
enum OrcaFolders {
    struct Found: Sendable, Hashable, Identifiable {
        let slicer: StudioEngine.Slicer
        let configDir: URL
        let filamentDir: URL
        var printers: [StudioEngine.Printer] = []
        var defaultPrinter: String?
        var id: String { slicer.id }
    }

    /// `~/Library/Application Support`, or `KHAYT_ORCA_CONFIG_BASE` — the
    /// override the desktop's tests use, honoured here for the same reason.
    static var configBase: URL {
        if let o = ProcessInfo.processInfo.environment["KHAYT_ORCA_CONFIG_BASE"], !o.isEmpty {
            return URL(fileURLWithPath: o)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    }

    private static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private static func subdirs(_ url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { isDir(url.appending(path: $0)) }
    }

    /// Files under `dir` matching `keep`, depth first, capped — `collect()`.
    static func collect(_ dir: URL, cap: Int, _ keep: (URL) -> Bool) -> [URL] {
        var out: [URL] = []
        func walk(_ d: URL) {
            guard out.count < cap else { return }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).sorted()
            for name in names {
                guard out.count < cap else { return }
                let u = d.appending(path: name)
                if isDir(u) { walk(u) } else if keep(u) { out.append(u) }
            }
        }
        walk(dir)
        return out
    }

    static func readJson(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The installed slicers, each with its printers — `targets()`.
    static func detect(_ engine: StudioEngine, base: URL = configBase) async -> [Found] {
        guard let known = try? await engine.slicers() else { return [] }
        var found: [Found] = []
        for s in known {
            for name in s.dirs {
                let config = base.appending(path: name)
                guard isDir(config.appending(path: "system")), isDir(config.appending(path: "user")) else { continue }
                let user = config.appending(path: "user")
                let hasDefault = isDir(user.appending(path: "default"))
                let profile = (try? await engine.userProfileName(subdirs: hasDefault ? [] : subdirs(user).sorted(),
                                                                 hasDefault: hasDefault)) ?? "default"
                var f = Found(slicer: s, configDir: config,
                              filamentDir: user.appending(path: profile).appending(path: "filament"))
                let machines = collect(config.appending(path: "system"), cap: 4000) {
                    $0.pathExtension == "json" && $0.pathComponents.contains("machine")
                }.map { $0.deletingPathExtension().lastPathComponent }
                f.printers = (try? await engine.groupPrinters(machines)) ?? []
                f.defaultPrinter = try? await engine.defaultPrinter(f.printers)
                found.append(f)
                break // first matching dir spelling wins
            }
        }
        return found
    }

    /// The version to stamp on a preset written for this slicer — `resolveVersion`.
    static func version(for f: Found, _ engine: StudioEngine) async -> String? {
        let versions: [String?] = collect(f.filamentDir, cap: 400) { $0.pathExtension == "json" }.map { url in
            if case .object(let o)? = readJson(url), case .string(let v)? = o["version"] { return v }
            return nil
        }
        return (try? await engine.pickVersion(versions, fallback: f.slicer.version)) ?? nil
    }

    /// The preset basenames already in the folder, for "Installed".
    static func installedNames(_ f: Found) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: f.filamentDir.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    /// The user's own filament presets — the bases a tuned profile starts from.
    static func userFilaments(_ f: Found, _ engine: StudioEngine) async -> [StudioEngine.UserFilament] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: f.filamentDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
        var out: [StudioEngine.UserFilament] = []
        for name in names {
            let url = f.filamentDir.appending(path: name)
            guard !isDir(url), let j = readJson(url),
                  let one = try? await engine.userFilament(j, file: name) else { continue }
            out.append(one)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Write a preset into the slicer's folder, the way the desktop does: the
    /// folder made if missing, the file replaced whole.
    static func write(_ text: String, named base: String, into f: Found) throws -> URL {
        try FileManager.default.createDirectory(at: f.filamentDir, withIntermediateDirectories: true)
        let out = f.filamentDir.appending(path: base + ".json")
        try Data(text.utf8).write(to: out, options: .atomic)
        return out
    }

    static func reveal(_ f: Found) {
        try? FileManager.default.createDirectory(at: f.filamentDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(f.filamentDir)
    }
}

/// The OrcaSlicer filament library, installed into the slicer of the shop's
/// choosing — the desktop's "Add filament to your slicer"
/// (`renderer/bedready-filaments.js`).
struct OrcaFilamentProfiles: View {
    @Bindable var shop: Shop

    struct Profile: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let vendor: String?
        let type: String?
        let file: String
        let nozzleTemp: JSONValue?
        let bedTemp: JSONValue?
    }

    struct Manifest: Decodable {
        let profiles: [Profile]
        let vendors: [String]?
        let types: [String]?
    }

    /// bedready.io, not makerrun.com: the dataset belongs to the converter
    /// (see the note in `lib/orca-filament-install.js`).
    static let base = URL(string: "https://bedready.io")!
    static let manifestCap = 8 << 20
    static let profileCap = 2 << 20
    /// Rows drawn at once — the desktop's CAP; a search narrows 1,200+.
    static let shown = 60

    @State private var slicers: [OrcaFolders.Found] = []
    @State private var slicerId: String?
    @State private var printerLabel: String?
    @State private var manifest: Manifest?
    @State private var installed: Set<String> = []
    @State private var loading = true
    @State private var problem: String?
    @State private var note: String?
    @State private var query = ""
    @State private var vendor = ""
    @State private var type = ""
    @State private var asking: Profile?
    @State private var installing: String?
    @State private var safeNames: [String: String] = [:]

    private var words: Words { shop.words }
    private var slicer: OrcaFolders.Found? { slicers.first { $0.id == slicerId } ?? slicers.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading {
                ProgressView(words.callIt("mac.of_loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem {
                EmptyHere(title: problem) {
                    Button(words.callIt("mac.of_try_again")) { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                filters
                list
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .task { await load() }
        .alert(words.callIt("mac.of_install_q"), isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
               presenting: asking) { p in
            Button(words.callIt("mac.of_install")) { Task { await install(p) } }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        } message: { p in
            Text(words.callIt("mac.of_install_body", ["name": .string(p.name), "slicer": .string(slicer?.slicer.label ?? ""),
                                                       "printer": .string(printerLabel ?? "")]))
        }
    }

    private var header: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker(words.callIt("mac.of_slicer"), selection: Binding(get: { slicer?.id ?? "" }, set: { id in
                        slicerId = id
                        printerLabel = slicers.first { $0.id == id }?.defaultPrinter
                        refreshInstalled()
                    })) {
                        ForEach(slicers) { s in Text(s.slicer.label).tag(s.id) }
                    }
                    if let s = slicer, !s.printers.isEmpty {
                        Picker(words.callIt("mac.of_printer"), selection: Binding(get: { printerLabel ?? "" }, set: { printerLabel = $0 })) {
                            ForEach(s.printers) { p in Text(p.label).tag(p.label) }
                        }
                    } else {
                        Text(words.callIt("mac.of_no_printers", ["slicer": .string(slicer?.slicer.label ?? "")]))
                            .foregroundStyle(.red)
                    }
                    Button(words.callIt("mac.of_reveal")) { if let s = slicer { OrcaFolders.reveal(s) } }
                }
                Text(words.callIt("mac.of_quit_first", ["slicer": .string(slicer?.slicer.label ?? "")]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private var filters: some View {
        HStack {
            TextField(words.callIt("mac.of_search"), text: $query).textFieldStyle(.roundedBorder)
            Picker(words.callIt("mac.of_brand"), selection: $vendor) {
                Text(words.callIt("mac.of_all")).tag("")
                ForEach(manifest?.vendors ?? [], id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 220)
            Picker(words.callIt("mac.of_material"), selection: $type) {
                Text(words.callIt("mac.of_all")).tag("")
                ForEach(manifest?.types ?? [], id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 200)
        }
    }

    private var matching: [Profile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (manifest?.profiles ?? []).filter { p in
            if !vendor.isEmpty && p.vendor != vendor { return false }
            if !type.isEmpty && p.type != type { return false }
            if !q.isEmpty && !(p.name + " " + (p.vendor ?? "")).lowercased().contains(q) { return false }
            return true
        }
    }

    private var list: some View {
        let all = matching
        let rows = Array(all.prefix(Self.shown))
        return VStack(alignment: .leading, spacing: 6) {
            Text(all.isEmpty ? words.callIt("mac.of_none_match")
                 : words.callIt(all.count > Self.shown ? "mac.of_showing_more" : "mac.of_showing",
                                ["n": .number(Double(rows.count)), "total": .number(Double(all.count))]))
                .font(.caption).foregroundStyle(.secondary)
            List(rows) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).fontWeight(.semibold).lineLimit(1)
                        Text([p.vendor, p.type].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isInstalled(p) {
                        Text(words.callIt("mac.of_installed")).font(.caption).foregroundStyle(.green)
                    } else {
                        Button(installing == p.id ? words.callIt("mac.of_installing") : words.callIt("mac.of_install")) {
                            asking = p
                        }
                        .disabled(installing != nil || slicer?.printers.isEmpty != false || !shop.permitted("settings", "edit"))
                    }
                }
            }
        }
    }

    private func isInstalled(_ p: Profile) -> Bool {
        guard let name = safeNames[p.id] else { return false }
        return installed.contains(name)
    }

    private func refreshInstalled() {
        installed = slicer.map(OrcaFolders.installedNames) ?? []
    }

    private func load() async {
        loading = true
        problem = nil
        defer { loading = false }
        guard let engine = await Studio.engine() else { problem = words.callIt("mac.of_failed"); return }
        let found = await OrcaFolders.detect(engine)
        slicers = found
        guard !found.isEmpty else { problem = words.callIt("mac.of_no_slicer"); return }
        // Snapmaker Orca when it is there — this app's own printer — as the desktop does.
        let def = found.first { $0.id == "snapmaker" } ?? found[0]
        slicerId = def.id
        printerLabel = def.defaultPrinter
        do {
            let m = try await Self.fetch(Self.base.appending(path: "orca-filaments/manifest.json"),
                                         cap: Self.manifestCap, as: Manifest.self)
            var names: [String: String] = [:]
            for p in m.profiles { names[p.id] = (try? await engine.safeFileBase(p.name)) ?? p.name }
            safeNames = names
            manifest = m
            refreshInstalled()
        } catch {
            problem = words.callIt("mac.of_failed")
        }
    }

    /// GET with a size cap, as `getJson` does: refuse a declared length over
    /// it, and refuse a body over it.
    static func fetch<T: Decodable>(_ url: URL, cap: Int, as: T.Type) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard Int(http.expectedContentLength) <= cap, data.count <= cap else { throw URLError(.dataLengthExceedsMaximum) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func install(_ p: Profile) async {
        asking = nil
        guard shop.permitted("settings", "edit"), let s = slicer, let engine = await Studio.engine() else { return }
        guard let printer = s.printers.first(where: { $0.label == printerLabel })
                ?? s.printers.first(where: { $0.label == s.defaultPrinter }) ?? s.printers.first else {
            note = words.callIt("mac.of_no_printers", ["slicer": .string(s.slicer.label)]); return
        }
        installing = p.id
        defer { installing = nil }
        do {
            guard try await engine.validProfileRef(p.file) else { note = words.callIt("mac.of_failed"); return }
            let preset = try await Self.fetch(Self.base.appending(path: "orca-filaments/" + p.file),
                                              cap: Self.profileCap, as: JSONValue.self)
            let version = await OrcaFolders.version(for: s, engine)
            guard let text = try await engine.retarget(preset: preset, printer: printer, version: version) else {
                note = words.callIt("mac.of_failed"); return
            }
            let base = try await engine.safeFileBase(p.name)
            _ = try await Studio.offMain { try OrcaFolders.write(text, named: base, into: s) }
            refreshInstalled()
            note = words.callIt("mac.of_done", ["name": .string(p.name), "printer": .string(printer.label),
                                                "slicer": .string(s.slicer.label)])
        } catch {
            note = words.callIt("mac.of_failed")
        }
    }
}
