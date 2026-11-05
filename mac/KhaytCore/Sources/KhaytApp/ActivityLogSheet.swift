import SwiftUI
import KhaytCore

/// Who did what: the team activity log, newest first, narrowed to one
/// member if asked.
///
/// The desktop's Activity log (`renderer/app-helpers.js openActivityLog`):
/// the same collection, the same newest-first order, the same three hundred
/// rows, the same member filter. This app has written the entries all along
/// (`Shop.appendActivity`) and never shown them.
struct ActivityLogSheet: View {
    @Bindable var shop: Shop
    /// Empty is everybody.
    @State private var member = ""

    /// How many the desktop lists; the book keeps two thousand.
    static let shown = 300

    /// One line of the log, read leniently.
    struct Entry: Identifiable, Hashable {
        let id: String
        let at: String
        let action: String
        let detail: String
        let operatorId: String
        let operatorName: String
    }

    /// The log as the sheet lists it: newest first, `member`'s only when one
    /// is chosen, at most `shown`. Static so a test can ask it of a book.
    static func entries(_ rows: [JSONValue], member: String) -> [Entry] {
        var out: [Entry] = []
        for (at, row) in rows.enumerated().reversed() {
            guard case .object(let r) = row else { continue }
            let who = Shop.plainString(r["operatorId"]) ?? ""
            if !member.isEmpty, who != member { continue }
            out.append(Entry(id: Shop.plainString(r["id"]) ?? "row-" + String(at),
                             at: Shop.plainString(r["at"]) ?? "",
                             action: Shop.plainString(r["action"]) ?? "",
                             detail: Shop.plainString(r["detail"]) ?? "",
                             operatorId: who,
                             operatorName: Shop.plainString(r["operatorName"]) ?? ""))
            if out.count == shown { break }
        }
        return out
    }

    /// The action's own word, else the action as stored — a newer build may
    /// write one this catalogue has not heard of.
    private func said(_ action: String) -> String {
        let key = "audit.act_" + action
        let word = shop.words.callIt(key)
        return word == key ? action : word
    }

    private func when(_ iso: String) -> String {
        guard let date = Calendar.instant(iso) else { return iso }
        return shop.words.say(date, Date.FormatStyle(date: .abbreviated, time: .shortened))
    }

    var body: some View {
        let rows = Self.entries(shop.auditRows, member: member)
        SheetFrame(width: 560) {
            HStack {
                Text(shop.words.callIt("audit.title")).font(.headline)
                Spacer()
                if !shop.operators.isEmpty {
                    Picker("", selection: $member) {
                        Text(shop.words.callIt("audit.all_members")).tag("")
                        ForEach(shop.operators) { op in Text(op.name).tag(op.id) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if rows.isEmpty {
                Text(shop.words.callIt("audit.empty"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(Text(said(e.action)).fontWeight(.semibold)) \(e.detail)")
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(e.operatorName.isEmpty ? shop.words.callIt("audit.system") : e.operatorName)
                                Text(when(e.at)).monospacedDigit()
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.showingActivityLog = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
