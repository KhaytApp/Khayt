import Foundation
import KhaytCore

/// MakerRun for the shop: the one client, its vocabularies, and the two things
/// that touch the book — a downloaded design becoming a library record, and a
/// listing's progress written onto the record it was published from.
///
/// ── THE RECORD A DOWNLOAD MAKES ───────────────────────────────────────────
///
/// The desktop makes it with `importConvertedAsNew`: the design's title as
/// `name`, its page as `source`, the licence id `toRecordLicence` can read
/// (none when it cannot), and `makerrun: {slug, license, creator}` with the
/// raw licence string kept beside it. The Mac makes the rest of the record
/// the way every Mac import makes it (`LibraryImport.prepare` — measured,
/// pictured, hashed), then sets those four fields exactly as the desktop does,
/// in the same write.
///
/// ── THE LISTING ───────────────────────────────────────────────────────────
///
/// `rec.makerrunListing` — `{slug, status, step, publishedAt, verification,
/// wantPic, kind, usePhoto}`, the desktop's own shape — is written after each
/// step succeeds, through the library's write chain (`editFiles`), so a
/// failure or a quit leaves a record that knows what exists on MakerRun and a
/// second Mac or the desktop can finish it.
extension Shop {

    /// The one client. Made on first use; its link lives in the Keychain.
    var makerRun: MakerRunClient {
        if let made = makerRunClient { return made }
        let made = MakerRunClient(store: MakerRunKeychain())
        makerRunClient = made
        return made
    }

    /// MakerRun's vocabularies, from `lib/makerrun-terms.js`, handed to the
    /// client once so it narrows and validates with the same lists.
    func makerRunTerms() async -> KhaytEngine.MakerRunTerms? {
        if let makerRunTermsLoaded { return makerRunTermsLoaded }
        guard let engine, let terms = try? await engine.makerRunTerms() else { return nil }
        await makerRun.setTerms(categories: terms.categories.map(\.value), materials: terms.materials,
                                licences: terms.licences)
        makerRunTermsLoaded = terms
        return terms
    }

    /// A refusal, said in the shop's language — the desktop's own words for
    /// each code (`bedready-makerrun.js` errorHtml).
    func saidMakerRun(_ error: Error, downloading: Bool = false, publishing: Bool = false) -> String {
        guard let f = error as? MakerRun.Failure else { return said(error) }
        return Self.saidMakerRun(f, words: words, downloading: downloading, publishing: publishing)
    }

    /// The sentence for a refusal. Static so a test can hold each code to it.
    ///
    /// The four codes the MakerRun lane checked against the live API:
    /// - `mfa_required` (403) is NOT a dead token. The shop finishes two-factor
    ///   on makerrun.com and tries again. Nothing here signs it out: only a
    ///   401 on `/api/app-token` clears the link.
    /// - `maintenance` (503) is MakerRun being down for a while, not a failure.
    ///   It is said once, with the wait, and nothing retries on its own.
    /// - `rate_limited` (429) while publishing is MakerRun's cap of 20 new
    ///   listings an hour and 60 a day. Said plainly; the half-made listing
    ///   stays on the record so Finish Upload resumes it.
    /// - `invalid` (422) names each refused field by the form's own label.
    static func saidMakerRun(_ f: MakerRun.Failure, words: Words, downloading: Bool = false,
                             publishing: Bool = false) -> String {
        switch f.code {
        case "not_linked", "relink", "auth", "unauthorized": return words.callIt("mr.err_relink")
        case "mfa_required": return words.callIt("mr.err_mfa")
        case "age_required": return words.callIt("mr.err_age")
        case "maintenance":
            let mins = max(1, Int((Double(f.retryAfter ?? 60) / 60).rounded()))
            return words.callIt("mr.err_maintenance", ["mins": .string(words.numeral(mins))])
        case "rate_limited":
            if publishing { return words.callIt("mac.mkr_rate_publish") }
            return words.callIt("mr.err_rate", ["secs": .string(words.numeral(f.retryAfter ?? 60))])
        case "forbidden", "rejected":
            return words.callIt(downloading ? "mr.err_forbidden_download" : "mr.err_forbidden")
        case "not_found": return words.callIt("mr.err_not_found")
        case "network", "timeout": return words.callIt("mr.err_network")
        case "unavailable": return words.callIt("mr.err_unavailable")
        case "bad_response": return words.callIt("mr.err_bad_response")
        case "invalid" where !f.details.isEmpty:
            let lines = f.details.map { d -> String in
                words.callIt("mac.mkr_field_refused", ["field": .string(fieldLabel(d.field, words: words)),
                                                       "message": .string(d.message.isEmpty ? words.callIt("mr.err_generic") : d.message)])
            }
            return lines.joined(separator: " ")
        default: return f.message.isEmpty ? words.callIt("mr.err_generic") : f.message
        }
    }

    /// A refused field, by the publish form's own label; an unknown one by name.
    static func fieldLabel(_ field: String, words: Words) -> String {
        switch field {
        case "title": words.callIt("mr.f_title")
        case "description": words.callIt("mr.f_description")
        case "category": words.callIt("mr.f_category")
        case "material": words.callIt("mr.f_material")
        case "license": words.callIt("mr.f_licence")
        case "nsfw": words.callIt("mr.f_nsfw")
        case "file": words.callIt("mr.files")
        default: field
        }
    }

    // MARK: - Downloading into the library

