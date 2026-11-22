import Foundation
import Testing
@testable import KhaytCore

/// `KhaytCore.Smtp` against the JavaScript it was ported from, case by case.
///
/// ── WHY THIS ONE IS PORTED AT ALL ─────────────────────────────────────────
///
/// Every other shared rule this app needs, it asks `KhaytEngine` for. SMTP
/// cannot: the plaintext half of a STARTTLS connection runs inside an
/// `NWProtocolFramer`, on Network.framework's own queue, where nothing may
/// `await` — and `KhaytEngine` is an actor, so every call into it is one. A
/// framer that suspends deadlocks the connection it is framing.
///
/// So there are two implementations, which is the thing this repository has
/// spent most of its effort undoing. What makes it safe is this file: the real
/// `lib/smtp-format.js` is loaded off disk and run over the same inputs, and
/// the two must agree. The JavaScript is the specification.
///
/// ── AND WHY THE INPUTS ARE UGLY ───────────────────────────────────────────
///
/// Every case here is one a shop can actually produce. A customer's name
/// reaches the Subject line through `{{name}}`, and a name is data — it holds
/// whatever somebody pasted into it once, including a newline, a tab, or the
/// U+007F that a copy out of a PDF leaves behind. A reply arrives split across
/// packets because that is what TCP does.
struct SmtpParityTests {

    static let module = "smtp-format"

    /// Strings chosen because they are where a hand port and a regex part
    /// company: runs of control characters, a lone CR, a DEL, leading and
    /// trailing space, and the empty string.
    static let headers: [String] = [
        "", " ", "Acme 3D", "  Acme 3D  ",
        "Layla\r\nBcc: someone@else.test",      // the injection this exists for
        "Layla\nBcc: someone@else.test",
        "Layla\r\r\nStudio",                    // a RUN, which must collapse to one space
        "\r\n\r\nLayla",                        // leading run, then trimmed away
        "Layla\u{7F}Studio",                    // DEL
        "Layla\tStudio",                        // tab is a control character here
        "Layla\u{0}Studio",                     // NUL
        "\u{1}\u{2}\u{3}",                      // nothing but control characters
        "ليلى للتصميم", "Ünïcødé", "🙂 shop",
        "a\u{B}b\u{C}c",                        // vertical tab, form feed
    ]

    /// Bodies that decide whether an email arrives whole.
    static let bodies: [String] = [
        "", "Hello", ".", "..", ".\r\n.", "\r\n.\r\n",
        ".hidden first line",
        "line one\nline two\n.line three",
        "mixed\r\nendings\rand\nmore",
        "trailing newline\n",
        "\n",
        "<p>Your print is ready.</p>\n<p>.Thanks</p>",
        "...three dots",
    ]

    /// What a server can put on the wire, including the halves of a reply.
    static let replies: [String] = [
        "", "2", "22", "220", "220 ",
        "220 smtp.example.com ESMTP ready\r\n",
        "250-smtp.example.com\r\n",
        "250-smtp.example.com\r\n250-STARTTLS\r\n",
        "250-smtp.example.com\r\n250-STARTTLS\r\n250 8BITMIME\r\n",
        "250-smtp.example.com\r\n250 8BITMIME\r\n",
        "250 OK\r\n",
        "354 End data with <CR><LF>.<CR><LF>\r\n",
        "421 Service not available\r\n",
        "535 5.7.8 Authentication credentials invalid\r\n",
        "550 5.7.1 Relay access denied\r\n",
        "250-A\r\n250-B\r\n250-C\r\n250 D\r\n",
        // A banner that says the word without offering the thing. The naive
        // spelling of `offersStartTls` — does the text contain "STARTTLS" —
        // reads this as an offer and puts the shop's password on a plaintext
        // socket, which is the reason both sides anchor to a line.
        "220 starttls-relay.example.com ESMTP\r\n250 OK\r\n",
        "250 STARTTLS\r\n",
        "250-starttls\r\n250 OK\r\n",
        "250-X-STARTTLS-ISH\r\n250 OK\r\n",
        "\r\n\r\n250 OK\r\n",
        "999 who knows\r\n",
        "1 OK\r\n",
        "٢٥٠ OK\r\n",                          // Arabic-Indic digits are not digits here
    ]

