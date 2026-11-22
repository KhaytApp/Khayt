import UIKit
import Vision

/// Full-frame OCR on a still photo — usually more reliable than live DataScanner fragments.
enum LabelPhotoOCR {
    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let sorted = observations.sorted { a, b in
                    let ay = 1 - a.boundingBox.midY
                    let by = 1 - b.boundingBox.midY
                    if abs(ay - by) > 0.015 { return ay < by }
                    return a.boundingBox.minX < b.boundingBox.minX
                }
                let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                let deduped = LabelTextAccumulator.dedupeLines(lines)
                continuation.resume(returning: deduped.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = [
                "en-US", "ar-SA", "de-DE", "fr-FR", "es-ES",
                "it-IT", "pt-BR", "zh-Hans", "ja-JP", "ko-KR", "tr-TR"
            ]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
