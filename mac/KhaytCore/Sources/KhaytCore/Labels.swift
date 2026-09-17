import Foundation

/// A printable sheet of QR labels — ported to Swift.
///
/// ── WHY THIS IS MARKUP AND NOT A VIEW ─────────────────────────────────────
///
/// A rack of spools gets labelled over months, half of it from one app and
/// half from the other, and the two halves have to come out the same size or
/// they do not sit in the same holder. So the sheet is HTML printed through
/// one shared stylesheet, and this reproduces the ORIGINAL'S TAGS — classes,
/// order, whitespace and all — rather than markup that merely means the same
/// thing.
///
/// The QR image itself is not made here: drawing one is a platform job, and
/// the caller hands in a `data:` URL. It is escaped like anything else,
/// apostrophe included, because it lands inside an attribute.
///
/// Entries arrive as `JSONValue` rather than a Swift struct on purpose. A
/// label's title is whatever the caller had — a number, a missing field — and
/// the JavaScript coerced all of it with `String()`. Taking a typed struct
/// would quietly change which sheets can be printed at all.
public enum Labels {

    /// The five-character escape, exactly the original's set.
    ///
    /// The apostrophe is in there for a reason: `src="${esc(l.qr)}"` puts
    /// caller-supplied text inside an attribute, and a four-character escape
    /// that skips `'` is the usual way markup escaping is subtly wrong.
    public static func esc(_ value: JSONValue?) -> String {
        escape(JSSemantics.text(value))
    }

    /// The same escape over text that is already text.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// The inner HTML of the print area.
    ///
    /// `heading` is optional in the sense JavaScript means it: an empty string
    /// prints no heading at all, rather than an empty one.
    public static func sheet(_ labels: [JSONValue], heading: JSONValue? = nil) -> String {
        let cards = labels.filter(JSSemantics.truthy).map(card).joined()
        let head = JSSemantics.truthy(heading)
            ? "<div class=\"lbl-heading\">\(esc(heading))</div>" : ""
        return "\(head)<div class=\"label-grid\">\(cards)</div>"
    }

    /// The same, for the common case of a plain heading string.
    public static func sheet(_ labels: [JSONValue], heading: String) -> String {
        sheet(labels, heading: .string(heading))
    }

    private static func card(_ label: JSONValue) -> String {
        let fields: [String: JSONValue]
        if case .object(let o) = label { fields = o } else { fields = [:] }

        var lines = ""
        if case .array(let items)? = fields["lines"] {
            for item in items {
                // Not truthiness here — the original asks whether the printed
                // form is blank, so `0` and `false` DO get a line and a string
                // of spaces does not.
                if case .null = item { continue }
                let text = JSSemantics.text(item)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                lines += "<div class=\"lbl-line\">\(escape(text))</div>"
            }
        }
        let qr = JSSemantics.truthy(fields["qr"])
            ? "<img class=\"lbl-qr\" src=\"\(esc(fields["qr"]))\" alt=\"QR\">" : ""
        let sub = JSSemantics.truthy(fields["sub"])
            ? "<div class=\"lbl-sub\">\(esc(fields["sub"]))</div>" : ""
        // The indentation is the original's, to the space: the sheet is diffed
        // against the other app's output, not just rendered.
        return "<div class=\"lbl-card\">\n"
            + "      \(qr)\n"
            + "      <div class=\"lbl-body\">\n"
            + "        <div class=\"lbl-title\">\(esc(fields["title"]))</div>\n"
            + "        \(lines)\n"
            + "        \(sub)\n"
            + "      </div>\n"
            + "    </div>"
    }
}
