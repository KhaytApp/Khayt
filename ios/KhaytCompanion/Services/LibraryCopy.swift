import Foundation
import KhaytCore

/// The shop's library on the phone, for when the Mac cannot be reached.
///
/// ── WHY ──────────────────────────────────────────────────────────────────
///
/// A customer asks for a price while the owner is out on mobile data. The
/// library routes (`GET /api/library`) need the shop's Wi-Fi, but the library
/// is already on its way to this phone: every whole-book pull from Khayt Cloud
/// carries `printFiles`, and the phone used to throw it away at
/// `BookScope.take`. Now it keeps the part a price needs — a few hundred bytes
/// a model, about 2.5 MB for a ten-thousand-model shop — beside the book.
///
/// ── THE SAME FIGURES THE MAC USES ────────────────────────────────────────
///
/// A model's weight and time come from the slicer when it recorded them
/// (`KhaytPartFromPrintFile.partPatch`, the Mac's rule), and otherwise from
/// its measured geometry — `geometryKey`'s volume and box, and the surface
/// area the overhang check saved — through `estimateMeshes`, which is what the
/// Mac's library runs on the same fields (`LoadFigures.meshInputs`). The price
/// is the phone calculator's, at the shop's default margin, on the spool of
/// the model's material. The one difference from the Mac: a model sliced in
/// several colours is costed on one spool, as the desktop does.
enum LibraryCopy {
    /// The fields a model keeps on the phone. `rev` and `updatedAt` so cloud
    /// changes fold in by the sync's own rule; `licence` and `licenceExpires`
    /// for "Not licensed for sale" on a job (`ModelLicence.saleProblems`).
    static let kept: Set<String> = [
        "id", "rev", "updatedAt", "name", "originalName", "folder", "tags", "category", "material",
        "favorite", "timesPrinted", "lastPrinted", "parsed", "colors", "setups", "consumables",
        "geometryKey", "testedNotes", "sourceFile", "figuresStaleFor", "licence", "licenceExpires",
    ]

    /// Every model the Mac's library shows, slimmed. A model put aside on the
    /// Mac (`archivedAt`) is left out, as the Mac's own list and its
    /// `/api/library` leave it out — the phone's two libraries, at the shop
    /// and away from it, list the same models. Sync carries whole records, so
    /// one brought back on the Mac arrives again with its next change.
    static func slimAll(_ printFiles: JSONValue?) -> [JSONValue] {
        guard case .array(let rows)? = printFiles else { return [] }
        return rows.filter { !isArchived($0) }.compactMap(slim)
    }

