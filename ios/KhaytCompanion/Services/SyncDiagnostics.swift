import Foundation
import KhaytCore

/// What this phone's syncs last did, kept so a person testing a shop can see
/// why something is missing (Settings ▸ long-press the version line) instead
/// of guessing. READ-ONLY and value-free: kinds, outcomes, dates and counts,
/// never a record, a setting's value or a connector id. Unpair forgets it all
/// (`forget`).
enum SyncDiagnostics {

    /// Where the book (or a part of it) last came from.
    enum Source: String, CaseIterable, Sendable {
        /// `KhaytAPIClient.pullBook`: the Mac's whole `/api/store`, pairing included.
        case macStore = "mac-store"
        /// `CloudSync.pull`'s whole path: the cloud's book, adopted.
        case cloudWhole = "cloud-whole"
        /// `CloudSync.pull`'s warm path: changes folded in (none counts).
        case cloudDelta = "cloud-delta"
        /// `KhaytAPIClient.refreshMacSettings`: the Mac's settings alone.
        case macSettings = "mac-settings"
    }

    /// How the last `refreshMacSettings` went.
    enum SettingsOutcome: Equatable, Sendable {
        case ok
        case http(Int)
        case transport
        /// A 2xx with no settings in it, or one that could not be read.
        case empty
        /// Read, but the book could not take it (busy, or its baseline unreadable).
        case unwritten
        case skipped(Skip)

        enum Skip: String, Sendable {
            case pulled = "pulled", notConfigured = "not-configured", sampleShop = "sample-shop", noBook = "no-book"
        }

        var stored: String {
            switch self {
            case .ok: return "ok"
            case .http(let code): return "http \(code)"
            case .transport: return "transport"
            case .empty: return "empty"
            case .unwritten: return "unwritten"
            case .skipped(let why): return "skipped \(why.rawValue)"
            }
        }

        init?(stored: String) {
            switch stored {
            case "ok": self = .ok
            case "transport": self = .transport
            case "empty": self = .empty
            case "unwritten": self = .unwritten
            default:
                if stored.hasPrefix("http "), let code = Int(stored.dropFirst(5)) { self = .http(code); return }
                if stored.hasPrefix("skipped "), let why = Skip(rawValue: String(stored.dropFirst(8))) {
                    self = .skipped(why); return
                }
                return nil
            }
        }
    }

    enum Keys {
        static let sources = "khayt.diag.sources"
        static let lastSource = "khayt.diag.lastSource"
        static let lastSourceAt = "khayt.diag.lastSourceAt"
        static let macSettings = "khayt.diag.macSettings"
        static let macSettingsAt = "khayt.diag.macSettingsAt"
        static let macAnsweredAt = "khayt.diag.macAnsweredAt"
        static let macFailedAt = "khayt.diag.macFailedAt"
        static let all = [sources, lastSource, lastSourceAt, macSettings, macSettingsAt, macAnsweredAt, macFailedAt]
    }

