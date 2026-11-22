import Foundation
import VisionKit

/// Keeps every text/barcode snippet seen during a scan session (VisionKit removes items when they leave the frame).
final class LabelTextAccumulator: @unchecked Sendable {
    private var byItemID: [UUID: String] = [:]
    private var extraLines: [String] = []
    private let lock = NSLock()

    func ingestLiveItems(_ items: [RecognizedItem]) {
        lock.lock()
        defer { lock.unlock() }
        for item in items {
            guard let text = Self.text(from: item) else { continue }
            byItemID[item.id] = text
        }
    }

    func ingestPhotoText(_ blob: String) {
        let lines = blob
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        lock.lock()
        defer { lock.unlock() }
        extraLines.append(contentsOf: lines)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        byItemID.removeAll()
        extraLines.removeAll()
    }

    var allLines: [String] {
        lock.lock()
        let snapshot = Array(byItemID.values) + extraLines
        lock.unlock()
        return Self.dedupeLines(snapshot)
    }

    var combinedText: String {
        allLines.joined(separator: "\n")
    }

    private static func text(from item: RecognizedItem) -> String? {
        switch item {
        case .barcode(let barcode):
            return barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .text(let text):
            return text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        @unknown default:
            return nil
        }
    }

  /// Drop duplicates and very short fragments absorbed by longer lines.
    static func dedupeLines(_ lines: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for line in lines.sorted(by: { $0.count > $1.count }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            let key = trimmed.lowercased()
            if seen.contains(key) { continue }
            if unique.contains(where: { longer in
                let l = longer.lowercased()
                return l != key && l.contains(key) && key.count < 12
            }) {
                continue
            }
            seen.insert(key)
            unique.append(trimmed)
        }
        return unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
