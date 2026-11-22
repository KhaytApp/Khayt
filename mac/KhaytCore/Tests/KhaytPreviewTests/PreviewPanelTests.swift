import Testing
import Foundation
import AppKit
import KhaytCore
@testable import KhaytPreview

/// The panel itself, built and looked at.
///
/// Quick Look hosts an extension's view OUT OF PROCESS, which is why the first
/// attempts to photograph the real thing came back blank: `cacheDisplay` renders
/// this process's layers and a remote view has none. (And why the attempt before
/// that came back looking plausible — it was Quick Look's own thumbnail
/// fallback, drawn locally, which is exactly what a broken extension leaves
/// behind.) Built here, the view is local and can be both measured and
/// photographed.
///
/// `KHAYT_PREVIEW_SNAPSHOT=<dir>` writes the picture out to be looked at.
@MainActor
struct PreviewPanelTests {

    static func facts(_ json: String) throws -> KhaytEngine.PrintFacts {
        try JSONDecoder().decode(KhaytEngine.PrintFacts.self, from: Data(json.utf8))
    }

    static let king = """
    {"printer":"Snapmaker U1","layerHeight":0.12,"nozzle":0.4,"nozzleVaries":false,
     "materials":["PLA"],"infill":"100%","infillVaries":false,
     "support":false,"supportStyle":null,"objects":1,"source":"orca"}
    """

    /// A picture the size a slicer really writes, so the layout is exercised
    /// against a real aspect rather than a square guess.
    static func plate(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.42, green: 0.46, blue: 0.23, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.76, green: 0.64, blue: 0.31, alpha: 1))
        ctx.fill(CGRect(x: w / 8, y: h / 8, width: w * 3 / 4, height: h * 3 / 4))
        return ctx.makeImage()!
    }

    func build(language: String, facts: KhaytEngine.PrintFacts?,
               picture: CGImage?) -> KhaytPreviewController {
        let vc = KhaytPreviewController()
        _ = vc.view              // loadView
        vc.install(picture: picture, facts: facts,
                   words: Words(language: language, khayt: [:]))
        vc.view.layoutSubtreeIfNeeded()
        return vc
    }

    @Test func thePanelDrawsARowPerFact() throws {
        let vc = build(language: "en", facts: try Self.facts(Self.king),
                       picture: Self.plate(512, 512))
        let labels = Self.textIn(vc.view)
        // Printer, layer, nozzle, material, infill, supports — six facts, and
        // the single-object plate does not brag about being one.
        #expect(labels.contains("Snapmaker U1"))
        #expect(labels.contains("0.12"))
        #expect(labels.contains("0.4"))
        #expect(labels.contains("PLA"))
        #expect(labels.contains("100%"))
        #expect(labels.contains("Infill"))
        #expect(!labels.contains { $0.contains("object") })
    }

    @Test func aFileWithNoSettingsSaysSoRatherThanShowingAnEmptyPanel() throws {
        let vc = build(language: "en", facts: nil, picture: Self.plate(512, 512))
        #expect(Self.textIn(vc.view).contains(PrintFactLines.ownWords["mac.no_settings"]!["en"]!))
    }

    @Test func aFileWithNoRenderStillGetsAPanel() throws {
        // A 3MF a CAD program wrote has no picture in it. The facts are still
        // worth showing, and an empty image well is better than no panel.
        let vc = build(language: "en", facts: try Self.facts(Self.king), picture: nil)
        #expect(Self.textIn(vc.view).contains("Snapmaker U1"))
    }

    @Test func nothingIsClipped() throws {
        // Every label and value has to fit the panel it is in. A row wider than
        // the view is a truncated printer name, which is the one thing on this
        // panel a person is trying to read.
        let vc = build(language: "en", facts: try Self.facts("""
            {"printer":"Bambu Lab X1 Carbon","layerHeight":0.16,"nozzle":0.4,
             "nozzleVaries":true,"materials":["PLA","PETG","TPU"],"infill":"15%",
             "infillVaries":true,"support":true,"supportStyle":"tree(auto)",
             "objects":20,"source":"orca"}
            """), picture: Self.plate(512, 384))
        let bounds = vc.view.bounds
        for field in Self.fieldsIn(vc.view) {
            let frame = field.convert(field.bounds, to: vc.view)
            #expect(frame.maxX <= bounds.maxX + 0.5,
                    "\"\(field.stringValue)\" runs past the panel: \(frame) in \(bounds)")
            #expect(field.frame.width >= field.intrinsicContentSize.width - 0.5,
                    "\"\(field.stringValue)\" is narrower than its text")
        }
    }

    @Test(arguments: ["en", "ar"]) func aPictureOfIt(_ language: String) async throws {
        // The REAL catalogue, so the picture shows what a person sees rather
        // than a panel full of keys.
        // A plain engine, NOT `Rules.engine()`: that one looks inside the
        // running bundle, which in a test runner is the test runner. In the
        // .appex it looks in the .appex, which is the point of it.
        let khayt = (try? await KhaytEngine().translations(language: language)) ?? [:]
        #expect(!khayt.isEmpty, "no catalogue — the picture would be a panel of keys")
        let vc = KhaytPreviewController()
        _ = vc.view
        vc.install(picture: Self.plate(512, 512), facts: try Self.facts(Self.king),
                   words: Words(language: language, khayt: khayt))
        vc.view.layoutSubtreeIfNeeded()
        #expect(vc.preferredContentSize.height > 400)
        guard let dir = ProcessInfo.processInfo.environment["KHAYT_PREVIEW_SNAPSHOT"] else { return }
        let v = vc.view
        v.setFrameSize(vc.preferredContentSize)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appending(path: "preview-\(language).png"))
    }

    // MARK: - Reading the view

    static func fieldsIn(_ view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let f = view as? NSTextField { out.append(f) }
        for sub in view.subviews { out += fieldsIn(sub) }
        return out
    }

    static func textIn(_ view: NSView) -> [String] { fieldsIn(view).map(\.stringValue) }
}

