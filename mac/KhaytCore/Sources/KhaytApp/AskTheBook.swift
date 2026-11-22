import SwiftUI
import KhaytCore

/// Asking questions about the shop's own book.
///
/// ── WHAT IT IS GIVEN, AND WHY THAT IS THE WHOLE DESIGN ────────────────────
///
/// Not the book. A SUMMARY — `buildShopContext` reduces orders, shelf,
/// customers and settings to a few hundred bytes of totals and counts, and the
/// system prompt forbids the model to answer with anything absent from it.
///
/// That is what makes this answerable when a shop asks what it sends: a list of
/// four collections and a summary it can be shown, rather than a shrug. It is
/// also why the answers are about figures and not about individual customers —
/// no name, no address and no order reference is in the payload.
///
/// ── AND WHY THE QUESTIONS ARE SUGGESTED ───────────────────────────────────
///
/// A blank box with a cursor in it is a test a shop can fail. The suggestions
/// are the questions the summary can actually answer, so the first thing
/// anybody tries works rather than coming back "that is not in the summary".
struct AskTheBook: View {
    @Bindable var shop: Shop
    @State private var question = ""
    @FocusState private var focused: Bool

    /// Questions the summary genuinely contains an answer to.
    private var suggestions: [String] {
        ["mac.ask_eg_month", "mac.ask_eg_owing", "mac.ask_eg_busy"]
            .map { shop.words.callIt($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            asker
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 320, idealHeight: 460)
    }

    private var header: some View {
        HStack {
            Label(shop.words.callIt("mac.ask_the_book"), systemImage: "sparkles")
                .font(.headline)
            Spacer()
            if !shop.asked.isEmpty {
                Button(shop.words.callIt("mac.start_over")) { shop.forgetConversation() }
                    .buttonStyle(.link)
            }
        }
        .padding(14)
    }

    @ViewBuilder private var transcript: some View {
        if shop.asked.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(shop.words.callIt("mac.ask_what_it_sees"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(suggestions, id: \.self) { one in
                    Button(one) { question = one; Task { await send() } }
                        .buttonStyle(.link)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(shop.asked) { turn in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(turn.question)
                                .font(.callout.weight(.medium))
                            if let answer = turn.answer {
                                Text(answer)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if let problem = turn.problem {
                                Text(problem)
                                    .foregroundStyle(Khayt.attention)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(shop.words.callIt("mac.thinking"))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
        }
    }

    private var asker: some View {
        HStack(spacing: 8) {
            TextField(shop.words.callIt("mac.ask_a_question"), text: $question)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { Task { await send() } }
            Button(shop.words.callIt("mac.ask_it")) { Task { await send() } }
                .disabled(shop.asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
        .onAppear { focused = true }
    }

    private func send() async {
        let said = question
        question = ""
        await shop.ask(said)
    }
}
