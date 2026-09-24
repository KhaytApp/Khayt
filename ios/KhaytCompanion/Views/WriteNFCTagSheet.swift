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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.tr("nfc.write.intro"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text(L10n.tr("nfc.write.standard"))) {
                    ForEach(NFCFilamentStandard.allCases) { standard in
                        Button {
                            selectedStandard = standard
                            encodeError = nil
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(standard.label)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(standard.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                if selectedStandard == standard {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(header: Text(L10n.tr("nfc.write.preview"))) {
                    LabeledContent(L10n.tr("nfc.write.material"), value: draft.material.isEmpty ? "—" : draft.material)
                    if !draft.brand.isEmpty {
                        LabeledContent(L10n.tr("nfc.write.brand"), value: draft.brand)
                    }
                    LabeledContent(L10n.tr("nfc.write.weight"), value: "\(draft.weightGrams) g")
                    if !draft.printTemp.isEmpty {
                        LabeledContent(L10n.tr("nfc.write.print_temp"), value: "\(draft.printTemp)°C")
                    }
                    if !draft.bedTemp.isEmpty {
                        LabeledContent(L10n.tr("nfc.write.bed_temp"), value: "\(draft.bedTemp)°C")
                    }
                }

                if let encodeError {
                    Section {
                        Text(encodeError)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }

                if nfc.writeSucceeded {
                    Section {
                        Label(L10n.tr("nfc.write.success"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else if let err = nfc.lastError, hasStartedWrite {
                    Section {
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    if !nfc.isAvailable {
                        Text(L10n.tr("nfc.unavailable"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        startWrite()
                    } label: {
                        Label(
                            nfc.isWriting ? L10n.tr("nfc.write.scanning") : L10n.tr("nfc.write.tap_blank"),
                            systemImage: "wave.3.right"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!nfc.isAvailable || nfc.isWriting || draft.material.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text(L10n.tr("nfc.write.footer"))
                        .font(.caption)
                }
            }
            .khaytForm()
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
