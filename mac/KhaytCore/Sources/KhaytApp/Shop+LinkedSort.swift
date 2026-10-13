import Foundation
import SwiftUI
import KhaytCore

/// What asking the shop's assistant came to, for the note under the buttons.
struct SortAsk: Sendable, Equatable {
    /// Folders it sorted this time.
    var sorted = 0
    /// Why it stopped, when it did. The heuristic stands for the rest.
    var problem: String?
    /// Folders not asked about this time because their request kept failing
    /// (`SortFailures`) — sorted on this Mac instead.
    var held = 0
    /// Loose top-level files it was asked about this time (`LooseCache`).
    var loose = 0
    /// Loose files not asked about because their request kept failing.
    var looseHeld = 0

    @MainActor func line(_ words: Words) -> String? {
        var parts: [String] = []
        if let problem { parts.append(words.callIt("mac.sort_ai_failed", ["why": .string(problem)])) }
        else {
            if sorted > 0 { parts.append(words.callIt("mac.sort_ai_used", ["n": .number(Double(sorted))])) }
            if loose > 0 { parts.append(words.callIt("mac.sort_ai_loose", ["n": .number(Double(loose))])) }
        }
        if held > 0 { parts.append(words.callIt("mac.sort_ai_held", ["n": .number(Double(held))])) }
        if looseHeld > 0 { parts.append(words.callIt("mac.sort_ai_loose_held", ["n": .number(Double(looseHeld))])) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// "Sort linked folders": what the sort would do, before it does it.
struct SortPreview: Identifiable {
    struct Row: Identifiable {
        /// The group (or, for a print of one model, its title).
        let id: String
        let name: String
        let models: Int
        let picture: ThumbnailSource?
        /// The collection it came from, when it came from one.
        let from: String?
    }

    let id = UUID()
    let plans: [PrintSort.Plan]
    let rows: [Row]
    let collections: Int
    let moved: Int
    let renamed: Int
    let tagged: Int
    /// Linked models the shop grouped by hand, left where they are.
    let kept: Int
    let assistant: SortAsk?
    /// The shop has not turned the assistant on for this.
    let assistantOff: Bool
    /// Models loose at the top of the linked folders, how many of them the
    /// sort put in a print, and in how many prints (`LooseSort`).
    var loose = (total: 0, grouped: 0, prints: 0)

    /// The loose figures of some sorted linked folders.
    nonisolated static func looseCounts(_ plans: [PrintSort.Plan]) -> (total: Int, grouped: Int, prints: Int) {
        var total = 0, grouped = 0, prints = 0
        for plan in plans {
            total += plan.looseModels.count
            grouped += plan.loose.values.reduce(0) { $0 + $1.members.count }
            prints += plan.loose.count
        }
        return (total, grouped, prints)
    }
}

extension Shop {

    // MARK: - Asking the assistant

    /// Ask the shop's assistant about every top-level folder it has not
    /// answered for yet (`SortCache`), a batch at a time, and keep what it
    /// says in the book — with what it cost in `settings.aiUsage`.
    ///
    /// Never the first thing that happens: the library is already filed by
    /// the heuristic when this runs, and anything it does not answer, or any
    /// fault on the way, leaves the heuristic standing. Stop ends it between
    /// requests.
    ///
    /// ── A REQUEST THAT KEEPS FAILING IS NOT PAID FOR ON EVERY LAUNCH ──────
    ///
    /// The launch pass (`byHand: false`) skips a request that failed today,
    /// and one that failed three times until its folders change
    /// (`SortFailures`); the note says how many folders that left unsorted.
    /// "Sort linked folders…" (`byHand: true`) always tries.
    func askAssistantToSort(_ plans: [PrintSort.Plan], stop: ScanStop?, byHand: Bool = false) async -> SortAsk {
        guard aiLibraryAllowed, let build = source.build, let engine else { return SortAsk() }
        let settings = settingsDict
        let units = plans.flatMap(SortCache.units).filter { !SortCache.isCached($0, in: settings) }
        // The loose top-level files not asked about yet, in copy order — at
        // most `LooseCache.perScan` names this scan, `perRequest` a request.
        var looseBatches: [(root: URL, names: [String])] = []
        var budget = LooseCache.perScan
        for plan in plans where budget > 0 {
            let names = Array(LooseCache.pending(plan, settings: settings).prefix(budget))
            budget -= names.count
            looseBatches += LooseCache.batches(names, births: plan.births).map { (plan.root, $0) }
        }
        guard !units.isEmpty || !looseBatches.isEmpty else { return SortAsk() }
        librarySortAsking = true
        defer { librarySortAsking = false }

        var got = PrintSort.Answers()
        var answeredPaths = Set<String>()
        var ledger: JSONValue = settings["aiUsage"] ?? .object([:])
        var spent = false
        var result = SortAsk()
        let today = SortFailures.today()
        let marks = SortFailures.read(settings)
        let batches = SortCache.batches(units)
        let pending = Set(batches.map(SortCache.signature)).union(looseBatches.map { LooseCache.signature($0.names) })
        var asked = Set<String>(), failed = Set<String>()
        var halted = false
        for batch in batches {
            if halted || stop?.isStopped == true || Task.isCancelled { break }
            let sig = SortCache.signature(batch)
            if !byHand, SortFailures.held(sig, in: marks, today: today) {
                result.held += batch.count
                continue
            }
            asked.insert(sig)
            do {
                let reply = try await AiClient.sortFolders(batch, shop: self)
                got.roles.merge(reply.answers.roles) { a, _ in a }
                got.names.merge(reply.answers.names) { a, _ in a }
                answeredPaths.formUnion(batch.map(\.path))
                if let usage = reply.usage, usage != .null,
                   let next = try? await engine.aiUsageRecord(ledger: ledger, task: "library", model: reply.model,
                                                              usage: usage, now: Date()) {
                    ledger = next
                    spent = true
                }
            } catch AiClient.Failure.notConsented {
                asked.remove(sig)
                halted = true               // switched off meanwhile: the heuristic stands, nothing to say
            } catch AiClient.Failure.noKey {
                // Nothing was sent, so nothing to hold against the request.
                // In the shop's words, not "No API key" in an Arabic sentence.
                asked.remove(sig)
                result.problem = words.callIt("mac.ai_no_key")
                halted = true
            } catch {
                // This request failed; the next may not (one too long for
                // the provider says nothing about the others).
                failed.insert(sig)
                result.problem = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
        // THE LOOSE FILES, the same way: names only, a batch at a time, each
        // answer kept as it comes, a failing request held like a folder's.
        var looseAnswered: [LooseCache.Answered] = []
        for batch in looseBatches {
            if halted || stop?.isStopped == true || Task.isCancelled { break }
            let sig = LooseCache.signature(batch.names)
            if !byHand, SortFailures.held(sig, in: marks, today: today) {
                result.looseHeld += batch.names.count
                continue
            }
            asked.insert(sig)
            do {
                let reply = try await AiClient.groupLoose(batch.names, shop: self)
                looseAnswered.append(LooseCache.answered(root: batch.root, sent: batch.names, prints: reply.prints))
                result.loose += batch.names.count
                if let usage = reply.usage, usage != .null,
                   let next = try? await engine.aiUsageRecord(ledger: ledger, task: "library", model: reply.model,
                                                              usage: usage, now: Date()) {
                    ledger = next
                    spent = true
                }
            } catch AiClient.Failure.notConsented {
                asked.remove(sig)
                halted = true
            } catch AiClient.Failure.noKey {
                asked.remove(sig)
                result.problem = words.callIt("mac.ai_no_key")
                halted = true
            } catch {
                failed.insert(sig)
                result.problem = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
        // A unit is remembered only when every one of its folders came back:
        // half an answer is asked again next time, not trusted as whole.
        let answered = units.filter { $0.entries.allSatisfy { answeredPaths.contains($0.path) } }
            .map { (unit: $0, answers: got) }
        result.sorted = answered.reduce(0) { $0 + $1.unit.entries.count }
        let nextMarks = SortFailures.after(marks, asked: asked, failed: failed, pending: pending, today: today)
        guard !answered.isEmpty || !looseAnswered.isEmpty || spent || nextMarks != marks else { return result }
        var present: [String: Set<String>] = [:]
        for plan in plans { present[plan.root.standardizedFileURL.path] = Set(plan.looseModels) }
        do {
            // lock: system — the shop turned this on; it writes only the
            // assistant's answers, their cost and which requests failed.
            try StoreWriter.update(build) { root in
                SortCache.store(answered, into: &root)
                LooseCache.store(looseAnswered, present: present, into: &root)
                if nextMarks != marks { SortFailures.write(nextMarks, into: &root) }
                if spent {
                    var s = Self.settings(root)
                    s["aiUsage"] = ledger
                    root["settings"] = .object(s)
                }
            }
        } catch {
            result.problem = String(describing: error)
        }
        return result
    }

    // MARK: - The prints' pictures

    /// Give the prints their pictures — a print's group wears its best
    /// picture (`PrintSort.pictures`), a print of one model wears it as the
    /// model's own photo, and a model with a picture of its very own name
    /// wears that. Returns how many pictures were put on.
    ///
    /// ── PICTURES ONLY, AND NOT MANY ───────────────────────────────────────
    ///
    /// A picture is small, so one the drive keeps online is fetched — read,
    /// which is what makes the drive download it — but never a model, never
    /// one bigger than `PrintPhotos.maxBytes`, at most `perPass` a pass, off
    /// the main actor, and Stop ends it. Every print looked at is remembered
    /// and not looked at again, so a picture the shop took off stays off; a
    /// group with a picture already, and a model whose photo the shop
    /// removed (`userPhotoRemoved`), are left alone.
    func fetchPrintPictures(_ plans: [PrintSort.Plan], stop: ScanStop?) async -> Int {
        guard let build = source.build, let roots = libraryRoots else { return 0 }
        let settings = settingsDict
        let jobs = PrintPhotos.jobs(plans, looked: PrintPhotos.looked(settings), limit: PrintPhotos.perPass * 4)
        guard !jobs.isEmpty else { return 0 }
        let covers = GroupKinds.covers(settings)
        // Linked records with no photo, by the file they point at.
        var photoless = Set<String>()
        var indexed = Set<String>()
        for case .object(let o) in fileRows {
            guard case .string(let p)? = o["externalPath"], !p.isEmpty else { continue }
            let hasPhoto: Bool = { if case .string(let s)? = o["userPhoto"], !s.isEmpty { true } else { false } }()
            let removed: Bool = { if case .bool(true)? = o["userPhotoRemoved"] { true } else { false } }()
            let path = URL(fileURLWithPath: p).standardizedFileURL.path
            indexed.insert(path)
            if !hasPhoto, !removed { photoless.insert(path) }
        }
        let primary = roots.primary
        var groupPictures: [(group: String, rel: String)] = []
        var modelPhotos: [String: String] = [:]
        var looked: [String] = []
        var fetched = 0
        for job in jobs {
            if stop?.isStopped == true || Task.isCancelled || fetched >= PrintPhotos.perPass { break }
            // ── LOOKED AT ONLY ONCE SETTLED (Oct 2026) ─────────────────────
            // A print is remembered as looked at when it got its picture, or
            // already had one, or the picture would not decode — so a print
            // left over by the per-pass cap, one whose pictures were all too
            // big, or a model not indexed yet is tried again next pass, until
            // every print with a picture wears one. Remembered once it got
            // one, so a picture the shop took off is never put back.
            var settled = true
            if let group = job.group, covers[group] == nil {
                if let pick = await PinWork.run({ PrintPhotos.pick(job.candidates) }) {
                    fetched += 1
                    if let rel = await PinWork.run({ try? GroupPictures.write(GroupPictures.encode(pick), for: group, under: primary) }) {
                        groupPictures.append((group, rel))
                    }
                } else {
                    settled = false
                }
            }
            if let only = job.only {
                if photoless.contains(only) {
                    if let pick = await PinWork.run({ PrintPhotos.pick(job.candidates) }) {
                        fetched += 1
                        if let uri = await PinWork.run({ try? LibraryPhoto.dataURI(of: pick) }) { modelPhotos[only] = uri }
                    } else {
                        settled = false
                    }
                } else if !indexed.contains(only) {
                    settled = false                      // not in the book yet
                }
            }
            if settled { looked.append(job.print) }
            for (model, image) in job.modelPictures.sorted(by: { $0.key < $1.key })
            where photoless.contains(model) && modelPhotos[model] == nil && fetched < PrintPhotos.perPass {
                guard let pick = await PinWork.run({ PrintPhotos.pick([image]) }) else { continue }
                fetched += 1
                if let uri = await PinWork.run({ try? LibraryPhoto.dataURI(of: pick) }) { modelPhotos[model] = uri }
            }
        }
        guard !looked.isEmpty || !modelPhotos.isEmpty || !groupPictures.isEmpty else { return 0 }
        var put = 0
        var unused: [String] = []
        do {
            // lock: system — part of the linked pass: pictures for the prints
            // it filed, never over one the shop chose.
            try StoreWriter.update(build) { root in
                var rows: [JSONValue] = []
                if case .array(let r)? = root["printFiles"] { rows = r }
                var changed = false
                for (i, row) in rows.enumerated() {
                    guard case .object(var o) = row, case .string(let p)? = o["externalPath"],
                          let uri = modelPhotos[URL(fileURLWithPath: p).standardizedFileURL.path] else { continue }
                    // Judged again on the book as it is now.
                    if case .string(let s)? = o["userPhoto"], !s.isEmpty { continue }
                    if case .bool(true)? = o["userPhotoRemoved"] { continue }
                    o["userPhoto"] = .string(uri)
                    StoreWriter.stamp(&o)
                    rows[i] = .object(o)
                    changed = true
                    put += 1
                }
                if changed { root["printFiles"] = .array(rows) }
                let now = GroupKinds.covers(Self.settings(root))
                let live = Set(GroupKinds.groupPaths(root))
                for (group, rel) in groupPictures {
                    guard now[group] == nil, live.contains(where: { Self.isUnder($0, group) }) else { unused.append(rel); continue }
                    GroupKinds.setCover(.image(rel), for: group, into: &root)
                    put += 1
                }
                PrintPhotos.markLooked(looked, into: &root)
            }
        } catch {
            unused = groupPictures.map(\.rel)
            put = 0
        }
        // A picture written for a group that, by the time of the write, had
        // one of its own: nobody wears it.
        for rel in unused {
            if let url = GroupPictures.url(of: rel, roots: roots.roots + [primary]) { try? FileManager.default.removeItem(at: url) }
        }
        return put
    }

    // MARK: - "Sort linked folders"

    /// Work out what sorting the linked folders would do, for the sheet:
    /// walk them, ask the assistant when the shop turned it on, and count
    /// what would move. Changes nothing in the library.
    func previewLinkedSort() async {
        guard let roots = libraryRoots else { return }
        let folders = linkedFolders.filter { FileManager.default.fileExists(atPath: $0) }
        guard !folders.isEmpty, !libraryMoveBusy else { return }
        libraryMoveProblem = nil
        libraryMoveBusy = true
        let stop = ScanStop()
        libraryScanStop = stop
        defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }
        let vaults = roots.roots + [roots.primary]
        let settings = settingsDict
        let walked = await PinWork.run {
            Shop.linkedWalk(folders.map { URL(fileURLWithPath: $0) }, skippingAll: vaults, known: [],
                            settings: settings, stop: stop)
        }
        if stop.isStopped || Task.isCancelled { return }
        var sorted = walked.map(\.plan)
        var asked: SortAsk?
        if aiLibraryAllowed {
            // Pressed by hand: always tries, even a request that kept failing.
            let a = await askAssistantToSort(sorted, stop: stop, byHand: true)
            asked = a
            if a.sorted > 0 || a.loose > 0 {
                await load(source)
                let answered = settingsDict
                sorted = await PinWork.run {
                    walked.map { Shop.sortedPlan(root: $0.root, models: $0.models, images: $0.images,
                                                 settings: answered, births: $0.plan.births) }
                }
            }
        }
        if stop.isStopped || Task.isCancelled { return }
        let plans = sorted
        let rows = fileRows
        let covers = GroupKinds.covers(settingsDict)
        let pictureRoots = libraryRoots?.roots ?? []
        let counted = await PinWork.run { Shop.sortCounts(plans, rows: rows) }
        // One row per print: its group's picture when it has one, else the
        // first of its own pictures that is already on this Mac.
        let printRows = await PinWork.run { () -> [SortPreview.Row] in
            var out: [String: SortPreview.Row] = [:]
            for plan in plans {
                var perGroup: [String: Int] = [:]
                var collection: [String: String] = [:]
                var picture: [String: URL] = [:]
                for (rel, p) in plan.placed {
                    guard let print = p.print else { continue }
                    let id = plan.group(ofPrint: print) ?? (p.title ?? rel)
                    perGroup[id, default: 0] += 1
                    if let c = p.collection { collection[id] = c }
                    if picture[id] == nil {
                        if let first = plan.pictures(ofPrint: print)
                            .lazy.map({ plan.root.appending(path: $0) })
                            .first(where: { !LinkedCloud.isOnlineOnly($0) }) {
                            picture[id] = first
                        }
                    }
                }
                for (id, n) in perGroup {
                    let had = out[id]
                    var source: ThumbnailSource? = had?.picture
                    if case .image(let rel)? = covers[id], let url = GroupPictures.url(of: rel, roots: pictureRoots) {
                        source = .file(url)
                    } else if source == nil, let url = picture[id] {
                        source = .file(url)
                    }
                    out[id] = SortPreview.Row(id: id, name: id, models: n + (had?.models ?? 0), picture: source,
                                              from: had?.from ?? collection[id])
                }
            }
            return out.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var preview = SortPreview(plans: plans, rows: printRows, collections: counted.collections,
                                  moved: counted.moved, renamed: counted.renamed, tagged: counted.tagged,
                                  kept: counted.kept, assistant: asked, assistantOff: !aiLibraryAllowed)
        preview.loose = SortPreview.looseCounts(plans)
        sortPreview = preview
    }

    /// What applying `plans` to `rows` would change — the same judgement
    /// `LinkedRegroup.changes` makes, counted.
    nonisolated static func sortCounts(_ plans: [PrintSort.Plan], rows: [JSONValue])
        -> (moved: Int, renamed: Int, tagged: Int, kept: Int, collections: Int) {
        var moved = 0, renamed = 0, tagged = 0, kept = 0
        var current: [String: String] = [:]
        for case .object(let o) in rows {
            guard case .string(let id)? = o["id"] else { continue }
            let folder: String? = { if case .string(let s)? = o["folder"] { s } else { nil } }()
            let group: String? = { if case .string(let s)? = o["group"] { s } else { nil } }()
            current[id] = LibraryFile.groupName(folder: folder, group: group) ?? ""
        }
        var collections = Set<String>()
        for plan in plans {
            let changes = LinkedRegroup.changes(rows: rows, plan: plan)
            for c in changes {
                if c.group != current[c.id] { moved += 1 }
                if c.name != nil { renamed += 1 }
                if c.tag != nil { tagged += 1 }
            }
            // Linked records under it that no rule may move, and that are not
            // already where the sort puts them: the shop's own.
            let movable = Set(changes.map(\.id))
            for case .object(let o) in rows {
                guard case .string(let id)? = o["id"], !movable.contains(id),
                      case .string(let p)? = o["externalPath"], LibraryMove.under(p, plan.root.path),
                      let target = plan.placement(of: URL(fileURLWithPath: p)) else { continue }
                if current[id] != LibraryFile.normalise(target.group) { kept += 1 }
            }
            for p in plan.placed.values where p.print != nil {
                if let c = p.collection { collections.insert(c) }
            }
        }
        return (moved, renamed, tagged, kept, collections.count)
    }

    /// Apply the sort the sheet showed: the records refiled through the same
    /// protections as every refile (judged again on the book as it is now),
    /// then the prints' pictures.
    func applyLinkedSort(_ preview: SortPreview) async {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, StoreLock.weOwnIt(build), !libraryMoveBusy else { return }
        sortPreview = nil
        libraryMoveProblem = nil
        libraryMoveBusy = true
        let stop = ScanStop()
        libraryScanStop = stop
        defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }
        do {
            let n = try Self.regroupLinked(preview.plans, linked: linkedFolders, storeURL: build.storeURL,
                                           owns: { StoreLock.weOwnIt(build) },
                                           whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) })
            await load(source)
            let pictures = stop.isStopped ? 0 : await fetchPrintPictures(preview.plans, stop: stop)
            if pictures > 0 { await load(source) }
            var lines = [words.callIt("mac.linked_regrouped", ["n": .number(Double(n))])]
            if pictures > 0 { lines.append(words.callIt("mac.sort_pictures_added", ["n": .number(Double(pictures))])) }
            libraryMoveNote = lines.joined(separator: " ")
        } catch {
            libraryMoveProblem = String(describing: error)
        }
    }
}

/// The sheet "Sort linked folders" opens: what was found, what would change,
/// and Apply / Cancel.
struct LinkedSortSheet: View {
    let shop: Shop
    let preview: SortPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("mac.sort_title")).font(.title2.weight(.semibold))
            Text(shop.words.callIt("mac.sort_summary", ["prints": .number(Double(preview.rows.count)),
                                                        "collections": .number(Double(preview.collections))]))
                .font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                Text(shop.words.callIt("mac.sort_moved", ["n": .number(Double(preview.moved))]))
                if preview.loose.total > 0 {
                    Text(shop.words.callIt("mac.sort_loose", ["n": .number(Double(preview.loose.grouped)),
                                                              "total": .number(Double(preview.loose.total)),
                                                              "prints": .number(Double(preview.loose.prints))]))
                }
                if preview.renamed > 0 {
                    Text(shop.words.callIt("mac.sort_renamed", ["n": .number(Double(preview.renamed))]))
                }
                if preview.tagged > 0 {
                    Text(shop.words.callIt("mac.sort_tagged", ["n": .number(Double(preview.tagged))]))
                }
                if preview.kept > 0 {
                    Text(shop.words.callIt("mac.sort_kept", ["n": .number(Double(preview.kept))]))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let line = preview.assistant?.line(shop.words) {
                Label(line, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if preview.assistantOff {
                Label(shop.words.callIt("mac.sort_ai_off"), systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(preview.rows) { row in
                HStack(spacing: 10) {
                    Thumbnail(source: row.picture)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.name).lineLimit(1)
                        if let from = row.from {
                            Text(shop.words.callIt("mac.sort_from", ["name": .string(from)]))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(shop.words.callIt("mac.sort_models", ["n": .number(Double(row.models))]))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel"), role: .cancel) {
                    shop.sortPreview = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.sort_apply")) {
                    let chosen = preview
                    dismiss()
                    Task { await shop.applyLinkedSort(chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!shop.canWrite || preview.moved + preview.renamed + preview.tagged == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480)
    }
}
