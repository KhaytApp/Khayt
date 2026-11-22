import Foundation

enum NFCParseError: Error, LocalizedError, Sendable {
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .invalidData(let message): return message
        }
    }
}

/// Parses OpenSpool, OpenTag3D, and OpenPrintTag (Prusa) NFC payloads — parity with `renderer/inventory.js`.
enum NFCParser {
    static func parse(bytes: [UInt8]) -> Result<NFCFilamentTag, NFCParseError> {
        if bytes.count < 10 {
            return .failure(.invalidData("Tag data too short."))
        }
        if let payload = extractNDEFPayload(bytes, mimeType: "application/json"),
           let tag = parseOpenSpool(payload) {
            return .success(tag)
        }
        if let payload = extractNDEFPayload(bytes, mimeType: "application/opentag3d"),
           let tag = parseOpenTag3D(payload) {
            return .success(tag)
        }
        if let payload = extractNDEFPayload(bytes, mimeType: "application/vnd.openprinttag"),
           let tag = parseOpenPrintTag(payload) {
            return .success(tag)
        }
        if let tag = parseOpenSpool(bytes) {
            return .success(tag)
        }
        if let tag = parseOpenTag3D(bytes) {
            return .success(tag)
        }
        return .failure(.invalidData("Could not parse as OpenSpool, OpenTag3D, or OpenPrintTag."))
    }

    // MARK: - OpenSpool

    private static func parseOpenSpool(_ bytes: [UInt8]) -> NFCFilamentTag? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              (obj["protocol"] as? String)?.lowercased() == "openspool" else { return nil }

