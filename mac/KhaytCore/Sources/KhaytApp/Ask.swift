import Foundation
import AppIntents
import SwiftUI
import KhaytCore

/// Khayt, answerable without being opened.
///
/// ── WHY THIS EXISTS AT ALL ────────────────────────────────────────────────
///
/// The question a print shop asks most often takes one second to answer and,
/// until now, a whole app launch to reach: *is it still printing, and what is
/// waiting?* App Intents put that answer in Spotlight, in Shortcuts, in Siri
/// and in an automation that can run at 07:00 without anybody present.
///
/// This is a thing a web app in a window cannot be. Not "harder" — a browser
/// process has no way to publish a verb to the system that the system can call
/// on its own.
///
/// ── WHAT THEY READ ────────────────────────────────────────────────────────
///
/// The book on disk, through `StoreReader`, and nothing else. No engine, no
/// window, no poller: an intent that had to boot JavaScriptCore to say how many
/// jobs are printing would be slower than opening the app, which is the thing
/// it exists to save.
///
/// That constrains them, deliberately, to facts the book STATES rather than
/// facts a rule derives. "Printing" is a status somebody wrote down; "late" is
/// a judgement `lib/attention.js` makes about due dates, voided orders and
/// shop scope, and it is not re-implemented here to save a launch. Where an
/// answer needs a rule, the intent opens the app at the screen that shows it.
///
/// ── A KNOWN GAP ───────────────────────────────────────────────────────────
///
/// The phrases and titles below are English. Khayt localises at runtime from
/// its own catalogue; App Intents titles are static and read by the system when
/// the app is registered, which wants a string catalog this hand-assembled
/// bundle does not have. The ANSWERS are in the shop's language — those are
/// content and go through `Words` like everything else. The verbs are not.
enum Ask {

    /// The book, read fresh, without the app.
    ///
    /// Whichever store was written most recently: a Mac may carry both the
    /// development and the shipped build, and the one somebody is keeping is
    /// the one that moved last.
    static func book() -> [String: JSONValue]? {
        let builds = StoreReader.Build.allCases
            .filter(\.exists)
            .sorted { ($0.lastWritten ?? .distantPast) > ($1.lastWritten ?? .distantPast) }
        for build in builds {
            if let reader = try? StoreReader(build: build) { return reader.raw }
        }
        return nil
    }

    static func rows(_ root: [String: JSONValue], _ key: String) -> [JSONValue] {
        if case .array(let rows)? = root[key] { return rows }
        return []
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    static func field(_ row: JSONValue, _ key: String) -> String? {
        guard case .object(let o) = row else { return nil }
        return string(o[key])
    }

    /// The shop's words, without loading the shared catalogue.
    ///
    /// `main.swift` warms `Words` with the shop's language before AppKit
    /// starts, and an intent runs in this same process — launched for it if
    /// need be — so a fresh `Words()` already speaks Arabic on an Arabic Mac.
    /// `Words.own` carries every key these answers use, so none of them waits
    /// on JavaScriptCore.
    @MainActor static func words() -> Words { Words() }

    // MARK: - The answers
    //
    // Pure functions of a book, so every sentence Khayt says to Siri can be
    // checked against a fixture. `perform()` reads the store and calls these;
    // there is nothing in an intent body worth trusting untested.

    @MainActor
    static func printing(in root: [String: JSONValue], words: Words) -> String {
        let jobs = rows(root, "printLog")
        let names = Dictionary(rows(root, "machines").compactMap { row -> (String, String)? in
            guard let id = field(row, "id") else { return nil }
            return (id, field(row, "name") ?? id)
        }, uniquingKeysWith: { first, _ in first })

        let running = jobs.filter { field($0, "status") == "printing" }
        guard !running.isEmpty else { return words.callIt("mac.nothing_printing") }

        // The job AND the machine: either alone leaves the obvious follow-up
        // unanswered.
        let lines = running.map { job -> String in
            let what = field(job, "project") ?? field(job, "id") ?? ""
            guard let on = field(job, "machineId"), let machine = names[on] else { return what }
            return words.callIt("mac.job_on_machine",
                                ["job": .string(what), "machine": .string(machine)])
        }
        return words.counting(running.count, "mac.printing_count")
             + " · " + lines.joined(separator: " · ")
    }

    @MainActor
    static func waiting(in root: [String: JSONValue], words: Words) -> String {
        let waiting = rows(root, "printLog").filter {
            let status = field($0, "status")
            return status == "pending" || status == "queued"
        }
        guard !waiting.isEmpty else { return words.callIt("mac.nothing_waiting") }
        // How many have no printer — the number that decides whether it is
        // worth opening the app to run the scheduler.
        let unplaced = waiting.filter { (field($0, "machineId") ?? "").isEmpty }.count
        var said = words.counting(waiting.count, "mac.waiting_count")
        if unplaced > 0 {
            said += " · " + words.callIt("mac.without_printer", ["n": .number(Double(unplaced))])
        }
        return said
    }
}

/// "What is printing?"
struct WhatIsPrintingIntent: AppIntent {
    static let title: LocalizedStringResource = "What is printing"
    static let description = IntentDescription(
        "Says which printers are running and what is on them, without opening Khayt.")
    /// The whole point is not opening the app.
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let words = Ask.words()
        guard let root = Ask.book() else {
            return .result(dialog: IntentDialog(stringLiteral: words.callIt("mac.no_book")))
        }
        return .result(dialog: IntentDialog(stringLiteral: Ask.printing(in: root, words: words)))
    }
}

/// "What is waiting?"
struct WhatIsWaitingIntent: AppIntent {
    static let title: LocalizedStringResource = "What is waiting to print"
    static let description = IntentDescription(
        "Says how much work is queued and how much of it has no printer yet.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let words = Ask.words()
        guard let root = Ask.book() else {
            return .result(dialog: IntentDialog(stringLiteral: words.callIt("mac.no_book")))
        }
        return .result(dialog: IntentDialog(stringLiteral: Ask.waiting(in: root, words: words)))
    }
}

/// The phrases the system offers without anybody building a shortcut.
struct KhaytShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatIsPrintingIntent(),
                    phrases: ["What is printing in \(.applicationName)",
                              "\(.applicationName) floor"],
                    shortTitle: "What is printing",
                    systemImageName: "printer")
        AppShortcut(intent: WhatIsWaitingIntent(),
                    phrases: ["What is waiting in \(.applicationName)",
                              "\(.applicationName) queue"],
                    shortTitle: "What is waiting",
                    systemImageName: "tray.full")
    }
}
