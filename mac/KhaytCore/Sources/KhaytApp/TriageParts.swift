import SwiftUI

/// The five machines, as tiles — the lower-left of Triage.
///
/// A tile per machine, sized so five fit a 13-inch window without scrolling.
/// What each says depends on what Khayt can actually ask it: a percentage and
/// a time remaining where a protocol exists, and a plain sentence where one
/// does not. "Khayt cannot ask this machine" is a fact about the machine, not
/// a failure, and it is said rather than left as an empty tile.
struct OnTheMachines: View {
    @Bindable var shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHead(title: shop.words.callIt("mac.on_the_machines"))
            HStack(spacing: 8) {
                ForEach(shop.machines.prefix(5)) { machine in
                    MachineTile(machine: machine, shop: shop)
                }
                if shop.machines.isEmpty {
                    Text(shop.words.callIt("mac.no_machines_yet"))
                        .font(TypeScale.body(11))
                        .foregroundStyle(Role.text3)
                }
            }
        }
    }
}

struct MachineTile: View {
    let machine: Machine
    @Bindable var shop: Shop

    private var reading: (percent: Double?, state: ShopState, line: String) {
        shop.tileReading(for: machine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let percent = reading.percent {
                Figure(value: percent, style: .signedPercent, size: 15, weight: .bold,
                       tint: Role.text)
            } else {
                Text(reading.state.glyph)
                    .font(TypeScale.label(12))
                    .foregroundStyle(reading.state.tint)
            }
            Text(machine.name)
                .font(TypeScale.row(10.5, weight: .semibold))
                .foregroundStyle(Role.text)
                .lineLimit(1)
            Text(reading.line)
                .font(TypeScale.body(9.5))
                .foregroundStyle(Role.text2)
                .lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .background(ground, in: RoundedRectangle(cornerRadius: Radius.control,
                                                 style: .continuous))
    }

    private var ground: Color {
        switch reading.state {
        case .running:  Role.surf3
        case .dueToday: Role.warnBg
        default:        Role.surf2
        }
    }
}

/// What is on the shelf, and what is about to stop a job.
struct TheShelf: View {
    @Bindable var shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHead(title: shop.words.callIt("mac.the_shelf"))
            VStack(spacing: 0) {
                ForEach(shop.spools.prefix(4)) { spool in
                    HStack(spacing: Space.md) {
                        // Material and the shop's own colour word — two
                        // `Text`s would be two runs on one line, so this is
                        // the one place a name is composed, and it is composed
                        // from the record rather than from a figure.
                        Text(shop.spoolName(spool))
                            .font(TypeScale.body(11))
                            .foregroundStyle(Role.text)
                            .lineLimit(1)
                        Spacer(minLength: Space.sm)
                        if (spool.weight ?? 0) <= 0 {
                            CapsLabel(shop.words.callIt("mac.out"), tint: Role.late, size: 9.5)
                        } else {
                            Figure(value: spool.weight, style: .unit("g"), size: 10.5,
                                   tint: shop.lowSpools[spool.id] != nil ? Role.warn : Role.text2)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            // The sentence §5 asks for: which figures on this screen are not
            // known, and what that means for the margin.
            if let note = shop.materialCostGapNote {
                Text(note)
                    .font(TypeScale.body(10.5))
                    .foregroundStyle(Role.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// §6's section: a bold heading, an 18×2.5 accent tick, and a hairline to the
/// edge. The only grouping device on a content surface — no boxes in boxes.
struct SectionHead: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                // The tick is `acc`: a graphic mark, carrying no text.
                Rectangle().fill(Role.acc).frame(width: 18, height: 2.5)
                Text(title)
                    .font(TypeScale.title(13, weight: .semibold))
                    .foregroundStyle(Role.text)
            }
            Rectangle().fill(Role.line).frame(height: 1)
        }
    }
}

/// The empty state — §6's four parts: what the thing is for, why it matters,
/// one obvious next step, one escape hatch.
///
/// A shop that has just installed sees this, and it is the only screen in the
/// app whose job is to be replaced.
struct FirstRun: View {
    @Bindable var shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("K")
                .font(TypeScale.display(22, weight: .bold))
                .foregroundStyle(Role.onNavy)
                .frame(width: 54, height: 54)
                .background(Role.navy, in: RoundedRectangle(cornerRadius: Radius.card,
                                                            style: .continuous))
            Text(shop.words.callIt("mac.first_run_title"))
                .font(TypeScale.title(21, weight: .bold))
                .foregroundStyle(Role.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(shop.words.callIt("mac.first_run_why"))
                .font(TypeScale.body(13))
                .lineSpacing(TypeScale.bodyLeading(13))
                .foregroundStyle(Role.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)

            HStack(alignment: .top, spacing: 10) {
                step("mac.first", "mac.add_a_machine", "mac.add_a_machine_why")
                step("mac.then", "mac.put_a_spool", "mac.put_a_spool_why")
                step("mac.then", "mac.take_a_job", "mac.take_a_job_why")
            }
            .frame(maxWidth: 720)

            // The escape hatch: a shop that wants to see the app working
            // before typing anything of its own.
            Button {
                Task { await shop.load(.sample) }
            } label: {
                Text(shop.words.callIt("mac.open_the_sample"))
                    .font(TypeScale.body(11.5))
                    .foregroundStyle(Role.accInk)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func step(_ whenKey: String, _ titleKey: String, _ whyKey: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            CapsLabel(shop.words.callIt(whenKey), tint: Role.acc, size: 9)
            Text(shop.words.callIt(titleKey))
                .font(TypeScale.title(12, weight: .semibold))
                .foregroundStyle(Role.text)
            Text(shop.words.callIt(whyKey))
                .font(TypeScale.body(11))
                .foregroundStyle(Role.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: 13)
    }
}
