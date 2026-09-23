import SwiftUI

/// Presented from Inventory — pick how to add, then review optional fields.
struct AddSpoolSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var nfc: NFCReader

    enum Step {
        case chooseMethod
        case barcode
        case scanLabel
        case nfc
        case review
    }

    @State private var step: Step = .chooseMethod
    @State private var draft = SpoolDraft()
    @State private var showCamera = false
    @State private var scannedRaw: String?
    @State private var isUploading = false
    @State private var errorMessage: String?
    @State private var showWriteNFC = false
    @State private var nfcWriteStandard: NFCFilamentStandard?
    @State private var showBarcodeScanner = false
    @State private var lookingUp = false

    var onAdded: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .chooseMethod:
                    chooseMethodView
                case .barcode:
                    barcodeView
                case .scanLabel:
                    scanLabelView
                case .nfc:
                    nfcView
                case .review:
                    SpoolReviewForm(
                        draft: $draft,
                        isUploading: isUploading,
                        errorMessage: errorMessage,
                        onWriteNFC: {
                            if draft.sourceNote.contains("OpenPrintTag") {
                                nfcWriteStandard = .openPrintTag
                            } else if draft.sourceNote.contains("OpenTag3D") {
                                nfcWriteStandard = .openTag3D
                            } else if draft.sourceNote.contains("OpenSpool") {
                                nfcWriteStandard = .openSpool
                            } else {
                                nfcWriteStandard = nil
                            }
                            showWriteNFC = true
                        }
                    ) {
                        Task { await submit() }
                    }
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
                if step != .chooseMethod && step != .review {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L10n.tr("pair.back")) { goBack() }
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                if BarcodeScannerView.isSupported() {
                    BarcodeScannerView(scannedText: $scannedRaw)
                } else {
                    Text(L10n.tr("spool.add.no_camera"))
                        .padding()
                }
            }
            .onChange(of: scannedRaw) { _, value in
                guard let value else { return }
                draft = SpoolDraft.from(parsed: FilamentLabelParser.parse(text: value))
                step = .review
            }
            .sheet(isPresented: $showBarcodeScanner) {
                ProductBarcodeScanner { code in
                    Task { await lookUp(code) }
                }
            }
            .onDisappear { nfc.invalidate() }
            .sheet(isPresented: $showWriteNFC) {
                WriteNFCTagSheet(draft: draft, suggestedStandard: nfcWriteStandard)
            }
        }
    }

    private var navTitle: String {
        switch step {
        case .chooseMethod: return L10n.tr("spool.add.title")
        case .barcode: return L10n.tr("spool.add.barcode_title")
        case .scanLabel: return L10n.tr("scan.title")
        case .nfc: return L10n.tr("spool.add.nfc_title")
        case .review: return L10n.tr("spool.add.confirm")
        }
    }

    private var chooseMethodView: some View {
        List {
            Section {
                Text(L10n.tr("spool.add.how"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                methodRow(
                    title: L10n.tr("spool.method.barcode"),
                    subtitle: L10n.tr("spool.method.barcode.sub"),
                    icon: "barcode"
                ) {
                    step = .barcode
                    showBarcodeScanner = true
                }
                methodRow(
                    title: L10n.tr("scan.title"),
                    subtitle: L10n.tr("spool.method.label.sub"),
                    icon: "barcode.viewfinder"
                ) {
                    step = .scanLabel
                }
                methodRow(
                    title: L10n.tr("spool.method.nfc"),
                    subtitle: L10n.tr("spool.method.nfc.sub"),
                    icon: "wave.3.right"
                ) {
                    step = .nfc
                }
                methodRow(
                    title: L10n.tr("spool.method.manual"),
                    subtitle: L10n.tr("spool.method.manual.sub"),
                    icon: "keyboard"
                ) {
                    draft = SpoolDraft()
                    draft.sourceNote = L10n.tr("spool.source.manual")
                    step = .review
                }
            }
        }
    }

    private func methodRow(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    private var barcodeView: some View {
        VStack(spacing: 20) {
            Spacer()
            if lookingUp {
                ProgressView()
                    .controlSize(.large)
                Text(L10n.tr("spool.lookup.busy"))
                    .font(.title3.bold())
                Text(L10n.tr("spool.lookup.busy.sub"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "barcode")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                Text(L10n.tr("spool.lookup.title"))
                    .font(.title3.bold())
                Text(L10n.tr("spool.lookup.body"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    showBarcodeScanner = true
                } label: {
                    Label(L10n.tr("spool.lookup.open"), systemImage: "barcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            }
            Spacer()
        }
    }

    private func lookUp(_ code: String) async {
        lookingUp = true
        defer { lookingUp = false }
        let shelf = (try? await api.fetchInventory()) ?? []
        let found = await BarcodeLookup().lookUp(code, shelf: shelf)
        draft = found.draft
        step = .review
    }

    private var scanLabelView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text(L10n.tr("spool.label.title"))
                .font(.title3.bold())
            Text(L10n.tr("spool.label.body"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                showCamera = true
            } label: {
                Label(L10n.tr("spool.label.open"), systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            Spacer()
        }
    }

    private var nfcView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "nfc")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text(L10n.tr("spool.nfc.title"))
                .font(.title3.bold())
            if !nfc.isAvailable {
                Text(L10n.tr("spool.nfc.unavailable"))
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Button {
                nfc.beginScan()
            } label: {
                Label(nfc.isScanning ? L10n.tr("spool.nfc.scanning") : L10n.tr("spool.nfc.scan"), systemImage: "wave.3.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!nfc.isAvailable || nfc.isScanning)
            .padding(.horizontal)

            if let tag = nfc.lastTag {
                TagPreviewCard(tag: tag)
                    .padding(.horizontal)
                Button(L10n.tr("pair.continue")) {
                    draft = SpoolDraft.from(tag: tag)
                    nfc.clearLastTag()
                    step = .review
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                Button {
                    draft = SpoolDraft.from(tag: tag)
                    switch tag.standard {
                    case "OpenPrintTag": nfcWriteStandard = .openPrintTag
                    case "OpenSpool": nfcWriteStandard = .openSpool
                    default: nfcWriteStandard = .openTag3D
                    }
                    showWriteNFC = true
                } label: {
                    Label(L10n.tr("nfc.write.title"), systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
            Spacer()
        }
        .padding()
    }

    private func goBack() {
        switch step {
        case .scanLabel, .nfc, .barcode:
            step = .chooseMethod
        default:
            step = .chooseMethod
        }
    }

    private func submit() async {
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        do {
            try await api.addSpools(draft: draft)
            onAdded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Review form

struct SpoolReviewForm: View {
    @Binding var draft: SpoolDraft
    let isUploading: Bool
    var errorMessage: String?
    var onWriteNFC: (() -> Void)?
    let onSubmit: () -> Void

    var body: some View {
        Form {
            if let errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }

            if !draft.sourceNote.isEmpty {
                Section {
                    Text(draft.sourceNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text(L10n.tr("spool.form.required"))) {
                TextField(L10n.tr("spool.form.material"), text: $draft.material)
                TextField(L10n.tr("spool.form.weight"), text: Binding(
                    get: { String(draft.weightGrams) },
                    set: { draft.weightGrams = Int($0) ?? draft.weightGrams }
                ))
                .keyboardType(.numberPad)
            }

            Section(footer: Text(draft.quantity > 1
                                 ? L10n.count("spool.quantity.many", draft.quantity)
                                 : L10n.tr("spool.quantity.one"))) {
                Stepper(value: $draft.quantity, in: 1...SpoolDraft.maxQuantity) {
                    HStack {
                        Text(L10n.tr("spool.quantity"))
                        Spacer()
                        Text("\(draft.quantity)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(header: Text(L10n.tr("spool.form.optional")),
                    footer: Text(L10n.tr("spool.form.cost.footer"))) {
                TextField(L10n.tr("spool.form.cost"), text: $draft.cost)
                    .keyboardType(.decimalPad)
                TextField(L10n.tr("field.brand"), text: $draft.brand)
                TextField(L10n.tr("spool.form.sku"), text: $draft.sku)
                TextField(L10n.tr("spool.form.barcode"), text: $draft.barcode)
                    .keyboardType(.numberPad)
                TextField(L10n.tr("spool.form.lot"), text: $draft.lot)
                TextField(L10n.tr("spool.form.print_temp"), text: $draft.printTemp)
                    .keyboardType(.numberPad)
                TextField(L10n.tr("spool.form.bed_temp"), text: $draft.bedTemp)
                    .keyboardType(.numberPad)
            }

            Section {
                Button(action: onSubmit) {
                    if isUploading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(draft.quantity > 1 ? L10n.count("spool.add.n", draft.quantity) : L10n.tr("spool.add.one"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isUploading || draft.material.trimmingCharacters(in: .whitespaces).isEmpty)

                if let onWriteNFC {
                    Button(action: onWriteNFC) {
                        Label(L10n.tr("nfc.write.title"), systemImage: "wave.3.right")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(draft.material.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Tag preview

struct TagPreviewCard: View {
    let tag: NFCFilamentTag

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let hex = tag.hex {
                    Circle()
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 28, height: 28)
                }
                VStack(alignment: .leading) {
                    Text(tag.materialLabel.isEmpty ? L10n.tr("spool.detail.filament") : tag.materialLabel)
                        .font(.headline)
                    Text(tag.standard)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                if let w = tag.weight { meta(L10n.tr("spool.tag.weight"), "\(w) g") }
                if let p = tag.printTemp { meta(L10n.tr("spool.tag.print"), "\(p)°C") }
                if let b = tag.bedTemp { meta(L10n.tr("spool.tag.bed"), "\(b)°C") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func meta(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.bold())
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
