import AppKit
import QuickLookUI
import CoreGraphics
import ImageIO
import KhaytCore

/// What the space bar shows for a `.3mf`.
///
/// ── WHY A PREVIEW AND NOT JUST THE ICON ───────────────────────────────────
///
/// The thumbnail answers "which model is this". The question a shop asks a
/// second later is "is this the one set up for the right machine" — because a
/// folder holds the same shape sliced for a U1 and for an X1 Carbon, at three
/// layer heights, one with support and one without, and the pictures are
/// identical. Every one of those answers is already inside the file.
///
/// Nothing here is estimated and nothing is rendered. The picture is the plate
/// render the slicer wrote; the facts are `lib/print-facts.js`, the same rule
/// the app's own library inspector calls, laid out by `PrintFactLines`, which is
/// the same code the inspector lays out with. Finder and Khayt cannot hold two
/// opinions about what a model prints in.
@objc(KhaytPreviewController)
final class KhaytPreviewController: NSViewController, QLPreviewingController {

    // The view is made here and FILLED IN later, never replaced. Quick Look has
    // already put this view into its own hierarchy by the time the file has been
    // read, so assigning `view` again leaves the panel showing the empty one it
    // already installed — which looks exactly like a preview that returned
    // nothing.
    override func loadView() {
        let v = NSView()
        v.setFrameSize(NSSize(width: 420, height: 560))
        view = v
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let picture = try? Self.picture(inside: url)
        // ONE ENGINE, used twice. The facts and the words both come through the
        // shared rules, and building an engine for each meant two JavaScriptCore
        // contexts and two loads of the same 82 modules — 78 ms apiece, paid
        // twice, every time somebody taps the space bar.
        let engine = try? Rules.engine()
        let facts = engine == nil ? nil : try? await Self.facts(inside: url, using: engine!)
        let words = await Words.load(using: engine)
        await MainActor.run { install(picture: picture, facts: facts ?? nil, words: words) }
    }

    enum Failure: Error { case noPreview, notAnImage }

    /// The plate render, chosen by the rule the thumbnail extension uses.
    static func picture(inside url: URL) throws -> CGImage {
        let entries = try Zip.entries(of: url)
        guard let name = ThreeMF.preview(among: entries.map(\.name)),
              let entry = entries.first(where: { $0.name == name }) else {
            throw Failure.noPreview
        }
        let data = try Zip.data(of: entry, in: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.notAnImage
        }
        return image
    }

    /// The slicer's own words about the print.
    ///
    /// The engine is built once per preview and dies with the process. That
    /// would be wasteful in a window and is right here: the alternative is a
    /// second implementation of a rule that already exists, and two
    /// implementations disagree eventually. It costs 78 ms to start and 7 ms to
    /// ask — see `EngineCostTests`, which is why that test exists.
    static func facts(inside url: URL,
                      using engine: KhaytEngine) async throws -> KhaytEngine.PrintFacts? {
        let entries = try Zip.entries(of: url)
        func text(_ name: String) -> String {
            guard let e = entries.first(where: { $0.name.lowercased() == name.lowercased() }),
                  let d = try? Zip.data(of: e, in: url) else { return "" }
            return String(decoding: d, as: UTF8.self)
        }
        let project = text("Metadata/project_settings.config")
        let model = text("Metadata/model_settings.config")
        // Either spelling, depending on how old the PrusaSlicer was.
        var prusa = text("Metadata/Slic3r_PE.config")
        if prusa.isEmpty { prusa = text("Metadata/Prusa_Slicer.config") }
        if project.isEmpty && model.isEmpty && prusa.isEmpty { return nil }
        return try await engine.printFacts(projectSettings: project,
                                           modelSettings: model, prusa: prusa)
    }

    // MARK: - The panel

    @MainActor
    func install(picture: CGImage?, facts: KhaytEngine.PrintFacts?, words: Words) {
        let root = view
        root.subviews.forEach { $0.removeFromSuperview() }
        root.userInterfaceLayoutDirection = words.isRTL ? .rightToLeft : .leftToRight

        let art = NSImageView()
        art.translatesAutoresizingMaskIntoConstraints = false
        art.imageScaling = .scaleProportionallyUpOrDown
        if let picture {
            art.image = NSImage(cgImage: picture,
                                size: NSSize(width: picture.width, height: picture.height))
        }

        let table = NSStackView()
        table.translatesAutoresizingMaskIntoConstraints = false
        table.orientation = .vertical
        table.alignment = words.isRTL ? .trailing : .leading
        table.spacing = 7
        table.userInterfaceLayoutDirection = root.userInterfaceLayoutDirection

        let lines = PrintFactLines.lines(from: facts,
                                         word: { words.callIt($0) },
                                         counting: { words.counting($0, $1) })
        for line in lines {
            table.addArrangedSubview(Self.row(label: line.label, value: line.value,
                                              dim: line.dim, rtl: words.isRTL))
        }
        if lines.isEmpty {
            let l = NSTextField(labelWithString: words.callIt("mac.no_settings"))
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            table.addArrangedSubview(l)
        }

        // The picture must not push the panel wider than it is. An NSImageView's
        // intrinsic size is the PICTURE's — 512 for a plate render — and left to
        // fight the panel's edges it won: the image view came out 512 wide
        // inside a 420 panel, with the render clipped on the right. Low
        // resistance says the edges are the authority and the picture scales.
        art.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        art.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        art.setContentHuggingPriority(.defaultLow, for: .horizontal)
        art.setContentHuggingPriority(.defaultLow, for: .vertical)

        root.addSubview(art)
        root.addSubview(table)
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            art.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            art.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            // Square, because a plate is square and a render that is not gets
            // letterboxed inside it rather than stretched.
            art.heightAnchor.constraint(equalTo: art.widthAnchor),
            table.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 18),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            table.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            table.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])

        // THE HEIGHT IS MEASURED, NOT GUESSED. It was arithmetic — a base plus a
        // row height times the number of rows — and the arithmetic disagreed
        // with the layout, so Auto Layout broke a constraint to fit and the
        // render ran off the right-hand edge. Asking the layout what it needs
        // cannot disagree with the layout.
        let width = root.widthAnchor.constraint(equalToConstant: Self.panelWidth)
        width.priority = .defaultHigh   // the host may still choose its own
        width.isActive = true
        root.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.panelWidth,
                                      height: root.fittingSize.height)
    }

    /// Wide enough for a printer name and a render worth looking at. Quick Look
    /// may choose otherwise; everything here is expressed against the edges, so
    /// it may.
    static let panelWidth: CGFloat = 420

    /// A label and a value, with the label column a fixed width — ragged colons
    /// down a panel read as a fault rather than as a layout.
    @MainActor
    static func row(label: String, value: String, dim: Bool, rtl: Bool) -> NSView {
        let line = NSStackView()
        line.orientation = .horizontal
        line.spacing = 12
        line.userInterfaceLayoutDirection = rtl ? .rightToLeft : .leftToRight
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.alignment = rtl ? .left : .right
        l.widthAnchor.constraint(equalToConstant: 116).isActive = true
        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: 11, weight: dim ? .regular : .medium)
        v.textColor = dim ? .secondaryLabelColor : .labelColor
        line.addArrangedSubview(l)
        line.addArrangedSubview(v)
        return line
    }
}
