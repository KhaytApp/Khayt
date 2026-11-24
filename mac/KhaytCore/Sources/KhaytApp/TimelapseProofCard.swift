import AppKit
import SwiftUI
import KhaytCore

// A finished print's time-lapse, kept as the customer's proof (Mac file,
// page 25, frame 3; the Windows/Linux app's job-page card). Five states:
// found on the printer, copying, kept, too large to keep, could not copy.
//
// KEPT ONLY WHEN ASKED. The copy is `Shop.keepTimelapse`, with its limits;
// this is the card that asks for it, and says what came of it.

/// How far a copy has got.
struct TimelapseProgress: Equatable, Sendable {
    let got: Int
    /// The printer's own figure for the whole video, when it gave one.
    let total: Double?
}

extension Shop {
    /// Where a job's time-lapse stands, apart from a copy that is running.
    enum TimelapseProof: Equatable {
        /// On the printer, and small enough to keep.
        case found(bytes: Double?, machineId: String, at: Date?)
        /// One of the job's files.
        case kept(bytes: Double?, machineId: String, at: Date?, filename: String?)
        /// On the printer, and it will not be copied: `over-budget` or `size-unknown`.
        case stays(bytes: Double?, maxBytes: Double?, reason: String, machineId: String)
    }

    /// Nil for a job with no time-lapse (or one whose record is not usable).
    func timelapseProof(_ jobId: String) async -> TimelapseProof? {
        guard let engine, let job = orderRow(jobId),
              let plan = try? await engine.timelapseKeepPlan(order: job, stamp: "0"), let machineId = plan.machineId else { return nil }
        var at: Date?
        if case .object(let o) = job, case .object(let t)? = o["printerTimelapse"], case .string(let stamp)? = t["at"] { at = NetworkSwitch.date(stamp) }
        switch plan.action {
        case "attach": return .found(bytes: plan.bytes, machineId: machineId, at: at)
        case "already": return .kept(bytes: plan.bytes, machineId: machineId, at: at, filename: plan.filename)
        case "link": return .stays(bytes: plan.bytes, maxBytes: plan.maxBytes, reason: plan.reason ?? "size-unknown", machineId: machineId)
        default: return nil
        }
    }

    /// The printer's name for the card: the machine's, and for one the
    /// decoded list does not hold (a record this build cannot fully read),
    /// the name its raw record carries, before falling back to the id.
    func proofMachineName(_ id: String) -> String {
        if machines.contains(where: { $0.id == id }) { return machineName(forId: id) }
        for row in machineRows where Self.recordId(row) == id {
            if case .object(let o) = row, case .string(let name)? = o["name"], !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        }
        return machineName(forId: id)
    }

    /// Changes whenever the card should look again: the job's own record of
    /// the video and its files, and a copy starting or ending.
    func timelapseStamp(_ jobId: String) -> String {
        var files = 0, has = false
        if case .object(let o)? = orderRow(jobId) {
            has = o["printerTimelapse"] != nil
            if case .array(let a)? = o["attachedFiles"] { files = a.count }
        }
        return "\(has) \(files) \(timelapseCopying.contains(jobId)) \(timelapseProblem[jobId] ?? "")"
    }

