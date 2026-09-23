import SwiftUI
import Vision
import VisionKit

/// Reads the product barcode off a box of filament and hands back the code.
///
/// Only retail symbologies — EAN-13 (which is how iOS reports a UPC-A), EAN-8
/// and UPC-E — so the QR code and the lot barcode printed beside it on most
/// boxes are not what gets picked. The first code whose check digit holds is
/// the answer; a half-read one fails that and the camera keeps looking.
///
/// A box with a crumpled label, or a phone without the live scanner, can have
/// the digits typed instead.
struct ProductBarcodeScanner: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var typedCode: String? { ProductBarcode.normalize(typed) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ProductBarcodeScanner.isLiveSupported {
                    LiveBarcodeHost { code in finish(code) }
                        .ignoresSafeArea(edges: .horizontal)
                } else {
                    ContentUnavailableView(
                        L10n.tr("barcode.unavailable"),
                        systemImage: "barcode.viewfinder",
                        description: Text(L10n.tr("barcode.unavailable.sub"))
                    )
                }
                entryPanel
            }
            .navigationTitle(L10n.tr("barcode.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
            }
        }
    }

    private var entryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("barcode.type"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(L10n.tr("barcode.placeholder"), text: $typed)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                Button(L10n.tr("barcode.look_up")) {
                    if let code = typedCode { finish(code) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(typedCode == nil)
            }
            if !typed.isEmpty, typedCode == nil {
                Text(L10n.tr("barcode.invalid"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func finish(_ code: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode(code)
        dismiss()
    }

    static var isLiveSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}

private struct LiveBarcodeHost: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.startIfNeeded(scanner)
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var started = false
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func startIfNeeded(_ scanner: DataScannerViewController) {
            guard !started else { return }
            started = true
            Task { @MainActor in try? scanner.startScanning() }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            consider(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            consider(updatedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            consider([item])
        }

        private func consider(_ items: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue else { continue }
                let kind: ProductBarcode.Kind
                switch barcode.observation.symbology {
                case .ean13: kind = .ean13
                case .ean8: kind = .ean8
                case .upce: kind = .upce
                default: kind = .unknown
                }
                if let code = ProductBarcode.normalize(payload, kind: kind) {
                    done = true
                    Task { @MainActor in self.onCode(code) }
                    return
                }
            }
        }
    }
}
