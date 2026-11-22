import SwiftUI
import KhaytCore

// The question a changed switch asks the owner (`Shop+NetworkSwitch.swift`
// holds the rule and the words). In a file of its own because it DRAWS:
// `MessagesAreShownTests` holds every message `Shop` writes to a reader that
// can draw it, and a view inside a `Shop+` file is not one it can see.

/// One of the two questions, as page 27 draws it (frames G1 and G2): the
/// sentence on an amber ground, and under it the buttons the rule allows, the
/// first one filled. The question is the owner's: anybody else sees it, with
/// the buttons off.
///
/// `link`: the way to Internet use, where the switch and what follows it are
/// said in full. On in the every-screen notice, off on the Internet use page
/// itself, which shows the same question at its top.
struct NetworkSwitchQuestion: View {
    let shop: Shop
    let ask: NetworkSwitchAsk
    var link = true
    /// Rounded, inside a page; square, across the top of a window.
    var rounded = false
    /// A capture's stand-in for who is signed in. Nil asks the lock.
    var pretendMayAnswer: Bool?

    private var mayAnswer: Bool { pretendMayAnswer ?? shop.lockAllows("security", "edit") }
    /// What the other computer set, when it was read (`networkSwitchHeld`).
    var pretendThere: Bool??
    private var there: Bool? { pretendThere ?? shop.networkSwitchHeld?.offline }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(Khayt.attention).accessibilityHidden(true)
                Text(NetworkSwitchWords.sentence(ask, there: there, words: shop.words))
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                ForEach(Array(ask.choices(there: there).enumerated()), id: \.element.key) { index, choice in
                    if index == 0 {
                        Button(shop.words.callIt(choice.key)) { Task { await shop.answerNetworkSwitch(apply: choice.apply) } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(shop.words.callIt(choice.key)) { Task { await shop.answerNetworkSwitch(apply: choice.apply) } }
                            .buttonStyle(.bordered)
                    }
                }
                .disabled(!mayAnswer || shop.networkSwitchAnswering)
                if link {
                    Spacer(minLength: 8)
                    OpenInternetUse(shop: shop)
                }
            }
            .controlSize(.small)
            // The answer changed nothing, and why: the question stays.
            if let problem = shop.networkSwitchAnswerProblem {
                Text(problem)
                    .font(.system(size: 12)).foregroundStyle(Khayt.late)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, rounded ? 12 : 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Khayt.attention.opacity(0.13), in: RoundedRectangle(cornerRadius: rounded ? 8 : 0))
    }
}

