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
                    Button("Cancel") { dismiss() }
                }
                if step != .chooseMethod && step != .review {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { goBack() }
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                if BarcodeScannerView.isSupported() {
                    BarcodeScannerView(scannedText: $scannedRaw)
                } else {
                    Text("Camera not available on this device.")
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
        case .chooseMethod: return "Add filament"
        case .barcode: return "Product barcode"
        case .scanLabel: return "Scan label"
        case .nfc: return "NFC tag"
        case .review: return "Confirm spool"
        }
    }

    private var chooseMethodView: some View {
        List {
            Section {
                Text("How would you like to add this spool?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                methodRow(
                    title: "Scan product barcode",
                    subtitle: "The UPC/EAN on the box, looked up for you",
                    icon: "barcode"
                ) {
                    step = .barcode
                    showBarcodeScanner = true
                }
                methodRow(
                    title: "Scan label",
                    subtitle: "QR code or text on the spool label",
                    icon: "barcode.viewfinder"
                ) {
                    step = .scanLabel
                }
                methodRow(
                    title: "Tap NFC tag",
                    subtitle: "OpenSpool, OpenTag3D, or Prusa OpenPrintTag",
                    icon: "wave.3.right"
                ) {
                    step = .nfc
                }
                methodRow(
                    title: "Enter manually",
                    subtitle: "Type details yourself",
                    icon: "keyboard"
                ) {
                    draft = SpoolDraft()
                    draft.sourceNote = "Manual"
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
                Text("Looking it up…")
                    .font(.title3.bold())
                Text("Your shelf first, then the product database.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "barcode")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                Text("Scan the barcode on the box")
                    .font(.title3.bold())
                Text("A filament you have booked in before is filled in from your own shelf, price included.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    showBarcodeScanner = true
                } label: {
                    Label("Open scanner", systemImage: "barcode.viewfinder")
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
            Text("Point at the label")
                .font(.title3.bold())
            Text("Use Photo mode for best results — take a clear picture of the whole label.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                showCamera = true
            } label: {
                Label("Open camera", systemImage: "camera.fill")
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
            Text("Hold iPhone near the spool")
                .font(.title3.bold())
            if !nfc.isAvailable {
                Text("NFC is not available on this device.")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Button {
                nfc.beginScan()
            } label: {
                Label(nfc.isScanning ? "Scanning…" : "Scan NFC", systemImage: "wave.3.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!nfc.isAvailable || nfc.isScanning)
            .padding(.horizontal)

            if let tag = nfc.lastTag {
                TagPreviewCard(tag: tag)
                    .padding(.horizontal)
                Button("Continue") {
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

            Section(header: Text("Required")) {
                TextField("Material name", text: $draft.material)
                TextField("Weight (grams)", text: Binding(
                    get: { String(draft.weightGrams) },
                    set: { draft.weightGrams = Int($0) ?? draft.weightGrams }
                ))
                .keyboardType(.numberPad)
            }

            Section(footer: Text(draft.quantity > 1
                                 ? "\(draft.quantity) separate spools, each tracked on its own."
                                 : "Several boxes of the same filament? Add them in one go.")) {
                Stepper(value: $draft.quantity, in: 1...SpoolDraft.maxQuantity) {
                    HStack {
                        Text("How many")
                        Spacer()
                        Text("\(draft.quantity)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(header: Text("Optional"),
                    footer: Text("What the roll cost. Jobs printed from it are priced off this.")) {
                TextField("Price paid", text: $draft.cost)
                    .keyboardType(.decimalPad)
                TextField("Brand", text: $draft.brand)
                TextField("SKU", text: $draft.sku)
                TextField("Barcode (UPC/EAN)", text: $draft.barcode)
                    .keyboardType(.numberPad)
                TextField("Batch / lot no.", text: $draft.lot)
                TextField("Print temp (°C)", text: $draft.printTemp)
                    .keyboardType(.numberPad)
                TextField("Bed temp (°C)", text: $draft.bedTemp)
                    .keyboardType(.numberPad)
            }

            Section {
                Button(action: onSubmit) {
                    if isUploading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(draft.quantity > 1 ? "Add \(draft.quantity) spools" : "Add to Khayt inventory")
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
                    Text(tag.materialLabel.isEmpty ? "Filament" : tag.materialLabel)
                        .font(.headline)
                    Text(tag.standard)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                if let w = tag.weight { meta("Weight", "\(w) g") }
                if let p = tag.printTemp { meta("Print", "\(p)°C") }
                if let b = tag.bedTemp { meta("Bed", "\(b)°C") }
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
