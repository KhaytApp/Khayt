import SwiftUI
import KhaytCore

/// What to run next, above the machines it would run on.
///
/// The question every print farm asks all day and Khayt could not answer: it
/// knew the queue and it knew which printers were idle, and putting the two
/// together was a person doing it in their head. With three machines that is
/// fine. With twelve it is where the idle hours come from.
///
/// ── IT PROPOSES ───────────────────────────────────────────────────────────
///
/// No printer Khayt talks to can clear its own plate, so "idle" very often
/// means idle with yesterday's part still bolted to the bed. `Send` is a person
/// agreeing, and a machine nobody has marked clear is shown as WAITING rather
/// than quietly dropped — a dispatcher that silently stops offering a printer
/// is one nobody trusts.
struct NextUp: View {
    @Bindable var shop: Shop

    private var plan: KhaytEngine.DispatchPlan? { shop.dispatch }

    var body: some View {
        if let plan, !plan.proposals.isEmpty || !plan.waiting.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(shop.words.callIt("mac.dispatch_title"))
                    .font(.headline)

                ForEach(plan.proposals) { proposal in
                    row(proposal)
                }

                // Why a machine is not being offered work. The bed line is the
                // one this panel exists to show.
                ForEach(plan.waiting) { blocked in
                    if let machine = shop.machines.first(where: { $0.id == blocked.machineId }) {
                        HStack(spacing: 8) {
                            Text(machine.name).foregroundStyle(.secondary)
                            Text(shop.words.callIt(blocked.blocked))
                                .font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            // The one thing a printer cannot tell us, so a
                            // person says it — and only where it is the answer.
                            if blocked.blocked.hasPrefix("ad.bed") {
                                Button(shop.words.callIt("mac.bed_cleared")) {
                                    Task { await shop.markBedClear(machine) }
                                }
                                .buttonStyle(.link)
                                .disabled(!shop.canMoveJobs)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(rail: Khayt.brand, padding: 14)
        }
    }

    @ViewBuilder private func row(_ proposal: KhaytEngine.DispatchProposal) -> some View {
        let order = shop.orders.first { $0.id == proposal.orderId }
        let machine = shop.machines.first { $0.id == proposal.machineId }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(order?.project ?? proposal.orderId).fontWeight(.medium)
                    // `arrow.forward`, not `arrow.right`: in an Arabic window
                    // the queue runs the other way and a pinned arrow points
                    // back at where the job came from. Held by
                    // `ColourStudioTests`, which caught this one.
                    Image(systemName: "arrow.forward").font(.caption2).foregroundStyle(.tertiary)
                    Text(machine?.name ?? proposal.machineId)
                }
                Text(shop.words.callIt(proposal.reason))
                    .font(.caption).foregroundStyle(.secondary)
                // Said before somebody presses Send, not after.
                ForEach(proposal.caveats, id: \.self) { caveat in
                    Label(shop.words.callIt(caveat), systemImage: "exclamationmark.triangle")
                        // The app's own amber, not the system's: `PaletteTests`
                        // refuses a raw system colour because it does not move
                        // with the theme or survive Increase Contrast.
                        .font(.caption2).foregroundStyle(Khayt.attention)
                }
            }
            Spacer()
            Button(shop.words.callIt("mac.dispatch_send")) {
                Task { await shop.accept(proposal) }
            }
            .disabled(!shop.canMoveJobs)
        }
    }
}
