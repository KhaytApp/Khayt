import Foundation
import KhaytCore

/// Optional numbers and words, read the way the other app reads them.
///
/// ── A RECORD THIS APP CANNOT DECODE IS A RECORD THE SHOP CANNOT SEE ──────
///
/// Every model here is `Decodable`, and a synthesised decoder throws on the
/// first field of the wrong JSON type — `StoreReader.decode` then skips the
/// WHOLE record. A book written by an import, an older build or a hand edit
/// holds `"powerDraw": "150"`, `"cost": "85"`, `"phone": 966500000000`, and
/// the other app reads every one of them (`Number(x)`, `String(x)`). Here the
/// printer, the spool, the customer simply did not exist: not on the shop
/// floor, not in a picker, not editable — and what cannot be opened cannot
/// be corrected either.
///
/// These overloads are picked by every synthesised `init(from:)` in this
/// module (a concrete overload beats the generic one), and by the hand-written
/// ones that call `decodeIfPresent(Double.self, …)`. They only WIDEN: a value
/// of the right type reads exactly as before. A value that still cannot be
/// read as the type asked for reads as absent rather than refusing the record.
///
/// Reading is all this changes. Writing a record back is `RoundTrip`'s job:
/// what an editor did not change goes back to the book in the book's own
/// spelling, so `"150"` stays `"150"` however it was read.
extension KeyedDecodingContainer {

    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let n = try? decode(Double.self, forKey: key) { return n }
        if let s = try? decode(String.self, forKey: key) {
            // `lib/`'s own `num()`: blank is "not set", not nought.
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let n = Double(t), n.isFinite else { return nil }
            return n
        }
        return nil
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        guard let n = try decodeIfPresent(Double.self, forKey: key),
              n.isFinite, abs(n) < Double(Int.max) else { return nil }
        return Int(n)
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let s = try? decode(String.self, forKey: key) { return s }
        // `String(x)` in the other app: a phone number or a VAT number that
        // an import wrote as a number is still that number.
        if let n = try? decode(Double.self, forKey: key) { return JSSemantics.string(n) }
        return nil
    }
}
