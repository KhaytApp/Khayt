import Foundation

/// What the Mac's widgets show, written by the app and read by the widget
/// extension.
///
/// ── WHY A FILE THE APP WRITES, AND NOT THE BOOK ─────────────────────────
///
/// A widget is a separate, sandboxed process that macOS runs whenever it
/// likes, with no engine, no keychain grant and no business opening the shop's
/// store. So the app does the arithmetic it already does for the dashboard and
/// the menu bar, and leaves the answer here: a few hundred bytes of finished
/// figures in the App Group container both of them are allowed to see.
///
/// Everything a widget draws is ALREADY in the words the shop reads in: the
/// app's language (the book's choice, not the Mac's), its direction, and money
/// formatted in the shop's currency. A widget that worked any of that out
/// again would be a second place for "owed" to mean something different.
///
/// No customer names. A widget sits on the desktop where anybody at the Mac can
/// read it, so it carries machines, counts and one total — nothing that names
/// who a job is for.
public struct ShopWidgetSnapshot: Codable, Sendable, Equatable {

    /// The format of this file. A widget from a newer build reading an older
    /// file, or the other way round, decodes what it knows; a bump here is for
    /// a change that would make an old reader draw something WRONG.
    public static let currentVersion = 1

    public var version: Int
    /// When the app wrote this. The widget says so, because a widget that keeps
    /// showing a print at 40% after the Mac went to sleep is otherwise a lie.
    public var writtenAt: Date
    public var shopName: String
    /// "en" or "ar" — the app's language, which is the book's setting.
    public var language: String
    public var rightToLeft: Bool
    /// Every word a widget draws, already in `language`. Keyed by
    /// `ShopWidgetSnapshot.Word`.
    public var words: [String: String]
    public var printing: [Printer]
    /// Machines the shop has, printing or not — so "nothing printing" can say
    /// how many are idle rather than looking like an empty book.
    public var machineCount: Int
    public var today: Today
    /// When the shop's day ends (the book's calendar). `today`'s due and late
    /// counts are true until then; after it, with the app not running to
    /// write tomorrow's, the widget shows a dash rather than yesterday's
    /// figures under today's heading. Optional, so a file from before it
    /// still reads.
    public var dayEnds: Date?
    /// Spools the app calls low (`Shop.lowSpools`, the inventory's own rule),
    /// the emptiest first, at most `listLimit`. Nil in a file from before the
    /// filament widget, which then says "Open Khayt" rather than "all stocked".
    public var lowSpools: [LowSpool]?
    /// How many spools are low in all, which may be more than are listed.
    public var lowSpoolCount: Int?
    /// The jobs waiting for a printer, in the board's own order (urgent, then
    /// due date, then longest waiting), at most `listLimit`. No customer.
    public var upNext: [QueuedJob]?
    /// How many jobs are waiting in all.
    public var queuedCount: Int?

    /// The most rows any widget draws (the large one); the counts say the rest.
    public static let listLimit = 6

    public struct LowSpool: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// "PLA Basic · Black", as the inventory names it.
        public var name: String
        /// "#RRGGBB", when the spool has a colour.
        public var colour: String?
        /// Grams left, rounded.
        public var gramsLeft: Int

