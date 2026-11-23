import SwiftUI
import KhaytCore

/// Roles ▸ PRINTERS (P5; Figma Qqxg4imtKVgC3TfNGcRGOk, page 23, frame 2).
///
/// Printers are an area of their own in the role rules (`lib/rbac.js`
/// `canPrinter`): sending a file, controlling a print, and editing the
/// connection. They were covered by "edit orders", and the defaults are what
/// each role could do then, so nothing changes for a shop that never opens
/// this sheet.
///
/// A tick here is the shop's own TIGHTENING (`settings.roleLimits`): it can
/// take a right away from a manager or an operator and give it back, never
/// give one the rules do not, and never take one from the owner, so a shop
/// cannot lock itself out of its printers. Changing a tick is the owner's
/// (`security`/`edit`), like every other part of the staff lock.
extension Shop {

    /// The three rows of the sheet, in the frame's order.
    static let printerRoleVerbs = ["send", "control", "connection"]

    /// Whether a role has a verb today: the rules, then the shop's limits.
    func printerRoleHas(_ role: String, _ verb: String) -> Bool {
        rbac?.canPrinter(role: role, verb: verb, lockEnabled: true, limits: settingsDict["roleLimits"]) ?? false
    }

    /// Whether the tick can be changed at all: the rules give the role the
    /// verb, and the role is not the owner.
    func printerRoleCanChange(_ role: String, _ verb: String) -> Bool {
        guard role != "owner", let rbac else { return false }
        return rbac.canPrinter(role: role, verb: verb, lockEnabled: true, limits: nil)
    }

    /// `settings.roleLimits` with one tick changed. Allowing removes the
    /// limit (and the empty objects it leaves); refusing writes `false`.
    nonisolated static func roleLimits(_ limits: JSONValue?, role: String, verb: String, allowed: Bool) -> JSONValue {
        var all: [String: JSONValue] = { if case .object(let o)? = limits { return o }; return [:] }()
        var mine: [String: JSONValue] = { if case .object(let o)? = all[role] { return o }; return [:] }()
        var row: [String: JSONValue] = { if case .object(let o)? = mine["printers"] { return o }; return [:] }()
        if allowed { row[verb] = nil } else { row[verb] = .bool(false) }
        mine["printers"] = row.isEmpty ? nil : .object(row)
        all[role] = mine.isEmpty ? nil : .object(mine)
        return .object(all)
    }

    /// Change one tick. Refused for the owner's column and for a right the
    /// rules do not give; written on the book as it is on disk.
    func setPrinterRole(_ role: String, _ verb: String, allowed: Bool) async {
        moveProblem = nil
        guard permitted("security", "edit") else { return }
        guard printerRoleCanChange(role, verb) else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        do {
            try await StoreWriter.updateOffMain(build) { root in
                var settings: [String: JSONValue] = { if case .object(let o)? = root["settings"] { return o }; return [:] }()
                let next = Self.roleLimits(settings["roleLimits"], role: role, verb: verb, allowed: allowed)
                if case .object(let o) = next, o.isEmpty { settings["roleLimits"] = nil } else { settings["roleLimits"] = next }
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch { moveProblem = ErrorText.plain(error) }
    }
}

/// The sheet: one row per verb, one column per role.
struct PrinterRolesSheet: View {
    let shop: Shop
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    static let roles = ["owner", "manager", "operator", "viewer"]

    var body: some View {
        let words = shop.words
        let canChange = shop.lockAllows("security", "edit") && shop.canWrite
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("mac.roles_title")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text(words.callIt("mac.roles_printers")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Self.roles, id: \.self) { role in
                        Text(words.callIt("role." + role)).font(.caption).foregroundStyle(.secondary)
                            .gridColumnAlignment(.center)
                    }
                }
                Divider()
                ForEach(Shop.printerRoleVerbs, id: \.self) { verb in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(words.callIt("mac.roles_printer_" + verb))
                            Text(words.callIt("mac.roles_printer_" + verb + "_note"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Self.roles, id: \.self) { role in
                            tick(role, verb, canChange: canChange)
                        }
                    }
                }
            }
            Text(words.callIt("mac.roles_printers_note"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = shop.moveProblem {
                Text(problem).font(.caption).foregroundStyle(Khayt.late)
            }
            HStack {
                Spacer()
                Button(words.callIt("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// A tick the owner can change is a checkbox; one nobody can change is
    /// drawn as the frame draws it: ✓ or a dash.
    @ViewBuilder private func tick(_ role: String, _ verb: String, canChange: Bool) -> some View {
        let has = shop.printerRoleHas(role, verb)
        if shop.printerRoleCanChange(role, verb) {
            Toggle("", isOn: Binding(get: { has }, set: { on in
                saving = true
                Task { await shop.setPrinterRole(role, verb, allowed: on); saving = false }
            }))
            .labelsHidden().toggleStyle(.checkbox)
            .disabled(!canChange || saving)
            .accessibilityLabel(Text(shop.words.callIt("role." + role) + ", " + shop.words.callIt("mac.roles_printer_" + verb)))
        } else {
            Text(verbatim: has ? "\u{2713}" : "\u{2014}")
                .foregroundStyle(has ? .primary : .secondary)
                .accessibilityLabel(Text(shop.words.callIt("role." + role) + ", "
                    + shop.words.callIt(has ? "mac.roles_allowed" : "mac.roles_not_allowed")))
        }
    }
}