    /// The fields a MakerRun design puts on its record, as the desktop's
    /// `importConvertedAsNew` takes them: each only in the shape its editor
    /// would write.
    nonisolated static func makerRunFields(slug: String, license: String?, creator: String?,
                                           page: String?, recordLicence: String?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let page = page?.trimmingCharacters(in: .whitespacesAndNewlines), !page.isEmpty {
            out["source"] = .string(String(page.prefix(300)))
        }
        if let recordLicence, ModelLicence.all.contains(where: { $0.id == recordLicence }) {
            out["licence"] = .string(recordLicence)
        }
        out["makerrun"] = .object([
            "slug": .string(String(slug.prefix(200))),
            "license": license.map { .string(String($0.prefix(120))) } ?? .null,
            "creator": creator.map { .string(String($0.prefix(120))) } ?? .null,
        ])
        return out
    }

    /// Download one hosted file of a design and add it to the library as a
    /// new model. The licence was named on the button pressed; that press is
    /// the acknowledgement, as on the desktop. Returns the new record's id.
    func downloadFromMakerRun(_ design: MakerRun.Design, file: MakerRun.File) async throws -> String {
        guard permitted("inventory", "create") else {
            throw MakerRun.Failure("forbidden", moveProblem ?? words.callIt("mr.err_forbidden"))
        }
        guard let build = source.build, StoreLock.weOwnIt(build) else { throw LibraryImport.Failure.notOurs }
        guard let roots = libraryRoots else { throw LibraryImport.Failure.noLibrary }
        guard let engine else { throw LibraryImport.Failure.failed("the engine is not loaded") }
        _ = await makerRunTerms()

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("khayt-makerrun-" + UUID().uuidString, isDirectory: true)
        defer { let dir = staging; DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: dir) } }
        let downloaded = try await makerRun.download(slug: design.slug, filename: file.filename,
                                                     title: design.title, into: staging)

        let recordLicence = try? await engine.recordLicence(fromMakerRun: design.license)
        let fields = Self.makerRunFields(slug: design.slug, license: design.license, creator: design.creator,
                                         page: design.url, recordLicence: recordLicence ?? nil)
        var made = try await LibraryImport.prepare(
            downloaded, libraryRoot: URL(fileURLWithPath: roots.primary),
            knownHashes: Set(files.compactMap(\.contentHash)),
            nameOfExisting: { hash in self.files.first { $0.contentHash == hash }?.title },
            engine: engine, title: design.title, analyseRisk: analysesRiskAtImport)
        var record = made.record
        // The design's title verbatim, as the desktop's `displayName` wins.
        record["name"] = .string(design.title.isEmpty ? "Untitled" : design.title)
        for (k, v) in fields { record[k] = v }
        made = LibraryImport.Prepared(dir: made.dir, record: record, added: made.added)
        do {
            // lock: StoreLock.weOwnIt above; written as one record, newest first.
            try await LibraryImport.write([made], storeURL: build.storeURL,
                                          owns: { StoreLock.weOwnIt(build) },
                                          whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) })
        } catch {
            try? FileManager.default.removeItem(at: made.dir)
            throw LibraryImport.Failure.failed(ErrorText.plain(error))
        }
        await load(source)
        return made.added.id
    }

    /// Show a model in the library, from another window.
    func showInLibrary(_ id: String) {
        shelf = .library(nil)
        fileSelection = [id]
    }

    // MARK: - The listing on the record

    /// `rec.makerrunListing`, as stored — nil when the model was never
    /// published from Khayt.
    func makerRunListing(of fileId: String) -> [String: JSONValue]? {
        guard case .object(let o)? = fileRecord(fileId)?["makerrunListing"] else { return nil }
        return o
    }

    /// `rec.makerrun` — set when the model was downloaded FROM MakerRun.
    func makerRunOrigin(of fileId: String) -> (slug: String, creator: String?)? {
        guard case .object(let o)? = fileRecord(fileId)?["makerrun"], case .string(let slug)? = o["slug"] else { return nil }
        if case .string(let c)? = o["creator"] { return (slug, c) }
        return (slug, nil)
    }

    /// Write the listing (nil removes it), through the library's write chain.
    @discardableResult
    func setMakerRunListing(_ listing: [String: JSONValue]?, on fileId: String) -> Bool {
        let stamp = LibraryImport.iso(Date().timeIntervalSince1970 * 1000)
        return editFiles([fileId], named: words.callIt("mr.publish_title")) { record in
            if let listing { record["makerrunListing"] = .object(listing) }
            else { record.removeValue(forKey: "makerrunListing") }
            record["updatedAt"] = .string(stamp)
        }
    }

    /// The picture a listing is published with: the shop's photo, else the
    /// record's inline preview, else its preview file — fitted to MakerRun's
    /// 2048-pixel longest edge, because MakerRun refuses rather than resamples.
    func makerRunPicture(for file: LibraryFile) async -> Data? {
        func dataURL(_ s: String?) -> Data? {
            guard let s, s.hasPrefix("data:image/"), let comma = s.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(s[s.index(after: comma)...]))
        }
        var raw = dataURL(file.userPhoto)
        if raw == nil, case .string(let t)? = fileRecord(file.id)?["thumb"] { raw = dataURL(t) }
        let dir = modelFile(for: file)?.deletingLastPathComponent()
        let thumb = file.thumbFile
        let picked = raw
        return await PinWork.run { () -> Data? in
            var bytes = picked
            if bytes == nil, let dir {
                for name in [thumb, "thumb.jpg", "thumb.png", "thumb.webp"].compactMap({ $0 }) where !name.contains("/") {
                    if let d = try? Data(contentsOf: dir.appendingPathComponent(name)) { bytes = d; break }
                }
            }
            guard let bytes, !bytes.isEmpty, bytes.count <= 64 * 1024 * 1024 else { return nil }
            return MakerRunPicture.fitted(bytes)
        }
    }
}
