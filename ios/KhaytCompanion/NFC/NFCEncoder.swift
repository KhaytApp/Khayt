import CoreNFC
import Foundation

enum NFCFilamentStandard: String, CaseIterable, Identifiable, Sendable {
    case openSpool
    case openTag3D
    case openPrintTag

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openSpool: return L10n.tr("nfc.standard.openspool")
        case .openTag3D: return L10n.tr("nfc.standard.opentag3d")
        case .openPrintTag: return L10n.tr("nfc.standard.openprinttag")
        }
    }

    var subtitle: String {
        switch self {
        case .openSpool: return L10n.tr("nfc.standard.openspool.hint")
        case .openTag3D: return L10n.tr("nfc.standard.opentag3d.hint")
        case .openPrintTag: return L10n.tr("nfc.standard.openprinttag.hint")
        }
    }

    var mimeType: String {
        switch self {
        case .openSpool: return "application/json"
        case .openTag3D: return "application/opentag3d"
        case .openPrintTag: return "application/vnd.openprinttag"
        }
    }
}

enum NFCEncodeError: Error, LocalizedError, Sendable {
    case missingMaterial
    case payloadTooLarge(Int)
    case invalidColor

    var errorDescription: String? {
        switch self {
        case .missingMaterial: return L10n.tr("nfc.error.missing_material")
        case .payloadTooLarge(let n): return L10n.format("nfc.error.payload_large", n)
        case .invalidColor: return L10n.tr("nfc.error.invalid_color")
        }
    }
}

/// Builds OpenSpool, OpenTag3D, and OpenPrintTag NFC payloads — mirror of `NFCParser` / `renderer/inventory.js`.
enum NFCEncoder {
    private static let openTag3DSize = 0x66
    private static let maxNDEFPayload = 888

    private static let optMaterials: [String: Int] = [
        "PLA": 0, "PETG": 1, "TPU": 2, "ABS": 3, "ASA": 4, "PC": 5, "PCTG": 6,
        "PP": 7, "PA6": 8, "PA11": 9, "PA12": 10, "PA66": 11, "CPE": 12, "TPE": 13,
        "HIPS": 14, "PHA": 15, "PET": 16, "PEI": 17, "PBT": 18, "PVB": 19,
        "PVA": 20, "PEKK": 21, "PEEK": 22
    ]

    static func encode(draft: SpoolDraft, standard: NFCFilamentStandard) throws -> NFCNDEFMessage {
        let payload: [UInt8]
        switch standard {
        case .openSpool:
            payload = try encodeOpenSpool(draft)
        case .openTag3D:
            payload = try encodeOpenTag3D(draft)
        case .openPrintTag:
            payload = try encodeOpenPrintTag(draft)
        }
        guard payload.count <= maxNDEFPayload else {
            throw NFCEncodeError.payloadTooLarge(payload.count)
        }
        guard let typeData = standard.mimeType.data(using: .utf8) else {
            throw NFCEncodeError.missingMaterial
        }
        let record = NFCNDEFPayload(
            format: .media,
            type: typeData,
            identifier: Data(),
            payload: Data(payload)
        )
        return NFCNDEFMessage(records: [record])
    }

    // MARK: - OpenSpool

    private static func encodeOpenSpool(_ draft: SpoolDraft) throws -> [UInt8] {
        let material = draft.material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !material.isEmpty else { throw NFCEncodeError.missingMaterial }

        let parts = material.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let type = String((parts.first ?? material).prefix(16))
        let subtype = parts.count > 1 ? String(parts.dropFirst().joined(separator: " ").prefix(32)) : nil
        let colorHex = try openspoolColorHex(from: draft.colorHex)

        var json: [String: Any] = [
            "protocol": "openspool",
            "version": "1.0",
            "type": type,
            "color_hex": colorHex
        ]
        let brand = draft.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brand.isEmpty { json["brand"] = String(brand.prefix(32)) }
        if let subtype, !subtype.isEmpty { json["subtype"] = subtype }
        if draft.weightGrams > 0 { json["weight"] = draft.weightGrams }
        json["diameter"] = 1.75

        let printC = Int(draft.printTemp.trimmingCharacters(in: .whitespaces))
        if let printC, printC > 0 {
            json["min_temp"] = max(printC - 15, 150)
            json["max_temp"] = printC + 15
        }
        let bedC = Int(draft.bedTemp.trimmingCharacters(in: .whitespaces))
        if let bedC, bedC > 0 {
            json["bed_min_temp"] = max(bedC - 10, 0)
            json["bed_max_temp"] = bedC + 10
        }

        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return Array(data)
    }

    // MARK: - OpenTag3D

    private static func encodeOpenTag3D(_ draft: SpoolDraft) throws -> [UInt8] {
        let material = draft.material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !material.isEmpty else { throw NFCEncodeError.missingMaterial }

        var bytes = [UInt8](repeating: 0, count: openTag3DSize)
        writeU16(&bytes, offset: 0x00, value: 1000) // version 1.000

        let (base, modifiers) = splitMaterial(material)
        writeString(&bytes, offset: 0x02, value: base, maxLength: 5)
        writeString(&bytes, offset: 0x07, value: modifiers, maxLength: 5)
        writeString(&bytes, offset: 0x1B, value: draft.brand, maxLength: 16)

        let (r, g, b) = try rgbComponents(from: draft.colorHex)
        bytes[0x4B] = r
        bytes[0x4C] = g
        bytes[0x4D] = b
        bytes[0x4E] = 255 // alpha

        writeU16(&bytes, offset: 0x5C, value: 1750) // 1.75 mm
        writeU16(&bytes, offset: 0x5E, value: min(max(draft.weightGrams, 1), 65_535))
        if let printC = Int(draft.printTemp.trimmingCharacters(in: .whitespaces)), printC > 0 {
            bytes[0x60] = UInt8(min(printC / 5, 255))
        }
        if let bedC = Int(draft.bedTemp.trimmingCharacters(in: .whitespaces)), bedC > 0 {
            bytes[0x61] = UInt8(min(bedC / 5, 255))
        }
        writeU16(&bytes, offset: 0x62, value: densityFor(material: base))
        return bytes
    }