    @Test("sanitizeHeader agrees with the module on every awkward string")
    func sanitize() throws {
        let js = try Parity.context(loading: [Self.module])
        for input in Self.headers {
            let theirs = try Parity.run(js, "KhaytSmtpFormat.sanitizeHeader(ARG0)",
                                        [.string(input)])
            #expect(theirs == .string(Smtp.sanitizeHeader(input)),
                    "sanitizeHeader disagreed on \(escaped(input))")
        }
    }

    @Test("dotStuff agrees with the module on every body")
    func stuffing() throws {
        let js = try Parity.context(loading: [Self.module])
        for input in Self.bodies {
            let theirs = try Parity.run(js, "KhaytSmtpFormat.dotStuff(ARG0)", [.string(input)])
            #expect(theirs == .string(Smtp.dotStuff(input)),
                    "dotStuff disagreed on \(escaped(input))")
        }
    }

    @Test("offersStartTls agrees — including on the banner that only says the word")
    func startTls() throws {
        let js = try Parity.context(loading: [Self.module])
        var offered = 0
        for input in Self.replies {
            let theirs = try Parity.run(js, "KhaytSmtpFormat.offersStartTls(ARG0)",
                                        [.string(input)])
            let mine = Smtp.offersStartTls(input)
            #expect(theirs == .bool(mine), "offersStartTls disagreed on \(escaped(input))")
            if mine { offered += 1 }
        }
        // Anti-vacuity: a port that always answered `false` would agree with a
        // module that always answered `false`, and both would be wrong.
        #expect(offered >= 3, "no fixture actually offers STARTTLS — this test proves nothing")
    }

    @Test("replyIsComplete agrees on where a reply ends and what it says")
    func replies() throws {
        let js = try Parity.context(loading: [Self.module])
        var complete = 0
        for input in Self.replies {
            let theirs = try Parity.run(js, "KhaytSmtpFormat.replyIsComplete(ARG0)",
                                        [.string(input)])
            let mine = Smtp.replyIsComplete(input)
            guard case .object(let their) = theirs else {
                #expect(mine == nil, "the module wanted more bytes and the port did not, on \(escaped(input))")
                continue
            }
            guard let mine else {
                Issue.record("the port wanted more bytes and the module did not, on \(escaped(input))")
                continue
            }
            complete += 1
            #expect(their["code"] == .number(Double(mine.code)), "code differed on \(escaped(input))")
            #expect(their["text"] == .string(mine.text), "text differed on \(escaped(input))")
            #expect(their["ok"] == .bool(mine.ok), "ok differed on \(escaped(input))")
        }
        #expect(complete >= 8, "hardly any fixture parsed — this test proves nothing")
    }

    @Test("a reply arriving in pieces completes in the same place as the module")
    func partialArrival() throws {
        // TCP splits where it likes. A client that reads the first packet of a
        // 250- response as the whole answer decides the server cannot encrypt,
        // which is not a hang — it is a refusal to send.
        //
        // Note what "complete" means: the terminator is the SPACE after the
        // code, so `250 ` completes the reply before the rest of its own line
        // has arrived. That is correct, and it is exactly the sort of detail
        // two implementations drift on, so it is checked against the module
        // byte by byte rather than asserted from memory.
        let js = try Parity.context(loading: [Self.module])
        let whole = "250-smtp.example.com\r\n250-STARTTLS\r\n250 8BITMIME\r\n"
        var seen = ""
        var firstComplete: String?
        for character in whole {
            seen.append(character)
            let mine = Smtp.replyIsComplete(seen)
            let theirs = try Parity.run(js, "KhaytSmtpFormat.replyIsComplete(ARG0)",
                                        [.string(seen)])
            let theyAgree = (mine == nil) == (theirs == .null)
            #expect(theyAgree, "they disagreed about whether this is complete: \(escaped(seen))")
            if mine != nil, firstComplete == nil { firstComplete = seen }
        }

        // And nothing in the first two lines may look like a whole reply: both
        // of them begin `250-`, which is the continuation marker.
        let completed = try #require(firstComplete, "the whole reply was never complete")
        #expect(completed.hasPrefix("250-smtp.example.com\r\n250-STARTTLS\r\n250 "),
                "read as complete too early, at \(escaped(completed))")
    }

    @Test("buildMessage agrees with the module, headers, stuffing and terminator")
    func message() throws {
        let js = try Parity.context(loading: [Self.module])
        var checked = 0
        for name in Self.headers {
            for body in Self.bodies where checked < 400 {
                checked += 1
                let theirs = try Parity.run(
                    js,
                    "KhaytSmtpFormat.buildMessage({from: ARG0, fromName: ARG1, to: ARG2, subject: ARG3, html: ARG4})",
                    [.string("orders@shop.test"), .string(name),
                     .string("customer@example.com"), .string(name), .string(body)])
                let mine = Smtp.buildMessage(
                    from: "orders@shop.test", fromName: name,
                    to: "customer@example.com", subject: name, html: body)
                #expect(theirs == .string(mine),
                        "buildMessage disagreed for name \(escaped(name)) body \(escaped(body))")
            }
        }
        #expect(checked > 100, "hardly anything was compared — this test proves nothing")
    }

    @Test("both apps say the same name in EHLO")
    func ehlo() throws {
        let js = try Parity.context(loading: [Self.module])
        #expect(try Parity.run(js, "KhaytSmtpFormat.EHLO_NAME") == .string(Smtp.ehloName))
    }

    @Test("AUTH LOGIN sends the user and then the password, each base64")
    func auth() {
        // Not parity — `custom-smtp.js` uses Node's Buffer, which is not in the
        // shared module — but the ORDER is the protocol and getting it round
        // the wrong way authenticates as the password.
        let payloads = Smtp.authLoginPayloads(user: "orders@shop.test", pass: "hunter2")
        #expect(payloads.count == 2)
        #expect(payloads[0] == "b3JkZXJzQHNob3AudGVzdA==")
        #expect(payloads[1] == "aHVudGVyMg==")
    }

    /// Control characters printed as escapes, so a failure names the input
    /// instead of moving the cursor around.
    private func escaped(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u{%02X}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
