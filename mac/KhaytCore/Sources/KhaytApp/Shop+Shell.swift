import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - Changing something

    // MARK: - What the menus ask for

    /// The menu bar acts on the selection, not on a row it was handed. These
    /// are the same actions the context menu and the inspector use, named once
    /// so the two can never drift into meaning different things.
    func reload() { Task { await load(source) } }

    // MARK: - What the menu bar asks

    /// How many machines are printing RIGHT NOW, from the poller rather than
    /// from the book.
    ///
    /// The book's `status` is what somebody last told Khayt; this is what the
    /// printers last said themselves. On the one question the menu bar exists
    /// to answer they can disagree for hours — a print that finished at 03:00
    /// is still "printing" in a book nobody has touched since.
    var printingNow: Int {
        machines.reduce(into: 0) { count, machine in
            // `PrinterWatch.isPrinting`, not `== "printing"`. OctoPrint passes
            // the printer's own `state.text` through untouched and OctoPrint
            // capitalises it — so an exact comparison counted zero on every
            // OctoPrint shop, and the menu bar this property exists for said
            // "nothing is printing" while the machine was printing.
            if let state = printers.readings[machine.id]?.status?.state,
               PrinterWatch.isPrinting(state) { count += 1 }
        }
    }

    /// Seconds until the first machine is free, or nil when none is running.
    var soonestFinish: Double? {
        machines.compactMap { machine -> Double? in
            guard let status = printers.readings[machine.id]?.status,
                  PrinterWatch.isPrinting(status.state),
                  let left = status.timeRemaining, left > 0 else { return nil }
            return left
        }.min()
    }

    // MARK: - What the table shows

    var shown: [Order] {
        var rows = orders.filter(inSite)
        if let stage { rows = rows.filter { Stage.of($0) == stage } }
        // Narrowed to one kit, when the band above the table has been asked
        // for one. A chip that only states a total is decoration; this is what
        // makes it a control — "show me the four jobs that made the figure".
        if let kitFilter, let kit = kits.first(where: { $0.id == kitFilter }) {
            let inKit = Set(kit.jobIds)
            rows = rows.filter { inKit.contains($0.id) }
        }
        return matching(rows)
    }

    /// `siteScope`'s ids as sets, built once when the scope changes. Every
    /// screen asks `inSite` once per row as it draws, and building the set on
    /// each ask made the board and the sidebar count quadratic in the jobs.
    struct SiteIds { var orders = Set<String>(), machines = Set<String>(), spools = Set<String>() }

    func count(_ stage: Stage) -> Int { orders.count { Stage.of($0) == stage && inSite($0) } }

    // MARK: - What the shell needs to draw itself
    //
    // Small readings, kept together because they are all answers to "what
    // does the window say about this book" rather than facts about the shop.

    /// WHAT THE STRIP SAYS YOU ARE LOOKING AT — the name, not the screen.
    ///
    /// `shelfTitleKey` answers with the SCREEN, and inside a library group that
    /// is wrong in a way a shop cannot get out of: opening a folder left the
    /// title reading "All models", the sidebar row still on Library, and
    /// nothing anywhere naming the folder or offering a way back up. The old
    /// window had a subtitle and a group menu in its toolbar; this one has the
    /// strip.
    ///
    /// A stage does the same to Jobs, and says so the same way.
    @MainActor var shelfTitle: String {
        switch shelf {
        case .library(let group?): group
        case .jobs(let stage?):    words.callIt(stage.key)
        default:                   words.callIt(shelfTitleKey)
        }
    }

    var shelfTitleKey: String { Self.titleKey(of: shelf) }

    /// The word for a screen — the sidebar's, and ⌘K's for the same row.
    static func titleKey(of shelf: Shelf) -> String {
        switch shelf {
        case .dashboard:  "mac.dashboard"
        case .jobs:       "mac.all_jobs"
        case .board:      "mac.board"
        case .library:    "mac.all_models"
        case .catalogue:  "cat.title"
        case .customers:  "tab.clients"
        case .machines:   "mac.machines"
        case .inventory:  "mac.inventory"
        case .expenses:   "mac.nav_expenses"
        case .waste:      "mac.nav_waste"
        case .reports:    "mac.nav_reports"
        case .portfolio:  "pf.title"
        case .calculator: "mac.calc_title"
        case .colour:     "cmix.title"
        case .giftCards:  "giftCards"
        }
    }

    /// The file this book lives in, by name only. The whole path in a 150px
    /// sidebar is a middle-truncated string nobody can read; the name is what
    /// a shop with two books actually distinguishes them by.
    var bookFileName: String {
        source.build.map { $0.storeURL.lastPathComponent } ?? "sample-shop.json"
    }

    /// Whether this Mac is signed in to the cloud at all — NOT whether it has
    /// synced recently, which is a different sentence and belongs in Settings.
    var isCloudLinked: Bool { cloudConnected }

    /// "saved today", "saved yesterday", "saved 14 Sep" — or "not saved yet".
    ///
    /// The last backup is a DAY (`2026-09-14`, from the file's name), not a
    /// moment. Formatting it with a time printed that day's midnight, so the
    /// strip read "saved 12:00 AM" on every shop, every day. And the
    /// never-saved case borrowed `mac.never`, which is "never PRINTED" in
    /// Arabic.
    var lastSavedLabel: String { Self.savedLabel(lastBackup, words: words) }

    static func savedLabel(_ backup: String?, words: Words, today: Date = Date()) -> String {
        guard let backup, let day = Order.day(backup) else {
            return words.callIt("mac.not_saved_yet")
        }
        let cal = Calendar.book
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: day),
                                      to: cal.startOfDay(for: today)).day ?? 0
        if days == 0 { return words.callIt("mac.saved_today") }
        if days == 1 { return words.callIt("mac.saved_yesterday") }
        return words.callIt("mac.saved_at",
                            ["t": .string(words.say(day, .dateTime.day().month(.abbreviated)))])
    }

    /// Is anything actually printing? One dot in the sidebar, and a dot is
    /// the right weight: the number of running machines is on the Machines
    /// screen, and repeating it in the nav is a figure to keep in step.
    var anyMachineRunning: Bool {
        machines.contains {
            PrinterWatch.isPrinting(printers.readings[$0.id]?.status?.state ?? "")
        }
    }

    /// The print this job IS, right now, or nothing.
    ///
    /// ── THE LIVEST FACT IN THE SHOP WAS NOT ON THE SHOP'S OWN SCREEN ──────
    ///
    /// This app polls every linked printer and knows, to the percent, how far
    /// through each running print is. It drew that on the Dashboard and on the
    /// floor — and the Jobs table, the screen a shop actually lives in, said
    /// "Printing" as flat text for three hours. A shop watching its own work
    /// had to leave the list of that work to find out how it was going.
    ///
    /// ── WHY IT IS THIS NARROW ─────────────────────────────────────────────
    ///
    /// Three conditions, and each one is a way of being wrong:
    ///
    /// - **The job says it is printing.** A job the shop has already moved to
    ///   Post-processing is not the print on the bed even if its machine is
    ///   busy — the machine has moved on to the next one.
    /// - **The job names a machine.** Without it there is nothing to ask, and
    ///   guessing from "the only machine running" would put one printer's
    ///   progress on another printer's job the moment a second one starts.
    /// - **The machine says PRINTING.** An idle printer answers happily with
    ///   `progress: 0`, and a job left marked printing against an idle machine
    ///   would be drawn as 0% underway rather than as needing a look. Same
    ///   refusal `machineBand` makes, for the same reason.
    ///
    /// Two jobs against one machine both match, which is right: the book says
    /// both are printing and this reports what the machine says. The fix for
    /// that is in the book, not in a tie-break invented here.
    func livePrint(for job: Order) -> KhaytEngine.PrinterStatus? {
        guard Stage.of(job) == .printing, let machineId = job.machineId,
              let status = printers.readings[machineId]?.status,
              PrinterWatch.isPrinting(status.state) else { return nil }
        return status
    }

    func readLibraryNames() async {
        guard let engine, !libraryRows.isEmpty else {
            categoriesInUse = []; tagsInUse = []; return
        }
        let ticket = loadGeneration
        let categories = ((try? await engine.categoryCounts(libraryRows)) ?? []).map(\.name)
        let tags = ((try? await engine.tagCounts(libraryRows)) ?? []).map(\.name)
        // Not over a newer load's answer (`Shop.load`).
        guard ticket == loadGeneration else { return }
        categoriesInUse = categories
        tagsInUse = tags
    }

    /// File the selected models under a category, or clear it with "".
    func fileSelection(underCategory name: String) async {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        // Through the engine, for the same reason as the group above: a name
        // matching one the shop already uses adopts that spelling rather than
        // becoming a second chip holding part of the same idea.
        guard let engine,
              let patch = try? await engine.fileUnderCategory(name, known: categoriesInUse)
        else {
            writeProblem = words.callIt("mac.group_unknown")
            return
        }
        let named = name.isEmpty
            ? words.callIt("mac.remove_from_category")
            : words.callIt("mac.file_in", ["name": .string(name)])
        editFiles(ids, named: named) { record in
            for (key, value) in patch { record[key] = value }
        }
    }

    /// Set the tags on the selected models from a typed, comma-separated line.
    ///
    /// Replaces rather than merges. Tagging several models at once is how a
    /// shop says "these are the same kind of thing", and a merge would make the
    /// result depend on what each already carried — so what is typed is what
    /// they all end up with, which is the only version of this a person can
    /// predict.
    func tagSelection(_ typed: String) async {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        guard let engine, let tags = try? await engine.normaliseTags(typed, known: tagsInUse)
        else {
            writeProblem = words.callIt("mac.group_unknown")
            return
        }
        editFiles(ids, named: words.callIt("mac.tag_models")) { record in
            record["tags"] = .array(tags.map { .string($0) })
        }
    }

    /// Attach a photograph of the finished print to a model.
    ///
    /// `thumbnail(for:)` has always preferred one — "a photograph the shop took
    /// beats a generated thumbnail" — and this app had no way to take one. The
    /// bytes are the other app's: 480px, JPEG at 0.82, inline as a data URI, so
    /// a picture attached here is one Khayt draws without knowing where it came
    /// from.
    func setLibraryPhoto(_ fileId: LibraryFile.ID, from url: URL) {
        writeProblem = nil
        guard source.build != nil else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        let uri: String
        do { uri = try LibraryPhoto.dataURI(of: url) }
        catch {
            // The reader's own sentence — "8 MB", "not a picture Khayt can
            // read" — rather than a generic failure, because each of them
            // tells the shop what to do differently.
            writeProblem = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return
        }
        editFiles([fileId], named: words.callIt("mac.lp_action")) { record in
            record["userPhoto"] = .string(uri)
        }
    }

    /// Take the photograph off again, leaving the generated preview to show.
    func clearLibraryPhoto(_ fileId: LibraryFile.ID) {
        writeProblem = nil
        guard source.build != nil else {
            writeProblem = words.callIt("mac.move_sample"); return
        }
        // NULL, not absent. The other app writes `userPhoto: null` on a new
        // record, and a field removed entirely is a field a merge can resurrect
        // from the older copy on another machine.
        editFiles([fileId], named: words.callIt("mac.lp_removed")) { record in
            record["userPhoto"] = .null
            // So the linked pass never puts a found picture back on it
            // (`Shop.fetchPrintPictures`).
            record["userPhotoRemoved"] = .bool(true)
        }
    }
}