    // MARK: - OpenPrintTag

    private static func encodeOpenPrintTag(_ draft: SpoolDraft) throws -> [UInt8] {
        let material = draft.material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !material.isEmpty else { throw NFCEncodeError.missingMaterial }

        var entries: [(Int, Any)] = []
        let upper = material.uppercased()
        if let idx = optMaterials.first(where: { upper.hasPrefix($0.key) })?.value {
            entries.append((9, idx))
        } else {
            entries.append((10, String(material.prefix(32))))
        }
        let brand = draft.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brand.isEmpty { entries.append((11, String(brand.prefix(32)))) }
        let sku = draft.sku.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sku.isEmpty { entries.append((12, String(sku.prefix(32)))) }
        let lot = draft.lot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lot.isEmpty { entries.append((13, String(lot.prefix(32)))) }
        entries.append((16, min(max(draft.weightGrams, 1), 65_535)))
        let (r, g, b) = try rgbComponents(from: draft.colorHex)
        entries.append((19, [r, g, b]))
        if let printC = Int(draft.printTemp.trimmingCharacters(in: .whitespaces)), printC > 0 {
            entries.append((34, printC))
        }
        if let bedC = Int(draft.bedTemp.trimmingCharacters(in: .whitespaces)), bedC > 0 {
            entries.append((37, bedC))
        }
        return CBOR.encodeMap(entries)
    }

    // MARK: - Helpers

    private static func splitMaterial(_ material: String) -> (String, String) {
        let parts = material.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return ("", "") }
        let base = String(first.prefix(5))
        let mods = parts.dropFirst().joined(separator: " ")
        return (base, String(mods.prefix(5)))
    }

    private static func densityFor(material: String) -> Int {
        switch material.uppercased() {
        case "ABS": return 1070
        case "PETG": return 1270
        case "TPU": return 1200
        default: return 1240 // PLA-ish default
        }
    }

    private static func rgbComponents(from hex: String) throws -> (UInt8, UInt8, UInt8) {
        let value = try parseHexColor(hex)
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    private static func openspoolColorHex(from hex: String) throws -> String {
        let value = try parseHexColor(hex)
        return String(format: "%06X", value)
    }

    private static func parseHexColor(_ hex: String) throws -> UInt32 {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            throw NFCEncodeError.invalidColor
        }
        return value
    }

    private static func writeString(_ bytes: inout [UInt8], offset: Int, value: String, maxLength: Int) {
        guard offset < bytes.count else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Array(trimmed.prefix(maxLength).utf8)
        for (i, b) in data.enumerated() where offset + i < bytes.count {
            bytes[offset + i] = b
        }
    }

    private static func writeU16(_ bytes: inout [UInt8], offset: Int, value: Int) {
        guard offset + 1 < bytes.count else { return }
        let v = min(max(value, 0), 65_535)
        bytes[offset] = UInt8((v >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(v & 0xFF)
    }
}

// MARK: - Minimal CBOR encoder

private enum CBOR {
    static func encodeMap(_ entries: [(Int, Any)]) -> [UInt8] {
        var out: [UInt8] = []
        appendMapHeader(count: entries.count, into: &out)
        for (key, value) in entries {
            appendUInt(key, into: &out)
            appendValue(value, into: &out)
        }
        return out
    }

    private static func appendMapHeader(count: Int, into out: inout [UInt8]) {
        appendType(major: 5, info: count, into: &out)
    }

    private static func appendArray(_ values: [Any], into out: inout [UInt8]) {
        appendType(major: 4, info: values.count, into: &out)
        for v in values { appendValue(v, into: &out) }
    }

    private static func appendText(_ text: String, into out: inout [UInt8]) {
        let bytes = Array(text.utf8)
        appendType(major: 3, info: bytes.count, into: &out)
        out.append(contentsOf: bytes)
    }

    private static func appendUInt(_ n: Int, into out: inout [UInt8]) {
        appendType(major: 0, info: n, into: &out)
    }

    private static func appendValue(_ value: Any, into out: inout [UInt8]) {
        switch value {
        case let n as Int:
            appendUInt(n, into: &out)
        case let s as String:
            appendText(s, into: &out)
        case let arr as [Int]:
            appendArray(arr.map { $0 as Any }, into: &out)
        case let arr as [Any]:
            appendArray(arr, into: &out)
        default:
            appendText(String(describing: value), into: &out)
        }
    }

    private static func appendType(major: Int, info: Int, into out: inout [UInt8]) {
        if info < 24 {
            out.append(UInt8((major << 5) | info))
        } else if info < 256 {
            out.append(UInt8((major << 5) | 24))
            out.append(UInt8(info))
        } else if info < 65_536 {
            out.append(UInt8((major << 5) | 25))
            out.append(UInt8((info >> 8) & 0xFF))
            out.append(UInt8(info & 0xFF))
        } else {
            out.append(UInt8((major << 5) | 26))
            out.append(UInt8((info >> 24) & 0xFF))
            out.append(UInt8((info >> 16) & 0xFF))
            out.append(UInt8((info >> 8) & 0xFF))
            out.append(UInt8(info & 0xFF))
        }
    }
}
