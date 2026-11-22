import Foundation

/// Parsed fields from a spool QR/barcode or label text.
struct ParsedFilamentLabel: Sendable {
    var rawText: String
    var materialType: String?
    var brand: String?
    var colorName: String?
    var sku: String?
    var lot: String?
    var weightGrams: Int?
    var printTemp: Int?
    var bedTemp: Int?

    var materialLine: String {
        [brand, materialType, colorName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var suggestedMaterial: String {
        let line = materialLine
        return line.isEmpty ? rawText.trimmingCharacters(in: .whitespacesAndNewlines) : line
    }
}

enum FilamentLabelParser {
    /// Parse one or more lines from label OCR, barcodes, URLs, or JSON in a QR code.
    static func parse(text: String) -> ParsedFilamentLabel {
        let normalized = text.precomposedStringWithCanonicalMapping
        var merged = ParsedFilamentLabel(rawText: normalized)

        for chunk in expandChunks(from: normalized) {
            let part = parsePlainText(chunk)
            merged = merge(merged, with: part)
        }
        return merged
    }

    // MARK: - Chunk expansion (URL, JSON, GS1)

    private static func expandChunks(from text: String) -> [String] {
        var chunks: [String] = [text]
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            chunks.append(line)

            if line.hasPrefix("{") || line.hasPrefix("[") {
                chunks.append(contentsOf: jsonStringChunks(line))
            }

            if let url = URL(string: line), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                chunks.append(url.absoluteString)
                if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    for item in items {
                        if let value = item.value, !value.isEmpty {
                            chunks.append("\(item.name)=\(value)")
                            chunks.append(value)
                        }
                    }
                }
                let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !path.isEmpty { chunks.append(path) }
            }

            if line.contains("(01)") || line.contains("(10)") {
                chunks.append(contentsOf: gs1Chunks(line))
            }
        }
        return chunks
    }

    private static func jsonStringChunks(_ line: String) -> [String] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return flattenJSON(json)
    }

    private static func flattenJSON(_ value: Any, prefix: String = "") -> [String] {
        switch value {
        case let dict as [String: Any]:
            return dict.flatMap { key, val -> [String] in
                let keyLower = key.lowercased()
                let head = prefix.isEmpty ? keyLower : "\(prefix).\(keyLower)"
                var out = flattenJSON(val, prefix: head)
                if let scalar = val as? String, !scalar.isEmpty {
                    out.append("\(keyLower)=\(scalar)")
                    out.append(scalar)
                } else if let n = val as? NSNumber {
                    out.append("\(keyLower)=\(n)")
                }
                return out
            }
        case let array as [Any]:
            return array.flatMap { flattenJSON($0, prefix: prefix) }
        case let s as String where !s.isEmpty:
            return [s]
        case let n as NSNumber:
            return ["\(n)"]
        default:
            return []
        }
    }

    private static func gs1Chunks(_ line: String) -> [String] {
        var out: [String] = []
        let pattern = #"\((\d{2})\)([^\(]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let range = NSRange(line.startIndex..., in: line)
        regex.enumerateMatches(in: line, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 3,
                  let aiRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { return }
            let ai = String(line[aiRange])
            let value = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(value)
            if ai == "10" { out.append("lot=\(value)") }
            if ai == "01" { out.append("gtin=\(value)") }
        }
        return out
    }

    private static func merge(_ base: ParsedFilamentLabel, with part: ParsedFilamentLabel) -> ParsedFilamentLabel {
        var r = base
        if r.materialType == nil { r.materialType = part.materialType }
        if r.brand == nil { r.brand = part.brand }
        if r.colorName == nil { r.colorName = part.colorName }
        if r.sku == nil { r.sku = part.sku }
        if r.lot == nil { r.lot = part.lot }
        if r.weightGrams == nil { r.weightGrams = part.weightGrams }
        if r.printTemp == nil { r.printTemp = part.printTemp }
        if r.bedTemp == nil { r.bedTemp = part.bedTemp }
        return r
    }

    private static func parsePlainText(_ text: String) -> ParsedFilamentLabel {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ParsedFilamentLabel(rawText: t)
        guard !t.isEmpty else { return result }

        for (type, pattern) in materialPatterns {
            if matches(pattern, in: t) { result.materialType = type; break }
        }
        for (brand, pattern) in brandPatterns {
            if matches(pattern, in: t) { result.brand = brand; break }
        }
        for (color, pattern) in colorPatterns {
            if matches(pattern, in: t) { result.colorName = color; break }
        }

        result.sku = extractSKU(from: t) ?? skuFromJSONKeys(t)
        result.lot = extractLot(from: t) ?? lotFromJSONKeys(t)
        result.weightGrams = extractWeightGrams(from: t)
        let temps = extractTemperatures(from: t)
        result.printTemp = temps.print
        result.bedTemp = temps.bed

        return result
    }

    private static func skuFromJSONKeys(_ text: String) -> String? {
        firstCapture(#"(?i)(?:sku|product_?id|item_?id|material_?id|code)[=:"\s]+([A-Za-z0-9][A-Za-z0-9._\-/]{2,})"#, in: text)
    }

    private static func lotFromJSONKeys(_ text: String) -> String? {
        firstCapture(#"(?i)(?:lot|batch|batch_?no|lot_?no)[=:"\s]+([A-Za-z0-9][A-Za-z0-9._\-/]{1,})"#, in: text)
    }

    // MARK: - Extraction

    private static func extractSKU(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:sku|ref(?:erence)?|art(?:icle)?|art\.?\s*no|item|eancode|gtin|product\s*code|model)[\s.#:*\-]*([A-Z0-9][A-Z0-9._\-/]{2,})"#,
            #"(?i)\b([A-Z]{2,5}[-_][A-Z0-9]{3,})\b"#,
            #"(?i)^([0-9]{8,14})$"#
        ]
        for p in patterns {
            if let v = firstCapture(p, in: text) { return v }
        }
        return nil
    }

    private static func extractLot(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:lot|batch|bn|charge|los|partie|lote|losnummer|batch\s*no|lot\s*no|lot\/?batch)[\s.#:*\-]*([A-Za-z0-9][A-Za-z0-9._\-/]{1,})"#,
            #"(?i)(?:دفعة|تشغيلة|رقم\s*الدفعة)\s*[:#]?\s*([A-Za-z0-9\-]+)"#,
            #"(?i)(?:mfg|manufacture)\s*date[^\d]*(\d{4}[-/]\d{2}[-/]\d{2})"#
        ]
        for p in patterns {
            if let v = firstCapture(p, in: text) { return v }
        }
        return nil
    }

    private static func extractWeightGrams(from text: String) -> Int? {
        if let g = firstCapture(#"(?i)(\d{3,4})\s*(?:g|gram|grams|غرام|جرام|г)\b"#, in: text), let n = Int(g) { return n }
        if let kg = firstCapture(#"(?i)([\d.]+)\s*kg\b"#, in: text), let d = Double(kg) { return Int(d * 1000) }
        if let net = firstCapture(#"(?i)net\s*wt\.?\s*([\d.]+)\s*kg"#, in: text), let d = Double(net) { return Int(d * 1000) }
        return nil
    }

    private static func extractTemperatures(from text: String) -> (print: Int?, bed: Int?) {
        if let m = regexFirst(#"(?i)(?:nozzle|print|extr(?:uder)?|hotend|druck|طباعة)[^\d]{0,25}(\d{2,3})\s*°?"#, in: text),
           let p = Int(m[0]), isPlausiblePrintTemp(p) {
            if let b = regexFirst(#"(?i)(?:bed|plate|heated|bett|lit|سرير|سطح)[^\d]{0,25}(\d{2,3})\s*°?"#, in: text).flatMap({ Int($0[0]) }),
               isPlausibleBedTemp(b) {
                return (p, b)
            }
        }

        if let m = regexFirst(#"(?i)(\d{2,3})\s*°?\s*[/\-–]\s*(\d{2,3})\s*°?"#, in: text), m.count >= 2,
           let p = Int(m[0]), let b = Int(m[1]), isPlausiblePrintTemp(p), isPlausibleBedTemp(b) {
            return (p, b)
        }

        if let m = regexFirst(#"(?i)(\d{2,3})\s*[/\-–]\s*(\d{2,3})(?:\s*°|\s*c\b)"#, in: text), m.count >= 2,
           let p = Int(m[0]), let b = Int(m[1]), isPlausiblePrintTemp(p), isPlausibleBedTemp(b) {
            return (p, b)
        }

        var printT: Int?
        var bedT: Int?
        let printPatterns = [
            #"(?i)(?:print|nozzle|extruder|hotend|druck|طباعة|رأس|喷头)\s*[:=]?\s*(\d{2,3})\s*°?"#,
            #"(?i)(\d{2,3})\s*°?\s*c\s*(?:print|nozzle|extr)"#,
            #"(?i)printing\s*temp(?:erature)?\s*[:=]?\s*(\d{2,3})"#
        ]
        let bedPatterns = [
            #"(?i)(?:bed|plate|heated|build\s*plate|bett|lit|platform|سرير|سطح|热床)\s*[:=]?\s*(\d{2,3})\s*°?"#,
            #"(?i)bed\s*temp(?:erature)?\s*[:=]?\s*(\d{2,3})"#,
            #"(?i)(\d{2,3})\s*°?\s*c\s*bed"#
        ]
        for p in printPatterns {
            if let v = firstCapture(p, in: text), let n = Int(v), isPlausiblePrintTemp(n) { printT = n; break }
        }
        for p in bedPatterns {
            if let v = firstCapture(p, in: text), let n = Int(v), isPlausibleBedTemp(n) { bedT = n; break }
        }
        return (printT, bedT)
    }

    private static func isPlausiblePrintTemp(_ n: Int) -> Bool { (150...320).contains(n) }
    private static func isPlausibleBedTemp(_ n: Int) -> Bool { (30...130).contains(n) }

    // MARK: - Patterns (EN + DE + FR + ES + AR + ZH hints on labels)

    private static let materialPatterns: [(String, String)] = [
        ("PLA-CF", #"(?i)pla[\s\-+]?cf"#),
        ("PETG-CF", #"(?i)petg[\s\-+]?cf"#),
        ("PA-CF", #"(?i)pa[\s\-+]?cf|nylon[\s\-+]?cf"#),
        ("PETG", #"(?i)\bpetg\b"#),
        ("TPU", #"(?i)\btpu\b|\btpe\b"#),
        ("ASA", #"(?i)\basa\b"#),
        ("ABS", #"(?i)\babs\b"#),
        ("Nylon", #"(?i)\bnylon\b|\bpa\s*6\b|\bpa6\b|\bpa12\b"#),
        ("HIPS", #"(?i)\bhips\b"#),
        ("PVA", #"(?i)\bpva\b"#),
        ("PLA", #"(?i)\bpla\b"#),
    ]

    private static let brandPatterns: [(String, String)] = [
        ("Bambu Lab", #"(?i)bambu|bambulab"#),
        ("eSun", #"(?i)esun|e-sun"#),
        ("Polymaker", #"(?i)polymaker|poly maker"#),
        ("Creality", #"(?i)creality"#),
        ("SUNLU", #"(?i)sunlu"#),
        ("Prusament", #"(?i)prusament|prusa"#),
        ("Hatchbox", #"(?i)hatchbox"#),
        ("Overture", #"(?i)overture"#),
        ("Fillamentum", #"(?i)fillamentum"#),
        ("ColorFabb", #"(?i)colorfabb|color fabb"#),
    ]

    private static let colorPatterns: [(String, String)] = [
        ("White", #"(?i)\bwhite\b|\bwei[sß]\b|\bblanc\b|\bblanco\b|\bbianco\b|\bأبيض\b|\bابيض\b|白色"#),
        ("Black", #"(?i)\bblack\b|\bschwarz\b|\bnoir\b|\bnegro\b|\bnero\b|\bأسود\b|\bاسود\b|黑色"#),
        ("Red", #"(?i)\bred\b|\brot\b|\brouge\b|\brojo\b|\brosso\b|\bأحمر\b|\bاحمر\b|红色"#),
        ("Orange", #"(?i)\borange\b|\bnaranja\b|\barancione\b|\bبرتقالي\b|橙色"#),
        ("Yellow", #"(?i)\byellow\b|\bgelb\b|\bjaune\b|\bamarillo\b|\bgiallo\b|\bأصفر\b|\bاصفر\b|黄色"#),
        ("Green", #"(?i)\bgreen\b|\bgr[uü]n\b|\bvert\b|\bverde\b|\bأخضر\b|\bاخضر\b|绿色"#),
        ("Blue", #"(?i)\bblue\b|\bblau\b|\bbleu\b|\bazul\b|\bblu\b|\bأزرق\b|\bازرق\b|蓝色"#),
        ("Purple", #"(?i)\bpurple\b|\bviolet\b|\blila\b|\bviola\b|\bبنفسجي\b|\bموف\b|紫色"#),
        ("Pink", #"(?i)\bpink\b|\brosa\b|\brose\b|\bوردي\b|\bزهري\b|粉色"#),
        ("Gray", #"(?i)\bgr[ae]y\b|\bgrau\b|\bgris\b|\bرمادي\b|\bرصاصي\b|灰色"#),
        ("Brown", #"(?i)\bbrown\b|\bbraun\b|\bmarron\b|\bmarr[oó]n\b|\bبني\b|棕色"#),
        ("Gold", #"(?i)\bgold\b|\bdorado\b|\bذهبي\b|金色"#),
        ("Silver", #"(?i)\bsilver\b|\bsilber\b|\bargent\b|\bفضي\b|银色"#),
        ("Clear", #"(?i)\bclear\b|\btransparent\b|\bklar\b|\bشفاف\b|透明"#),
        ("Natural", #"(?i)\bnatural\b|\bnatur\b|\bطبيعي\b|本色"#),
    ]

    private static func matches(_ pattern: String, in text: String) -> Bool {
        regexFirst(pattern, in: text) != nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexFirst(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<m.numberOfRanges).compactMap { i -> String? in
            guard let r = Range(m.range(at: i), in: text), i > 0 else { return nil }
            return String(text[r])
        }
    }
}
