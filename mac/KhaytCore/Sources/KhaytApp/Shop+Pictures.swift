import Foundation
import KhaytCore

/// What "Check pictures" came to, for the note in the sheet.
struct PictureAsk: Sendable, Equatable {
    /// Pictures the assistant looked at this time.
    var checked = 0
    /// Put on because it said yes and had the print's own preview to compare.
    var attached = 0
    /// The provider cannot take images: nothing was sent.
    var unsupported = false
    var problem: String?
}

extension Shop {

    // MARK: - Whether a print already wears a picture

    /// The book's linked record for a model, by its path below the linked folder.
    private func record(_ plan: PrintSort.Plan, _ rel: String) -> LibraryFile? {
        let path = plan.root.appending(path: rel).standardizedFileURL.path
        return files.first { ($0.externalPath).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path }
    }

    /// Whether a picture is already on it: the group's cover, or the model's
    /// own photo — or one the shop took off (`userPhotoRemoved`). Never put
    /// over either.
    func hasPicture(_ plan: PrintSort.Plan, _ target: LooseSort.Suggestion.Target) -> Bool {
        switch target {
        case .print(let key):
            // Settled once with a picture (`PrintPhotos.markLooked`): one the
            // shop took off a GROUP leaves no marker of its own, so without
            // this the sheet offered it again, ticked (review of #1844).
            if PrintPhotos.looked(settingsDict).contains(plan.root.appending(path: key).standardizedFileURL.path) {
                return true
            }
            if let group = plan.group(ofPrint: key) { return GroupKinds.covers(settingsDict)[group] != nil }
            guard let only = plan.models(ofPrint: key).first else { return true }
            return hasPicture(plan, .model(only))
        case .model(let rel):
            guard let file = record(plan, rel) else { return false }
            if file.userPhoto?.isEmpty == false { return true }
            return fileRows.contains { row in
                guard case .object(let o) = row, case .string(file.id)? = o["id"] else { return false }
                if case .bool(true)? = o["userPhotoRemoved"] { return true }
                return false
            }
        }
    }