    /// "Keep as proof" from this Mac's own card. The copy is one task per
    /// job, so Cancel has something to stop.
    func startKeepTimelapse(_ jobId: String) {
        // lock: callers — keepTimelapse (which asks orders/edit itself)
        guard timelapseTasks[jobId] == nil else { return }
        timelapseProblem[jobId] = nil
        timelapseTasks[jobId] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.keepTimelapse(jobId)
            self.timelapseTasks[jobId] = nil
            self.timelapseProblem[jobId] = self.keptSentence(outcome)
        }
    }

    /// Stop a copy this Mac started. Nothing is kept.
    func cancelKeepTimelapse(_ jobId: String) {
        // lock: system — stops this Mac's own copy; nothing is written, and the partial file is removed by the copy itself.
        timelapseTasks[jobId]?.cancel()
    }

    /// What to say on the card when a try kept nothing; nil when there is
    /// nothing to say (it was kept, it was stopped, or the card's own state says it).
    func keptSentence(_ outcome: TimelapseKept) -> String? {
        switch outcome {
        case .kept, .already, .cancelled, .busy, .none: return nil
        // The printer said it was small and sent more: the card still reads "found", so this is said.
        case .link(let reason, _, let most):
            return reason == "over-budget" ? words.callIt("mac.proof_grew", ["max": .string(TimelapseLine.size(most, words))]) : nil
        case .unreachable, .noMachine: return words.callIt("mac.proof_offline")
        case .readOnly: return words.callIt("mac.move_sample")
        case .notPermitted: return moveProblem
        case .notSaved(let why): return words.callIt("mac.proof_not_saved") + " " + why
        }
    }

    /// The kept file on disk, or nil when the job has none or the name is not one this app wrote.
    func keptTimelapseFile(_ jobId: String) -> URL? {
        guard let folder = filesFolder, case .object(let job)? = orderRow(jobId), case .array(let files)? = job["attachedFiles"] else { return nil }
        for file in files {
            guard case .object(let f) = file, f["kind"] == .string("timelapse"), case .string(let name)? = f["filename"], Self.safeKeptName(name) else { continue }
            let url = folder.appending(path: name)
            if url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") { return url }
        }
        return nil
    }

    /// The kept rows taken off a job: the names of the files they pointed at.
    nonisolated static func removeKept(from job: inout [String: JSONValue]) -> [String] {
        guard case .array(let files)? = job["attachedFiles"] else { return [] }
        var names: [String] = [], rest: [JSONValue] = []
        for file in files {
            if case .object(let f) = file, f["kind"] == .string("timelapse") {
                if case .string(let name)? = f["filename"] { names.append(name) }
            } else { rest.append(file) }
        }
        guard rest.count != files.count else { return [] }
        job["attachedFiles"] = .array(rest)
        return names
    }

    /// "Remove…": the kept copy leaves the job, and the file is deleted. The
    /// video on the printer, if it is still there, is not touched.
    @discardableResult
    func removeKeptTimelapse(_ jobId: String) async -> Bool {
        guard permitted("orders", "edit") else { return false }
        guard let build = source.build, canWrite, let folder = filesFolder else { moveProblem = words.callIt("mac.move_sample"); return false }
        let names: [String]?
        do {
            names = try await StoreWriter.updateRecordOffMain(build, collection: "printLog", id: jobId) { record -> [String] in
                Self.removeKept(from: &record)
            }
        } catch { moveProblem = said(error); return false }
        // Only files this app could have written, inside the folder.
        for name in names ?? [] where Self.safeKeptName(name) {
            let url = folder.appending(path: name)
            if url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") { try? FileManager.default.removeItem(at: url) }
        }
        timelapseProblem[jobId] = nil
        await load(source)
        return !(names ?? []).isEmpty
    }
}

struct TimelapseProofCard: View {
    let shop: Shop
    let jobId: String
    /// A capture's stand-ins (page 25, frame 3).
    var pretend: (proof: Shop.TimelapseProof, copying: TimelapseProgress?, problem: String?)?
    @State private var proof: Shop.TimelapseProof?
    @State private var removing = false
    @State private var playing: URL?

    private var words: Words { shop.words }
    private var copying: TimelapseProgress? {
        if let pretend { return pretend.copying }
        return shop.timelapseCopying.contains(jobId) ? (shop.timelapseProgress[jobId] ?? TimelapseProgress(got: 0, total: nil)) : nil
    }
    private var problem: String? { pretend.map { $0.problem } ?? shop.timelapseProblem[jobId] }

