import SwiftUI
import KhaytCore

/// A row on one of the job page's cards: an icon, what it does, a line
/// under it, and a chevron — the invoice card's shape.
struct PaperRow: View {
    let title: String
    let detail: String
    let icon: String
    var tone: Color = KhaytDesign.brandV2

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tone).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(detail)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").flipsForRightToLeftLayoutDirection(true)
                .font(.caption).foregroundStyle(KhaytDesign.note)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// The small caps over a card, as the WhatsApp card heads itself.
private struct CardHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .khaytTracking(1.05)
            .foregroundStyle(KhaytDesign.note)
    }
}

/// A job's packing slip, delivery note and work order (`ShopPapers.swift`).
/// Showing one writes nothing.
struct JobPapersCard: View {
    let onOpen: (KhaytEngine.ShopPaper) -> Void

    static func detailKey(_ kind: KhaytEngine.ShopPaper) -> String {
        switch kind {
        case .packingSlip: return "paper.packing_slip.sub"
        case .deliveryNote: return "paper.delivery_note.sub"
        case .workOrder: return "paper.work_order.sub"
        }
    }

    static func icon(_ kind: KhaytEngine.ShopPaper) -> String {
        switch kind {
        case .packingSlip: return "shippingbox"
        case .deliveryNote: return "signature"
        case .workOrder: return "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(text: L10n.tr("paper.section"))
            VStack(spacing: 0) {
                ForEach(Array(KhaytEngine.ShopPaper.allCases.enumerated()), id: \.element) { i, kind in
                    Button { onOpen(kind) } label: {
                        PaperRow(title: L10n.tr(PaperSubject.titleKey(kind)),
                                 detail: L10n.tr(Self.detailKey(kind)), icon: Self.icon(kind))
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if i < KhaytEngine.ShopPaper.allCases.count - 1 {
                            Rectangle().fill(KhaytDesign.hairline).frame(height: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .card()
        }
    }
}

/// A quote's Revise, Follow up and history (`QuoteTools.swift`).
struct QuoteToolsCard: View {
    let state: KhaytAPIClient.QuoteState
    let followingUp: Bool
    let onRevise: () -> Void
    let onFollowUp: () -> Void
    let onHistory: () -> Void

    private var followUpDetail: String {
        guard state.followUpCount > 0 else { return L10n.tr("quote.followup.none") }
        var line = L10n.format("quote.followup.count", state.followUpCount)
        if let day = DueDateParser.display(state.followUpSentAt) {
            line += " · " + L10n.format("quote.followup.last", day)
        }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(text: L10n.tr("quote.tools"))
            VStack(spacing: 0) {
                Button(action: onRevise) {
                    PaperRow(title: L10n.tr("quote.revise"),
                             detail: L10n.format("quote.revise.sub", state.version),
                             icon: "pencil.and.list.clipboard")
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                Button(action: onFollowUp) {
                    PaperRow(title: L10n.tr("quote.followup"), detail: followUpDetail,
                             icon: "message.fill", tone: KhaytDesign.done)
                        .opacity(followingUp ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(followingUp)
                if !state.revisions.isEmpty {
                    Rectangle().fill(KhaytDesign.hairline).frame(height: 1)
                    Button(action: onHistory) {
                        PaperRow(title: L10n.tr("quote.history"),
                                 detail: L10n.format("quote.history.sub", state.revisions.count),
                                 icon: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .card()
        }
    }
}

/// Revise a quote: a new price and notes. Saving keeps the quote as it is
/// now in its history and moves it on a version, in one write.
struct ReviseQuoteSheet: View {
    let orderId: String
    let start: KhaytAPIClient.QuoteState
    var currency: String?
    var onSaved: () async -> Void = {}

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var price = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(currency.map { L10n.format("order.new.price_in", Money.mark($0)) } ?? L10n.tr("order.new.price"),
                              text: $price)
                        .keyboardType(.decimalPad)
                        .font(.khayt(16, relativeTo: .body).monospacedDigit())
                } header: {
                    Text(L10n.tr("quote.revise.price"))
                }
                Section {
                    TextField(L10n.tr("quote.revise.notes"), text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text(L10n.tr("quote.revise.notes"))
                } footer: {
                    Text(problem ?? L10n.format("quote.revise.note", start.version, start.version + 1))
                        .foregroundStyle(problem == nil ? KhaytDesign.note : KhaytDesign.late)
                }
            }
            .navigationTitle(L10n.tr("quote.revise"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.save")) { Task { await save() } }.disabled(saving)
                }
            }
            .onAppear {
                price = Money.figure(start.price)
                notes = start.notes
            }
        }
    }

    private func save() async {
        let fields = KhaytAPIClient.revisionFields(start: start, price: SpoolDraft.price(price), notes: notes)
        guard !fields.isEmpty else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            try await api.reviseQuote(orderId: orderId, fields: fields)
            CompanionHaptics.success()
            await onSaved()
            dismiss()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}

/// A quote's kept versions, newest first — the desktop's "Quote history":
/// version, day, price, parts and notes.
struct QuoteHistorySheet: View {
    let state: KhaytAPIClient.QuoteState
    var currency: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(version: state.version, day: nil, price: state.price, parts: nil, notes: state.notes,
                        current: true)
                }
                Section {
                    if state.revisions.isEmpty {
                        Text(L10n.tr("quote.history.empty"))
                            .font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                    }
                    ForEach(state.revisions) { r in
                        row(version: r.version, day: DueDateParser.display(r.snapshotAt), price: r.price,
                            parts: r.partCount, notes: r.notes, current: false)
                    }
                }
            }
            .navigationTitle(L10n.tr("quote.history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("common.done")) { dismiss() } }
            }
        }
    }

    private func row(version: Int, day: String?, price: Double, parts: Int?, notes: String,
                     current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.format("quote.history.version", version))
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                if current {
                    Text(L10n.tr("quote.history.current"))
                        .font(.khayt(11, .semibold, relativeTo: .caption2))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .foregroundStyle(KhaytDesign.done)
                        .background(KhaytDesign.done.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text(Money.text(price, currency))
                    .font(.khayt(13.5, .medium, relativeTo: .subheadline).monospacedDigit())
                    .foregroundStyle(KhaytDesign.ink)
            }
            let facts = [day, parts.map { L10n.format("quote.history.parts", $0) }].compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.khayt(12, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(KhaytDesign.note)
            }
            if !notes.isEmpty {
                Text(notes)
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 2)
    }
}
