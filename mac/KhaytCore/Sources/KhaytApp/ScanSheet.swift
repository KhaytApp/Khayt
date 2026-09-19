import SwiftUI
import KhaytCore

/// Reading back a label this app printed.
///
/// ── THE LOOP THIS CLOSES ──────────────────────────────────────────────────
///
/// `ShelfLabels` already writes a code onto every label this app prints: a
/// spool gets `KHAYT-SPOOL:<id>`, a parcel gets `KHAYT-ORDER:<id>` or, for a
/// shop with the cloud connected, the customer's own tracking link. The other
/// app has been able to read those back since 3.0 and this one could only
/// write them — so a shop could print a label here, hold a scanner to it, and
/// have nothing happen.
///
/// A BARCODE SCANNER IS A KEYBOARD. It types the code and presses Return, so
/// the field takes the whole thing and acts on submit; there is no camera and
/// no "Scan" button to press, because the scanner has already pressed it.
struct ScanSheet: View {
    /// See `NewJobSheet.width`.
    static let width: CGFloat = 420

    @Bindable var shop: Shop

    @State private var code = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        SheetFrame(width: Self.width) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.scan_title")).font(.headline)
                Text(shop.words.callIt("mac.scan_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(shop.words.callIt("mac.scan_ph"), text: $code)
                .textFieldStyle(.roundedBorder)
                .monospaced()
                .focused($focused)
                .onSubmit(follow)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.scanning = false }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.scan_open"), action: follow)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func follow() {
        let typed = code
        Task {
            if let said = await shop.followScan(typed) {
                problem = said
                // The code stays so it can be read and corrected — a scanner
                // that misread one character is the common case, and clearing
                // the field hides the evidence.
            } else {
                shop.scanning = false
            }
        }
    }
}
