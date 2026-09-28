import AppKit

/// Copy a secret — a key shown once, a sign-in link — so that clipboard
/// managers and Universal Clipboard leave it alone.
///
/// `org.nspasteboard.ConcealedType` is the convention (nspasteboard.org) that
/// clipboard history apps honour by not recording the item, and that macOS's
/// own password fields use. The string is still on the pasteboard for the one
/// paste the shop meant to make. Sep 2026 security review.
enum SecretPasteboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(_ secret: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
    }
}
