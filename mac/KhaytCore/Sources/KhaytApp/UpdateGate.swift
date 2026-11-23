import SwiftUI
import KhaytCore

// "An update is ready" (Mac file, page 28, frame C; signed off by Turki on
// Nov 23 2026, with all five decisions of mac-custom-updater-plan.md).
//
// A release can carry "Before you update" items. The first-launch sheet
// (`LaunchGate.swift`, frame B) shows them AFTER the update is installed.
// This one stands in front of the update itself: when Khayt finds a version
// with such items (or one that skips over a release that has them) and they
// have not been read on this Mac, this sheet opens, and the update window
// Khayt already has (Sparkle's) is not reachable until "I have read these
// changes" is ticked. Nothing here downloads or installs anything: after
// Continue, Sparkle does what it always did.
//
// WHERE THE ITEMS COME FROM. This Mac runs the OLD version and cannot know
// the new one's items from anything inside itself. Every Mac release carries
// its `release-gates.json` as a release asset (`mac/release-local.sh`): the
// same file the new app bundles, with every language. It is read under the
// `updates` purpose, 5 seconds and 512 KB at most, and run through the same
// rule as frame B (`lib/launch-gate.js`), so the two cannot disagree.
//
// IT FAILS OPEN, ON PURPOSE (decision 2). No asset (a release cut before
// this), a file that is not one, no network: the update is offered as it
// always was, and frame B covers it at the first start. The only thing that
// can hold an update is having positively read items for it that nobody has
// ticked. An update the shop cannot reach is the one bug an update cannot fix.
//
// WHAT IS REMEMBERED: the items that were read, by their English text, per
// Mac, outside the book. Not "read up to version X": frame B drops exactly
// the items ticked here and still shows any the installed app holds that this
// sheet never showed, so the signed app's own list stays the backstop for a
// download that was tampered with.

enum UpdateGate {
    /// The English text of every item ticked on this sheet, on this Mac.
    /// Kept short: old items fall off the front. Emptied by a downgrade.
    static let readItemsKey = "updateGate.readItems"
    static let keeps = 200
    static let maxBytes = 512 * 1024
    static let seconds: TimeInterval = 5

    /// What Khayt knows about a version on offer.
    enum Verdict: Equatable {
        /// Nothing to read, or it could not be found out: Sparkle's window.
        case proceed
        /// Items nobody has ticked: this sheet, and no update window.
        case hold([KhaytEngine.GatedRelease])
        /// Not looked into yet.
        case ask
    }

    /// `known`: nil before the release's file has been asked for; its unread
    /// items after (empty when there are none, or when it could not be read).
    static func verdict(_ known: [KhaytEngine.GatedRelease]?) -> Verdict {
        guard let known else { return .ask }
        return known.isEmpty ? .proceed : .hold(known)
    }

