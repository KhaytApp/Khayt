import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Everything a shop still has to open the other app for.
///
/// ── WHY THIS IS A TEST AND NOT A DOCUMENT ─────────────────────────────────
///
/// "The Mac app is the product; you should never need Khayt" is a standing
/// requirement, and a requirement nobody can measure decays into a claim. Three
/// separate times this session a screen was found telling a shop to go to the
/// other app for something this one had done for weeks — the library's empty
/// state, the machines', the shelf's — and each had been true when it was
/// written.
///
/// So the list lives here, and it is CLOSED: a dependency not named below fails
/// the suite. Adding one is then a deliberate act with a sentence attached
/// rather than a line of code nobody notices, and removing one is a line
/// deleted from a test, which is the direction this list is supposed to move.
@MainActor
struct NeedsTheOtherAppTests {

    /// A thing this app cannot do yet, and what a shop hits when it tries.
    struct Gap {
        let id: String
        /// What a shop is actually trying to do.
        let what: String
        /// Why it is not here yet — the honest reason, not a plan.
        let why: String
    }

    /// THE LIST. Shorten it; do not lengthen it without a very good `why`.
    static let known: [Gap] = [
        // NARROWED, not removed. SendGrid and Mailgun are sent from this app
        // now: the words are `lib/order-email.js` and the sending is one
        // URLSession POST each. What is left is the third provider, and it is
        // not a missing `if`.
        Gap(id: "outbound.email.smtp",
            what: "Moving a job that would email the customer through the "
                + "shop's own mail server",
            why: "`custom` is SMTP — a socket, EHLO, STARTTLS, AUTH, a dialogue "
               + "with a server the shop names. A second implementation of a "
               + "protocol is how two apps come to disagree about whether a "
               + "customer was told."),
        // NARROWED, not removed. The comparables half — the shop's own realized
        // margins, net of tax — is on the new-job sheet and needs no model at
        // all. What is still missing is the half that asks one to weigh them.



    ]

    // MARK: - The list is closed

