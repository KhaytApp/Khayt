import SwiftUI
import KhaytCore

// "Khayt was updated" (Mac file, page 28, frame B; signed off by Turki on
// Nov 23 2026, with these titles).
//
// A release can carry "Before you update" items: things a shop must know or
// do before it carries on (update every computer first, a setting to check).
// Sparkle shows them as release notes and holds nothing. This sheet stands
// over the window at the first start of the new version, for every gated
// release since the one this Mac last ran, and Continue is off until
// "I have read these changes" is ticked. There is no Later.
//
// The same rule as the Windows/Linux app's first-launch gate
// (`lib/launch-gate.js`), so the two cannot disagree about what is unread.

enum LaunchGate {
    /// Where a Mac with a book and no record counts as coming from: the last
    /// version that shipped WITHOUT this sheet. Every gated release after it,
    /// up to the one running, is shown once.
    ///
    /// SET AT THE CUT THAT SHIPS THE SHEET. If the sheet first ships in
    /// beta.44, this is beta.43. `LaunchGateTests` holds it below the
    /// version in `mac/VERSION`.
    static let floor = "4.0.0-beta.42"

    static let lastRunKey = "launchGate.lastRun"
    static let acceptedForKey = "launchGate.acceptedFor"
    /// Where every Mac release's notes are (`mac/release-local.sh`).
    static let releaseNotes = URL(string: "https://github.com/KhaytApp/khayt-mac/releases")!

    /// "beta.43" for "4.0.0-beta.43": how an item says which release it is from.
    static func short(_ version: String) -> String {
        guard let dash = version.firstIndex(of: "-") else { return version }
        let tail = version[version.index(after: dash)...]
        return tail.isEmpty ? version : String(tail)
    }
}

extension Shop {
    /// This build's version, or nil for a build with none (`swift run`, a
    /// test): such a build has no "since the last one" to speak of.
    static var runningVersion: String? {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (v?.isEmpty == false) ? v : nil
    }

    /// Work out what is unread, at start, once the book is loaded. Sets
    /// `launchGatePending`; with nothing to read it moves this Mac's record
    /// to the running version (also down, after a downgrade), as the other
    /// app does.
    func checkLaunchGate(current: String? = Shop.runningVersion) async {
        // lock: system — reads this Mac's own record of the version it last ran and notes the one running; nothing in the book is written.
        guard let current, !current.isEmpty, let engine else { return }
        let last = launchGateDefaults.string(forKey: LaunchGate.lastRunKey)
        let accepted = launchGateDefaults.string(forKey: LaunchGate.acceptedForKey)
        let pending = (try? await engine.launchGatePending(current: current, lastRun: last, acceptedFor: accepted,
                                                           hasBook: source.isReal, floor: LaunchGate.floor,
                                                           gates: launchGateFileForTests)) ?? []
        launchGateFrom = last
        launchGateCurrent = current
        launchGatePending = pending
        if pending.isEmpty { launchGateDefaults.set(current, forKey: LaunchGate.lastRunKey) }
    }

    /// "I have read these changes", then Continue: this Mac has read every
    /// gated release up to the one running.
    func acceptLaunchGate() {
        // lock: system — whoever is at this Mac has read the notes; this Mac's own record is updated, nothing in the book.
        guard let current = launchGateCurrent, !launchGatePending.isEmpty else { return }
        launchGateDefaults.set(current, forKey: LaunchGate.acceptedForKey)
        launchGateDefaults.set(current, forKey: LaunchGate.lastRunKey)
        launchGatePending = []
    }

    /// Whether the sheet stands over the window now. After sign-in when the
    /// staff lock is on: the sign-in screen comes first, and whoever signs in
    /// may read and continue.
    var showsLaunchGate: Bool { !launchGatePending.isEmpty && !needsSignIn }
}

struct LaunchGateSheet: View {
    let shop: Shop
    /// A capture's stand-ins (page 28: B1 unticked, B2 ticked).
    var pretend: (current: String, from: String?, releases: [KhaytEngine.GatedRelease])?
    @State var read = false

    private var words: Words { shop.words }
    private var releases: [KhaytEngine.GatedRelease] { pretend?.releases ?? shop.launchGatePending }
    private var current: String { pretend?.current ?? shop.launchGateCurrent ?? "" }
    private var from: String? { pretend.map { $0.from } ?? shop.launchGateFrom }

    /// "This Mac now runs Khayt 4.0.0-beta.43 (it ran beta.41 before). Two
    /// things changed that you should know before you carry on."
    @MainActor static func summary(current: String, from: String?, count: Int, words: Words) -> String {
        let now = from.map { words.callIt("mac.gate_now_from", ["v": .string(current), "from": .string(LaunchGate.short($0))]) }
            ?? words.callIt("mac.gate_now", ["v": .string(current)])
        return now + " " + words.counting(count, "mac.gate_changed")
    }

    var body: some View {
        let count = releases.reduce(0) { $0 + $1.items.count }
        VStack(alignment: .leading, spacing: 12) {
            Text(words.callIt("mac.gate_title")).font(.system(size: 15, weight: .semibold))
            Text(Self.summary(current: current, from: from, count: count, words: words))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(words.callIt("mac.gate_head")).font(.system(size: 12, weight: .semibold))
                    ForEach(releases) { release in
                        ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\u{2022}").accessibilityHidden(true)
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
            Toggle(words.callIt("mac.gate_read"), isOn: $read)
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
            HStack {
                Link(words.callIt("mac.gate_notes"), destination: LaunchGate.releaseNotes)
                    .font(.system(size: 12))
                Spacer()
                // No Later: the update is already installed. Off until read.
                Button(words.callIt("mac.gate_continue")) { shop.acceptLaunchGate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!read)
            }
        }
        .padding(20)
        .frame(width: 520)
        // Nothing behind it can be used, and Escape does not close it.
        .interactiveDismissDisabled(true)
    }
}
