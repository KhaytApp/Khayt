import Foundation
import Testing
import KhaytCore
import KhaytWidgetData
@testable import KhaytApp

/// The desktop widgets' feed (`WidgetFeed`): what the app writes for
/// `KhaytWidgets.appex`, and — the half that matters more — what it never
/// writes.
@MainActor
struct WidgetFeedTests {

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-widgets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A feed pointed at a scratch folder, counting its reloads.
    final class Counter { var reloads = 0 }
    static func feed(_ dir: URL, _ counter: Counter) -> WidgetFeed {
        let feed = WidgetFeed()
        feed.directory = { dir }
        feed.reloadTimelines = { counter.reloads += 1 }
        return feed
    }

    static func snapshot(at: Date, overdue: Int = 1) -> ShopWidgetSnapshot {
        ShopWidgetSnapshot(writtenAt: at, shopName: "Tuwaiq", language: "en", rightToLeft: false,
                           words: ["printingTitle": "Printing now"],
                           printing: [.init(id: "M1", name: "P1S", progress: 40,
                                            endsAt: at.addingTimeInterval(600), paused: false)],
                           machineCount: 2,
                           today: .init(dueToday: 2, overdue: overdue, owed: "120.00 SAR"))
    }

    // MARK: - What may be shown at all

    @Test("only a real book with the staff lock off reaches the desktop")
    func whoMayShow() {
        #expect(WidgetFeed.shows(isReal: true, lockOn: false))
        #expect(!WidgetFeed.shows(isReal: false, lockOn: false), "the sample book must write nothing")
        #expect(!WidgetFeed.shows(isReal: true, lockOn: true), "the lock exists so the book is not on view")
    }

    @Test("opening the sample takes away what the real book wrote, and writes nothing")
    func sampleWritesNothing() async throws {
        let dir = try Self.scratch()
        let file = dir.appending(path: ShopWidgetSnapshot.fileName)
        try Self.snapshot(at: Date()).encoded().write(to: file)

        let shop = Shop()
        await shop.load(.sample)
        let counter = Counter()
        Self.feed(dir, counter).update(shop: shop)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(counter.reloads == 1, "a widget showing the old book must be told it is gone")
    }

    @Test("a build with no app group writes nothing anywhere")
    func noGroupNoWrite() {
        let feed = WidgetFeed()
        feed.directory = { nil }
        var reloads = 0
        feed.reloadTimelines = { reloads += 1 }
        feed.write(Self.snapshot(at: Date()))
        #expect(reloads == 0)
        #expect(feed.last == nil)
    }

    // MARK: - Writing

    @Test("a snapshot is written whole and reads back the same")
    func writesAndReadsBack() throws {
        let dir = try Self.scratch()
        let counter = Counter()
        let feed = Self.feed(dir, counter)
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let snap = Self.snapshot(at: now)
        feed.write(snap, now: now)
        #expect(ShopWidgetSnapshot.read(in: dir) == snap)
        #expect(counter.reloads == 1)
    }