    /// The two lines of a state, as the frame words them.
    @MainActor static func lines(_ proof: Shop.TimelapseProof, copying: TimelapseProgress?, problem: String?, shop: Shop) -> (title: String, sub: String) {
        let words = shop.words
        func size(_ bytes: Double?) -> String { TimelapseLine.size(bytes, words) }
        func when(_ date: Date?) -> String { date.map { words.say($0, .dateTime.month(.abbreviated).day().hour().minute()) } ?? "" }
        switch proof {
        case .found(let bytes, let machineId, let at):
            let machine = shop.proofMachineName(machineId)
            if let copying {
                return (words.callIt("mac.proof_copying", ["machine": .string(machine)]),
                        words.callIt("mac.proof_progress", ["got": .string(size(Double(copying.got))), "total": .string(size(copying.total ?? bytes))]))
            }
            let title = words.callIt("mac.proof_found", ["machine": .string(machine)])
            if let problem { return (title, problem) }
            return (title, at == nil ? size(bytes) : words.callIt("mac.proof_found_sub", ["size": .string(size(bytes)), "when": .string(when(at))]))
        case .kept(let bytes, let machineId, let at, _):
            return (words.callIt("mac.proof_kept", ["size": .string(size(bytes))]),
                    words.callIt("mac.proof_kept_sub", ["machine": .string(shop.proofMachineName(machineId)), "when": .string(when(at))]))
        case .stays(let bytes, let most, let reason, _):
            return (words.callIt("mac.proof_stays", ["size": .string(size(bytes))]),
                    reason == "over-budget" ? words.callIt("mac.proof_too_large", ["max": .string(size(most))]) : words.callIt("mac.proof_no_size"))
        }
    }

    var body: some View {
        Group {
            if let proof = pretend?.proof ?? proof { card(proof) }
        }
        .task(id: shop.timelapseStamp(jobId)) { if pretend == nil { proof = await shop.timelapseProof(jobId) } }
        .alert(words.callIt("mac.proof_remove_q"), isPresented: $removing) {
            Button(words.callIt("mac.proof_remove_yes"), role: .destructive) { Task { await shop.removeKeptTimelapse(jobId) } }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        } message: { Text(words.callIt("mac.proof_remove_note")) }
        .shopSheet(item: Binding(get: { playing.map(Playing.init) }, set: { playing = $0?.url })) { p in
            TimelapsePlayer(url: p.url, bytes: nil, words: words) { playing = nil }
        }
    }

    private struct Playing: Identifiable { let url: URL; var id: String { url.absoluteString } }

    @ViewBuilder private func card(_ proof: Shop.TimelapseProof) -> some View {
        let said = Self.lines(proof, copying: copying, problem: problem, shop: shop)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(said.title).font(.system(size: 13, weight: .medium))
                    Text(said.sub).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                buttons(proof)
            }
            // Said once, where the choice is: on the found state, before anything is copied.
            if case .found = proof, copying == nil, problem == nil {
                Text(words.callIt("mac.proof_note")).font(.system(size: 12)).foregroundStyle(Khayt.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func buttons(_ proof: Shop.TimelapseProof) -> some View {
        switch proof {
        case .found:
            if copying != nil {
                Button(words.callIt("common.cancel")) { shop.cancelKeepTimelapse(jobId) }.controlSize(.small)
            } else {
                Button(words.callIt(problem == nil ? "mac.proof_keep" : "mac.proof_again")) { shop.startKeepTimelapse(jobId) }
                    .controlSize(.small)
                    .disabled(!shop.canMoveJobs)
            }
        case .kept:
            Button(words.callIt("mac.proof_show")) {
                if let file = shop.keptTimelapseFile(jobId), FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
                else { shop.timelapseProblem[jobId] = words.callIt("mac.proof_gone") }
            }.controlSize(.small)
            Button(words.callIt("mac.proof_remove")) { removing = true }.controlSize(.small).disabled(!shop.canMoveJobs)
        case .stays:
            // Plays from the printer, as "Watch timelapse" does: nothing is copied.
            Button(words.callIt("mac.proof_open")) {
                Task {
                    if let link = await shop.timelapseLink(jobId), let url = await shop.timelapsePlayable(link) { playing = url }
                    else { shop.timelapseProblem[jobId] = words.callIt("mac.timelapse_gone") }
                }
            }.controlSize(.small)
        }
    }
}
