import Foundation

/// A number as somebody typed it, read the way they meant it.
///
/// `Double("١٥٠")` is nil, and so is `Double("1,5")`. Every text field that
/// read its number that way took a weight typed on an Arabic keyboard as 0 —
/// Add part stayed greyed out, a price override became 0, a new price was
/// silently not saved — and took the comma a German, French, Spanish, Turkish
/// or Brazilian shop types for a decimal as nothing at all (or, where the
/// commas were stripped first, read "1,5" hours as 15).
///
/// The rule:
///  - any Unicode digit is its value (Arabic-Indic, Persian);
///  - "." and "٫" are the decimal point; "٬", spaces and "'" group thousands;
///  - a "," is the decimal point when it is the only separator and is not
///    followed by exactly three digits ("1,5" is 1.5, "12,75" is 12.75);
///    otherwise it groups thousands ("1,528" is 1528, "1,250.5" is 1250.5 —
///    this app pre-fills fields with grouped figures, so that reading wins);
///  - "1.250,5" (a point grouping, a comma deciding) is 1250.5.
/// Anything else — a letter, a second decimal point, a minus — is not a
/// number, and the caller gets nil rather than a guess.
enum TypedNumber {
    static func parse(_ text: String) -> Double? {
        var plain = ""
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let d = ch.wholeNumberValue, ch.isNumber { plain.append(String(d)) }
            else if ch == "." || ch == "٫" { plain.append(".") }
            else if ch == "," || ch == "،" { plain.append(",") }
            else if ch == "٬" || ch == " " || ch == "\u{00A0}" || ch == "\u{202F}" || ch == "'" { continue }
            else { return nil }
        }
        let commas = plain.filter { $0 == "," }.count
        let points = plain.filter { $0 == "." }.count
        if commas > 0 {
            if points == 0, commas == 1, let at = plain.firstIndex(of: ",") {
                let after = plain[plain.index(after: at)...]
                // "1,528" groups; "1,5", "12,75" and "0,125" decide.
                let groups = after.count == 3 && plain[..<at].count <= 3
                    && plain[..<at].first != "0" && !plain[..<at].isEmpty
                plain = groups ? plain.replacingOccurrences(of: ",", with: "")
                               : plain.replacingOccurrences(of: ",", with: ".")
            } else if points == 1, let lastComma = plain.lastIndex(of: ","),
                      let point = plain.firstIndex(of: "."), point < lastComma, commas == 1 {
                // "1.250,5": the point groups, the comma decides.
                plain = plain.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                plain = plain.replacingOccurrences(of: ",", with: "")
            }
        }
        guard !plain.isEmpty, plain.filter({ $0 == "." }).count <= 1,
              let n = Double(plain), n.isFinite, n >= 0 else { return nil }
        return n
    }
}
