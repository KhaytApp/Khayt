import Foundation

/// A printer on the shop floor.
///
/// Decoded leniently, like everything else read out of this store. The record is
/// wide — webcam, downtime blocks, per-vendor API settings — and this app shows
/// the part a person standing in front of the machine cares about.
struct Machine: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let name: String
    let color: String?
    let vendor: String?
    let printerModelName: String?
    let compatMaterials: [String]?
    let maxColors: Int?
    let nozzleDiameter: Double?
    let extruderType: String?
    let powerDraw: Double?
    let bed: Bed?
    let nozzle: Nozzle?
    let printerApi: PrinterApi?

    struct Bed: Decodable, Hashable, Sendable {
        let x: Double?
        let y: Double?
        let z: Double?
    }

    struct Nozzle: Decodable, Hashable, Sendable {
        let material: String?
        let installedAt: String?
        let gramsThreshold: Double?
        let gramsAtInstall: Double?
    }

    /// How the app reaches the machine. **The key is never read here**: the
    /// store keeps it encrypted, `SafeStorage` is the only thing that opens it,
    /// and a screen that shows a printer's address has no business decrypting
    /// its credentials to do so.
    struct PrinterApi: Decodable, Hashable, Sendable {
        let type: String?
        let host: String?
        let port: Int?
        /// STILL SEALED. Carried so the poller can open it at the moment it
        /// sends one — OctoPrint and PrusaLink always need a key — and opened
        /// nowhere else. No screen displays it and none ever should.
        let apiKey: String?
    }

    /// Has the machine's own job history been read into the book?
    ///
    /// It is not decoded — five hundred jobs are a wear figure, not something a
    /// screen shows — but whether it is THERE changes what the nozzle counter
    /// means, and a shop is owed that.
    let printerHistory: History?

    struct History: Decodable, Hashable, Sendable {
        let source: String?
        let importedAt: String?
    }

    var hasPrinterHistory: Bool { printerHistory?.importedAt?.isEmpty == false }

    var model: String { printerModelName ?? vendor ?? "" }

    /// `270 × 270 × 270 mm`, or nothing when the record does not say.
    var bedSize: String? {
        guard let bed, let x = bed.x, let y = bed.y, let z = bed.z else { return nil }
        return "\(Int(x)) × \(Int(y)) × \(Int(z)) mm"
    }

    /// Where it can be reached, without the credential.
    var address: String? {
        guard let api = printerApi, let host = api.host, !host.isEmpty else { return nil }
        guard let port = api.port, port > 0 else { return host }
        return "\(host):\(port)"
    }
}

/// A spool on the shelf.
struct Spool: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let material: String
    /// What the spool cost, in the shop's currency.
    let cost: Double?
    /// Grams remaining. The seed rows are whole kilos.
    let weight: Double?
    /// What it weighed when it arrived, written once by `spool-edit.js`.
    /// Absent on every spool bought before that, and unrecoverable.
    let spoolWeight: Double?
    let openedAt: String?
    let storage: String?
    /// What the shop calls this particular colour — "Matte Black" — as opposed
    /// to `color`, which is the swatch a screen draws.
    let colourVariant: String?
    let color: String?
    let materialType: String?
    let lot: String?
    let purchasedAt: String?
    /// Warn below this many grams; reorder this many.
    let reorderPoint: Double?
    let reorderQty: Double?
    let printTemp: Double?
    let bedTemp: Double?
    let maxSpeed: Double?
    /// What this spool cost before, and when it changed. Written by the editor
    /// whenever the price moves, so a shop can check a supplier's invoice.
    let priceHistory: [PriceChange]?

    struct PriceChange: Decodable, Hashable, Sendable {
        let cost: Double
        let date: String
    }

    /// How a shop picks this spool out of a list: what it is, and where — the
    /// two things that tell one 1kg PLA apart from another on the same shelf.
    ///
    /// Takes the catalogue because the gram is in it. `common.grams` is `جم` in
    /// Arabic, so a `g` written here is an English letter in an Arabic list.
    @MainActor func label(_ words: Words) -> String {
        let grams = weight.map { " · \(Int($0))\(words.callIt("common.grams"))" } ?? ""
        let where_ = storage.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        return material + grams + where_
    }

    /// What a kilo of it cost, from what it weighed WHEN IT ARRIVED.
    ///
    /// Never from `weight`, which is what is left and falls as the shop prints:
    /// dividing the price by that made the supplier-comparison figure climb as
    /// the roll emptied — 75 became 150 half way down and 2,000 near the end,
    /// worst on exactly the spool a shop is about to reorder. That version was
    /// deleted rather than fixed, because nothing recorded the original weight
    /// to divide by.
    ///
    /// `spool-edit.js` records it now, so this answers for every spool bought
    /// from that point on and NIL for one already on the shelf. Nil is the
    /// honest answer there: a shop that has used half a roll has no record of
    /// the other half, and a rate worked out from what is left would be the
    /// same wrong number wearing a new comment.
    var costPerKilo: Double? {
        guard let cost, let original = spoolWeight, original > 0 else { return nil }
        return cost / (original / 1000)
    }
}
