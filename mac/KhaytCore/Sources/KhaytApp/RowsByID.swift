import SwiftUI

/// Editable rows bound by their ID, never by their position.
///
/// ── THE CRASH THIS EXISTS FOR ─────────────────────────────────────────────
///
/// `ForEach($lines) { $line in TextField(…, value: $line.amount …) }` hands
/// each field a binding that reads `lines[i]`. Remove a row (its ✖︎ button,
/// Cancel, or a save that reloads the list) while a field in it still has
/// focus, and the field commits its text on the way out — through that
/// binding, to an index that is no longer there. Swift traps, and the app
/// quits. Seen in Settings ▸ Overhead on alpha.77 (Oct 17 2026): crash in
/// `Array._checkSubscript` under `SystemTextField.body`.
///
/// `$rows.byID` gives each row a binding that FINDS its row by `id` on every
/// read and write. A write to a row that has gone is dropped, and a read
/// returns the row as it last was, so a field going away can never index
/// past the end. `MacConventionsTests` keeps `ForEach($…)` from coming back.
extension Binding where Value: MutableCollection, Value.Element: Identifiable {
    var byID: [Binding<Value.Element>] {
        wrappedValue.map { row in
            let id = row.id
            return Binding<Value.Element>(
                get: { wrappedValue.first { $0.id == id } ?? row },
                set: { new in
                    if let at = wrappedValue.firstIndex(where: { $0.id == id }) {
                        wrappedValue[at] = new
                    }
                })
        }
    }
}

/// A number field that changes its value AS YOU TYPE.
///
/// `TextField(value:format:)` only hands its number over on Return or when it
/// loses focus. In Settings ▸ Overhead that meant: type 100 in a cost's
/// amount, click Save — and Save was still greyed out (nothing had changed
/// yet), or saved 0. This field parses on every keystroke, takes Arabic-Indic
/// digits and a thousands comma, and leaves the value alone while the text is
/// half a number ("12.").
struct LiveNumberField: View {
    @Binding var value: Double
    var prompt = "0"
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text(verbatim: prompt))
            .onAppear { text = Self.show(value) }
            .onChange(of: text) {
                if let typed = Self.parse(text) {
                    if typed != value { value = typed }
                } else if text.trimmingCharacters(in: .whitespaces).isEmpty, value != 0 {
                    value = 0
                }
            }
            // Cancel, or a reload, puts a different number underneath.
            .onChange(of: value) {
                if Self.parse(text) != value { text = Self.show(value) }
            }
    }

    static func show(_ value: Double) -> String {
        value == 0 ? "" : value.formatted(.number.grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }

    static func parse(_ text: String) -> Double? {
        var plain = ""
        for ch in text {
            if let d = ch.wholeNumberValue, ch.isNumber { plain.append(String(d)) }
            else if ch == "." || ch == "٫" { plain.append(".") }
            else if ch == "," || ch == "٬" || ch == " " { continue }
            else { return nil }
        }
        guard !plain.isEmpty, let n = Double(plain), n.isFinite, n >= 0 else { return nil }
        return n
    }
}
