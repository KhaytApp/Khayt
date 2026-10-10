import SwiftUI
import UIKit
import KhaytCore

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
    // Read off the receipt's ZATCA QR — see `ReceiptScan.swift`.
    @State private var fromReceipt: KhaytEngine.ReceiptDraft?
    @State private var vatAmount = ""
    @State private var receiptSays: String?
    @State private var scanningQR = false
    @State private var reclaimsTax = false

    // The desktop's own categories, so the phone cannot invent one that never
    // appears in a report.
    private let categories = ["filament", "resin", "parts", "tools", "rent", "power", "shipping", "other"]

    /// An amount and a category: a receipt fills the first and never the
    /// second, because it does not say what the money was for.
    private var canSave: Bool {
        (Double(amount.trimmingCharacters(in: .whitespaces)) ?? 0) > 0 && !category.isEmpty
    }

    /// The QR route needs the book: the shared rule and the shop's suppliers live there.
    private var canReadReceipts: Bool { api.holdsBook && api.reader != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if canReadReceipts { receiptQRCard }
                    V2FieldCard {
                        V2Field(label: L10n.tr("exp.amount")) {
                            TextField("", text: $amount, prompt: Text(verbatim: "0.00"))
                                .keyboardType(.decimalPad)
                                .font(.khayt(26, .semibold, relativeTo: .title).monospacedDigit())
                        }
                        if fromReceipt != nil && reclaimsTax {
                            V2Field(label: L10n.tr("exp.vat")) {
                                TextField("", text: $vatAmount, prompt: Text(verbatim: "0.00"))
                                    .keyboardType(.decimalPad)
                                    .monospacedDigit()
                            }
                        }
                        V2Field(label: L10n.tr("exp.category")) {
                            V2Chips(options: categories, selection: $category) { L10n.tr("exp.cat.\($0)") }
                                .padding(.vertical, 4)
                        }
                        V2Field(label: L10n.tr("exp.note"), last: true) {
                            TextField("", text: $note, axis: .vertical)
                                .lineLimit(1...3)
                        }
                    }
                    receiptCard
                    if let error {
                        V2Note(text: error, tone: KhaytDesign.late)
                    }
                    V2PrimaryButton(title: L10n.tr("exp.save"), busy: isSaving, disabled: !canSave) {
                        Task { await save() }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("exp.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
            .sheet(isPresented: $showCamera) { LabelCameraPicker(image: $receipt) }
            .sheet(isPresented: $scanningQR) {
                LabelScanner(title: L10n.tr("exp.qr.title"), hint: L10n.tr("exp.qr.hint")) { code in
                    Task { await read([code]) }
                }
            }
            // A photographed receipt is searched for its QR, so one photo does both.
            .onChange(of: receipt) { _, picture in
                guard let picture, fromReceipt == nil, canReadReceipts else { return }
                Task {
                    let codes = await ReceiptQR.payloadsAsync(in: picture)
                    if !codes.isEmpty { await read(codes, quietIfNone: true) }
                }
            }
            .task {
                if let reader = api.reader, canReadReceipts { reclaimsTax = await reader.reclaimsTax() }
                #if DEBUG
                // `-KhaytReceipt <QR text>` on the launch line, for screenshots.
                if let code = UserDefaults.standard.string(forKey: "KhaytReceipt") { await read([code]) }
                #endif
            }
        }
    }

    // MARK: - The receipt's QR

    @ViewBuilder
    private var receiptQRCard: some View {
        if let draft = fromReceipt {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.isolated(draft.supplier?.name ?? draft.sellerName))
                    .font(.khayt(15.5, .semibold, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                Text(L10n.format("exp.qr.vat_number", Self.isolated(draft.vatNumber)) + " · " + Self.isolated(draft.draft.date))
                    .font(.khayt(13, relativeTo: .footnote).monospacedDigit())
                    .foregroundStyle(KhaytDesign.note)
                Text(L10n.tr(draft.supplier != nil ? "exp.qr.supplier" : "exp.qr.new_supplier"))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                V2Note(text: L10n.tr("exp.qr.filled"))
                if receipt != nil { V2Note(text: L10n.tr("exp.qr.photo_stays"), tone: KhaytDesign.attention) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button { scanningQR = true } label: {
                    Label(L10n.tr("exp.qr.scan"), systemImage: "qrcode.viewfinder")
                        .font(.khayt(15.5, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.brand)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(KhaytDesign.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.brand, lineWidth: 1))
                }
                .buttonStyle(.plain)
                V2Note(text: receiptSays ?? L10n.tr("exp.qr.why"),
                       tone: receiptSays == nil ? KhaytDesign.note : KhaytDesign.attention)
            }
        }
    }

    /// Read every code found; the first that is a receipt not already filed
    /// fills the form. A receipt already in the books is said, never offered:
    /// the same receipt filed twice is the same money counted twice.
    private func read(_ codes: [String], quietIfNone: Bool = false) async {
        guard let reader = api.reader else { return }
        var reason: String?
        var duplicate = false
        for code in codes {
            switch try? await reader.readReceipt(code) {
            case .draft(let d)?:
                if d.duplicateOf != nil { duplicate = true; continue }
                apply(d)
                return
            case .refused(let why)?:
                reason = reason ?? why
            case nil:
                reason = reason ?? "not_base64"
            }
        }
        if duplicate {
            receiptSays = L10n.tr("exp.qr.duplicate")
        } else if !quietIfNone {
            receiptSays = L10n.tr("exp.qr.reason.\(reason ?? "not_base64")")
        }
    }

    private func apply(_ d: KhaytEngine.ReceiptDraft) {
        fromReceipt = d
        receiptSays = nil
        amount = Self.halala(d.draft.amount)
        vatAmount = Self.halala(d.draft.vatAmount)
        note = L10n.format("exp.qr.note", d.supplier?.name ?? d.sellerName, d.vatNumber)
        // Filled in, not filed: the category is the person's to choose.
        category = ""
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// To the halala, in Western digits — a QR may write six decimals.
    static func halala(_ x: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), (x * 100).rounded() / 100)
    }

    /// A seller's name or a number in its own direction, so an Arabic name in
    /// an English sheet (or the other way round) does not reorder what is beside it.
    static func isolated(_ s: String) -> String { "\u{2068}" + s + "\u{2069}" }

    @ViewBuilder
    private var receiptCard: some View {
        if let receipt {
            VStack(spacing: 0) {
                Image(uiImage: receipt)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                Button(role: .destructive) { self.receipt = nil } label: {
                    Text(L10n.tr("exp.retake"))
                        .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.late)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                }
                .buttonStyle(.plain)
            }
            .card()
        } else if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button { showCamera = true } label: {
                Label(L10n.tr("exp.photograph"), systemImage: "camera")
                    .font(.khayt(15.5, .semibold, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.brand)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(KhaytDesign.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.brand, lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else {
            // The simulator, and any device without a camera. An expense with
            // no receipt is still worth recording.
            V2Note(text: L10n.tr("exp.no_camera"))
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

        var payload = ExpenseDraft(
            amount: Double(amount.trimmingCharacters(in: .whitespaces)) ?? 0,
            category: category,
            note: note.trimmingCharacters(in: .whitespaces),
            receiptBase64: base64
        )
        if let d = fromReceipt {
            payload.vatAmount = reclaimsTax ? Double(vatAmount.trimmingCharacters(in: .whitespaces)) ?? 0 : 0
            payload.date = d.draft.date
            payload.receiptRef = d.draft.receiptRef
        }
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