    /// The print's own preview, when one of its models is ON THIS MAC: the
    /// picture its 3MF carries first, else the one this app drew of it. Read
    /// from the vault, where indexing a downloaded file put it — a model kept
    /// only in the cloud has none, and is never downloaded to make one.
    func reference(_ plan: PrintSort.Plan, _ target: LooseSort.Suggestion.Target) -> URL? {
        guard let roots = libraryRoots?.roots else { return nil }
        let rels: [String] = {
            switch target {
            case .print(let key): plan.models(ofPrint: key)
            case .model(let rel): [rel]
            }
        }()
        let held = rels.compactMap { record(plan, $0) }.filter { $0.thumbFile?.isEmpty == false }
        let ordered = held.filter(\.hasEmbeddedPreview) + held.filter { !$0.hasEmbeddedPreview }
        for file in ordered {
            guard let thumb = file.thumbFile, let dir = LibraryLocation.directory(for: file.id, roots: roots) else { continue }
            let url = dir.appending(path: (thumb as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: url.path), !LinkedCloud.isOnlineOnly(url) { return url }
        }
        return nil
    }

    // MARK: - "Check pictures"

    /// Ask the assistant about the pictures the sort is not sure of — at most
    /// `PictureSend.checksPerScan` a scan, its own budget. Each check sends the
    /// print's name, the photo redrawn (`PictureSend.jpeg`) and, when there is
    /// one, the print's own preview (`reference`). A verdict is kept by the
    /// photo's bytes and the print, so the same pair is never sent twice:
    ///
    ///   yes + preview → put on (never over a picture the shop set or took off)
    ///   yes, no preview → offered, ticked
    ///   no → never offered again
    ///   unsure, or a fault → offered, unticked
    ///
    /// Independent of "Sort linked folders": it checks any picture the sort
    /// offered, the Mac's own finds included.
    ///
    /// `put`: false from the "Sort linked folders…" preview, which changes
    /// nothing in the library until Apply — a "yes" there is offered ticked.
    func checkPictures(_ plans: [PrintSort.Plan], stop: ScanStop?, byHand: Bool = false,
                       put: Bool = true) async -> PictureAsk {
        var result = PictureAsk()
        guard aiPicturesAllowed, let build = source.build, let engine else { return result }
        let settings = settingsDict
        guard (try? await engine.aiTakesImages(settings: settings)) == true else {
            result.unsupported = true
            return result
        }
        let rejected = PictureRejects.read(settings)
        let verdicts = PictureVerdicts.read(settings)
        let knownHashes = PictureVerdicts.hashes(settings)
        let today = SortFailures.today()
        var marks = SortFailures.read(settings)
        /// The failure marks this pass changed — merged into the book's
        /// marks inside the write, never written over the folder sort's.
        var touched = Set<String>()
        var ledger: JSONValue = settings["aiUsage"] ?? .object([:])
        var spent = false
        var newVerdicts: [String: PictureVerdicts.Verdict] = [:]
        var hashes: [String: String] = [:]
        var rejects: [String] = []
        var attach: [(plan: PrintSort.Plan, suggestion: LooseSort.Suggestion)] = []
        var budget = PictureSend.checksPerScan
        outer: for plan in plans {
            for s in plan.suggestions {
                if budget <= 0 || stop?.isStopped == true || Task.isCancelled { break outer }
                guard !rejected.contains(PictureRejects.id(root: plan.root, image: s.image, target: s.target)),
                      !hasPicture(plan, s.target) else { continue }
                let url = plan.root.appending(path: s.image)
                // Already judged (by the bytes it had then): not read again —
                // reading is the download — and not counted against the 40,
                // or 40 unsure pairs would hold the budget for good.
                if PictureVerdicts.judged(verdicts, hashes: knownHashes, root: plan.root,
                                          image: s.image, target: s.target) { continue }
                let listed = LinkedCloud.listedSize(url)
                guard listed > 0, listed <= PictureSend.maxSourceBytes else { continue }
                budget -= 1
                // Reading it is what fetches a picture kept online — within
                // the 8 MB cap and this scan's budget.
                guard let data = await PinWork.run({ try? Data(contentsOf: url) }) else { continue }
                let hash = PictureSend.hash(data)
                hashes[plan.root.standardizedFileURL.path + "|" + s.image] = hash
                let key = PictureVerdicts.key(hash: hash, root: plan.root, target: s.target)
                if verdicts[key] != nil || newVerdicts[key] != nil { continue }      // never sent twice
                let sig = "picture:" + key
                if !byHand, SortFailures.held(sig, in: marks, today: today) { continue }
                guard let photo = await PinWork.run({ try? PictureSend.jpeg(data: data) }) else { continue }
                let ref = reference(plan, s.target)
                let refData = await PinWork.run { ref.flatMap { try? PictureSend.jpeg(url: $0) } }
                let name: String = {
                    switch s.target {
                    case .print(let k): plan.group(ofPrint: k) ?? plan.name(ofPrint: k)
                    case .model(let rel): LinkedRegroup.stem(plan.root.appending(path: rel))
                    }
                }()
                do {
                    let reply = try await AiClient.checkPicture(printName: name, photo: photo, reference: refData, shop: self)
                    result.checked += 1
                    touched.insert(sig)
                    if reply.answer.ok {
                        marks[sig] = nil
                        newVerdicts[key] = PictureVerdicts.Verdict(verdict: reply.answer.verdict, reference: refData != nil)
                    } else {
                        // No verdict came back: held like a failure, or the
                        // same pair was sent again on every scan.
                        marks[sig] = SortFailures.Mark(count: (marks[sig]?.count ?? 0) + 1, last: today)
                        result.problem = reply.answer.problem
                    }
                    switch reply.answer.outcome {
                    case "attach" where reply.answer.ok: attach.append((plan, s))
                    case "rejected": rejects.append(PictureRejects.id(root: plan.root, image: s.image, target: s.target))
                    default: break
                    }
                    if let usage = reply.answer.usage, usage != .null,
                       let next = try? await engine.aiUsageRecord(ledger: ledger, task: "pictures", model: reply.model,
                                                                  usage: usage, now: Date()) {
                        ledger = next
                        spent = true
                    }
                } catch AiClient.Failure.noVision {
                    result.unsupported = true
                    break outer
                } catch AiClient.Failure.notConsented {
                    break outer
                } catch AiClient.Failure.noKey {
                    result.problem = words.callIt("mac.ai_no_key")
                    break outer
                } catch {
                    touched.insert(sig)
                    marks[sig] = SortFailures.Mark(count: (marks[sig]?.count ?? 0) + 1, last: today)
                    result.problem = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
            }
        }
        let marksNow = marks
        let changedSigs = touched
        if !newVerdicts.isEmpty || !hashes.isEmpty || !rejects.isEmpty || spent || !changedSigs.isEmpty {
            // lock: system — the shop turned "Check pictures" on; this writes
            // only the verdicts, which pairings were turned down, their cost
            // and which checks failed.
            try? StoreWriter.update(build) { root in
                PictureVerdicts.write(newVerdicts, hashes: hashes, into: &root)
                PictureRejects.add(rejects, into: &root)
                if !changedSigs.isEmpty {
                    var current = SortFailures.read(Self.settings(root))
                    for sig in changedSigs { current[sig] = marksNow[sig] }
                    SortFailures.write(current, into: &root)
                }
                if spent {
                    var s = Self.settings(root)
                    s["aiUsage"] = ledger
                    root["settings"] = .object(s)
                }
            }
            await load(source)
        }
        if put, !attach.isEmpty { result.attached = await putPictures(attach, stop: stop) }
        return result
    }

    // MARK: - Putting pictures on, and turning them down

    /// Put pictures on: a print's as its group's picture, a model's as its
    /// own photo — judged again inside the write, so a picture the shop set
    /// a moment ago, or took off (`userPhotoRemoved`), is never put over.
    /// Each at most `PrintPhotos.maxBytes`. Returns how many went on.
    func putPictures(_ items: [(plan: PrintSort.Plan, suggestion: LooseSort.Suggestion)], stop: ScanStop?) async -> Int {
        guard let build = source.build, let roots = libraryRoots, !items.isEmpty else { return 0 }
        let primary = roots.primary
        let covers = GroupKinds.covers(settingsDict)
        var groupPictures: [(group: String, rel: String)] = []
        var modelPhotos: [String: String] = [:]
        var looked: [String] = []
        for (plan, s) in items {
            if stop?.isStopped == true || Task.isCancelled { break }
            let url = plan.root.appending(path: s.image)
            guard let pick = PrintPhotos.pick([url]) else { continue }
            switch s.target {
            case .print(let key):
                if let group = plan.group(ofPrint: key) {
                    guard covers[group] == nil, !groupPictures.contains(where: { $0.group == group }) else { continue }
                    if let rel = await PinWork.run({ try? GroupPictures.write(GroupPictures.encode(pick), for: group, under: primary) }) {
                        groupPictures.append((group, rel))
                        looked.append(plan.root.appending(path: key).standardizedFileURL.path)
                    }
                } else if let only = plan.models(ofPrint: key).first {
                    let path = plan.root.appending(path: only).standardizedFileURL.path
                    if let uri = await PinWork.run({ try? LibraryPhoto.dataURI(of: pick) }) { modelPhotos[path] = uri }
                }
            case .model(let rel):
                let path = plan.root.appending(path: rel).standardizedFileURL.path
                if let uri = await PinWork.run({ try? LibraryPhoto.dataURI(of: pick) }) {
                    modelPhotos[path] = uri
                    looked.append(path + "#photo")
                }
            }
        }
        guard !groupPictures.isEmpty || !modelPhotos.isEmpty else { return 0 }
        var put = 0
        var unused: [String] = []
        do {
            // lock: system — pictures the shop ticked, or the assistant
            // confirmed against the print's own preview; never over one the
            // shop chose.
            try StoreWriter.update(build) { root in
                var rows: [JSONValue] = []
                if case .array(let r)? = root["printFiles"] { rows = r }
                var changed = false
                for (i, row) in rows.enumerated() {
                    guard case .object(var o) = row, case .string(let p)? = o["externalPath"],
                          let uri = modelPhotos[URL(fileURLWithPath: p).standardizedFileURL.path] else { continue }
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
        for rel in unused {
            if let url = GroupPictures.url(of: rel, roots: roots.roots + [primary]) { try? FileManager.default.removeItem(at: url) }
        }
        if put > 0 { await load(source) }
        return put
    }

    /// Remember pairings the shop turned down, so they are never offered again.
    func rejectPictures(_ ids: [String]) {
        guard let build = source.build, !ids.isEmpty else { return }
        // lock: system — the shop's own answer in the sort sheet.
        try? StoreWriter.update(build) { root in PictureRejects.add(ids, into: &root) }
    }
}
