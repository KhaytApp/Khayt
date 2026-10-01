import SwiftUI
import KhaytCore

/// Help ▸ Send Feedback…
///
/// Small on purpose: what happened, two ticks, and one button that opens a
/// draft in the person's own mail app. What is attached, and why none of it
/// can carry a customer or a secret, is `Feedback`'s note.
struct FeedbackSheet: View {
    let shop: Shop

    static let width: CGFloat = 460

    @State private var message = ""
    @State private var screenshot = true
    @State private var book = false
    @State private var busy = false
    @State private var outcome: Feedback.Outcome?
    @State private var bookLeftOut = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.photographFlat) private var flat

    var body: some View {
        SheetFrame(width: Self.width) {
            Text(shop.words.callIt("mac.feedback_title")).font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("mac.feedback_what"))
                // `ImageRenderer` cannot host the text view behind a
                // TextEditor and draws its no-entry placeholder instead, so a
                // photograph gets the same box with the text laid in it.
                Group {
                    if flat {
                        Text(message).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(6)
                    } else {
                        TextEditor(text: $message)
                    }
                }
                    .font(.body)
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text(shop.words.callIt("mac.feedback_what_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(shop.words.callIt("mac.feedback_screenshot"), isOn: $screenshot)
                    .disabled(shop.feedbackCapture?.png == nil)
                // On by default, because it is the most useful thing in a
                // report — so it says what it shows.
                Text(shop.words.callIt("mac.feedback_screenshot_note"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(shop.words.callIt("mac.feedback_book"), isOn: $book)
                Text(shop.words.callIt("mac.feedback_book_note"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            Text(shop.words.callIt("mac.feedback_diag_note"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let said = said {
                Text(said)
                    .font(.callout)
                    .foregroundStyle(isProblem ? Khayt.attention : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } footer: {
            HStack {
                Spacer()
                if outcome == nil || isProblem {
                    Button(shop.words.callIt("common.cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(shop.words.callIt("mac.feedback_compose")) { Task { await compose() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(shop.words.callIt("common.done")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            if shop.feedbackCapture?.png == nil { screenshot = false }
        }
    }

    private var isProblem: Bool {
        if case .failed? = outcome { return true } else { return false }
    }

    /// What happened to the report, in words.
    private var said: String? {
        var lines: [String] = []
        if bookLeftOut { lines.append(shop.words.callIt("mac.feedback_book_left_out")) }
        switch outcome {
        case .composed?:
            lines.append(shop.words.callIt("mac.feedback_composed", ["address": .string(Feedback.address)]))
        case .saved(let url)?:
            lines.append(shop.words.callIt("mac.feedback_saved",
                                           ["file": .string(url.lastPathComponent),
                                            "address": .string(Feedback.address)]))
        case .failed(let why)?:
            lines.append(shop.words.callIt("mac.feedback_failed") + " " + why)
        case nil:
            break
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func compose() async {
        busy = true
        defer { busy = false }
        let capture = shop.feedbackCapture
        let facts = Feedback.facts(for: shop, windowSize: capture?.size)
        var parts = Feedback.Parts(message: message,
                                   diagnostics: Feedback.diagnostics(facts),
                                   screenshot: screenshot ? capture?.png : nil,
                                   book: nil)
        bookLeftOut = false
        if book {
            if let root = try? Feedback.storedBook(shop) {
                parts.book = await Feedback.maskedBook(root, engine: shop.engine)
            }
            bookLeftOut = parts.book == nil
        }
        let (version, build) = Feedback.appVersion()
        outcome = Feedback.compose(parts, subject: Feedback.subject(version: version, build: build)) { later in
            outcome = later
        }
    }
}