/// The layout, measured.
@MainActor
struct PreviewLayoutTests {

    /// THE PICTURE MUST NOT PUSH THE PANEL WIDER THAN IT IS.
    ///
    /// An NSImageView's intrinsic size is the picture's, and a plate render is
    /// 512 across. Against a 420-wide panel it won: the image view came out
    /// 512 wide with the render clipped on the right, because the height was
    /// arithmetic that disagreed with the constraints and Auto Layout broke one
    /// to fit. The height is asked of the layout now, and this is what says so.
    @Test(arguments: [(512, 512), (512, 384), (1024, 1024), (128, 96)])
    func theRenderFitsThePanelWhateverSizeItIs(_ size: (Int, Int)) throws {
        let vc = KhaytPreviewController()
        _ = vc.view
        vc.install(picture: PreviewPanelTests.plate(size.0, size.1),
                   facts: try PreviewPanelTests.facts(PreviewPanelTests.king),
                   words: Words(language: "en", khayt: [:]))
        vc.view.setFrameSize(vc.preferredContentSize)
        vc.view.layoutSubtreeIfNeeded()
        let panel = vc.view.bounds
        for sub in vc.view.subviews {
            #expect(sub.frame.maxX <= panel.maxX + 0.5,
                    "\(type(of: sub)) \(sub.frame) runs past the panel \(panel)")
            #expect(sub.frame.maxY <= panel.maxY + 0.5,
                    "\(type(of: sub)) \(sub.frame) runs past the panel \(panel)")
            #expect(sub.frame.minX >= -0.5)
            #expect(sub.frame.minY >= -0.5)
        }
    }

    /// The panel grows with its content rather than to a number somebody typed.
    @Test func theHeightComesFromTheLayout() throws {
        let one = KhaytPreviewController()
        _ = one.view
        one.install(picture: PreviewPanelTests.plate(512, 512), facts: nil,
                    words: Words(language: "en", khayt: [:]))
        let many = KhaytPreviewController()
        _ = many.view
        many.install(picture: PreviewPanelTests.plate(512, 512),
                     facts: try PreviewPanelTests.facts(PreviewPanelTests.king),
                     words: Words(language: "en", khayt: [:]))
        #expect(many.preferredContentSize.height > one.preferredContentSize.height)
    }
}
