import AppKit

/// Copy a secret — a key shown once, a sign-in link — so that it stays on
/// this Mac and clipboard history apps are asked not to keep it.
///
/// Three separate things, and none of them is a guarantee:
///
/// - `prepareForNewContents(with: .currentHostOnly)` is AppKit's own switch
///   (macOS 10.12+): "the pasteboard contents should not be available to
///   other devices", i.e. it keeps the item off Universal Clipboard. This is
///   the one that macOS itself enforces.
/// - `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType` are
///   the nspasteboard.org conventions: concealed means "a password or other
///   sensitive data", transient means "only there for a moment". Clipboard
///   managers that follow the convention do not record such an item. They are
///   a REQUEST to third-party apps — macOS does not enforce them, and a
///   clipboard manager that ignores them still sees the string.
///
/// The string is still on the pasteboard for the one paste the shop meant to
/// make, and any app on this Mac that reads the pasteboard can read it.
/// Sep 2026 security review; corrected Oct 2026 (the earlier note said the
/// concealed marker kept it off Universal Clipboard, which it does not).
enum SecretPasteboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(_ secret: String, to pasteboard: NSPasteboard = .general) {
        // Not `declareTypes`, which is the older way to start new contents:
        // the header promises the option persists only until the next
        // `prepareForNewContents` or `clearContents`, so the setters below
        // write onto the contents this call prepared.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setData(Data(), forType: transient)
    }
}
