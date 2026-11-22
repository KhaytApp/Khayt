import SwiftUI

/// Pause / Resume and Stop under a running machine's card. Stop asks first:
/// a stopped print cannot be resumed. What the Mac answers is said here —
/// done, or why not.
struct PrinterControls: View {
    let machine: MachineLiveStatus

    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var health: ConnectionHealth
    @EnvironmentObject private var printers: LivePrinters
    @State private var working: PrinterVerb?
    @State private var confirmStop = false
    @State private var note: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if machine.isPaused {
                    button(.resume, L10n.tr("printer.resume"), "play.fill", KhaytDesign.done)
                } else {
                    button(.pause, L10n.tr("printer.pause"), "pause.fill", KhaytDesign.attention)
                }
                button(.stop, L10n.tr("printer.stop"), "stop.fill", KhaytDesign.late)
            }
            if let note {
                Text(note)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(failed ? KhaytDesign.late : KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(L10n.format("printer.stop.confirm", machine.displayName), isPresented: $confirmStop,
                            titleVisibility: .visible) {
            Button(L10n.tr("printer.stop"), role: .destructive) { Task { await send(.stop) } }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("printer.stop.message"))
        }
    }

    private func button(_ verb: PrinterVerb, _ title: String, _ icon: String, _ tint: Color) -> some View {
        Button {
            if verb == .stop { confirmStop = true } else { Task { await send(verb) } }
        } label: {
            Group {
                if working == verb { ProgressView() } else { Label(title, systemImage: icon) }
            }
            .font(.khayt(14, .semibold, relativeTo: .subheadline))
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(working != nil)
    }

    private func send(_ verb: PrinterVerb) async {
        working = verb
        note = L10n.tr(health.macInReach ? "printer.sending" : "printer.sending.cloud")
        failed = false
        let reply = await api.printer(verb, machineId: machine.id, macInReach: health.macInReach)
        working = nil
        failed = !reply.ok
        note = reply.ok ? L10n.tr("printer.done." + verb.rawValue) : reply.sentence
        if reply.ok {
            CompanionHaptics.success()
            await printers.refresh()
        } else {
            CompanionHaptics.warning()
        }
    }
}
