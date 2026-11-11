import AppKit
import Testing
@testable import KhaytApp

/// ⌘→, ⌘← and ⌘⌫ are Move Along, Move Back and Delete… in the menu bar, and
/// they are also how a person moves and deletes in a text field. While text is
/// being typed they are the text's (`TypingKeys`).
@MainActor
struct TypingKeysTests {

    static func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags,
                    in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    static let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)

    /// Never shown: built off-screen and not ordered in.
    static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 80),
                 styleMask: [.titled], backing: .buffered, defer: false)
    }

    @Test("only arrows and deletes with ⌘, only while typing, and never with ⌃")
    func theRule() {
        let cmd: NSEvent.ModifierFlags = [.command]
        for code: UInt16 in [123, 124, 125, 126, 51, 117] {
            #expect(TypingKeys.belongsToText(keyCode: code, flags: cmd, editing: true))
            #expect(TypingKeys.belongsToText(keyCode: code, flags: [.command, .shift], editing: true))
            #expect(!TypingKeys.belongsToText(keyCode: code, flags: cmd, editing: false),
                    "with nothing being typed the menu keeps the key")
            #expect(!TypingKeys.belongsToText(keyCode: code, flags: [.command, .control], editing: true))
            #expect(!TypingKeys.belongsToText(keyCode: code, flags: [], editing: true),
                    "a plain arrow is not a menu key; it needs no routing")
        }
        // ⌘N (45), ⌘F (3), ⌘1 (18), ⌘K (40) stay menu commands while typing.
        for code: UInt16 in [45, 3, 18, 40] {
            #expect(!TypingKeys.belongsToText(keyCode: code, flags: cmd, editing: true))
        }
    }

    @Test("typing in a search field: ⌘→ moves the caret, ⌘⌫ deletes text, and neither reaches the menu")
    func theSearchFieldKeepsItsKeys() throws {
        let window = Self.window()
        let field = NSSearchField(frame: NSRect(x: 10, y: 20, width: 280, height: 24))
        field.stringValue = "turbine bracket"
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(TypingKeys.editor(in: window))
        editor.setSelectedRange(NSRange(location: 3, length: 0))

        let along = Self.key(124, Self.right, [.command, .numericPad, .function], in: window)
        #expect(TypingKeys.route(along, keyWindow: window) == nil, "swallowed: the menu never sees it")
        #expect(editor.selectedRange().location == 15, "the caret went to the end of the line")

        let back = Self.key(123, Self.left, [.command, .numericPad, .function], in: window)
        #expect(TypingKeys.route(back, keyWindow: window) == nil)
        #expect(editor.selectedRange().location == 0)

        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let delete = Self.key(51, "\u{7F}", [.command], in: window)
        #expect(TypingKeys.route(delete, keyWindow: window) == nil)
        #expect(editor.string == "bine bracket", "deleted to the start of the line; no job was asked about")
    }

    @Test("with no text being typed the menu has its keys, as before")
    func theMenuKeepsItsKeys() {
        let window = Self.window()
        #expect(TypingKeys.editor(in: window) == nil)
        let along = Self.key(124, Self.right, [.command, .numericPad, .function], in: window)
        #expect(TypingKeys.route(along, keyWindow: window) === along)
        // ⌘N while typing is still New Job.
        let field = NSTextField(frame: NSRect(x: 10, y: 20, width: 280, height: 24))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let new = Self.key(45, "n", [.command], in: window)
        #expect(TypingKeys.route(new, keyWindow: window) === new)
    }

    @Test("selectable text is not being typed into")
    func selectableTextIsNotTyping() {
        let window = Self.window()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        text.isEditable = false
        text.isSelectable = true
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        #expect(TypingKeys.editor(in: window) == nil)
    }

    @Test("the app installs it at launch, and the menu still has the three shortcuts it guards")
    func itIsWired() {
        let app = MenuCoverageTests.source("KhaytApp.swift")
        #expect(app.contains("TypingKeys.install()"),
                "a monitor nobody installs routes nothing")
        let menus = MenuCoverageTests.menus
        #expect(menus.contains(".keyboardShortcut(.rightArrow, modifiers: .command"))
        #expect(menus.contains(".keyboardShortcut(.leftArrow, modifiers: .command"))
        #expect(menus.contains(".keyboardShortcut(.delete, modifiers: .command)"))
    }
}
