import SwiftUI

/// One spool, as `design/ios-v2/` draws it: a PAGE — the colour and what it
/// is, how much is left with a ±50 g nudge beneath it, the label's facts, and
/// writing it to an NFC tag.
struct SpoolDetailPage: View {
    let spool: InventorySpool
    var onChanged: () async -> Void = {}

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var remaining: Int
    @State private var showWriteNFC = false
    @State private var showAdjust = false
    @State private var adjustText = ""
    @State private var showDeleteConfirm = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// The pending nudge. Tapping +50 three times is ONE write of +150, made
    /// once the taps stop — not three changes queued for the Mac.
    @State private var writeTask: Task<Void, Never>?
    /// What the book holds now, so leaving the page writes only what is new.
    @State private var written: Int

    init(spool: InventorySpool, onChanged: @escaping () async -> Void = {}) {
        self.spool = spool
        self.onChanged = onChanged
        let grams = Int((spool.remainingGrams ?? 0).rounded())
        _remaining = State(initialValue: grams)
        _written = State(initialValue: grams)
    }

    private var low: Bool { remaining > 0 && remaining <= 200 }
    private var tone: Color { low ? KhaytDesign.attention : KhaytDesign.note }
    private var fraction: Double? {
        guard let full = spool.initialWeight, full > 0 else { return nil }
        return min(1, max(0, Double(remaining) / full))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                level
                facts
                nfc
                if let errorMessage {
                    Text(errorMessage)
                        .font(.khayt(12.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.late)
                }
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Text(L10n.tr("spool.detail.remove"))
                        .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.late)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .padding(.top, 8)
            }
            .padding(16)
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle([spool.brand, spool.material].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWriteNFC) {
            WriteNFCTagSheet(draft: SpoolDraft.from(spool: spool))
        }
        .alert(L10n.tr("spool.detail.adjust"), isPresented: $showAdjust) {
            TextField(L10n.tr("spool.detail.grams"), text: $adjustText)
                .keyboardType(.numberPad)
            Button(L10n.tr("common.save")) {
                if let g = Int(adjustText.trimmingCharacters(in: .whitespaces)) {
                    set(g)
                } else {
                    errorMessage = L10n.tr("spool.detail.grams_error")
                }
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("spool.detail.adjust.body"))
        }
        .alert(L10n.tr("spool.detail.remove_q"), isPresented: $showDeleteConfirm) {
            Button(L10n.tr("common.remove"), role: .destructive) { Task { await removeSpool() } }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L10n.tr("inventory.remove.body"), spool.displayLabel))
        }
        .onDisappear { writeTask?.cancel(); flushIfPending() }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 15) {
            SpoolSwatch(hex: spool.colorHex, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(spool.displayLabel)
                    .font(.khayt(21, .semibold, relativeTo: .title2))
                    .foregroundStyle(KhaytDesign.ink)
                Text(spool.id)
                    .font(.khayt(13.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .card()
    }

    private var level: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tapping the figure sets it exactly — the nudges are for the
            // common case, not the only way.
            Button {
                adjustText = "\(remaining)"
                showAdjust = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(remaining.formatted())
                        .font(.khayt(34, .semibold, relativeTo: .largeTitle).monospacedDigit())
                        .foregroundStyle(low ? KhaytDesign.attention : KhaytDesign.ink)
                    Text(L10n.tr("spool.detail.g_remaining"))
                        .font(.khayt(15, .medium, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.note)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.tr("spool.detail.adjust"))
            if let fraction {
                LevelBar(fraction: fraction, color: tone, height: 7).padding(.top, 12)
            }
            HStack(spacing: 9) {
                nudge(-50)
                nudge(50)
            }
            .padding(.top, 14)
            if low {
                Text(L10n.tr("spool.detail.low_warn"))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.attention)
                    .padding(.top, 13)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func nudge(_ grams: Int) -> some View {
        Button { set(remaining + grams) } label: {
            Text(grams < 0 ? "−\(-grams) g" : "+\(grams) g")
                .font(.khayt(15, .semibold, relativeTo: .body))
                .foregroundStyle(KhaytDesign.ink)
                .frame(maxWidth: .infinity, minHeight: 46)
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private var facts: some View {
        let rows: [(String, String)] = [
            (L10n.tr("spool.form.sku"), spool.sku ?? ""),
            (L10n.tr("spool.detail.lot"), spool.lot ?? ""),
            (L10n.tr("spool.detail.print_temp"), spool.printTemp.map { "\($0) °C" } ?? ""),
            (L10n.tr("spool.detail.bed_temp"), spool.bedTemp.map { "\($0) °C" } ?? ""),
        ].filter { !$0.1.isEmpty }
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 12) {
                        Text(row.0)
                            .font(.khayt(14, relativeTo: .subheadline))
                            .foregroundStyle(KhaytDesign.note)
                        Spacer(minLength: 12)
                        Text(row.1)
                            .font(.khayt(14.5, .medium, relativeTo: .subheadline).monospacedDigit())
                            .foregroundStyle(KhaytDesign.ink)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .overlay(alignment: .bottom) {
                        if i < rows.count - 1 { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                    }
                }
            }
            .card()
        }
    }

    private var nfc: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { showWriteNFC = true } label: {
                Label(L10n.tr("nfc.write.title"), systemImage: "wave.3.right")
                    .font(.khayt(15.5, .semibold, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.brand)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(KhaytDesign.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.brand, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text(L10n.tr("nfc.write.footer"))
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .padding(.horizontal, 2)
        }
    }

    // MARK: - Writing

    private func set(_ grams: Int) {
        let upper = spool.initialWeight.map { Int($0.rounded()) } ?? Int.max
        remaining = max(0, min(upper, grams))
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await write()
        }
    }

    /// Leaving the page with a nudge not yet written still writes it.
    private func flushIfPending() {
        let target = remaining
        guard target != written else { return }
        Task { await write(target) }
    }

    private func write(_ grams: Int? = nil) async {
        let target = grams ?? remaining
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await api.updateSpoolRemaining(id: spool.id, grams: target)
            written = target
            CompanionHaptics.success()
            await onChanged()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    private func removeSpool() async {
        writeTask?.cancel()
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await api.deleteSpool(id: spool.id)
            CompanionHaptics.success()
            await onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}

/// A spool's colour as a disc, ringed so a black roll on a dark card — or a
/// white one on a light card — is not a hole in the row.
struct SpoolSwatch: View {
    let hex: String?
    var size: CGFloat = 34

    var body: some View {
        Circle()
            .fill(hex.flatMap { Color(hex: $0) } ?? KhaytDesign.sunk)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A thin rounded level, filled from the leading edge — so it reads the right
/// way round in Arabic too.
struct LevelBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(KhaytDesign.hairline)
                Capsule().fill(color).frame(width: max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}

extension View {
    /// The design's card: surface, hairline, 14pt corners.
    func card(radius: CGFloat = 14) -> some View {
        background(KhaytDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }
}
