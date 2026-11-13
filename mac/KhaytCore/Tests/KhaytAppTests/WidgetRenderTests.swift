import AppKit
import Foundation
import SwiftUI
import Testing
import WidgetKit
import KhaytWidgetData
@testable import KhaytWidgetViews

/// The widgets, drawn.
///
/// A widget is drawn by the system on the desktop, where no snapshot run can
/// reach it, so its views live in `KhaytWidgetViews` and are rendered here:
/// both widgets, both sizes, English and Arabic, light and dark. With
/// `KHAYT_WIDGET_SNAPSHOT_DIR` set the pictures are written there for review.
@MainActor
struct WidgetRenderTests {

    static func snapshot(_ lang: String, printing: Bool = true) -> ShopWidgetSnapshot {
        let now = Date()
        let en: [String: String] = [
            "printingTitle": "Printing now", "nothingPrinting": "Nothing on the beds",
            "idleMachines": "Every printer is free", "noMachines": "No machines yet", "paused": "Paused",
            "todayTitle": "Today", "dueToday": "Due today", "overdue": "Late", "owed": "Owed",
            "updated": "Updated", "more": "+{n} more",
            "filamentTitle": "Filament low", "allStocked": "Every spool is stocked", "grams": "{n} g",
            "upNextTitle": "Up next", "queueEmpty": "Nothing waiting to print", "urgent": "Urgent",
            "glanceTitle": "Shop at a glance",
        ]
        let ar: [String: String] = [
            "printingTitle": "قيد الطباعة الآن", "nothingPrinting": "لا شيء قيد الطباعة",
            "idleMachines": "كل الطابعات متاحة", "noMachines": "لا طابعات بعد", "paused": "متوقفة مؤقتًا",
            "todayTitle": "اليوم", "dueToday": "مستحقة اليوم", "overdue": "متأخرة", "owed": "المستحق",
            "updated": "حُدّث", "more": "+{n} أخرى",
            "filamentTitle": "خيط على وشك النفاد", "allStocked": "كل البكرات متوفرة", "grams": "{n} غ",
            "upNextTitle": "التالي", "queueEmpty": "لا شيء بانتظار الطباعة", "urgent": "عاجل",
            "glanceTitle": "الورشة في لمحة",
        ]
        let day = Calendar.book.startOfDay(for: now)
        let spools: [ShopWidgetSnapshot.LowSpool] = printing ? [
            .init(id: "s1", name: "PLA Basic · Black", colour: "#1C1C1C", gramsLeft: 85),
            .init(id: "s2", name: "PETG HF · Translucent Orange", colour: "#F0763D", gramsLeft: 140),
            .init(id: "s3", name: "PLA Silk · Gold", colour: "#C9A227", gramsLeft: 160),
            .init(id: "s4", name: "TPU 95A · White", colour: "#F4F4F4", gramsLeft: 190),
            .init(id: "s5", name: "ASA", colour: nil, gramsLeft: 199),
        ] : []
        let jobs: [ShopWidgetSnapshot.QueuedJob] = printing ? [
            .init(id: "ORD-01011", title: lang == "ar" ? "دلة قهوة" : "Coffee dallah",
                  due: day.addingTimeInterval(-86_400), late: true, urgent: true),
            .init(id: "ORD-01015", title: lang == "ar" ? "منظم مكتب بأدراج" : "Desk organiser with three drawers and a long name",
                  due: day, late: false, urgent: false),
            .init(id: "ORD-01016", title: lang == "ar" ? "غطاء مصباح" : "Lamp shade",
                  due: day.addingTimeInterval(86_400 * 2), late: false, urgent: false),
            .init(id: "ORD-01017", title: lang == "ar" ? "مشابك كابلات ×٤٠" : "Cable clips ×40", due: nil, late: false, urgent: false),
            .init(id: "ORD-01018", title: lang == "ar" ? "مجسم صقر" : "Falcon figure",
                  due: day.addingTimeInterval(86_400 * 5), late: false, urgent: false),
            .init(id: "ORD-01019", title: lang == "ar" ? "حامل هاتف" : "Phone stand",
                  due: day.addingTimeInterval(86_400 * 6), late: false, urgent: false),
        ] : []
        return ShopWidgetSnapshot(
            writtenAt: now.addingTimeInterval(-120), shopName: "Tuwaiq 3D",
            language: lang, rightToLeft: lang == "ar", words: lang == "ar" ? ar : en,
            printing: printing ? [
                .init(id: "a", name: "Bambu Lab P1S", progress: 62, endsAt: now.addingTimeInterval(5_340), paused: false),
                .init(id: "b", name: "Prusa MK4S", progress: 28, endsAt: now.addingTimeInterval(9_180), paused: false),
                .init(id: "c", name: "Snapmaker U1", progress: 51, endsAt: nil, paused: true),
                .init(id: "d", name: "Ender 3", progress: 5, endsAt: now.addingTimeInterval(20_000), paused: false),
            ] : [],
            machineCount: 4,
            today: .init(dueToday: 3, overdue: 1, owed: "12,480 \u{20C1}"),
            lowSpools: spools, lowSpoolCount: printing ? 7 : 0,
            upNext: jobs, queuedCount: printing ? 9 : 0)
    }

