import SwiftUI

/// Pick NFC standard (printer-dependent) and write spool data to a blank tag.
struct WriteNFCTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var nfc: NFCReader

    let draft: SpoolDraft
    var suggestedStandard: NFCFilamentStandard?

    @State private var selectedStandard: NFCFilamentStandard = .openTag3D
    @State private var encodeError: String?
    @State private var hasStartedWrite = false

    private var canWrite: Bool {
        nfc.isAvailable && !nfc.isWriting && !draft.material.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tagMark
                    V2Note(text: L10n.tr("nfc.write.intro"))
                    eyebrow(L10n.tr("nfc.write.standard"))
                    VStack(spacing: 0) {
                        ForEach(Array(NFCFilamentStandard.allCases.enumerated()), id: \.element.id) { i, standard in
                            standardRow(standard, last: i == NFCFilamentStandard.allCases.count - 1)
                        }
                    }
                    .card()
                    eyebrow(L10n.tr("nfc.write.preview"))
                    VStack(spacing: 0) {
                        previewRow(L10n.tr("nfc.write.material"), draft.material.isEmpty ? "—" : draft.material)
                        if !draft.brand.isEmpty { previewRow(L10n.tr("nfc.write.brand"), draft.brand) }
                        previewRow(L10n.tr("nfc.write.weight"), "\(draft.weightGrams) g")
                        if !draft.printTemp.isEmpty { previewRow(L10n.tr("nfc.write.print_temp"), "\(draft.printTemp) °C") }
                        if !draft.bedTemp.isEmpty { previewRow(L10n.tr("nfc.write.bed_temp"), "\(draft.bedTemp) °C") }
                    }
                    .card()
                    status
                    V2PrimaryButton(title: L10n.tr(nfc.isWriting ? "nfc.write.scanning" : "nfc.write.tap_blank"),
                                    busy: nfc.isWriting, disabled: !canWrite) {
                        startWrite()
                    }
                    .padding(.top, 4)
                    V2Note(text: L10n.tr("nfc.write.footer"))
                }
                .padding(16)
            }
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("nfc.write.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("nfc.write.done")) {
                        nfc.clearWriteState()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let suggested = suggestedStandard {
                    selectedStandard = suggested
                } else if draft.sourceNote.contains("OpenPrintTag") {
                    selectedStandard = .openPrintTag
                } else if draft.sourceNote.contains("OpenTag3D") {
                    selectedStandard = .openTag3D
                } else if draft.sourceNote.contains("OpenSpool") {
                    selectedStandard = .openSpool
                }
            }
            .onDisappear { nfc.invalidate() }
        }
    }

    /// The design's NFC mark: the waves in a brand-blue disc, ringed while the
    /// phone is listening for a tag.
    private var tagMark: some View {
        ZStack {
            Circle().fill(KhaytDesign.brand.opacity(0.12))
            if nfc.isWriting {
                Circle().strokeBorder(KhaytDesign.brand, lineWidth: 2)
                    .phaseAnimator([false, true]) { ring, on in
                        ring.scaleEffect(on ? 1.35 : 1).opacity(on ? 0 : 1)
                    } animation: { _ in .easeOut(duration: 1.9) }
            }
            Image(systemName: nfc.writeSucceeded ? "checkmark" : "wave.3.right")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(nfc.writeSucceeded ? KhaytDesign.done : KhaytDesign.brand)
        }
        .frame(width: 92, height: 92)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityHidden(true)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .tracking(1.05)
            .foregroundStyle(KhaytDesign.note)
            .padding(.horizontal, 2)
            .padding(.top, 8)
    }

    /// Which format to write — a real choice, because which one a printer reads
    /// depends on its firmware. Each says who reads it.
    private func standardRow(_ standard: NFCFilamentStandard, last: Bool) -> some View {
        let on = selectedStandard == standard
        return Button {
            selectedStandard = standard
            encodeError = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(on ? KhaytDesign.brand : KhaytDesign.note)
                VStack(alignment: .leading, spacing: 3) {
                    Text(standard.label)
                        .font(.khayt(15, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                    Text(standard.subtitle)
                        .font(.khayt(12.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func previewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.khayt(14, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
            Spacer()
            Text(value)
                .font(.khayt(14.5, .medium, relativeTo: .subheadline).monospacedDigit())
                .foregroundStyle(KhaytDesign.ink)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    @ViewBuilder
    private var status: some View {
        if !nfc.isAvailable {
            V2Note(text: L10n.tr("nfc.unavailable"), tone: KhaytDesign.attention)
        } else if let encodeError {
            V2Note(text: encodeError, tone: KhaytDesign.late)
        } else if nfc.writeSucceeded {
            V2Note(text: L10n.tr("nfc.write.success"), tone: KhaytDesign.done)
        } else if let err = nfc.lastError, hasStartedWrite {
            V2Note(text: err, tone: KhaytDesign.late)
        }
    }

    private func startWrite() {
        encodeError = nil
        hasStartedWrite = true
        do {
            let message = try NFCEncoder.encode(draft: draft, standard: selectedStandard)
            nfc.beginWrite(message: message)
        } catch {
            encodeError = error.localizedDescription
        }
    }
}
