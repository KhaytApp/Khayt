import Foundation
import UIKit
import Vision
import KhaytCore

/// A supplier's receipt, read off its ZATCA QR — on the phone.
///
/// Every Saudi tax invoice carries one: the seller, their VAT number, the
/// moment, the total and the VAT. Read off the code, the expense is the exact
/// figures — the input VAT to the halala, with no typing. What the code says
/// is `lib/zatca-qr.js`'s to decide (`decodeTLV`, then `receiptToExpenseDraft`,
/// which matches the seller to a supplier and spots a receipt already filed),
/// exactly as the Mac's "Add from receipt" asks it (`ReceiptQr.swift`). This
/// file only finds the code — live, or in the photo of the receipt — and
/// hands the sheet a filled-in expense to check. It never files one by itself:
/// a receipt does not say what the money was for.
enum ReceiptQR {

    /// Every QR payload Vision finds in a photo, top of the page first,
    /// without repeats. Blocking work: call it off the main actor.
    static func payloads(in image: UIImage) -> [String] {
        guard let cg = image.cgImage else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation(image.imageOrientation))
        guard (try? handler.perform([request])) != nil else { return [] }
        var seen = Set<String>()
        return (request.results ?? [])
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap(\.payloadStringValue)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The same, off the main actor and the cooperative pool (Vision blocks).
    static func payloadsAsync(in image: UIImage) async -> [String] {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: payloads(in: image)) }
        }
    }

    private static func orientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// What one code turned out to be.
enum ReceiptReading: Equatable, Sendable {
    /// A tax invoice, as the expense it proposes.
    case draft(KhaytEngine.ReceiptDraft)
    /// Not one — `lib/zatca-qr.js`'s reason (`not_base64`, `truncated`, …).
    case refused(String)
}

extension BookReader {

    /// Read one code against the book: its suppliers (a seller matched by VAT
    /// number, then name), its recent expenses (the same receipt filed before),
    /// and whether the shop reclaims VAT at all — a shop that is not
    /// registered carries none, so the whole total is its cost.
    func readReceipt(_ code: String) async throws -> ReceiptReading {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = try sharedEngine()
        let read = try await engine.readReceiptQr(text)
        guard read.ok else { return .refused(read.reason ?? "not_base64") }
        let store = try wholeBook()
        func rows(_ key: String) -> [JSONValue] {
            if case .array(let r)? = store[key] { return r }
            return []
        }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { settings = s }
        let reclaims = (try? await engine.taxProfile(settings: settings))?.isRegistered ?? false
        guard let draft = try await engine.receiptDraft(text, suppliers: rows("suppliers"),
                                                        expenses: rows("expenses"), reclaimsTax: reclaims)
        else { return .refused("not_base64") }
        return .draft(draft)
    }

    /// Whether the shop reclaims input VAT — the sheet shows the VAT field only then.
    func reclaimsTax() async -> Bool {
        guard let store = try? wholeBook(), case .object(let s)? = store["settings"],
              let engine = try? sharedEngine() else { return false }
        return (try? await engine.taxProfile(settings: s))?.isRegistered ?? false
    }
}
