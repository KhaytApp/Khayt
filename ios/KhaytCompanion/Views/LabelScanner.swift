import SwiftUI
import VisionKit

/// Reads a Khayt label — the QR the desktops print on a job's bag or a spool —
/// and hands back its text. What the text MEANS is `lib/scan.js`, the module
/// that reads what `lib/labels.js` writes (`KHAYT-ORDER:`, `KHAYT-SPOOL:`, or
/// the order's tracking link when the shop's cloud is on).
struct LabelScanner: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    LiveQRHost { code in
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        onCode(code)
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .horizontal)
                    .overlay(alignment: .bottom) {
                        Text(L10n.tr("scan.label.hint"))
                            .font(.khayt(13.5, .medium, relativeTo: .subheadline))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                    }
                } else {
                    ContentUnavailableView(L10n.tr("barcode.unavailable"), systemImage: "qrcode.viewfinder",
                                           description: Text(L10n.tr("barcode.unavailable.sub")))
                }
            }
            .navigationTitle(L10n.tr("scan.label.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.cancel")) { dismiss() } }
            }
        }
    }
}

private struct LiveQRHost: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighlightingEnabled: true)
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

        func dataScanner(_ d: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) { take(added) }
        func dataScanner(_ d: DataScannerViewController, didTapOn item: RecognizedItem) { take([item]) }

        private func take(_ items: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                guard case .barcode(let b) = item, let text = b.payloadStringValue, !text.isEmpty else { continue }
                done = true
                Task { @MainActor in self.onCode(text) }
                return
            }
        }
    }
}