    @Test("an unchanged sweep costs nothing until the refresh is due, and a change is written at once")
    func unchangedIsSkipped() throws {
        let dir = try Self.scratch()
        let counter = Counter()
        let feed = Self.feed(dir, counter)
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        feed.write(Self.snapshot(at: t0), now: t0)

        let t1 = t0.addingTimeInterval(10)
        feed.write(Self.snapshot(at: t1), now: t1)
        #expect(ShopWidgetSnapshot.read(in: dir)?.writtenAt == t0, "the same figures ten seconds later")

        let t2 = t0.addingTimeInterval(20)
        feed.write(Self.snapshot(at: t2, overdue: 3), now: t2)
        #expect(ShopWidgetSnapshot.read(in: dir)?.today.overdue == 3)

        let t3 = t2.addingTimeInterval(WidgetFeed.refreshAfter + 1)
        feed.write(Self.snapshot(at: t3, overdue: 3), now: t3)
        #expect(ShopWidgetSnapshot.read(in: dir)?.writtenAt == t3,
                "Updated must mean the app was looking, so an old file is written again")
    }

    @Test("reloads are spent at most once a minute")
    func reloadsAreThrottled() throws {
        let dir = try Self.scratch()
        let counter = Counter()
        let feed = Self.feed(dir, counter)
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        for i in 0..<5 {
            let t = t0.addingTimeInterval(Double(i) * 10)
            feed.write(Self.snapshot(at: t, overdue: i), now: t)
        }
        #expect(counter.reloads == 1, "five changes inside a minute are one reload now and one later")
    }

    // MARK: - The figures

    @Test("due today counts open jobs on the shop's own day, and nothing finished or quoted")
    func dueToday() {
        let now = Date()
        let f = DateFormatter()
        f.calendar = .book
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: now)
        let tomorrow = f.string(from: Calendar.book.date(byAdding: .day, value: 1, to: now)!)
        let jobs: [(stage: Stage?, due: String?)] = [
            (.pending, today), (.printing, today), (.qc, today),
            (.completed, today), (.quote, today), (.cancelled, today),
            (.pending, tomorrow), (.pending, nil), (nil, today),
        ]
        #expect(WidgetFeed.dueToday(jobs, now: now) == 3)
    }

    @Test("printing and paused machines, soonest first, and a paused one has no finish time")
    func printingRows() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let heard: [WidgetFeed.Heard] = [
            .init(id: "a", name: "Slow", state: "printing", progress: 10, timeRemaining: 7200),
            .init(id: "b", name: "Idle", state: "idle", progress: 0, timeRemaining: nil),
            .init(id: "c", name: "Fast", state: "Printing", progress: 90, timeRemaining: 300),
            .init(id: "d", name: "Held", state: "paused", progress: 50, timeRemaining: 900),
            .init(id: "e", name: "Mute", state: "printing", progress: 20, timeRemaining: nil),
        ]
        let rows = WidgetFeed.printing(heard, now: now)
        #expect(rows.map(\.id) == ["c", "a", "d", "e"])
        #expect(rows[0].endsAt == now.addingTimeInterval(300))
        #expect(rows.first { $0.id == "d" }?.paused == true)
        #expect(rows.first { $0.id == "d" }?.endsAt == nil)
    }

    @Test("the snapshot carries every word, in the book's language, and no customer's name")
    func composedFromTheBook() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let snap = WidgetFeed.compose(shop, now: Date())
        for word in ShopWidgetSnapshot.Word.allCases {
            let said = snap.word(word)
            #expect(!said.isEmpty && !said.hasPrefix("mac."), "\(word) has no word")
        }
        #expect(snap.today.owed != nil)
        #expect(snap.machineCount == shop.machines.count)
        let json = String(decoding: try snap.encoded(), as: UTF8.self)
        let names = shop.clients.map(\.anyName) + shop.orders.map(\.client)
        for name in Set(names) where name.count > 2 {
            #expect(!json.contains(name), "\(name) is on the desktop")
        }
    }

    @Test("today's counts end with the shop's day, and an older file without that still reads")
    func todayEndsAtTheBooksMidnight() throws {
        let noon = Calendar.book.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        let shop = Shop()
        let snap = WidgetFeed.compose(shop, now: noon)
        let midnight = Calendar.book.date(byAdding: .day, value: 1, to: Calendar.book.startOfDay(for: noon))!
        #expect(snap.dayEnds == midnight)
        #expect(!snap.dayIsOver(at: noon))
        #expect(!snap.dayIsOver(at: midnight.addingTimeInterval(-1)))
        #expect(snap.dayIsOver(at: midnight))

        // A file written before `dayEnds` existed: read, and never "over".
        var old = Self.snapshot(at: noon)
        old.dayEnds = nil
        var json = try JSONSerialization.jsonObject(with: try old.encoded()) as! [String: Any]
        json.removeValue(forKey: "dayEnds")
        let read = ShopWidgetSnapshot.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(read != nil)
        #expect(read?.dayIsOver(at: noon.addingTimeInterval(86_400 * 3)) == false)
    }

    @Test("a finish time counts down only while it is ahead — past it, the widget does not count back up")
    func countdownStopsAtTheFinish() {
        let now = Date()
        #expect(ShopWidgetSnapshot.countsDown(to: now.addingTimeInterval(60), at: now))
        #expect(!ShopWidgetSnapshot.countsDown(to: now, at: now))
        #expect(!ShopWidgetSnapshot.countsDown(to: now.addingTimeInterval(-3_600), at: now))
        #expect(!ShopWidgetSnapshot.countsDown(to: nil, at: now))
    }

    @Test("a file from a newer format is not drawn")
    func newerFormatIsRefused() throws {
        var snap = Self.snapshot(at: Date())
        snap.version = ShopWidgetSnapshot.currentVersion + 1
        #expect(ShopWidgetSnapshot.decode(try snap.encoded()) == nil)
    }
}

/// The widget extension, against its source and its built binary.
struct WidgetExtensionTests {

