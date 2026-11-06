import SwiftUI
import AppKit
import KhaytCore

/// Publish a library model as a new MakerRun listing — and, for a model that
/// already has one, its status and the way to finish or remove a half-made one.
///
/// The desktop's flow, step for step (`renderer/bedready-makerrun.js`
/// publish/runSteps), in its words (`mr.*`):
///
///   form → confirm → create the listing → upload and verify the model →
///   upload the picture → done
///
/// Each step that succeeds is written onto the record (`rec.makerrunListing`)
/// before the next begins, so a failure — or a quit — leaves a record that
/// knows exactly what exists on MakerRun, and "Finish upload" resumes from
/// there on this Mac or the desktop. Nothing here publishes: MakerRun reviews
/// every listing, and listings made here are free.
struct MakerRunPublishSheet: View {
    @Bindable var shop: Shop
    let file: LibraryFile
    @Environment(\.dismiss) private var dismiss

    enum Stage { case signIn, form, confirm, running, status, recreate, delete }

    struct Step: Identifiable, Equatable {
        enum State { case pending, running, done, failed }
        let id: String
        var state: State
    }

    @State private var stage: Stage = .form
    @State private var form = MakerRun.CreateInput()
    @State private var includePic = false
    @State private var printClaim = false
    @State private var errors: [String: String] = [:]
    @State private var steps: [Step] = []
    @State private var running = false
    @State private var problem: String?
    @State private var note: String?
    @State private var terms: KhaytEngine.MakerRunTerms?
    @State private var licenceUnmapped = false
    /// A create whose answer was lost: the listing may exist.
    @State private var createUncertain = false
    @State private var recreateConfirmed = false
    @State private var hasPicture = false

    private var listing: [String: JSONValue]? { shop.makerRunListing(of: file.id) }