    /// The models behind a job that may not be sold today: non-commercial, or
    /// a bought licence past its last day — the Mac's own check
    /// (`ModelLicence.saleProblems`), on the job's parts and this copy. Empty
    /// without a book or a copy: unknown is not no. A phone that reaches the
    /// Mac only on Wi-Fi holds no copy, so says nothing here.
    static func saleProblems(orderId: String, book: CompanionBook, now: Date) -> [ModelLicence.SaleProblem] {
        guard book.exists, let library = book.library(),
              case .array(let rows)? = try? book.read()["printLog"],
              case .object(let order)? = rows.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }), case .array(let parts)? = order["parts"] else { return [] }
        var ids: [String] = []
        for case .object(let p) in parts { if case .string(let id)? = p["printFileId"] { ids.append(id) } }
        return ModelLicence.saleProblems(ids, records: library, today: BookWriter.localDay(now))
    }

    static func isArchived(_ row: JSONValue) -> Bool {
        guard case .object(let o) = row, case .string(let at)? = o["archivedAt"] else { return false }
        return !at.isEmpty
    }

    static func slim(_ row: JSONValue) -> JSONValue? {
        guard case .object(let o) = row, case .string(let id)? = o["id"], !id.isEmpty else { return nil }
        var out = o.filter { kept.contains($0.key) }
        // The surface area the overhang check paid for, without the rest of
        // its analysis.
        if case .object(let risk)? = o["riskAnalysis"], case .number(let a)? = risk["totalAreaMm2"], a > 0 {
            out["areaMm2"] = .number(a)
        }
        return .object(out)
    }

    // MARK: - Reading it as the screen does

    struct Mesh: Equatable { let volume, x, y, z: Double }

    /// `triangles:volume:XxYxZ` (`lib/geometry-key.js`).
    static func mesh(_ key: String?) -> Mesh? {
        guard let parts = key?.split(separator: ":"), parts.count >= 3,
              let volume = Double(parts[1]), volume > 0 else { return nil }
        let box = parts[2].split(separator: "x").compactMap { Double($0) }
        guard box.count == 3, box.allSatisfy({ $0 > 0 }) else { return nil }
        return Mesh(volume: volume, x: box[0], y: box[1], z: box[2])
    }

    static func items(_ rows: [JSONValue]) -> [LibraryItem] { rows.compactMap(item) }

    /// A kept model in the shape `GET /api/library` sends one, so there is
    /// one decoder for both.
    static func item(_ row: JSONValue) -> LibraryItem? {
        guard case .object(let o) = row else { return nil }
        // A new version the Mac has not measured yet: its figures and its
        // shape are the old file's, and the Mac sends none of them (#2077).
        let stale = figuresStale(row)
        let parsed: [String: JSONValue] = stale ? [:] : { if case .object(let p)? = o["parsed"] { return p } else { return [:] } }()
        var shaped: [String: JSONValue] = [:]
        for key in ["id", "folder", "category", "tags", "material", "favorite", "timesPrinted", "lastPrinted", "testedNotes"] {
            if let v = o[key] { shaped[key] = v }
        }
        var title = ""
        if case .string(let n)? = o["name"] { title = n }
        if title.trimmingCharacters(in: .whitespaces).isEmpty, case .string(let n)? = o["originalName"] { title = n }
        shaped["name"] = .string(title)
        var ext = ""
        if case .object(let src)? = o["sourceFile"], case .string(let e)? = src["ext"] { ext = e }
        if ext.isEmpty, case .string(let n)? = o["originalName"], let dot = n.lastIndex(of: ".") {
            ext = String(n[n.index(after: dot)...])
        }
        if !ext.isEmpty { shaped["ext"] = .string(ext.lowercased()) }
        shaped["thumb"] = .bool(false)
        shaped["printTimeMins"] = parsed["printTimeMins"] ?? .null
        shaped["grams"] = parsed["filamentGrams"] ?? .null
        var plates: [JSONValue] = []
        if case .array(let ps)? = parsed["plates"] {
            for case .object(let p) in ps {
                var row: [String: JSONValue] = [:]
                row["index"] = p["index"]; row["name"] = p["name"]
                row["printTimeMins"] = p["printTimeMins"]; row["grams"] = p["filamentGrams"]
                plates.append(.object(row))
            }
        }
        shaped["plates"] = .array(plates)
        let sliced = number(parsed["printTimeMins"]) != nil || number(parsed["filamentGrams"]) != nil
        shaped["estimable"] = .bool(!stale && (sliced || mesh(text(o["geometryKey"])) != nil))
        if stale { shaped["figuresStale"] = .bool(true) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(shaped)) else { return nil }
        return try? JSONDecoder().decode(LibraryItem.self, from: data)
    }

    /// `figuresStaleFor`: the new file's hash, until the Mac re-measures it.
    static func figuresStale(_ row: JSONValue) -> Bool {
        guard case .object(let o) = row, case .string(let hash)? = o["figuresStaleFor"] else { return false }
        return !hash.isEmpty
    }

    private static func text(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s } else { return nil } }
    private static func number(_ v: JSONValue?) -> Double? {
        if case .number(let n)? = v, n.isFinite, n > 0 { return n }
        return nil
    }

    // MARK: - Pricing it here

    /// A model's weight (g) and time (h) for one piece: the slicer's when it
    /// recorded them, else the shape's.
    struct Figures: Equatable {
        let grams: Double
        let hours: Double
        let exact: Bool
        let reliable: Bool
        let material: String?
    }

    static func figures(_ row: JSONValue, plate: Int?, engine: KhaytEngine,
                        settings: [String: JSONValue], orders: [JSONValue]) async -> Figures? {
        guard case .object(var o) = row, !figuresStale(row) else { return nil }
        // One plate: the record as the shared rule reads it, with that plate's
        // own figures in place of the whole file's — the Mac's `modelPart`.
        if let plate {
            guard case .object(var parsed)? = o["parsed"], case .array(let ps)? = parsed["plates"],
                  let p = ps.first(where: { if case .object(let x) = $0 { return number(x["index"]) == Double(plate) } else { return false } }),
                  case .object(let chosen) = p else { return nil }
            parsed["printTimeMins"] = chosen["printTimeMins"] ?? .null
            parsed["filamentGrams"] = chosen["filamentGrams"] ?? .null
            if let t = chosen["filamentType"] { parsed["filamentType"] = t }
            parsed.removeValue(forKey: "plates")
            o["parsed"] = .object(parsed)
        }
        let patch = try? await engine.partFieldsFromFile(.object(o))
        var grams = number(patch?.fields["printWeight"]) ?? 0
        var hours = number(patch?.fields["printTime"]) ?? 0
        let material = text(patch?.fields["material"]) ?? text(o["material"])
        if grams > 0 && hours > 0 {
            return Figures(grams: grams, hours: hours, exact: true, reliable: true, material: material)
        }
        // Not for a plate: one plate's share of the whole shape is not known.
        guard plate == nil, let m = mesh(text(o["geometryKey"])) else { return nil }
        let input = KhaytEngine.MeshInput(volumeMm3: m.volume, areaMm2: number(o["areaMm2"]) ?? 0,
                                          bbox: (x: m.x, y: m.y, z: m.z))
        guard let e = (try? await engine.estimateMeshes([input], settings: settings, orders: orders))?.first ?? nil
        else { return nil }
        if grams <= 0 { grams = e.grams }
        if hours <= 0 { hours = e.hours }
        guard grams > 0 else { return nil }
        return Figures(grams: grams, hours: hours, exact: false, reliable: !e.shellUnreliable, material: material)
    }

    /// The spool a model is costed on: one of its material, else the first
    /// with a price — the Mac's and the desktop's rule.
    static func spool(for material: String?, among spools: [CalculatorShelf.Spool]) -> CalculatorShelf.Spool? {
        let want = (material ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if !want.isEmpty, let same = spools.first(where: { s in
            let m = s.costing.material.lowercased()
            return s.hasPrice && !m.isEmpty && (m == want || want.hasPrefix(m) || m.hasPrefix(want))
        }) { return same }
        return spools.first { $0.hasPrice }
    }

    /// The shop's default margin, as the Mac reads it (`Shop.defaultMargin`).
    static func defaultMargin(_ settings: [String: JSONValue]) -> Double {
        if case .number(let m)? = settings["defaultMargin"], m.isFinite { return m }
        return 30
    }
}