    /// UserDefaults is thread-safe; these are called from the main actor and
    /// from `OffMain` work alike.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static func record(_ source: Source, at date: Date = Date()) {
        var all = defaults.dictionary(forKey: Keys.sources) ?? [:]
        all[source.rawValue] = date
        defaults.set(all, forKey: Keys.sources)
        defaults.set(source.rawValue, forKey: Keys.lastSource)
        defaults.set(date, forKey: Keys.lastSourceAt)
    }

    static func record(_ outcome: SettingsOutcome, at date: Date = Date()) {
        defaults.set(outcome.stored, forKey: Keys.macSettings)
        defaults.set(date, forKey: Keys.macSettingsAt)
    }

    /// The paired Mac answered a request — any HTTP status.
    static func macAnswered(at date: Date = Date()) { defaults.set(date, forKey: Keys.macAnsweredAt) }
    /// A request to the paired Mac failed below HTTP: no route, no answer.
    static func macFailed(at date: Date = Date()) { defaults.set(date, forKey: Keys.macFailedAt) }

    static func forget() { for k in Keys.all { defaults.removeObject(forKey: k) } }

    /// What is recorded now.
    struct Recorded: Equatable, Sendable {
        var sources: [Source: Date] = [:]
        var last: Source?
        var lastAt: Date?
        var macSettings: SettingsOutcome?
        var macSettingsAt: Date?
        var macAnsweredAt: Date?
        var macFailedAt: Date?
    }

    static func recorded() -> Recorded {
        var r = Recorded()
        for (k, v) in defaults.dictionary(forKey: Keys.sources) ?? [:] {
            if let s = Source(rawValue: k), let d = v as? Date { r.sources[s] = d }
        }
        r.last = defaults.string(forKey: Keys.lastSource).flatMap(Source.init(rawValue:))
        r.lastAt = defaults.object(forKey: Keys.lastSourceAt) as? Date
        r.macSettings = defaults.string(forKey: Keys.macSettings).flatMap(SettingsOutcome.init(stored:))
        r.macSettingsAt = defaults.object(forKey: Keys.macSettingsAt) as? Date
        r.macAnsweredAt = defaults.object(forKey: Keys.macAnsweredAt) as? Date
        r.macFailedAt = defaults.object(forKey: Keys.macFailedAt) as? Date
        return r
    }
}

/// The Diagnostics sheet's rows, as data: built from the client, the book and
/// what `SyncDiagnostics` recorded, with nothing drawn — so it can be tested.
/// Counts and states only.
struct BookDiagnostics: Equatable, Sendable {
    enum Baseline: String, Equatable, Sendable { case held, absent, unreadable }

    var holdsBook: Bool
    var bookExists: Bool
    var baseline: Baseline
    var settingsPresent: Bool
    /// `settings.plugins` entries in the book, however they read.
    var pluginEntries: Int
    /// What `KhaytAPIClient.connectors()` made of them, by status.
    var connectorCount: Int
    var byStatus: [Connector.Status: Int]
    var recorded: SyncDiagnostics.Recorded
    var isPaired: Bool
    var isConfigured: Bool
    var cloudSignedIn: Bool
    var isSampleShop: Bool
    var version: String
    var build: String

    /// The book's half, read from disk. A missing or unreadable book is
    /// "no settings, no entries", never a guess.
    static func book(_ book: CompanionBook?) -> (exists: Bool, baseline: Baseline, settings: Bool, plugins: Int) {
        guard let book else { return (false, .absent, false, 0) }
        let baseline: Baseline = {
            switch book.readBaseline() {
            case .held: return .held
            case .absent: return .absent
            case .unreadable: return .unreadable
            }
        }()
        guard book.exists, let store = try? book.read(), case .object(let s)? = store["settings"] else {
            return (book.exists, baseline, false, 0)
        }
        let plugins: Int = { if case .array(let rows)? = s["plugins"] { return rows.count }; return 0 }()
        return (true, baseline, true, plugins)
    }

    static func make(holdsBook: Bool, book: CompanionBook?, connectors: [Connector],
                     recorded: SyncDiagnostics.Recorded, isPaired: Bool, isConfigured: Bool,
                     cloudSignedIn: Bool, isSampleShop: Bool,
                     info: [String: Any]? = Bundle.main.infoDictionary) -> BookDiagnostics {
        let b = Self.book(book)
        var byStatus: [Connector.Status: Int] = [:]
        for c in connectors { byStatus[c.status, default: 0] += 1 }
        return BookDiagnostics(
            holdsBook: holdsBook, bookExists: b.exists, baseline: b.baseline, settingsPresent: b.settings,
            pluginEntries: b.plugins, connectorCount: connectors.count, byStatus: byStatus, recorded: recorded,
            isPaired: isPaired, isConfigured: isConfigured, cloudSignedIn: cloudSignedIn, isSampleShop: isSampleShop,
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?")
    }
}
