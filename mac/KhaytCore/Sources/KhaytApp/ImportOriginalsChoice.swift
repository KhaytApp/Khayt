import AppKit
import KhaytCore

/// "When adding models: Keep my original files / Move them into Khayt's
/// library" — the Add panel's own question, with its label and its warning.
///
/// ── WHAT WAS WRONG WITH THE BARE POP-UP ───────────────────────────────────
///
/// It sat at the foot of the open panel with no label, so it read as one of
/// the panel's own controls rather than a question about the shop's files.
/// Choosing Move said nothing about iCloud Drive or Dropbox, where sending a
/// file to the Trash removes it from every device the folder syncs to. And
/// the choice was REMEMBERED, so a Move picked here once applied, without a
/// word, to every folder later dragged onto the library.
///
/// Now it is labelled, says what Move means the moment it is chosen (the
/// same sentence Settings › Library shows), starts at the Settings answer
/// and applies to this one import.
@MainActor
final class ImportOriginalsChoice: NSObject {
    let view: NSView
    private let popup: NSPopUpButton
    private let hint: NSTextField

    init(words: Words, moves: Bool) {
        let label = NSTextField(labelWithString: words.callIt("mac.import_originals_title") + ":")
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [words.callIt("mac.import_keep_originals"),
                                    words.callIt("mac.import_move_originals")])
        popup.selectItem(at: moves ? 1 : 0)
        hint = NSTextField(wrappingLabelWithString: words.callIt("mac.import_originals_hint"))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 440
        hint.isHidden = !moves

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [row, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    /// True when the shop chose to move the originals in, for this import.
    var moves: Bool { popup.indexOfSelectedItem == 1 }

    /// The warning comes and goes with the choice it is about.
    @objc private func changed() {
        hint.isHidden = !moves
        view.needsLayout = true
    }
}

extension Shop {
    /// " · 3 originals moved to the Trash." after an import that sent any
    /// there — the shop's own files, which it should not have to discover are
    /// gone. A model taken out of an archive is a scratch copy, not an
    /// original, and is not counted.
    static func trashedNote(_ trashed: [URL], scratches: [URL], words: Words) -> String {
        let scratchPaths = scratches.map { $0.standardizedFileURL.path }
        let originals = trashed.filter { url in
            let path = url.standardizedFileURL.path
            return !scratchPaths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        guard !originals.isEmpty else { return "" }
        return " " + words.counting(originals.count, "mac.import_trashed")
    }
}
