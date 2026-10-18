import SwiftUI
import KhaytCore

/// "Under service · waiting for a hotend · since 12 Oct", or "Retired 3 Sep ·
/// sold". IN WORDS: a symbol and a sentence, so the state reads without the
/// colour — the tint only repeats what the words already say.
struct MachineLifeBadge: View {
    let machine: Machine
    let words: Words

    var body: some View {
        if machine.isUnderService || machine.isRetired {
            Label {
                Text(sentence)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: machine.isRetired ? "archivebox" : "wrench.and.screwdriver")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(machine.isRetired ? AnyShapeStyle(.secondary) : AnyShapeStyle(Khayt.attention))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)
        }
    }

    var sentence: String { Self.sentence(machine, words) }

    /// The badge's words, for the card and for a test that reads them.
    @MainActor static func sentence(_ machine: Machine, _ words: Words) -> String {
        var parts: [String] = []
        if machine.isRetired {
            if let day = machine.retiredOn.flatMap(Order.day) {
                parts.append(words.callIt("mac.life_retired_on", ["date": .string(say(day, words))]))
            } else {
                parts.append(words.callIt("mac.life_badge_retired"))
            }
            if let why = machine.retiredBecause { parts.append(why) }
        } else if machine.isUnderService {
            parts.append(words.callIt("mac.life_badge_service"))
            if let why = machine.underServiceReason { parts.append(why) }
            if let day = machine.underServiceSince.flatMap(Order.day) {
                parts.append(words.callIt("mac.life_since", ["date": .string(say(day, words))]))
            }
        }
        return parts.joined(separator: " · ")
    }

    @MainActor private static func say(_ day: Date, _ words: Words) -> String {
        words.say(day, Date.FormatStyle(date: .abbreviated, time: .omitted))
    }
}

/// The working-life items for one printer, for a context menu or the machine
/// sheet's Status menu. What is offered follows the state: a printer in
/// service can go under service or be retired; one under service can come
/// back; a retired one can return. Delete is offered to all three and is
/// ENABLED only when the rule found nothing that names the printer —
/// otherwise it is greyed, and the line under it says what does.
struct MachineLifeItems: View {
    let machine: Machine
    let shop: Shop
    /// Called after an action that needs no question — the sheet closes.
    var acted: () -> Void = {}
    let ask: (MachineAsk.Kind) -> Void

    var body: some View {
        if machine.isRetired {
            Button(shop.words.callIt("mac.life_unretire")) {
                Task { await shop.returnToService(machine.id); acted() }
            }
        } else {
            if machine.isUnderService {
                Button(shop.words.callIt("mac.life_back_in_service")) {
                    Task { await shop.setUnderService(machine.id, on: false); acted() }
                }
            } else {
                Button(shop.words.callIt("mac.life_mark_service")) { ask(.underService) }
            }
            Button(shop.words.callIt("mac.life_retire")) { ask(.retire) }
        }
        Divider()
        let verdict = shop.machineDeleteVerdicts[machine.id]
        Button(shop.words.callIt("mac.life_delete"), role: .destructive) { ask(.delete) }
            .disabled(verdict?.ok != true)
        if let verdict, !verdict.ok {
            // A menu draws a Text as a line it cannot choose: the reason,
            // right under the item it explains.
            Text(shop.cannotDeleteSentence(verdict))
            if !machine.isRetired { Text(shop.words.callIt("mac.life_delete_blocked_hint")) }
        }
    }
}

/// The three questions, wherever they are asked from. The reason fields start
/// empty each time a question opens.
struct MachineLifeDialogs: ViewModifier {
    let shop: Shop
    @Binding var ask: MachineAsk?
    /// Called once an answer has been acted on — the sheet closes itself.
    var answered: () -> Void = {}
    @State private var reason = ""

    private func binding(_ kind: MachineAsk.Kind) -> Binding<Bool> {
        Binding(get: { ask?.kind == kind }, set: { if !$0 { ask = nil } })
    }