    static var package: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    /// THE OPPOSITE OF THE QUICK LOOK RULE. A widget extension's point
    /// prohibits a principal class; WidgetKit starts the `WidgetBundle`'s
    /// `@main`. Without a Swift entry point there is nothing to start.
    @Test func hasASwiftEntryPoint() throws {
        var binary: URL?
        for build in ["release", "debug"] {
            let url = Self.package.appending(path: ".build/\(build)/KhaytWidgets")
            if FileManager.default.fileExists(atPath: url.path) { binary = url; break }
        }
        guard let binary else { return }
        let otool = Process()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        otool.arguments = ["otool", "-l", binary.path]
        let pipe = Pipe()
        otool.standardOutput = pipe
        otool.standardError = FileHandle.nullDevice
        try otool.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        otool.waitUntilExit()
        #expect(out.contains("__swift5_entry"))
        #expect(out.contains("LC_MAIN"))

        // …and the process must START in `NSExtensionMain`, as Xcode links it
        // (Apple's Calculator widget imports the same symbol). Started in the
        // Swift `main`, WidgetKit trapped in `_EXRunningExtension._shared`
        // on chronod's first query and the widgets never reached the gallery.
        let nm = Process()
        nm.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        nm.arguments = ["nm", "-u", binary.path]
        let nmOut = Pipe()
        nm.standardOutput = nmOut
        nm.standardError = FileHandle.nullDevice
        try nm.run()
        let imports = String(decoding: nmOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        nm.waitUntilExit()
        #expect(imports.contains("_NSExtensionMain"),
                "KhaytWidgets is not linked with -e _NSExtensionMain; it will crash when the gallery asks for it")
    }

    /// The widget draws in the app's colours, which it cannot import. Both
    /// files are read and every role the widget names must carry the same pair.
    @Test func inkMatchesThePalette() throws {
        let sources = Self.package.appending(path: "Sources")
        let palette = try String(contentsOf: sources.appending(path: "KhaytApp/Palette.swift"), encoding: .utf8)
        let widget = try String(contentsOf: sources.appending(path: "KhaytWidgetViews/WidgetViews.swift"), encoding: .utf8)
        for role in ["brand", "hot", "attention", "late"] {
            let app = try #require(Self.pair(in: palette, #"static let \#(role) = adaptive\(light: (0x[0-9A-F]+), dark: (0x[0-9A-F]+)"#),
                                   "Palette has no \(role)")
            let mine = try #require(Self.pair(in: widget, #"static let \#(role) = Ink\(light: (0x[0-9A-F]+), dark: (0x[0-9A-F]+)\)"#),
                                    "the widget has no \(role)")
            #expect(app == mine, "\(role): app \(app), widget \(mine)")
        }
    }

    static func pair(in text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) else { return nil }
        return "\(text[a])/\(text[b])"
    }

    /// Every key the widget asks its own strings for exists in both languages.
    @Test func everyStringInBothLanguages() throws {
        let dir = Self.package.appending(path: "Sources/KhaytWidgets/Localization")
        let widget = try ["Sources/KhaytWidgets/KhaytWidgets.swift", "Sources/KhaytWidgetViews/WidgetViews.swift"]
            .map { try String(contentsOf: Self.package.appending(path: $0), encoding: .utf8) }
            .joined(separator: "\n")
        var wanted = Set<String>()
        let re = try NSRegularExpression(pattern: #""(widget\.[a-z_.]+)""#)
        for m in re.matches(in: widget, range: NSRange(widget.startIndex..., in: widget)) {
            if let r = Range(m.range(at: 1), in: widget) { wanted.insert(String(widget[r])) }
        }
        for word in ShopWidgetSnapshot.Word.allCases { wanted.insert("widget.word.\(word.rawValue)") }
        wanted.remove("widget.word.")
        #expect(wanted.count > 5)
        for lang in ["en", "ar"] {
            let url = dir.appending(path: "\(lang).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String], "\(lang) does not parse")
            for key in wanted { #expect(table[key]?.isEmpty == false, "\(lang) has no \(key)") }
        }
    }
}

/// The built bundle, when there is one.
struct WidgetBundleTests {
    static var app: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appending(path: "dist/Khayt.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func theAppexIsAWidgetExtension() throws {
        guard let app = Self.app else { return }
        let appex = app.appending(path: "Contents/PlugIns/KhaytWidgets.appex")
        let info = try #require(NSDictionary(contentsOf: appex.appending(path: "Contents/Info.plist")) as? [String: Any])
        let ext = try #require(info["NSExtension"] as? [String: Any])
        #expect(ext["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension")
        #expect(ext["NSExtensionPrincipalClass"] == nil, "the widget extension point prohibits one")
        #expect(info["CFBundlePackageType"] as? String == "XPC!")
        for lang in ["en", "ar"] {
            #expect(FileManager.default.fileExists(
                atPath: appex.appending(path: "Contents/Resources/\(lang).lproj/Localizable.strings").path))
        }
        let inRoot = try FileManager.default.contentsOfDirectory(atPath: appex.path)
        #expect(inRoot == ["Contents"])
        // The same group on both sides, or the widget reads a container the
        // app never writes to.
        let appInfo = try #require(NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any])
        #expect(appInfo[ShopWidgetSnapshot.groupInfoKey] as? String == info[ShopWidgetSnapshot.groupInfoKey] as? String)
    }
}
