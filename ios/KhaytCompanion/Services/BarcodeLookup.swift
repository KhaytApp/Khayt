import Foundation

/**
 * What filament a scanned box is.
 *
 * ── THE SHELF FIRST ───────────────────────────────────────────────────────
 *
 * The best answer to "what is this box" is the last box of it the shop booked
 * in: the same material name the shop uses, its colour, and the price it paid
 * — which no product database knows. It is also offline, and it is right for
 * the case that is most of a shop's buying: more of what it already uses.
 *
 * A roll is matched by the `barcode` it was booked in with, or by its `sku`
 * when the shop typed a GTIN there before this field existed.
 *
 * ── THEN A PRODUCT DATABASE ───────────────────────────────────────────────
 *
 * For a filament the shop has never had, the code is sent to UPCitemdb's free
 * lookup — the digits and nothing else: no shop, no device, no key. What comes
 * back is a retail title ("SUNLU PLA+ Filament 1.75mm 1kg Black"), and the
 * label parser that already reads spool labels reads it the same way. The
 * public endpoint allows about a hundred lookups a day per address; running
 * out is answered like being offline — the form opens with the barcode filled
 * in, and once saved the next box is found on the shelf.
 *
 * It fills a form. Nothing is saved until the person looking at it says so.
 */
struct BarcodeLookup {

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Found {
        /// The same product is already on the shelf; `from` is the roll copied.
        case onShelf(SpoolDraft, from: InventorySpool)
        /// Not on the shelf; a product database knew it.
        case inDatabase(SpoolDraft, title: String)
        /// Nobody knew it. The draft carries the barcode and nothing else.
        case notFound(SpoolDraft, reason: String)

        var draft: SpoolDraft {
            switch self {
            case .onShelf(let d, _), .inDatabase(let d, _), .notFound(let d, _): return d
            }
        }
    }

    var fetch: Fetch = { try await URLSession.shared.data(for: $0) }

    static let endpoint = "https://api.upcitemdb.com/prod/trial/lookup"

    /// Look a normalized code up — shelf, then database.
    func lookUp(_ code: String, shelf: [InventorySpool]) async -> Found {
        if let roll = Self.onShelf(code, in: shelf) {
            var draft = SpoolDraft.again(from: roll, barcode: code)
            draft.sourceNote = "Barcode · same as a roll already on your shelf"
            return .onShelf(draft, from: roll)
        }
        do {
            if let product = try await productDatabase(code) {
                var draft = Self.draft(fromTitle: product.title, brand: product.brand)
                draft.barcode = code
                draft.sourceNote = "Barcode · \(product.title)"
                return .inDatabase(draft, title: product.title)
            }
            return Self.notFound(code, "Not in the product database. Fill it in once and the next box is found on your shelf.")
        } catch {
            return Self.notFound(code, "The product database could not be reached. Fill it in once and the next box is found on your shelf.")
        }
    }

    /// The newest roll of this product the shop has booked in.
    static func onShelf(_ code: String, in shelf: [InventorySpool]) -> InventorySpool? {
        let matches = shelf.filter { spool in
            if let b = spool.barcode, ProductBarcode.sameProduct(b, code) { return true }
            if let sku = spool.sku, ProductBarcode.sameProduct(sku, code) { return true }
            return false
        }
        // Newest first: the latest box carries the latest price.
        return matches.max { ($0.addedAt ?? $0.purchasedAt ?? "") < ($1.addedAt ?? $1.purchasedAt ?? "") }
    }

    /// A retail title read as a spool label.
    static func draft(fromTitle title: String, brand: String?) -> SpoolDraft {
        var parsed = FilamentLabelParser.parse(text: title)
        if let brand, !brand.trimmingCharacters(in: .whitespaces).isEmpty {
            parsed.brand = brand.trimmingCharacters(in: .whitespaces)
        }
        var draft = SpoolDraft.from(parsed: parsed)
        // `from(parsed:)` falls back to the whole raw text when it finds no
        // material; a retail title is a sentence, not a material name.
        if parsed.materialType == nil, parsed.colorName == nil {
            draft.material = InputLimits.clamp(title, max: InputLimits.maxMaterial)
        }
        draft.lot = ""
        return draft
    }

    private static func notFound(_ code: String, _ reason: String) -> Found {
        var draft = SpoolDraft()
        draft.barcode = code
        draft.sourceNote = "Barcode \(code) · \(reason)"
        return .notFound(draft, reason: reason)
    }

    /// The first product UPCitemdb has for this code, or nil when it has none.
    func productDatabase(_ code: String) async throws -> (title: String, brand: String?)? {
        guard var parts = URLComponents(string: Self.endpoint) else { return nil }
        parts.queryItems = [URLQueryItem(name: "upc", value: code)]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 and 400 are "no such product" / "not a code we take" — answers.
        // Anything else (429 when the day's allowance is spent) is not.
        if status == 404 || status == 400 { return nil }
        guard (200...299).contains(status) else { throw URLError(.badServerResponse) }

        struct Reply: Decodable {
            struct Item: Decodable { let title: String?; let brand: String? }
            let items: [Item]?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let item = reply.items?.first,
              let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return (title, item.brand)
    }
}
