import Foundation

/// In-progress spool before POST to desktop inventory.
struct SpoolDraft: Sendable {
    var material: String = ""
    var weightGrams: Int = 1000
    var brand: String = ""
    var colorHex: String = "#888888"
    var sku: String = ""
    var lot: String = ""
    var printTemp: String = ""
    var bedTemp: String = ""
    var sourceNote: String = ""
    /// What the roll cost, as typed. Empty is "not said", which the shop's
    /// own rule books as zero — see `costValue`.
    var cost: String = ""
    /// The product barcode (UPC/EAN) off the box, normalized — see
    /// `ProductBarcode`. Kept on the record so the next box of the same
    /// filament is found on the shelf instead of looked up again.
    var barcode: String = ""
    /// How many identical rolls to book in. Each is its own spool on the
    /// shelf — a job deducts from one roll, not from a pile — so ten boxes
    /// of the same filament are ten records, made in one go.
    var quantity: Int = 1

    static let maxQuantity = 50

    /// The price as a number, or nil when none was given.
    ///
    /// ── WHY THE PHONE ASKS AT ALL ─────────────────────────────────────────
    ///
    /// The desk's build screen prices a job as `spoolCost / spoolWeight x
    /// grams`, and picking a spool copies ITS cost into that box. A roll
    /// booked in without one copies a zero, and every job quoted off it
    /// charged nothing for filament. The companion is where most rolls get
    /// booked in — label, tag, camera — and it never asked.
    ///
    /// Whatever the keypad typed is accepted: a European one sends `75,50`,
    /// an Arabic one `٧٥٫٥٠`. `Double` reads neither, and reading a price as
    /// nothing is exactly how it went missing before.
    var costValue: Double? { Self.price(cost) }

    static func price(_ typed: String) -> Double? {
        var t = ""
        for ch in typed.trimmingCharacters(in: .whitespaces) {
            if let d = ch.wholeNumberValue, ch.isNumber { t.append(String(d)) }
            else if ch == "," || ch == "٫" || ch == "." { t.append(".") }
            else { return nil }
        }
        guard let v = Double(t), v.isFinite, v > 0 else { return nil }
        return v
    }

    static func from(parsed: ParsedFilamentLabel) -> SpoolDraft {
        var d = SpoolDraft()
        d.material = parsed.suggestedMaterial
        d.brand = parsed.brand ?? ""
        if let w = parsed.weightGrams { d.weightGrams = w }
        if let p = parsed.printTemp { d.printTemp = String(p) }
        if let b = parsed.bedTemp { d.bedTemp = String(b) }
        d.sku = parsed.sku ?? ""
        d.lot = parsed.lot ?? ""
        d.sourceNote = L10n.tr("spool.source.label")
        return d
    }

    static func from(tag: NFCFilamentTag) -> SpoolDraft {
        var d = SpoolDraft()
        d.material = InputLimits.clamp(
            tag.materialLabel.isEmpty ? (tag.material ?? "Filament") : tag.materialLabel,
            max: InputLimits.maxMaterial
        )
        d.brand = InputLimits.clamp(tag.manufacturer ?? "")
        if let w = tag.weight { d.weightGrams = min(max(w, 1), 50_000) }
        if let hex = tag.hex { d.colorHex = InputLimits.clamp(hex, max: 32) }
        if let p = tag.printTemp { d.printTemp = String(p) }
        if let b = tag.bedTemp { d.bedTemp = String(b) }
        d.sku = InputLimits.clamp(tag.sku ?? "")
        d.lot = InputLimits.clamp(tag.lot ?? "")
        d.sourceNote = InputLimits.clamp(tag.standard, max: 64)
        return d
    }

    /// The same filament again, from a roll the shop has already booked in.
    ///
    /// Everything the box says is copied — material, brand, colour, the
    /// temperatures, the price last paid — and the size it arrived at rather
    /// than what is left on that roll now. The lot is NOT copied: it is a
    /// fact about one production run, and a new box is usually another.
    static func again(from spool: InventorySpool, barcode: String) -> SpoolDraft {
        var d = SpoolDraft()
        d.material = InputLimits.clamp(spool.material ?? spool.materialType ?? "", max: InputLimits.maxMaterial)
        d.brand = InputLimits.clamp(spool.brand ?? "")
        if let hex = spool.color, !hex.isEmpty { d.colorHex = InputLimits.clamp(hex, max: 32) }
        if let full = spool.initialWeight ?? spool.weight {
            d.weightGrams = min(max(Int(full.rounded()), 1), 50_000)
        }
        if let p = spool.printTemp { d.printTemp = String(p) }
        if let b = spool.bedTemp { d.bedTemp = String(b) }
        d.sku = InputLimits.clamp(spool.sku ?? "")
        if let cost = spool.cost, cost > 0 { d.cost = String(format: "%.2f", cost) }
        d.barcode = barcode
        return d
    }

    static func from(spool: InventorySpool) -> SpoolDraft {
        var d = SpoolDraft()
        d.material = InputLimits.clamp(spool.material ?? spool.materialType ?? "")
        d.brand = InputLimits.clamp(spool.brand ?? "")
        if let w = spool.weight { d.weightGrams = min(max(Int(w.rounded()), 1), 50_000) }
        if let hex = spool.color, !hex.isEmpty { d.colorHex = InputLimits.clamp(hex, max: 32) }
        if let p = spool.printTemp { d.printTemp = String(p) }
        if let b = spool.bedTemp { d.bedTemp = String(b) }
        d.sku = InputLimits.clamp(spool.sku ?? "")
        d.lot = InputLimits.clamp(spool.lot ?? "")
        d.sourceNote = L10n.tr("tab.inventory")
        return d
    }
}