    /// Where a release keeps its gate file, or nil for a version that is not
    /// shaped like one. The version comes from the feed, so it is checked
    /// before it is put in an address.
    static func asset(for version: String) -> URL? {
        guard version.count <= 40, version.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?/) != nil else { return nil }
        return URL(string: "https://github.com/KhaytApp/khayt-mac/releases/download/v" + version + "/release-gates.json")
    }

    /// The release's gate file as text, or nil: not allowed, not there, too
    /// big, too slow, not text. Never throws and never waits past `seconds`.
    static func fetch(version: String) async -> String? {
        guard let url = asset(for: version) else { return nil }
        // "Make no internet calls" stops this as it stops the update check.
        guard (try? OutboundGate.shared.require(.updates)) != nil else { return nil }
        let setup = URLSessionConfiguration.ephemeral
        setup.timeoutIntervalForRequest = seconds
        setup.timeoutIntervalForResource = seconds
        let session = URLSession(configuration: setup)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: URLRequest(url: url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The releases with the items already ticked on this Mac taken out.
    static func unread(_ releases: [KhaytEngine.GatedRelease], read: [String]) -> [KhaytEngine.GatedRelease] {
        guard !read.isEmpty else { return releases }
        let read = Set(read)
        return releases.compactMap { release in
            let keep = release.english.indices.filter { !read.contains(release.english[$0]) }
            guard !keep.isEmpty else { return nil }
            return KhaytEngine.GatedRelease(version: release.version,
                                            items: keep.map { $0 < release.items.count ? release.items[$0] : release.english[$0] },
                                            english: keep.map { release.english[$0] })
        }
    }

    /// "One thing changes", "Two things change", in the shop's language.
    @MainActor static func changes(_ n: Int, words: Words) -> String {
        if n <= 1 { return words.callIt("mac.upgate_change_single") }
        if n == 2 { return words.callIt("mac.upgate_change_pair") }
        let count: [String: JSONValue] = ["count": .string(LaunchGate.spelled(n, words: words))]
        let said = (3...10).contains(n % 100) ? words.callIt("mac.upgate_change_few", count)
                                              : words.callIt("mac.upgate_change_many", count)
        return LaunchGate.capitalised(said, words: words)
    }
}

/// An update held for reading: the version on offer and what is unread.
struct UpdateOffer: Equatable {
    let version: String
    let releases: [KhaytEngine.GatedRelease]
}

extension Shop {
    /// The English text of the items ticked on this Mac.
    var readGateItems: [String] { launchGateDefaults.stringArray(forKey: UpdateGate.readItemsKey) ?? [] }

    /// Remember these items as read on this Mac.
    func noteGateItemsRead(_ releases: [KhaytEngine.GatedRelease]) {
        // lock: system — this Mac's own record of what was read on it; nothing in the book.
        var read = readGateItems
        for item in releases.flatMap(\.english) where !read.contains(item) { read.append(item) }
        launchGateDefaults.set(Array(read.suffix(UpdateGate.keeps)), forKey: UpdateGate.readItemsKey)
    }

    /// What an update to `version` has that this Mac has not read. Empty when
    /// there is nothing, AND when it cannot be found out: see "fails open".
    func updateGateItems(for version: String, running: String? = Shop.runningVersion) async -> [KhaytEngine.GatedRelease] {
        guard let running, !running.isEmpty, let engine else { return [] }
        let text: String?
        if let stand = updateGateFetchForTests { text = await stand(version) } else { text = await UpdateGate.fetch(version: version) }
        // The same rule as frame B, asked as if this Mac already ran the new
        // version: every gated release after the one running, up to it.
        guard let text, let all = try? await engine.launchGatePending(current: version, lastRun: running, acceptedFor: nil,
                                                                      hasBook: true, floor: LaunchGate.floor, gates: text,
                                                                      language: words.language) else { return [] }
        return UpdateGate.unread(all, read: readGateItems)
    }

    /// Stand the sheet over the window for this version.
    func holdUpdate(_ version: String, _ releases: [KhaytEngine.GatedRelease]) {
        // lock: system — shows what a found update says; nothing is written.
        guard !releases.isEmpty else { return }
        updateOffer = UpdateOffer(version: version, releases: releases)
    }

    /// "I have read these changes", then "Continue to the update": the items
    /// are read on this Mac, and Khayt's usual update window opens.
    func continueToUpdate() {
        // lock: system — anyone signed in may read and go on (decision 3); this Mac's own record, nothing in the book.
        guard let offer = updateOffer else { return }
        noteGateItemsRead(offer.releases)
        updateOffer = nil
        Updates.shared.wasRead(offer.version)
    }

    /// "Later": nothing is recorded, so the sheet comes back at the next check.
    func putOffUpdate() {
        // lock: system — closes the sheet and records nothing.
        updateOffer = nil
    }

    /// After sign-in, and after "Khayt was updated" when both wait.
    var showsUpdateGate: Bool { updateOffer != nil && !needsSignIn && !showsLaunchGate }
}

/// The items, on their tinted panel: the same in frames B and C.
struct GateItemsPanel: View {
    let head: String
    let releases: [KhaytEngine.GatedRelease]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(head).font(.system(size: 12, weight: .semibold))
                ForEach(releases) { release in
                    ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(LaunchGate.bullet).accessibilityHidden(true)
                            // Which release said it, when more than one did.
                            Text(releases.count > 1 ? LaunchGate.short(release.version) + ": " + item : item)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
        .background(Khayt.attention.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct UpdateGateSheet: View {
    let shop: Shop
    /// A capture's stand-ins (page 28: C1 unticked, C2 ticked).
    var pretend: (offer: UpdateOffer, running: String)?
    @State var read = false

    private var words: Words { shop.words }
    private var offer: UpdateOffer? { pretend?.offer ?? shop.updateOffer }

    /// "Khayt 4.0.0-beta.43 is ready to install on this Mac (it runs beta.41
    /// now). Two things change that you should know before you update."
    @MainActor static func summary(version: String, running: String, count: Int, words: Words) -> String {
        words.callIt("mac.upgate_ready", ["v": .string(version), "from": .string(LaunchGate.short(running))])
            + " " + UpdateGate.changes(count, words: words)
    }

    var body: some View {
        let releases = offer?.releases ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text(words.callIt("mac.upgate_title")).font(.system(size: 15, weight: .semibold))
            Text(Self.summary(version: offer?.version ?? "", running: pretend?.running ?? Shop.runningVersion ?? "",
                              count: releases.reduce(0) { $0 + $1.items.count }, words: words))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GateItemsPanel(head: words.callIt("mac.upgate_head"), releases: releases)
            Toggle(words.callIt("mac.gate_read"), isOn: $read)
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
            HStack {
                Link(words.callIt("mac.gate_notes"), destination: LaunchGate.releaseNotes)
                    .font(.system(size: 12))
                Spacer()
                // Nothing is installed yet and the shop may be mid-job.
                Button(words.callIt("mac.upgate_later")) { shop.putOffUpdate() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("mac.upgate_continue")) { shop.continueToUpdate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!read)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(true)
    }
}
