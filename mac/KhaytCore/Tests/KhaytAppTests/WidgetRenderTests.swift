import AppKit
import Foundation
import SwiftUI
import Testing
import WidgetKit
import KhaytWidgetData
import KhaytWidgetViews

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
        ]
        let ar: [String: String] = [
            "printingTitle": "قيد الطباعة الآن", "nothingPrinting": "لا شيء قيد الطباعة",
            "idleMachines": "كل الطابعات متاحة", "noMachines": "لا طابعات بعد", "paused": "متوقفة مؤقتًا",
            "todayTitle": "اليوم", "dueToday": "مستحقة اليوم", "overdue": "متأخرة", "owed": "المستحق",
            "updated": "حُدّث", "more": "+{n} أخرى",
        ]
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
            today: .init(dueToday: 3, overdue: 1, owed: "12,480 \u{20C1}"))
    }

    /// The macOS sizes, in points.
    static func size(_ family: WidgetFamily) -> CGSize {
        family == .systemSmall ? CGSize(width: 170, height: 170) : CGSize(width: 364, height: 170)
    }

    static func render(_ face: WidgetFace, _ family: WidgetFamily, _ snap: ShopWidgetSnapshot?,
                       dark: Bool) -> NSImage? {
        let size = size(family)
        let view = KhaytWidgetView(face: face, family: family, snapshot: snap)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.17) : Color(white: 0.95))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    @Test(arguments: [WidgetFace.printing, .today])
    func drawsAtEverySizeLanguageAndAppearance(_ face: WidgetFace) throws {
        let out = ProcessInfo.processInfo.environment["KHAYT_WIDGET_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for family in [WidgetFamily.systemSmall, .systemMedium] {
            for lang in ["en", "ar"] {
                for dark in [false, true] {
                    let image = try #require(Self.render(face, family, Self.snapshot(lang), dark: dark))
                    #expect(image.size == Self.size(family))
                    if let out {
                        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                        let name = "\(face)-\(family == .systemSmall ? "small" : "medium")-\(lang)-\(dark ? "dark" : "light").png"
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
            ] {
                let rep = try #require(image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: name))
            }
        }
    }
}
