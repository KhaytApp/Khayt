import SwiftUI
import VisionKit

/// Filament label capture: live scanner + photo OCR, with persistent accumulation.
struct BarcodeScannerView: View {
    @Binding var scannedText: String?
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ScanMode = .photo
    @State private var capturedLines: [String] = []
    @State private var showPhotoPicker = false
    @State private var pickedImage: UIImage?
    @State private var isProcessingPhoto = false
    @State private var photoError: String?

    @StateObject private var accumulator = LabelTextAccumulatorBox()

    enum ScanMode: String, CaseIterable, Identifiable {
        case photo = "Photo"
        case live = "Live"
        var id: String { rawValue }
        var title: String { L10n.tr(self == .photo ? "scan.mode.photo" : "scan.mode.live") }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if mode == .live, BarcodeScannerView.isLiveScannerSupported() {
                    ScannerHost(accumulator: accumulator)
                        .ignoresSafeArea()
                } else if mode == .live {
                    ContentUnavailableView(
                        L10n.tr("scan.live_unavailable"),
                        systemImage: "camera.fill",
                        description: Text(L10n.tr("scan.live_unavailable.sub"))
                    )
                } else {
                    photoPlaceholder
                }

                VStack {
                    Spacer()
                    capturePanel
                }
            }
            .navigationTitle(L10n.tr("scan.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
                if !capturedLines.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.tr("scan.clear")) {
                            accumulator.value.clear()
                            syncLines()
                        }
                    }
                }
            }
            .onAppear { syncLines() }
            .onReceive(accumulator.objectWillChange) { _ in syncLines() }
            .sheet(isPresented: $showPhotoPicker) {
                LabelCameraPicker(image: $pickedImage)
                    .ignoresSafeArea()
            }
            .onChange(of: pickedImage) { _, image in
                guard let image else { return }
                pickedImage = nil
                Task { await processPhoto(image) }
            }
        }
    }

    private var photoPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text(L10n.tr("scan.photo.title"))
                .font(.title3.bold())
            Text(L10n.tr("scan.photo.body"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showPhotoPicker = true
            } label: {
                Label(L10n.tr("scan.photo.take"), systemImage: "camera.shutter.button")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            Spacer()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var capturePanel: some View {
        VStack(spacing: 10) {
            Picker(L10n.tr("scan.mode"), selection: $mode) {
                ForEach(ScanMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if mode == .photo {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label(isProcessingPhoto ? L10n.tr("scan.photo.reading") : L10n.tr("scan.photo.take"), systemImage: "camera.shutter.button")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isProcessingPhoto)
                .padding(.horizontal)
            } else {
                Text(L10n.tr("scan.live.hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let photoError {
                Text(photoError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if !capturedLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(capturedLines.prefix(12), id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        if capturedLines.count > 12 {
                            Text("+\(capturedLines.count - 12) more…")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding(.horizontal)
            }

            Button {
                finishCapture()
            } label: {
                Label(String(format: L10n.tr("scan.use_text"), capturedLines.count), systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(capturedLines.isEmpty || isProcessingPhoto)
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .padding(.top, 10)
        .background(.ultraThinMaterial)
        .onChange(of: mode) { _, _ in syncLines() }
    }

    private func processPhoto(_ image: UIImage) async {
        isProcessingPhoto = true
        photoError = nil
        defer { isProcessingPhoto = false }
        do {
            let text = try await LabelPhotoOCR.recognizeText(in: image)
            guard !text.isEmpty else {
                photoError = L10n.tr("scan.photo.none")
                return
            }
            accumulator.value.ingestPhotoText(text)
            syncLines()
        } catch {
            photoError = error.localizedDescription
        }
    }

    private func syncLines() {
        capturedLines = accumulator.value.allLines
    }

    private func finishCapture() {
        let blob = accumulator.value.combinedText
        guard !blob.isEmpty else { return }
        scannedText = blob
        dismiss()
    }

    static func isSupported() -> Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static func isLiveScannerSupported() -> Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}

/// Bridges `LabelTextAccumulator` into SwiftUI state.
final class LabelTextAccumulatorBox: ObservableObject {
    let value = LabelTextAccumulator()
}

// MARK: - Live VisionKit scanner

private struct ScannerHost: UIViewControllerRepresentable {
    @ObservedObject var accumulator: LabelTextAccumulatorBox

    func makeCoordinator() -> Coordinator {
        Coordinator(accumulator: accumulator)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let types: Set<DataScannerViewController.RecognizedDataType> = [.barcode(), .text()]
        let scanner = DataScannerViewController(
            recognizedDataTypes: types,
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        context.coordinator.startIfNeeded(scanner: uiViewController)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let accumulator: LabelTextAccumulatorBox
        private var didStart = false

        init(accumulator: LabelTextAccumulatorBox) {
            self.accumulator = accumulator
        }

        func startIfNeeded(scanner: DataScannerViewController) {
            guard !didStart else { return }
            didStart = true
            Task { @MainActor in
                try? await scanner.startScanning()
            }
        }

        private func ingest(_ allItems: [RecognizedItem]) {
            accumulator.value.ingestLiveItems(allItems)
            accumulator.objectWillChange.send()
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            ingest(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            ingest(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            accumulator.value.ingestLiveItems(removedItems)
            ingest(allItems)
        }
    }
}
