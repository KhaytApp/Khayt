import SwiftUI
import KhaytCore

/// Who inspected a job, on the two sheets that record an inspection.
///
/// Settings › Production has had **Require inspector** all along, and the Mac
/// saved it and asked nobody: a shop that ticked it had jobs passed with no
/// inspector asked or recorded (the Nov 10 2026 review). The other app asks
/// on its QC sheets, from the shop's operators; so does this.
///
///  - Shown when QC is on and the shop has operators. With none there is
///    nobody to name, and the sheet is as it was.
///  - It opens on whoever is signed in at this Mac, when staff sign-in is on.
///  - With **Require inspector** on, the sheet's button is off until somebody
///    is chosen, and says why.
struct QcInspector {
    /// Whether the sheets ask at all.
    static func asks(settings: [String: JSONValue], operators: Int) -> Bool {
        guard operators > 0, case .object(let qc)? = settings["qc"], case .bool(true)? = qc["enabled"] else { return false }
        return true
    }

    /// Whether the sheet may not save yet: required, askable, and nobody chosen.
    static func missing(settings: [String: JSONValue], operators: Int, chosen: String) -> Bool {
        guard asks(settings: settings, operators: operators),
              case .object(let qc)? = settings["qc"], case .bool(true)? = qc["requireInspector"] else { return false }
        return chosen.isEmpty
    }

    struct Row: View {
        let shop: Shop
        @Binding var chosen: String

        var body: some View {
            if QcInspector.asks(settings: shop.settingsDict, operators: shop.activeOperators.count) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(shop.words.callIt("qc.inspector"), selection: $chosen) {
                        Text(shop.words.callIt("qc.inspector_none")).tag("")
                        ForEach(shop.activeOperators) { op in
                            Text(op.role.isEmpty ? op.name : op.name + " · " + op.role).tag(op.id)
                        }
                    }
                    if QcInspector.missing(settings: shop.settingsDict, operators: shop.activeOperators.count, chosen: chosen) {
                        Text(shop.words.callIt("qc.inspector_required"))
                            .font(.caption).foregroundStyle(Khayt.attention)
                    }
                }
                .onAppear {
                    // Whoever is signed in here is the likeliest inspector.
                    if chosen.isEmpty, let me = shop.lockSessionId,
                       shop.activeOperators.contains(where: { $0.id == me }) { chosen = me }
                }
            }
        }
    }
}
