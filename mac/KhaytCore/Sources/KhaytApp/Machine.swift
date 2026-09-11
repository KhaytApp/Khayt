import Foundation
import KhaytCore

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

    /// The camera on this machine, if the shop has set one up.
    ///
    /// Decoded but never DERIVED here: where a camera might live and what a
    /// relative path means against the printer's host are `lib/webcam.js`'s,
    /// asked through the engine. This is only what the book already says.
    let webcam: Webcam?

    /// When this machine is out of action. Three things read it — the band,
    /// the scheduler and the delivery promise — so an unreadable row is not
    /// cosmetic; see `lib/machine-edit.js`.
    let downtimeBlocks: [Downtime]?

    struct Downtime: Decodable, Hashable, Sendable {
        let from: String?
        let to: String?
        /// Khayt's machine modal writes `reason`; `note` is accepted too.
        let reason: String?
        let note: String?
        var words: String { (reason?.isEmpty == false ? reason : note) ?? "" }
    }

    struct Webcam: Decodable, Hashable, Sendable {
        let enabled: Bool?
        let snapshotUrl: String?
        let streamUrl: String?
        /// 0, 90, 180 or 270. A camera zip-tied to a gantry is rarely the right
        /// way up.
        let rotate: Int?
        let flipH: Bool?
        let flipV: Bool?
    }

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
        /// sends one — OctoPrint, PrusaLink and Repetier always need a key —
        /// and opened nowhere else. No screen displays it and none ever should.
        let apiKey: String?
        /// ALSO STILL SEALED — `store-secret-paths.js` registers
        /// `machines[].printerApi.accessCode` alongside the key. A Bambu's LAN
        /// access code is the MQTT password; it is opened at the moment the
        /// connection is made and held nowhere.
        let accessCode: String?
        /// Which Bambu. Every MQTT topic is scoped by it —
        /// `device/{serial}/report` — so without it there is nothing to
        /// subscribe to. Not a secret: it is printed on the machine.
        let serial: String?
        /// Which printer, on a Repetier-Server that runs several. It is in
        /// every request path rather than a header, and `machine-edit.js`
        /// stores an empty string when the shop has not said — which the
        /// adapter reads as `default`, the name Repetier itself uses.
        let printerSlug: String?
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

    /// Is there a camera to draw at all? `lib/webcam.js`'s `hasCamera` in one
    /// line: switched on, and with somewhere to fetch from.
    var hasCamera: Bool {
        guard let webcam, webcam.enabled == true else { return false }
        return !(webcam.snapshotUrl ?? "").isEmpty || !(webcam.streamUrl ?? "").isEmpty
    }

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
    /// What the spool cost, in the shop's currency. This is what left the bank
    /// and it never changes: `vatAmount` below is what a JOB is costed at.
    let cost: Double?
    /// The tax inside that price, when the shop recorded it and can reclaim it.
    /// Absent on every spool bought before Khayt asked, and reclaims nothing —
    /// no tax is invented on a receipt nobody described. See
    /// `KhaytSpoolEdit.netCost`, which is the one place that decides.
    let vatAmount: Double?
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
    /// What this item is counted in — `g`, `ml`, `sheet`. Absent is grams;
    /// `lib/inventory-units.js` decides that and this is the raw field. Prefer
    /// `Shop.unit(of:)`, which knows about a unit a newer Khayt may have
    /// written and this does not.
    let unit: String?
    /// Warn below this many — IN THE UNIT ABOVE. Reorder this many.
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
    /// Takes the catalogue because the unit is in it — `common.grams` is `جم`
    /// in Arabic, so a `g` written here would be an English letter in an Arabic
    /// list — and takes the item's UNIT, because a stack of plywood picked out
    /// of a list read "Birch ply · 6g · Rack by the laser".
    @MainActor func label(_ words: Words, unit: KhaytEngine.InventoryUnit? = nil) -> String {
        let amount = weight.map { " · " + Quantity.say($0, unit, words) } ?? ""
        let where_ = storage.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        return material + amount + where_
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

    /// How much of it is left, 0…1 — and NIL where that is not knowable.
    ///
    /// Same rule as `costPerKilo` and for the same reason: it needs what the
    /// spool weighed when it arrived. A spool bought before Khayt asked has no
    /// record of the other half, and guessing a kilo would draw a half-empty
    /// roll as two-thirds full — a picture that is confidently wrong is worse
    /// than one that does not claim.
    ///
    /// Clamped, because a shop that tops a roll up or mistypes a figure should
    /// get a full spool rather than a ring wider than the flange.
    var fill: Double? {
        guard let left = weight, let original = spoolWeight, original > 0 else { return nil }
        return min(1, max(0, left / original))
    }
}

extension String {
    /// Equal ignoring case and the spaces around it — "Snapmaker U1" and
    /// "snapmaker u1 " are the same printer typed twice.
    func caseInsensitiveEquals(_ other: String) -> Bool {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(other.trimmingCharacters(in: .whitespacesAndNewlines),
                     options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
