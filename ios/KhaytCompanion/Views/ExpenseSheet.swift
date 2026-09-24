import SwiftUI
import UIKit

/**
 * Photograph a receipt and file the expense on the spot.
 *
 * A receipt is a photograph, and the phone is the camera. The desktop's expense
 * form expects a file already sitting on that machine — which a receipt in
 * someone's hand at a supplier's counter never is, so it gets photographed,
 * emailed, forgotten, or filed weeks later from a shoebox.
 *
 * The photo is sent as base64 JSON rather than multipart: the desktop identifies
 * it by its own first bytes and generates the filename, so nothing this app
 * sends decides what lands on disk over there.
 */
struct ExpenseSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var amount = ""
    @State private var category = "filament"
    @State private var note = ""
    @State private var receipt: UIImage?
    @State private var showCamera = false
    @State private var isSaving = false
    @State private var error: String?

    // The desktop's own categories, so the phone cannot invent one that never
    // appears in a report.
    private let categories = ["filament", "resin", "parts", "tools", "rent", "power", "shipping", "other"]

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("exp.what")) {
                    HStack {
                        Text(L10n.tr("exp.amount"))
                        Spacer()
                        TextField("0.00", text: $amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                    Picker(L10n.tr("exp.category"), selection: $category) {
                        ForEach(categories, id: \.self) { Text(L10n.tr("exp.cat.\($0)")).tag($0) }
                    }
                    TextField(L10n.tr("exp.note"), text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section(L10n.tr("exp.receipt")) {
                    if let receipt {
                        Image(uiImage: receipt)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: KhaytDesign.radiusLG))
                        Button(L10n.tr("exp.retake"), role: .destructive) { self.receipt = nil }
                    } else if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            Label(L10n.tr("exp.photograph"), systemImage: "camera.fill")
                        }
                    } else {
                        // The simulator, and any device without a camera. An
                        // expense with no receipt is still worth recording.
                        Text(L10n.tr("exp.no_camera"))
                            .font(.system(size: 13))
                            .foregroundStyle(KhaytDesign.textMuted)
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(KhaytDesign.danger)
                    }
                }
            }
            .khaytForm()
            .navigationTitle(L10n.tr("exp.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("exp.save")) { Task { await save() } }
                        .disabled(isSaving || (Double(amount.trimmingCharacters(in: .whitespaces)) ?? 0) <= 0)
                }
            }
            .sheet(isPresented: $showCamera) { LabelCameraPicker(image: $receipt) }
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }

        // Downscaled and re-encoded before sending. A modern phone photo is
        // several megabytes of detail nobody needs to read a total off a till
        // slip, and every one of those bytes crosses the shop's Wi-Fi and then
        // sits on the desktop's disk forever.
        var base64: String?
        if let receipt, let data = Self.jpegForUpload(receipt) {
            base64 = data.base64EncodedString()
        }

        let payload = ExpenseDraft(
            amount: Double(amount.trimmingCharacters(in: .whitespaces)) ?? 0,
            category: category,
            note: note.trimmingCharacters(in: .whitespaces),
            receiptBase64: base64
        )
        do {
            try await api.addExpense(payload)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Longest edge capped, JPEG quality traded for size. Kept `static` and pure
    /// so the sizing rule is testable without a view.
    static func jpegForUpload(_ image: UIImage, maxEdge: CGFloat = 2000, quality: CGFloat = 0.7) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image.jpegData(compressionQuality: quality) }
        let scale = maxEdge / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let shrunk = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return shrunk.jpegData(compressionQuality: quality)
    }
}