    var body: some View {
        let w = shop.words
        VStack(alignment: .leading, spacing: 12) {
            Text(w.callIt("mr.publish_title")).font(.title3.weight(.semibold))
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Spacer()
                Button(w.callIt("mr.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .task { await start() }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .signIn: signIn
        case .form: formView
        case .confirm: confirm
        case .running: stepsView
        case .status: statusView
        case .recreate: recreate
        case .delete: deleteView
        }
    }

    // MARK: Opening

    private func start() async {
        terms = await shop.makerRunTerms()
        hasPicture = await shop.makerRunPicture(for: file) != nil
        let origin = shop.makerRunOrigin(of: file.id)
        // A design downloaded FROM MakerRun carries somebody else's licence;
        // carrying it into a listing would make that choice for the shop.
        var mrLicence: String?
        if origin == nil, let id = file.licence, !id.isEmpty {
            mrLicence = (try? await shop.engine?.makerRunLicence(fromRecord: id)) ?? nil
            licenceUnmapped = mrLicence == nil
        }
        form.title = String(file.title.prefix(MakerRun.maxTitle))
        form.material = MakerRun.guessMaterial(file.material)
        form.license = mrLicence ?? ""
        guard await shop.makerRun.isLinked() else { stage = .signIn; return }
        stage = listing == nil ? .form : .status
    }

    // MARK: Views

    private var signIn: some View {
        let w = shop.words
        return VStack(alignment: .leading, spacing: 10) {
            Text(w.callIt("mr.publish_signin"))
            MakerRunAccount(shop: shop)
            Button(w.callIt("mr.recheck")) { Task { await start() } }
        }
    }

    private var formView: some View {
        let w = shop.words
        let ext = (file.sourceFile?.ext ?? "").lowercased()
        let badExt = !MakerRun.modelExtensions.contains(ext)
        let here = shop.modelFile(for: file) != nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(w.callIt("mr.publish_lead", ["name": .string(file.title)])).font(.callout).foregroundStyle(.secondary)
            if let origin = shop.makerRunOrigin(of: file.id) {
                warning(origin.creator.map { w.callIt("mr.publish_downloaded_by", ["name": .string($0)]) }
                        ?? w.callIt("mr.publish_downloaded"))
            }
            if badExt { warning(w.callIt("mr.publish_bad_ext", ["ext": .string(ext.isEmpty ? "?" : ext)])) }
            if !here { warning(w.callIt("mac.mkr_not_here")) }
            if let problem { warning(problem) }
            field(w.callIt("mr.f_title"), "title") {
                TextField("", text: $form.title).textFieldStyle(.roundedBorder)
            }
            field(w.callIt("mr.f_description"), "description") {
                TextEditor(text: $form.description).frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            }
            HStack(alignment: .top) {
                field(w.callIt("mr.f_category"), "category") {
                    Picker("", selection: $form.category) {
                        Text(w.callIt("mr.choose_category")).tag("")
                        ForEach(terms?.categories ?? [], id: \.value) { c in Text(c.label).tag(c.value) }
                    }
                    .labelsHidden()
                }
                field(w.callIt("mr.f_material"), "material") {
                    Picker("", selection: $form.material) {
                        Text(w.callIt("mr.material_unset")).tag("")
                        Text(w.callIt("mr.mat_rigid")).tag("rigid")
                        Text(w.callIt("mr.mat_flexible")).tag("flexible")
                        Text(w.callIt("mr.mat_multi")).tag("multi")
                    }
                    .labelsHidden()
                }
            }
            field(w.callIt("mr.f_licence"), "license") {
                VStack(alignment: .leading, spacing: 4) {
                    if licenceUnmapped, let lic = file.licence {
                        Text(w.callIt("mr.licence_unmapped", ["licence": .string(lic)]))
                            .font(.caption).foregroundStyle(Khayt.attention)
                    }
                    Picker("", selection: $form.license) {
                        Text(w.callIt("mr.choose_licence")).tag("")
                        ForEach(terms?.licences ?? [], id: \.self) { l in Text(l).tag(l) }
                    }
                    .labelsHidden()
                }
            }
            Toggle(w.callIt("mr.f_nsfw"), isOn: $form.nsfw)
            if hasPicture {
                Toggle(w.callIt(file.userPhoto != nil ? "mr.include_photo" : "mr.include_thumb"), isOn: $includePic)
                if includePic && file.userPhoto != nil {
                    Toggle(w.callIt("mr.f_print_claim"), isOn: $printClaim).padding(.leading, 20)
                }
            } else {
                Text(w.callIt("mr.no_picture")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(w.callIt("mr.publish_free_note")).font(.caption).foregroundStyle(.secondary)
            Button(w.callIt("mr.publish_next")) { if validate() { stage = .confirm } }
                .buttonStyle(.borderedProminent)
                .disabled(badExt || !here || !shop.canWrite)
        }
    }

    private func field<C: View>(_ label: String, _ key: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold))
            control()
            if let e = errors[key] { Text(e).font(.caption).foregroundStyle(Khayt.attention) }
        }
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Khayt.attention.opacity(0.6)))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var confirm: some View {
        let w = shop.words
        let title = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            Text(w.callIt("mr.confirm_title")).font(.headline)
            Text(w.callIt("mr.confirm_body")).fixedSize(horizontal: false, vertical: true)
            Text(w.callIt("mr.confirm_item_title", ["title": .string(title)]))
            Text(w.callIt("mr.confirm_item_licence", ["licence": .string(form.license)]))
            Text(w.callIt("mr.confirm_item_file", ["name": .string(file.sourceFile?.filename ?? "")]))
            if includePic { Text(w.callIt(file.userPhoto != nil ? "mr.include_photo" : "mr.include_thumb")) }
            HStack {
                Button(w.callIt("mr.confirm_go")) { Task { await runSteps() } }.buttonStyle(.borderedProminent)
                Button(w.callIt("mr.back")) { stage = .form }
            }
        }
    }

    private var stepsView: some View {
        let w = shop.words
        let slug = Shop.plainString(listing?["slug"])
        return VStack(alignment: .leading, spacing: 8) {
            Text(w.callIt("mr.publishing", ["title": .string(file.title)])).font(.headline)
            ForEach(steps) { s in
                HStack(spacing: 8) {
                    switch s.state {
                    case .done: Image(systemName: "checkmark").foregroundStyle(Khayt.done)
                    case .running: ProgressView().controlSize(.small)
                    case .failed: Image(systemName: "xmark").foregroundStyle(Khayt.attention)
                    case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                    Text(w.callIt(Self.stepKey(s.id)))
                }
            }
            if !running {
                if let problem {
                    warning(problem)
                    HStack {
                        if slug != nil {
                            Button(w.callIt("mr.finish_upload")) { Task { await runSteps() } }.buttonStyle(.borderedProminent)
                            skipPictureButton
                            Button(w.callIt("mr.delete_half"), role: .destructive) { stage = .delete }
                        } else {
                            Button(w.callIt("mr.retry")) { Task { await runSteps() } }.buttonStyle(.borderedProminent)
                            Button(w.callIt("mr.back")) { stage = .form }
                        }
                    }
                } else {
                    summary
                    HStack {
                        Button(w.callIt("mr.check_status")) { Task { await checkStatus() } }
                        openPageButton
                    }
                }
            }
            if let note { Text(note).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
    }

    static func stepKey(_ id: String) -> String {
        switch id {
        case "create": "mr.step_create"
        case "file": "mr.step_file"
        default: "mr.step_images"
        }
    }

    @ViewBuilder private var skipPictureButton: some View {
        if Shop.plainString(listing?["step"]) == "file", case .bool(true)? = listing?["wantPic"] {
            Button(shop.words.callIt("mr.skip_picture")) { skipPicture() }
        }
    }

    @ViewBuilder private var openPageButton: some View {
        if let slug = Shop.plainString(listing?["slug"]), let url = MakerRun.pageURL(slug: slug) {
            Button(shop.words.callIt("mr.open_page")) { NSWorkspace.shared.open(url) }
        }
    }

    private func statusLabel(_ s: String?) -> String {
        let w = shop.words
        switch s {
        case "pending": return w.callIt("mr.status_pending")
        case "published": return w.callIt("mr.status_published")
        case "rejected": return w.callIt("mr.status_rejected")
        case "draft": return w.callIt("mr.status_draft")
        case let other?: return other
        case nil: return w.callIt("mr.status_unknown")
        }
    }

    @ViewBuilder private var summary: some View {
        let w = shop.words
        let l = listing ?? [:]
        let status = Shop.plainString(l["status"])
        VStack(alignment: .leading, spacing: 4) {
            Text(statusLabel(status)).font(.callout.weight(.semibold))
            if status == "pending" { Text(w.callIt("mr.review_note")).font(.caption).foregroundStyle(.secondary) }
            if case .object(let v)? = l["verification"] {
                if case .bool(true)? = v["verified"] {
                    let printer = [Shop.plainString(v["brand"]), Shop.plainString(v["printer"])].compactMap { $0 }.joined(separator: " ")
                    Text(w.callIt("mr.verified_for", ["printer": .string(printer.isEmpty ? "—" : printer)]))
                        .font(.caption).foregroundStyle(Khayt.done)
                } else if case .bool(false)? = v["verified"] {
                    Text(w.callIt("mr.not_verified", ["reason": .string(Shop.plainString(v["reason"]) ?? w.callIt("mr.reason_unknown"))]))
                        .font(.caption).foregroundStyle(Khayt.attention)
                } else if case .bool(true)? = v["badge"] {
                    Text(w.callIt("mr.v_badge")).font(.caption).foregroundStyle(Khayt.done)
                }
            }
            if let at = Shop.plainNumber(l["publishedAt"]) {
                Text(w.callIt("mr.created_on", ["date": .string(w.say(Date(timeIntervalSince1970: at / 1000),
                                                                       Date.FormatStyle(date: .abbreviated, time: .shortened)))]))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    private var statusView: some View {
        let w = shop.words
        let step = Shop.plainString(listing?["step"])
        let incomplete = step != nil && step != "done"
        return VStack(alignment: .leading, spacing: 8) {
            Text(w.callIt("mr.listing_title", ["title": .string(file.title)])).font(.headline)
            summary
            if incomplete { warning(w.callIt("mr.incomplete")) }
            if let problem { warning(problem) }
            HStack {
                Button(w.callIt("mr.check_status")) { Task { await checkStatus() } }
                if incomplete {
                    Button(w.callIt("mr.finish_upload")) { Task { await runSteps() } }.buttonStyle(.borderedProminent)
                    skipPictureButton
                    Button(w.callIt("mr.delete_half"), role: .destructive) { stage = .delete }
                }
                openPageButton
            }
            if let note { Text(note).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var recreate: some View {
        let w = shop.words
        return VStack(alignment: .leading, spacing: 8) {
            Text(w.callIt("mr.recreate_title")).font(.headline)
            Text(w.callIt("mr.recreate_body")).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(w.callIt("mr.recreate_go")) { recreateConfirmed = true; Task { await runSteps() } }
                    .buttonStyle(.borderedProminent)
                Button(w.callIt("mr.back")) { stage = .form }
            }
        }
    }

    private var deleteView: some View {
        let w = shop.words
        return VStack(alignment: .leading, spacing: 8) {
            Text(w.callIt("mr.delete_title")).font(.headline)
            Text(w.callIt("mr.delete_body")).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(w.callIt("mr.delete_go"), role: .destructive) { Task { await doDelete() } }
                Button(w.callIt("mr.cancel")) { stage = .status }
            }
        }
    }

    // MARK: Rules

    /// The form's own checks, mirroring `validateCreateInput`; the client and
    /// MakerRun check again.
    private func validate() -> Bool {
        let w = shop.words
        var e: [String: String] = [:]
        let title = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { e["title"] = w.callIt("mr.e_title") }
        else if title.count > MakerRun.maxTitle { e["title"] = w.callIt("mr.e_title_long") }
        if form.description.count > MakerRun.maxDescription { e["description"] = w.callIt("mr.e_description") }
        if form.category.isEmpty { e["category"] = w.callIt("mr.e_category") }
        if form.license.isEmpty || !(terms?.licences ?? []).contains(form.license) { e["license"] = w.callIt("mr.e_licence") }
        errors = e
        return e.isEmpty
    }

    private func set(_ id: String, _ state: Step.State) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = state }
    }

    private func fail(_ id: String, _ error: Error) {
        set(id, .failed)
        running = false
        problem = shop.saidMakerRun(error)
        if id == "create" {
            if let f = error as? MakerRun.Failure {
                if f.code == "timeout" || f.code == "network" { createUncertain = true }
                // Field errors belong on the form, beside the fields.
                if f.code == "invalid", !f.details.isEmpty {
                    errors = Dictionary(f.details.map { ($0.field, $0.message) }, uniquingKeysWith: { a, _ in a })
                    stage = .form
                }
            }
            recreateConfirmed = false
        }
    }

    /// Run the steps from wherever this record left off (`runSteps`).
    private func runSteps() async {
        guard !running else { return }
        // The listing is written onto the record after every step, so a shop
        // that may not edit the library may not start one it could not track.
        guard shop.permitted("inventory", "edit") else { return }
        var l = listing
        let wantPic = includePic || { if case .bool(true)? = l?["wantPic"] { return true }; return false }()
        steps = [Step(id: "create", state: .pending), Step(id: "file", state: .pending)]
            + (wantPic ? [Step(id: "images", state: .pending)] : [])
        let at: Int = {
            switch Shop.plainString(l?["step"]) {
            case nil: return 0
            case "created": return 1
            case "file": return 2
            default: return 3
            }
        }()
        for i in 0..<min(at, steps.count) { steps[i].state = .done }
        stage = .running
        running = true
        problem = nil
        note = nil
        let title = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let usePhoto = file.userPhoto != nil

        func adopt(_ slug: String, _ status: String?) {
            let made: [String: JSONValue] = [
                "slug": .string(slug), "status": .string(status ?? "pending"), "step": .string("created"),
                "publishedAt": .number((Date().timeIntervalSince1970 * 1000).rounded()), "verification": .null,
                "wantPic": .bool(wantPic), "kind": .string(printClaim ? "print" : "gallery"),
                "usePhoto": .bool(usePhoto),
            ]
            l = made
            shop.setMakerRunListing(made, on: file.id)
            createUncertain = false
            recreateConfirmed = false
            set("create", .done)
        }

        if l == nil, createUncertain, !recreateConfirmed {
            set("create", .running)
            do {
                if let hit = try await shop.makerRun.findRecent(title: title, since: Date().addingTimeInterval(-15 * 60)) {
                    adopt(hit.slug, hit.status)
                } else {
                    // Nothing matching on the account. Creating again is
                    // probably right — but it is the shop's call.
                    set("create", .pending)
                    running = false
                    stage = .recreate
                    return
                }
            } catch { fail("create", error); return }
        }
        if l == nil {
            set("create", .running)
            var input = form
            input.title = title
            input.description = form.description.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let created = try await shop.makerRun.create(input)
                adopt(created.slug, created.status)
            } catch { fail("create", error); return }
        }
        guard var current = l, let slug = Shop.plainString(current["slug"]) else { running = false; return }

        if Shop.plainString(current["step"]) == "created" {
            set("file", .running)
            do {
                guard let url = shop.modelFile(for: file) else {
                    throw MakerRun.Failure("missing", shop.words.callIt("mac.mkr_not_here"))
                }
                let name = file.sourceFile?.filename ?? url.lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                // Size and extension BEFORE reading: a 2 GB file is refused
                // without being loaded.
                if let issue = MakerRun.checkModel(filename: name, size: size) {
                    throw MakerRun.Failure("invalid", issue.message, details: [issue])
                }
                let data = try await Studio.offMain { try Data(contentsOf: url, options: .mappedIfSafe) }
                let up = try await shop.makerRun.uploadModel(slug: slug, filename: name, data: data)
                current["verification"] = .object([
                    "verified": .bool(up.verification.verified),
                    "printer": up.verification.printer.map(JSONValue.string) ?? .null,
                    "brand": up.verification.brand.map(JSONValue.string) ?? .null,
                    "reason": up.verification.reason.map(JSONValue.string) ?? .null,
                ])
                current["status"] = .string(up.status)
                current["step"] = .string("file")
                shop.setMakerRunListing(current, on: file.id)
                set("file", .done)
            } catch { fail("file", error); return }
        }
        if Shop.plainString(current["step"]) == "file" {
            if case .bool(true)? = current["wantPic"] {
                set("images", .running)
                do {
                    guard let picture = await shop.makerRunPicture(for: file) else {
                        throw MakerRun.Failure("missing", shop.words.callIt("mr.no_picture"))
                    }
                    let kind = Shop.plainString(current["kind"]) == "print" ? "print" : "gallery"
                    let stored = try await shop.makerRun.uploadImage(slug: slug, data: picture, kind: kind)
                    if !stored.failures.isEmpty {
                        note = shop.words.callIt("mr.image_failures", ["reasons": .string(stored.failures.joined(separator: " "))])
                    }
                    set("images", .done)
                } catch { fail("images", error); return }
            }
            current["step"] = .string("done")
            shop.setMakerRunListing(current, on: file.id)
        }
        running = false
    }

    private func skipPicture() {
        guard var l = listing, !running else { return }
        l["step"] = .string("done")
        l["wantPic"] = .bool(false)
        shop.setMakerRunListing(l, on: file.id)
        problem = nil
        stage = .status
        note = shop.words.callIt("mr.no_picture")
    }

    private func checkStatus() async {
        guard var l = listing, let slug = Shop.plainString(l["slug"]) else { return }
        let w = shop.words
        note = w.callIt("mr.checking")
        do {
            let r = try await shop.makerRun.status(slug: slug)
            problem = nil
            if !r.found {
                // Not seen is only "gone" when every listing was read.
                note = r.complete ? w.callIt("mr.status_gone")
                    : w.callIt("mr.status_not_in_recent", ["n": .string(w.numeral(r.searched))])
            } else {
                l["status"] = r.status.map(JSONValue.string) ?? .null
                var v: [String: JSONValue] = [:]
                if case .object(let old)? = l["verification"] { v = old }
                if let b = r.badge { v["badge"] = .bool(b) }
                if let f = r.fileChecked { v["fileChecked"] = .bool(f) }
                l["verification"] = .object(v)
                shop.setMakerRunListing(l, on: file.id)
                note = w.callIt("mr.status_now", ["status": .string(statusLabel(r.status))])
            }
        } catch {
            note = nil
            problem = shop.saidMakerRun(error)
        }
        stage = .status
    }

    private func doDelete() async {
        guard let l = listing, let slug = Shop.plainString(l["slug"]) else { return }
        do { _ = try await shop.makerRun.delete(slug: slug) }
        catch let f as MakerRun.Failure where f.code == "not_found" {
            // Already gone on the website is the outcome the shop asked for.
        } catch {
            problem = shop.saidMakerRun(error)
            stage = .status
            return
        }
        shop.setMakerRunListing(nil, on: file.id)
        problem = nil
        steps = []
        note = nil
        stage = .form
    }
}