    func body(content: Content) -> some View {
        let words = shop.words
        content
            .alert(ask.map { words.callIt("mac.life_service_title", ["name": .string($0.name)]) } ?? "",
                   isPresented: binding(.underService), presenting: ask) { asked in
                TextField(words.callIt("mac.life_reason"), text: $reason)
                Button(words.callIt("mac.life_service_confirm")) {
                    let why = reason
                    ask = nil
                    Task { await shop.setUnderService(asked.machineId, on: true, reason: why); answered() }
                }
                Button(words.callIt("common.cancel"), role: .cancel) { ask = nil }
            } message: { _ in
                Text(words.callIt("mac.life_service_message"))
            }
            .alert(ask.map { words.callIt("mac.life_retire_title", ["name": .string($0.name)]) } ?? "",
                   isPresented: binding(.retire), presenting: ask) { asked in
                TextField(words.callIt("mac.life_reason"), text: $reason)
                Button(words.callIt("mac.life_retire_confirm"), role: .destructive) {
                    let why = reason
                    ask = nil
                    Task { await shop.retireMachine(asked.machineId, reason: why); answered() }
                }
                Button(words.callIt("common.cancel"), role: .cancel) { ask = nil }
            } message: { asked in
                Text(Self.retireMessage(asked, words))
            }
            .confirmationDialog(ask.map { words.callIt("mac.life_delete_title", ["name": .string($0.name)]) } ?? "",
                                isPresented: binding(.delete), titleVisibility: .visible,
                                presenting: ask) { asked in
                Button(words.callIt("common.delete"), role: .destructive) {
                    ask = nil
                    Task { await shop.deleteMachine(asked.machineId); answered() }
                }
                Button(words.callIt("common.cancel"), role: .cancel) { ask = nil }
            } message: { _ in
                Text(words.callIt("mac.life_delete_message"))
            }
            .onChange(of: ask?.id) { _, _ in reason = "" }
    }

    /// What retiring takes with it, said before the shop agrees: the jobs
    /// still waiting on this printer lose it.
    @MainActor static func retireMessage(_ asked: MachineAsk, _ words: Words) -> String {
        let jobs = asked.jobs > 0 ? words.counting(asked.jobs, "mac.life_retire_jobs")
                                  : words.callIt("mac.life_retire_none")
        return words.callIt("mac.life_retire_message") + "\n\n" + jobs
    }
}

extension View {
    func machineLifeDialogs(shop: Shop, ask: Binding<MachineAsk?>,
                            answered: @escaping () -> Void = {}) -> some View {
        modifier(MachineLifeDialogs(shop: shop, ask: ask, answered: answered))
    }
}

/// The printers the shop has retired, folded away under the floor.
///
/// Kept, because each is still the printer its past jobs, costs and service
/// belong to; folded, because none of them is part of today. Dimmed, and the
/// badge on each says "Retired" in words. Under each, the two things a shop
/// still does with one: return it to service, or delete it — offered only
/// when nothing in the book names it, and otherwise greyed with the reason.
struct RetiredMachines: View {
    let shop: Shop
    let columns: [GridItem]
    @State private var open = false

    var body: some View {
        let retired = shop.siteMachines.filter(\.isRetired)
        if !retired.isEmpty {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(shop.words.callIt("mac.life_retired_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(retired) { machine in
                            VStack(alignment: .leading, spacing: 8) {
                                MachineCard(machine: machine, wear: nil, shop: shop)
                                    .opacity(0.62)
                                RetiredActions(machine: machine, shop: shop)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(shop.words.callIt("mac.life_retired_list", ["n": .string(shop.words.numeral(retired.count))]))
                    .font(.headline)
            }
        }
    }
}

/// Return to service and Delete, under a retired printer's card.
struct RetiredActions: View {
    let machine: Machine
    let shop: Shop

    var body: some View {
        let verdict = shop.machineDeleteVerdicts[machine.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(shop.words.callIt("mac.life_unretire")) {
                    Task { await shop.returnToService(machine.id) }
                }
                Button(shop.words.callIt("mac.life_delete"), role: .destructive) {
                    Task { await shop.ask(.delete, about: machine) }
                }
                .disabled(verdict?.ok != true)
            }
            .controlSize(.small)
            .disabled(!shop.canMoveJobs)
            if let verdict, !verdict.ok {
                Text(shop.cannotDeleteSentence(verdict))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