    @Test("every screen that sends a shop to the other app is on the list")
    func noUndeclaredDependency() throws {
        // Reads the SOURCE, because the thing that goes stale is a sentence.
        // A string telling a shop to do something in Khayt is a dependency
        // whether or not anyone remembered to write it down here.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let words = try String(contentsOf: dir.appending(path: "Words.swift"), encoding: .utf8)

        // The sentences that point at the other app, as a shop would read them.
        var pointers: [String] = []
        for line in words.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            guard let en = text.range(of: "\"en\": \"") else { continue }
            let rest = text[en.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { continue }
            let said = String(rest[..<close])
            let points = said.contains(" in Khayt")
                || said.contains("Windows and Linux app")
                || said.contains("the other app")
            if points { pointers.append(said) }
        }

        // Each one must correspond to something on the list above. The match is
        // by hand rather than by pattern, because the point is that somebody
        // looked: an unrecognised pointer is a dependency nobody declared.
        let allowed = [
            "Runs in the Windows and Linux app for now",            // ai.*
            "Do it in Khayt so it is sent",                         // outbound.*
            "Another app has this book open",                       // not a gap: a lock
        ]
        let undeclared = pointers.filter { said in
            !allowed.contains { said.hasPrefix($0) }
        }
        #expect(undeclared.isEmpty, Comment(rawValue: """
            \(undeclared.count) screen(s) send a shop to the other app without \
            being on the list in NeedsTheOtherAppTests:

            \(undeclared.joined(separator: "\n"))

            Either add a Gap with an honest `why`, or — better — the sentence is \
            stale and this app already does it.
            """))
    }

    @Test("the list itself is honest: nothing on it is already done")
    func nothingListedIsAlreadyDone() async throws {
        // The failure this catches is the one that actually happened three
        // times: a limitation written down, fixed, and the sentence left behind
        // telling shops to go elsewhere for something that works here.
        // The module list is internal to KhaytCore, so this reads the source —
        // which is the right thing anyway: the question is what the app SHIPS,
        // and that is what the list in `KhaytEngine.swift` decides.
        let engineSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytCore/KhaytEngine.swift"),
            encoding: .utf8)

        // An AI gap is only real while its module is absent.
        // Only the gaps whose id names a module. `ai.price.recommendation` is
        // a gap in a SURFACE, not a missing module — `ai-price.js` is bundled
        // and its deterministic half is on screen.
        for gap in Self.known
        where gap.id.hasPrefix("ai.") && gap.id.split(separator: ".").count == 2 {
            let module = "ai-" + gap.id.dropFirst("ai.".count)
            #expect(!engineSource.contains("\"\(module)\","), Comment(rawValue: """
                \(gap.id) is on the list, but \(module).js IS bundled — \
                either it works now and the entry should go, or the module is \
                bundled and unreachable.
                """))
        }

        // The outbound gaps are only real while the move refuses them.
        // Telegram is deliberately NOT on the list: this app sends it.
        #expect(Shop.aiRunsHere("quote"), "quote is done and must not be listed")
        #expect(!Self.known.contains { $0.id == "ai.quote" },
                "ai.quote works here and is still on the list")
        #expect(!Self.known.contains { $0.id.contains("telegram") },
                "Telegram is sent by this app and must not be listed")
        #expect(!Self.known.contains { $0.id.contains("webhook") },
                "Webhooks are sent by this app and must not be listed")
        #expect(!Self.known.contains { $0.id.hasPrefix("product.") },
                "the product sheet holds all of it now and must not be listed")

        // ── AND THE REMAINING OUTBOUND GAPS ARE REALLY STILL REFUSED ──────
        //
        // `applyMove` refuses a move it cannot carry out WHOLE, and the set of
        // channels it can carry is one line in `Shop.swift`. A channel added
        // there while its Gap stayed behind is exactly the stale sentence this
        // file exists to catch — and it would be caught nowhere else, because
        // the app would be working and only the words would be wrong.
        let shop = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/Shop.swift"),
            encoding: .utf8)
        guard let line = shop.range(of: "let canSend: Set<String> = ["),
              let close = shop[line.upperBound...].firstIndex(of: "]") else {
            Issue.record("applyMove no longer says which channels it can send")
            return
        }
        let canSend = String(shop[line.upperBound..<close])
        #expect(!canSend.isEmpty, "applyMove still declares the channels it carries")
        #expect(!Self.known.contains { $0.id == "outbound.portal" },
                "the customer's tracking link is refreshed by this app now")

        // ── EMAIL IS NARROWER THAN A CHANNEL, SO IT IS ASKED, NOT READ ────
        //
        // `email` is deliberately absent from `canSend`: whether this app can
        // carry it depends on the PROVIDER, and that question is answered by
        // the shared module. So this asks the same question the move asks,
        // rather than scanning for a word. `outbound.email.smtp` is honest
        // exactly while `custom` is refused and the other two are not.
        let engine = try KhaytEngine()
        #expect(try await engine.emailProviderIsHttp("sendgrid"),
                "SendGrid is sent from here; the gap must not cover it")
        #expect(try await engine.emailProviderIsHttp("mailgun"),
                "Mailgun is sent from here; the gap must not cover it")
        if Self.known.contains(where: { $0.id == "outbound.email.smtp" }) {
            #expect(!(try await engine.emailProviderIsHttp("custom")), """
                outbound.email.smtp is on the list, but the module says this \
                app can carry `custom` — the entry is stale.
                """)
        }
    }

    @Test("the list is not growing")
    func theListOnlyShrinks() {
        // A number, deliberately. It is a ratchet: lowering it is the work,
        // raising it needs somebody to decide that on purpose and say why in
        // the commit.
        #expect(Self.known.count <= 3, Comment(rawValue: """
            \(Self.known.count) things still need the other app. This number is \
            a ratchet — if a new dependency is genuinely unavoidable, lower \
            something else first or raise this deliberately.
            """))
        // And every entry says what a shop is trying to do and why it cannot.
        for gap in Self.known {
            #expect(!gap.what.isEmpty && gap.why.count > 30,
                    Comment(rawValue: "\(gap.id) has no honest reason written down"))
        }
    }
}
