import SwiftUI
import KhaytCore

/// Confirming a restore.
///
/// The only destructive thing this app can be asked to do, so the sheet says
/// what it will do rather than asking "are you sure?" — a question nobody can
/// answer. Three sentences: which file, what happens to the book, and that a
/// copy of the book as it stands is taken first.
struct RestoreSheet: View {
    let shop: Shop
    let subject: Restore.Candidate
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.restore_title")).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(subject.filename).font(.body).monospaced()
                HStack(spacing: 8) {
                    Text(shop.words.say(subject.written, Date.FormatStyle(date: .abbreviated, time: .shortened)))
                    Text(size).monospacedDigit()
                    if subject.isInsurance {
                        Text(shop.words.callIt("mac.restore_insurance"))
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }

            Text(shop.words.callIt("mac.restore_what"))
            Text(shop.words.callIt("mac.restore_safety"))
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.restore_do"), role: .destructive) {
                    working = true
                    Task {
                        await shop.restore(subject)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// The file's size, so a shop can tell a full book from a nearly empty one
    /// at a glance — the difference between a good backup and a bad day.
    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(subject.bytes), countStyle: .file)
    }
}