    /// The macOS sizes, in points.
    static func size(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        default: CGSize(width: 364, height: 170)
        }
    }

    static func name(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: "small"
        case .systemLarge: "large"
        default: "medium"
        }
    }

    static func render(_ face: WidgetFace, _ family: WidgetFamily, _ snap: ShopWidgetSnapshot?,
                       dark: Bool, now: Date = Date()) -> NSImage? {
        let size = size(family)
        let view = KhaytWidgetView(face: face, family: family, snapshot: snap, now: now)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.17) : Color(white: 0.95))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.widgetRowLinks, false)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    @Test(arguments: WidgetFace.allCases)
    func drawsAtEverySizeLanguageAndAppearance(_ face: WidgetFace) throws {
        let out = ProcessInfo.processInfo.environment["KHAYT_WIDGET_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for family in face.families {
            for lang in ["en", "ar"] {
                for dark in [false, true] {
                    let image = try #require(Self.render(face, family, Self.snapshot(lang), dark: dark))
                    #expect(image.size == Self.size(family))
                    if let out {
                        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                        let name = "\(face)-\(Self.name(family))-\(lang)-\(dark ? "dark" : "light").png"
                        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                        try rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: name))
                    }
                }
            }
        }
    }

    @Test func drawsTheQuietCases() throws {
        // Nothing printing, and no snapshot at all ("Open Khayt").
        #expect(Self.render(.printing, .systemSmall, Self.snapshot("en", printing: false), dark: false) != nil)
        #expect(Self.render(.today, .systemMedium, nil, dark: true) != nil)
        if let dir = ProcessInfo.processInfo.environment["KHAYT_WIDGET_SNAPSHOT_DIR"] {
            let out = URL(fileURLWithPath: dir)
            for (name, image) in [
                ("printing-small-en-idle.png", Self.render(.printing, .systemSmall, Self.snapshot("en", printing: false), dark: false)),
                ("printing-small-ar-idle.png", Self.render(.printing, .systemSmall, Self.snapshot("ar", printing: false), dark: true)),
                ("today-small-none.png", Self.render(.today, .systemSmall, nil, dark: false)),
                ("filament-medium-en-stocked.png", Self.render(.filament, .systemMedium, Self.snapshot("en", printing: false), dark: false)),
                ("upNext-medium-ar-empty.png", Self.render(.upNext, .systemMedium, Self.snapshot("ar", printing: false), dark: true)),
                ("glance-large-en-quiet.png", Self.render(.glance, .systemLarge, Self.snapshot("en", printing: false), dark: false)),
            ] {
                let rep = try #require(image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: name))
            }
        }
    }

    static func png(_ image: NSImage?) -> Data? {
        image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
    }

    // MARK: - Comparing two pictures

    /// The same snapshot with nothing in it that moves, for a test that
    /// compares two pictures.
    ///
    /// ── WHY TWO PICTURES OF ONE SNAPSHOT WERE NOT THE SAME BYTES ──────────
    ///
    /// `lateIsWorkedOutAtTheEntry` drew a snapshot twice and expected the two
    /// PNG files to be equal, and on one full run they were not (".glance: a
    /// job due yesterday was drawn grey") when nothing about the job differed.
    /// Drawing one snapshot over and over and comparing the pictures found
    /// two things that change, and neither is the job:
    ///
    /// 1. A printing row counts down with `Text(_, style: .relative)`, which
    ///    reads the WALL clock when it is drawn and not the entry's `now` —
    ///    the point of it: the widget keeps counting between reloads. 150
    ///    pictures of the Glance widget half a second apart were alike until
    ///    60.5 s after the snapshot was made, when "1 hr, 28 min" became
    ///    "1 hr, 27 min". `still` leaves the printers out.
    ///
    /// 2. With the printers out, the first two pictures of a widget are
    ///    alike and every later one differs from them by ONE level of one
    ///    colour channel on a few hundred pixels at the edges of the text
    ///    (445 of 556,192 in Up next, 44 in Glance; never more than one
    ///    level). The eye cannot see it and a byte comparison can. Which pair
    ///    of pictures falls either side of it depends on what else the
    ///    process has drawn, so on which tests ran first. `difference` counts
    ///    only channels that are further apart than that rounding.
    ///
    /// Which of the two the failing run met is not known. The test drew its
    /// two pictures a few hundredths of a second apart, so the second is the
    /// likelier.
    static func still(_ snapshot: ShopWidgetSnapshot) -> ShopWidgetSnapshot {
        var still = snapshot
        still.printing = []
        return still
    }

    /// Two levels of 255. The rounding measured between two pictures of the
    /// same thing is one; a late date against one that is not late is a red
    /// bold word against a grey regular one, hundreds of channels apart by
    /// most of the scale (`lateIsWorkedOutAtTheEntry` holds that end).
    static let rounding = 2

    /// How far apart two pictures are: how many colour channels differ by
    /// more than `rounding`, and the most any channel differs by. Nil when
    /// they are not two pictures of one size.
    static func difference(_ a: NSImage?, _ b: NSImage?) -> (beyondRounding: Int, most: Int)? {
        guard let x = a?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let y = b?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              x.pixelsWide == y.pixelsWide, x.pixelsHigh == y.pixelsHigh,
              x.bitsPerSample == 8, y.bitsPerSample == 8,
              x.samplesPerPixel == y.samplesPerPixel, x.bitsPerPixel == y.bitsPerPixel,
              x.bitsPerPixel == x.samplesPerPixel * 8,
              let p = x.bitmapData, let q = y.bitmapData else { return nil }
        // Row by row and only as far as the pixels go: what pads a row out
        // to its stride is not part of the picture.
        let wide = x.pixelsWide * x.samplesPerPixel
        var beyond = 0
        var most = 0
        for row in 0..<x.pixelsHigh {
            let left = p + row * x.bytesPerRow
            let right = q + row * y.bytesPerRow
            for i in 0..<wide {
                let apart = abs(Int(left[i]) - Int(right[i]))
                if apart > most { most = apart }
                if apart > rounding { beyond += 1 }
            }
        }
        return (beyond, most)
    }

    @Test("a job due before the entry's day is late, whatever the snapshot said when it was written")
    func lateIsWorkedOutAtTheEntry() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .autoupdatingCurrent
        let now = Date()
        let today = cal.startOfDay(for: now)
        let yesterday = try #require(cal.date(byAdding: .day, value: -1, to: today))
        func job(_ due: Date?, late: Bool) -> ShopWidgetSnapshot.QueuedJob {
            .init(id: "ORD-1", title: "x", due: due, late: late, urgent: false)
        }
        #expect(JobRow.isLate(job(yesterday, late: false), at: now), "due yesterday, written before midnight")
        #expect(!JobRow.isLate(job(today, late: false), at: now), "due today is not late yet")
        #expect(!JobRow.isLate(job(nil, late: false), at: now))
        #expect(JobRow.isLate(job(today, late: true), at: now), "the app's own late is kept")
        // Drawn yesterday, before midnight: yesterday's due was not late then.
        #expect(!JobRow.isLate(job(yesterday, late: false), at: yesterday.addingTimeInterval(3600)))

        // And drawn so: the stale snapshot's row looks exactly like a late one.
        // Without the printers, whose countdown reads the wall clock (`still`).
        var stale = Self.still(Self.snapshot("en"))
        var late = stale
        stale.upNext = [job(yesterday, late: false)]
        late.upNext = [job(yesterday, late: true)]
        for face in [WidgetFace.upNext, .glance] {
            let family = try #require(face.families.last)
            let apart = try #require(Self.difference(Self.render(face, family, stale, dark: false, now: now),
                                                     Self.render(face, family, late, dark: false, now: now)))
            #expect(apart.beyondRounding == 0,
                    "\(face): a job due yesterday was drawn grey (\(apart.beyondRounding) channels differ, by up to \(apart.most))")
        }
        // Sanity: the pictures DO tell a red row from a grey one — the same
        // snapshot drawn before midnight, when the job was not late yet. And
        // by far more than the rounding the comparison above lets through.
        let before = yesterday.addingTimeInterval(3600)
        let told = try #require(Self.difference(Self.render(.upNext, .systemLarge, stale, dark: false, now: before),
                                                Self.render(.upNext, .systemLarge, late, dark: false, now: before)))
        #expect(told.beyondRounding > 100 && told.most > 50,
                "a grey date and a red one are \(told.beyondRounding) channels apart, by up to \(told.most)")
    }

    /// The cause of the failure `still` describes, held in place: a printer's
    /// countdown follows the wall clock and nothing else in a widget does.
    ///
    /// The first printer is set to finish a second and a half past a whole
    /// number of minutes, so the minute turns while this test is running
    /// instead of up to sixty seconds later.
    @Test("a printer's countdown follows the wall clock, and nothing else in a widget does")
    func theCountdownIsTheOnlyThingThatMoves() async throws {
        for _ in 0..<5 {
            var moving = Self.snapshot("en")
            let made = Date()
            let turns = made.addingTimeInterval(1.5)
            moving.printing[0].endsAt = turns.addingTimeInterval(89 * 60)
            let still = Self.still(moving)

            let before = Self.render(.glance, .systemLarge, moving, dark: false, now: made)
            let stillBefore = Self.render(.glance, .systemLarge, still, dark: false, now: made)
            // Both pictures have to be from before the minute turns. On a
            // loaded machine they may not be; that says nothing about the
            // widget, so the same question is asked again with a new minute.
            guard Date() < turns else { continue }
            while Date() < turns.addingTimeInterval(0.3) { try await Task.sleep(for: .milliseconds(50)) }
            let after = Self.render(.glance, .systemLarge, moving, dark: false, now: made)
            let stillAfter = Self.render(.glance, .systemLarge, still, dark: false, now: made)

            let moved = try #require(Self.difference(before, after))
            #expect(moved.beyondRounding > 0, "the countdown did not move when its minute turned: it no longer reads the wall clock, and `still` can go")
            let stayed = try #require(Self.difference(stillBefore, stillAfter))
            #expect(stayed.beyondRounding == 0,
                    "something besides a printer's countdown changed between two pictures of one entry: \(stayed.beyondRounding) channels, by up to \(stayed.most)")
            return
        }
        Issue.record("five times, two pictures could not be drawn inside a second and a half")
    }

    /// And in the source: one text in the widget views reads the wall clock,
    /// the printer's countdown. A second one would make every byte-for-byte
    /// comparison in this file a coin toss again, on a face `still` does not
    /// know about.
    @Test("only the printer's countdown is drawn from the wall clock")
    func oneTextReadsTheWallClock() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytWidgetViews/WidgetViews.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        // The date styles that redraw themselves, and the ways to ask what
        // time it is. `now: Date = Date()` is the entry's moment, handed in.
        let live = code.filter { line in
            ["style: .relative", "style: .timer", "style: .offset", "Date.now", "Date()", "TimelineView"]
                .contains { line.contains($0) }
        }.map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(live.count == 2, "\(live)")
        #expect(live.contains { $0.contains("now: Date = Date()") }, "\(live)")
        #expect(live.contains { $0.hasPrefix("Text(ends, style: .relative)") }, "\(live)")
    }

    @Test("a snapshot from a build that sent no low spools claims nothing about filament")
    func glanceWithoutLowSpoolsSaysNothing() throws {
        // `still` and `difference`: a minute turning under a printer's
        // countdown, or one level of rounding, would make the two pictures
        // differ whatever was drawn about filament.
        var old = Self.still(Self.snapshot("en"))
        old.lowSpools = nil
        old.lowSpoolCount = nil
        var stocked = old
        stocked.lowSpools = []
        stocked.lowSpoolCount = 0
        let now = Date()
        let apart = try #require(Self.difference(Self.render(.glance, .systemLarge, old, dark: false, now: now),
                                                 Self.render(.glance, .systemLarge, stocked, dark: false, now: now)))
        #expect(apart.beyondRounding > 100, "no list was drawn as \"Every spool is stocked\"")
    }
}
