import SwiftUI

/// What a printer needs from a person, as the Mac works it out (#2612
/// problems, #2613 waiting at the machine; read by #2616). Drawn from the
/// signed-off frames (iPhone Figma "Printer states · iPhone (Nov 21)",
/// Turki, Nov 22): the problems worst first, each with what to do, and the
/// reasons the printer waits, most urgent first.
///
/// "Taken off" (a finished print) and "Bed is clear" (leftovers) tell the Mac
/// the plate is empty (`KhaytAPIClient.clearBed`). They show on a phone that
/// may control machines, in reach of its Mac; elsewhere the reason is shown
/// with no button. The problems' actions stay labels: they are done at the
/// printer, not sent by the phone.
struct PrinterNeedsPanel: View {
    let live: MachineLiveStatus

    /// Tells the Mac the plate is empty, and reads the printers again when it
    /// took. Nil where the buttons must not show (a viewer's phone, the Mac
    /// out of reach, the sample shop): the reason is then shown alone.
    var clearBed: (() async -> PrinterReply)? = nil
    @State private var clearing = false
    @State private var note: String?

    /// Which waiting reasons a tap can end, and the button's words.
    static func clearWords(_ reason: String) -> String? {
        switch reason {
        case "print-to-take-off": return L10n.tr("waiting.do.taken_off")
        case "bed-to-clear": return L10n.tr("waiting.do.bed_clear")
        default: return nil
        }
    }

    /// The button shows for a role that may control machines, on the shop's
    /// Wi-Fi with the Mac answering, and never on the sample shop.
    static func mayClear(canControl: Bool, macInReach: Bool, sampleShop: Bool) -> Bool {
        canControl && macInReach && !sampleShop
    }

    private func clear() async {
        guard !clearing else { return }
        clearing = true
        defer { clearing = false }
        guard let clearBed else { return }
        let reply = await clearBed()
        if reply.ok {
            note = nil
            CompanionHaptics.success()
        } else {
            note = reply.sentence
            CompanionHaptics.warning()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !live.problems.isEmpty {
                Text(L10n.format(live.problems.count == 1 ? "problems.count.one" : "problems.count.other",
                                 live.displayName, live.problems.count))
                    .font(.khayt(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(KhaytDesign.ink)
                ForEach(Array(live.problems.enumerated()), id: \.offset) { _, p in
                    row(dot: Self.tone(p.severity), title: Self.title(p), sub: Self.problemSub(p),
                        action: p.action.flatMap(Self.actionWords))
                }
            }
            if !live.waiting.isEmpty {
                if !live.problems.isEmpty { Divider().overlay(KhaytDesign.hairline) }
                Text(L10n.format("waiting.machine.title", live.displayName))
                    .font(.khayt(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(KhaytDesign.ink)
                ForEach(Array(live.waiting.enumerated()), id: \.offset) { _, w in
                    row(dot: w.reason == "bed-to-clear" || w.reason == "filament-runout" ? KhaytDesign.late : KhaytDesign.attention,
                        title: Self.reasonWords(w), sub: Self.since(w), action: nil,
                        tap: clearBed != nil ? Self.clearWords(w.reason) : nil)
                }
                if let note {
                    Text(note)
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.late)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    private func row(dot: Color, title: String, sub: String?, action: String?, tap: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.khayt(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub {
                    Text(sub)
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            // What to do, said on the printer: a label, not a command the
            // phone sends.
            if let tap {
                Button { Task { await clear() } } label: {
                    Group { if clearing { ProgressView() } else { Text(tap) } }
                        .font(.khayt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.ink)
                        .padding(.horizontal, 10).frame(minHeight: 32)
                        .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(clearing)
            }
            if let action {
                Text(action)
                    .font(.khayt(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .accessibilityElement(children: tap == nil ? .combine : .contain)
    }

    // ── Words (closed sets from the shared rules) ───────────────────────

    /// The rules' closed sets (`lib/printer-problems.js`, tested equal). A
    /// value from the wire is looked up only when it is one of these, so a
    /// hostile code can never pick some other key's words (review of #2657).
    static let codes: Set<String> = ["filament-runout", "nozzle-clog", "temperature", "door-open", "first-layer", "spaghetti",
                                     "bed-plate", "storage", "file-rejected", "power-lost", "paused-by-user", "print-cancelled",
                                     "printer-exception", "printer-attention", "printer-error"]
    static let actions: Set<String> = ["load-filament", "clear-nozzle", "check-heater", "close-door", "check-print", "check-plate",
                                       "check-storage", "reslice", "resend-file", "resume-on-printer", "check-printer", "none"]

    /// A head the printer named, shown 1-based; anything outside a real
    /// printer's heads is not shown (and never overflows).
    static func headLabel(_ words: String, _ head: Int?) -> String {
        guard let head, (0..<64).contains(head) else { return words }
        return L10n.format("problem.head", words, head + 1)
    }

    static func tone(_ severity: String) -> Color {
        switch severity {
        case "fatal", "serious": return KhaytDesign.late
        case "common": return KhaytDesign.attention
        default: return KhaytDesign.pending
        }
    }

    /// `problem.<code>`, "· head N" when the printer said which; an unknown
    /// code reads as a printer error, never as nothing.
    static func title(_ p: PrinterProblem) -> String {
        let words = L10n.tr("problem." + (codes.contains(p.code) ? p.code : "printer-error"))
        return headLabel(words, p.head)
    }

    /// Severity, then the printer's own message or the note a code carries.
    static func problemSub(_ p: PrinterProblem) -> String? {
        var parts = [L10n.tr("problem.severity." + (PrinterProblem.severities.contains(p.severity) ? p.severity : "info"))]
        if p.code == "power-lost" { parts.append(L10n.tr("problem.power-lost.note")) }
        else if let m = p.message, !m.isEmpty { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    static func actionWords(_ action: String) -> String? {
        guard action != "none", actions.contains(action) else { return nil }
        return L10n.tr("problem.action." + action)
    }

    static func reasonWords(_ w: WaitingReason) -> String {
        let words = L10n.tr("waiting.reason." + (WaitingReason.reasons.contains(w.reason) ? w.reason : "printer-attention"))
        return headLabel(words, w.head)
    }

    static func since(_ w: WaitingReason) -> String? {
        guard let at = w.sinceDate else { return nil }
        let style = Calendar.current.isDateInToday(at)
            ? Date.FormatStyle(date: .omitted, time: .shortened) : Date.FormatStyle(date: .abbreviated, time: .shortened)
        return L10n.format("waiting.since", at.formatted(style.locale(L10n.locale)))
    }
}