        public init(id: String, name: String, colour: String?, gramsLeft: Int) {
            self.id = id; self.name = name; self.colour = colour
            self.gramsLeft = max(0, gramsLeft)
        }
    }

    public struct QueuedJob: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// What the job is — its project title. Never the customer.
        public var title: String
        /// The due day's start in the shop's calendar, when it has one.
        public var due: Date?
        public var late: Bool
        public var urgent: Bool

        public init(id: String, title: String, due: Date?, late: Bool, urgent: Bool) {
            self.id = id; self.title = title; self.due = due; self.late = late; self.urgent = urgent
        }
    }

    public struct Printer: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// 0…100, as the printer reported it.
        public var progress: Int
        /// When the printer expects to finish, if it said. An absolute time,
        /// so the widget can count down on its own between reloads.
        public var endsAt: Date?
        public var paused: Bool

        public init(id: String, name: String, progress: Int, endsAt: Date?, paused: Bool) {
            self.id = id; self.name = name
            self.progress = min(100, max(0, progress))
            self.endsAt = endsAt; self.paused = paused
        }
    }

    public struct Today: Codable, Sendable, Equatable {
        /// Open jobs whose due date is today, in the shop's calendar.
        public var dueToday: Int
        /// Jobs the app calls late — the same count as the title bar's badge.
        public var overdue: Int
        /// What the shop is owed across every open job, formatted in its
        /// currency. Nil when the person at the Mac may not see money.
        public var owed: String?

        public init(dueToday: Int, overdue: Int, owed: String?) {
            self.dueToday = dueToday; self.overdue = overdue; self.owed = owed
        }
    }

    /// The words a widget needs, named once so the writer and the reader agree.
    public enum Word: String, CaseIterable, Sendable {
        case printingTitle, nothingPrinting, idleMachines, noMachines, paused
        case todayTitle, dueToday, overdue, owed, updated, more
        case filamentTitle, allStocked, grams, upNextTitle, queueEmpty, urgent, glanceTitle
    }

    public init(writtenAt: Date, shopName: String, language: String, rightToLeft: Bool,
                words: [String: String], printing: [Printer], machineCount: Int, today: Today,
                dayEnds: Date? = nil, lowSpools: [LowSpool]? = nil, lowSpoolCount: Int? = nil,
                upNext: [QueuedJob]? = nil, queuedCount: Int? = nil) {
        self.version = Self.currentVersion
        self.writtenAt = writtenAt
        self.shopName = shopName
        self.language = language
        self.rightToLeft = rightToLeft
        self.words = words
        self.printing = printing
        self.machineCount = machineCount
        self.today = today
        self.dayEnds = dayEnds
        self.lowSpools = lowSpools
        self.lowSpoolCount = lowSpoolCount
        self.upNext = upNext
        self.queuedCount = queuedCount
    }

    public func word(_ w: Word) -> String { words[w.rawValue] ?? "" }

    /// Past the day `today` was counted for: its due and late counts are no
    /// longer today's.
    public func dayIsOver(at now: Date) -> Bool { dayEnds.map { now >= $0 } ?? false }

    /// Whether a finish time is still ahead, so a countdown to it means
    /// something. `Text(_, style: .relative)` past its date counts back up.
    public static func countsDown(to ends: Date?, at now: Date) -> Bool {
        ends.map { $0 > now } ?? false
    }

    // MARK: - Opening the app at a row

    /// The address a widget row opens: `khayt://machine/<id>`, `job/<id>`,
    /// `spool/<id>`, or `screen/<name>` for a whole widget. The app's handler
    /// (`DeepLink`) reads these and nothing else.
    public static let scheme = "khayt"

    public enum Link: Equatable, Sendable {
        case machine(String), job(String), spool(String), screen(String)

        /// The id is ONE path segment, so a "/" in it is escaped rather than
        /// read back as a second segment (which `init` refuses).
        public var url: URL {
            let (kind, id): (String, String) = switch self {
            case .machine(let id): ("machine", id)
            case .job(let id): ("job", id)
            case .spool(let id): ("spool", id)
            case .screen(let name): ("screen", name)
            }
            var segment = CharacterSet.urlPathAllowed
            segment.remove("/")
            var c = URLComponents()
            c.scheme = ShopWidgetSnapshot.scheme
            c.host = kind
            c.percentEncodedPath = "/" + (id.addingPercentEncoding(withAllowedCharacters: segment) ?? "")
            return c.url ?? URL(fileURLWithPath: "/")
        }

        /// The link in `url`, or nil for anything that is not exactly one of
        /// ours: another scheme, an unknown kind, a query, an empty or nested id.
        public init?(_ url: URL) {
            guard url.scheme?.lowercased() == ShopWidgetSnapshot.scheme,
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  comps.query == nil, comps.fragment == nil, comps.user == nil,
                  comps.password == nil, comps.port == nil else { return nil }
            let parts = comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            guard parts.count == 1, let id = parts.first.flatMap({ String($0).removingPercentEncoding }),
                  !id.isEmpty, id.count <= 200,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            switch comps.host?.lowercased() {
            case "machine": self = .machine(id)
            case "job": self = .job(id)
            case "spool": self = .spool(id)
            case "screen": self = .screen(id)
            default: return nil
            }
        }
    }

    // MARK: - On disk

    /// The file's name inside the group container.
    public static let fileName = "widget-snapshot.json"

    /// The Info.plist key both the app and the extension read the group from.
    ///
    /// The group is `<team id>.app.khayt.mac`, and the team is whoever signed
    /// the build — so it is written into both bundles by `make-app.sh` rather
    /// than spelled here. An ad-hoc build has no team, carries no key, and
    /// writes nothing: its widget says "Open Khayt", which is true.
    public static let groupInfoKey = "KhaytAppGroup"

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> ShopWidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(ShopWidgetSnapshot.self, from: data),
              snap.version <= currentVersion else { return nil }
        return snap
    }

    /// The snapshot in `directory`, or nil when there is none or it is not one.
    public static func read(in directory: URL) -> ShopWidgetSnapshot? {
        guard let data = try? Data(contentsOf: directory.appending(path: fileName)) else { return nil }
        return decode(data)
    }
}
