import Foundation

/**
 * The number printed under the stripes on a box of filament — a GTIN, which is
 * what UPC and EAN both are.
 *
 * ── ONE PRODUCT, SEVERAL SPELLINGS ────────────────────────────────────────
 *
 * The same roll can be read as `012345678905` (UPC-A, 12 digits) or
 * `0012345678905` (EAN-13 — which is what iOS reports a UPC-A as), and a
 * GTIN-14 on the outer carton pads it further. They are one product: GTINs are
 * right-aligned numbers, and leading zeros say nothing. So two codes are the
 * same product when they agree padded to 14 digits, and a roll booked in from
 * a US box is found again when the next one arrives from a European supplier.
 *
 * UPC-E is the 8-digit squeezed form on small packaging. It is expanded to the
 * UPC-A it stands for, because that is the number every database files it
 * under; an 8-digit code that is not UPC-E is an EAN-8 and is left alone.
 *
 * ── THE CHECK DIGIT IS CHECKED ────────────────────────────────────────────
 *
 * A camera that half-reads a barcode produces a plausible number, and a
 * plausible number finds somebody else's product. The last digit exists to
 * catch exactly that, so a code that fails it is refused rather than looked up.
 */
enum ProductBarcode {

    enum Kind: Sendable { case ean13, ean8, upce, unknown }

    /// The code as it should be stored and looked up, or nil when it is not a
    /// valid GTIN. `kind` is what the scanner said it saw, when it said.
    static func normalize(_ raw: String, kind: Kind = .unknown) -> String? {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        // Anything but digits and spacing is not a GTIN — a URL in a QR code,
        // a lot number — and stripping it down to digits would invent one.
        let noise = raw.filter { !($0.isASCII && $0.isNumber) && !$0.isWhitespace && $0 != "-" }
        guard noise.isEmpty else { return nil }

        if kind == .upce || (kind == .unknown && digits.count == 8 && isUPCE(digits)) {
            if let upca = expandUPCE(digits), hasValidCheckDigit(upca) { return upca }
            if kind == .upce { return nil }
        }
        guard [8, 12, 13, 14].contains(digits.count), hasValidCheckDigit(digits) else { return nil }
        return digits
    }

    /// Whether two codes name the same product. See the note above: GTINs are
    /// right-aligned, so they are compared at 14 digits.
    static func sameProduct(_ a: String, _ b: String) -> Bool {
        guard let x = normalize(a), let y = normalize(b) else { return false }
        return padded(x) == padded(y)
    }

    static func padded(_ gtin: String) -> String {
        String(repeating: "0", count: max(0, 14 - gtin.count)) + gtin
    }

    /// The GS1 mod-10 check: weights 3 and 1 alternating from the right,
    /// starting with 3 on the digit next to the check digit.
    static func hasValidCheckDigit(_ digits: String) -> Bool {
        let values = digits.compactMap { $0.wholeNumberValue }
        guard values.count == digits.count, values.count >= 2, let check = values.last else { return false }
        var sum = 0
        for (offset, value) in values.dropLast().reversed().enumerated() {
            sum += value * (offset % 2 == 0 ? 3 : 1)
        }
        return (10 - sum % 10) % 10 == check
    }

    /// An 8-digit code whose number system is 0 or 1 can be UPC-E.
    private static func isUPCE(_ digits: String) -> Bool {
        guard let first = digits.first else { return false }
        return first == "0" || first == "1"
    }

    /// UPC-E to the UPC-A it abbreviates, by the standard's own table.
    static func expandUPCE(_ digits: String) -> String? {
        let d = digits.compactMap { $0.wholeNumberValue }
        guard d.count == 8, d[0] == 0 || d[0] == 1 else { return nil }
        let system = d[0], m = Array(d[1...6]), check = d[7]
        let body: [Int]
        switch m[5] {
        case 0, 1, 2:
            body = [m[0], m[1], m[5], 0, 0, 0, 0, m[2], m[3], m[4]]
        case 3:
            body = [m[0], m[1], m[2], 0, 0, 0, 0, 0, m[3], m[4]]
        case 4:
            body = [m[0], m[1], m[2], m[3], 0, 0, 0, 0, 0, m[4]]
        default:
            body = [m[0], m[1], m[2], m[3], m[4], 0, 0, 0, 0, m[5]]
        }
        return ([system] + body + [check]).map(String.init).joined()
    }
}