        let type = (obj["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtype = (obj["subtype"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = (obj["brand"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type != nil || !(brand ?? "").isEmpty else { return nil }

        var material = type
        if let subtype, !subtype.isEmpty, let type {
            material = "\(type) \(subtype)"
        }

        var hex: String?
        if let raw = obj["color_hex"] as? String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("#") { s.removeFirst() }
            if s.count == 6 { hex = "#\(s.lowercased())" }
        }

        let weight = intValue(obj["weight"])
        let printT = intValue(obj["max_temp"]) ?? intValue(obj["min_temp"])
        let bedT = intValue(obj["bed_max_temp"]) ?? intValue(obj["bed_min_temp"])

        return NFCFilamentTag(
            standard: "OpenSpool",
            manufacturer: brand?.isEmpty == false ? brand : nil,
            material: material,
            colorName: nil,
            hex: hex,
            weight: weight,
            printTemp: printT,
            bedTemp: bedT,
            sku: nil,
            lot: nil
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n > 0 ? n : nil
        case let n as Double: return n > 0 ? Int(n.rounded()) : nil
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    // MARK: - OpenTag3D

    private static func parseOpenTag3D(_ bytes: [UInt8]) -> NFCFilamentTag? {
        guard bytes.count >= 0x66 else { return nil }
        let baseMaterial = readString(bytes, offset: 0x02, length: 5)
        guard !baseMaterial.isEmpty else { return nil }
        let modifiers = readString(bytes, offset: 0x07, length: 5)
        let manufacturer = readString(bytes, offset: 0x1B, length: 16)
        let colorName = readString(bytes, offset: 0x2B, length: 32)
        let r = Int(bytes[0x4B]), g = Int(bytes[0x4C]), b = Int(bytes[0x4D])
        let hex: String? = (r > 0 || g > 0 || b > 0)
            ? String(format: "#%02x%02x%02x", r, g, b)
            : nil
        let weight = u16(bytes, 0x5E)
        let printTemp = Int(bytes[0x60]) * 5
        let bedTemp = Int(bytes[0x61]) * 5
        let material = modifiers.isEmpty ? baseMaterial : "\(baseMaterial) \(modifiers)".trimmingCharacters(in: .whitespaces)
        return NFCFilamentTag(
            standard: "OpenTag3D",
            manufacturer: manufacturer.isEmpty ? nil : manufacturer,
            material: material,
            colorName: colorName.isEmpty ? nil : colorName,
            hex: hex,
            weight: weight > 0 ? weight : nil,
            printTemp: printTemp > 0 ? printTemp : nil,
            bedTemp: bedTemp > 0 ? bedTemp : nil,
            sku: nil,
            lot: nil
        )
    }

    // MARK: - OpenPrintTag (minimal CBOR)

    private static let optMaterials = [
        0: "PLA", 1: "PETG", 2: "TPU", 3: "ABS", 4: "ASA", 5: "PC", 6: "PCTG",
        7: "PP", 8: "PA6", 9: "PA11", 10: "PA12", 11: "PA66", 12: "CPE", 13: "TPE",
        14: "HIPS", 15: "PHA", 16: "PET", 17: "PEI", 18: "PBT", 19: "PVB",
        20: "PVA", 21: "PEKK", 22: "PEEK"
    ]

    private static func parseOpenPrintTag(_ bytes: [UInt8]) -> NFCFilamentTag? {
        guard let decoded = decodeCBOR(bytes, offset: 0)?.value as? [[Any]] else { return nil }
        var data = [Int: Any]()
        for pair in decoded {
            guard pair.count >= 2, let key = pair[0] as? Int else { continue }
            data[key] = pair[1]
        }
        let matKey = data[9] as? Int
        let matType = matKey.flatMap { optMaterials[$0] } ?? (data[9] as? String)
        let matName = (data[10] as? String) ?? (data[52] as? String)
        let brand = data[11] as? String
        let weightVal = (data[16] as? Double) ?? (data[17] as? Double) ?? (data[16] as? Int).map(Double.init)
        var hex: String?
        if let cd = data[19] {
            var r: Int?, g: Int?, b: Int?
            if let arr = cd as? [Any], arr.count >= 3 {
                r = arr[0] as? Int; g = arr[1] as? Int; b = arr[2] as? Int
            } else if let map = cd as? [Int: Any] {
                r = map[0] as? Int; g = map[1] as? Int; b = map[2] as? Int
            }
            if let r, let g, let b { hex = String(format: "#%02x%02x%02x", r, g, b) }
        }
        let material = matType ?? matName
        guard material != nil || brand != nil else { return nil }
        let printT = intCelsius(data[34]) ?? intCelsius(data[35])
        let bedT = intCelsius(data[37]) ?? intCelsius(data[38])
        return NFCFilamentTag(
            standard: "OpenPrintTag",
            manufacturer: brand,
            material: material,
            colorName: nil,
            hex: hex,
            weight: weightVal.map { Int($0.rounded()) },
            printTemp: printT,
            bedTemp: bedT,
            sku: data[12] as? String,
            lot: data[13] as? String
        )
    }

    private static func intCelsius(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let n = value as? Int { return n > 0 && n < 80 ? n * 5 : (n > 80 ? n : nil) }
        if let n = value as? Double { return intCelsius(Int(n)) }
        return nil
    }

    // MARK: - NDEF

    private static func extractNDEFPayload(_ bytes: [UInt8], mimeType: String) -> [UInt8]? {
        var pos = 0
        if bytes.count > 16 && bytes[0] == 0x04 { pos = 16 }
        while pos < bytes.count - 2 {
            let t = bytes[pos]
            if t == 0xFE { break }
            if t == 0x00 { pos += 1; continue }
            let len: Int
            let dataStart: Int
            if bytes[pos + 1] == 0xFF {
                // The three-byte length needs pos + 3, one past what the loop
                // guarantees: a tag ending `03 FF xx` read off the end and
                // trapped (found by `testRandomBytesFailCleanly`, Oct 2026).
                guard pos + 3 < bytes.count else { break }
                len = (Int(bytes[pos + 2]) << 8) | Int(bytes[pos + 3])
                dataStart = pos + 4
            } else {
                len = Int(bytes[pos + 1])
                dataStart = pos + 2
            }
            let tlv = Array(bytes[dataStart..<min(dataStart + len, bytes.count)])
            pos = dataStart + len
            guard t == 0x03 else { continue }
            var p = 0
            while p < tlv.count {
                let flags = Int(tlv[p]); p += 1
                let tnf = flags & 0x07
                guard p + 2 <= tlv.count else { break }
                let typeLen = Int(tlv[p]); p += 1
                let sr = (flags & 0x10) != 0
                let payloadLen: Int
                if sr {
                    guard p < tlv.count else { break }
                    payloadLen = Int(tlv[p]); p += 1
                } else {
                    guard p + 4 <= tlv.count else { break }
                    payloadLen = (Int(tlv[p]) << 24) | (Int(tlv[p + 1]) << 16) | (Int(tlv[p + 2]) << 8) | Int(tlv[p + 3])
                    p += 4
                }
                let il = (flags & 0x08) != 0
                var idLen = 0
                if il {
                    guard p < tlv.count else { break }
                    idLen = Int(tlv[p]); p += 1
                }
                guard p + typeLen <= tlv.count else { break }
                let recType = String(bytes: tlv[p..<(p + typeLen)], encoding: .utf8) ?? ""
                p += typeLen + idLen
                guard p + payloadLen <= tlv.count else { break }
                let payload = Array(tlv[p..<(p + payloadLen)])
                p += payloadLen
                if tnf == 0x02 && recType == mimeType { return payload }
                if (flags & 0x40) != 0 { break }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func readString(_ bytes: [UInt8], offset: Int, length: Int) -> String {
        guard offset + length <= bytes.count else { return "" }
        let slice = bytes[offset..<(offset + length)]
        if let idx = slice.firstIndex(of: 0) {
            return String(bytes: slice[..<idx], encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        return String(bytes: slice, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset + 1 < bytes.count else { return 0 }
        return (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    private static let maxCBORDepth = 12
    private static let maxCBORCollectionCount = 64

    private static func decodeCBOR(_ buf: [UInt8], offset: Int, depth: Int = 0) -> (value: Any, off: Int)? {
        guard offset < buf.count, depth <= maxCBORDepth else { return nil }
        let first = buf[offset]
        var off = offset + 1
        let major = Int(first >> 5)
        let info = Int(first & 0x1F)

        func readCount() -> Int? {
            if info <= 23 { return info }
            if info == 24 {
                guard off < buf.count else { return nil }
                let n = Int(buf[off]); off += 1
                return n
            }
            if info == 25 {
                guard off + 1 < buf.count else { return nil }
                let n = (Int(buf[off]) << 8) | Int(buf[off + 1])
                off += 2
                return n
            }
            if info == 26 {
                guard off + 3 < buf.count else { return nil }
                let n = (Int(buf[off]) << 24) | (Int(buf[off + 1]) << 16) | (Int(buf[off + 2]) << 8) | Int(buf[off + 3])
                off += 4
                return n
            }
            return nil
        }

        switch major {
        case 0:
            guard let n = readCount() else { return nil }
            return (n, off)
        case 2:
            guard let n = readCount(), off + n <= buf.count else { return nil }
            let str = String(bytes: buf[off..<(off + n)], encoding: .utf8) ?? ""
            return (str, off + n)
        case 4:
            guard let n = readCount(), n <= maxCBORCollectionCount else { return nil }
            var arr: [Any] = []
            var cursor = off
            for _ in 0..<n {
                guard let item = decodeCBOR(buf, offset: cursor, depth: depth + 1) else { return nil }
                arr.append(item.value)
                cursor = item.off
            }
            return (arr, cursor)
        case 5:
            guard let n = readCount(), n <= maxCBORCollectionCount else { return nil }
            var pairs: [[Any]] = []
            var cursor = off
            for _ in 0..<n {
                guard let k = decodeCBOR(buf, offset: cursor, depth: depth + 1) else { return nil }
                cursor = k.off
                guard let v = decodeCBOR(buf, offset: cursor, depth: depth + 1) else { return nil }
                cursor = v.off
                pairs.append([k.value, v.value])
            }
            return (pairs, cursor)
        case 7:
            if info == 20 { return (false, off) }
            if info == 21 { return (true, off) }
            if info == 22 { return (NSNull(), off) }
            return nil
        default:
            return nil
        }
    }
}
