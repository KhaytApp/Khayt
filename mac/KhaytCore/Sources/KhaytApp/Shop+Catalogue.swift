import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - Writing a product down

    /// Every product id in the book — how the sheet tells a new one from an edit.
    var productIds: Set<String> {
        Set(productRows.compactMap { Self.recordId($0) })
    }

    static func catalogueLanguages(_ settings: [String: JSONValue],
                                   engine: KhaytEngine?) async -> [Product.LanguageKey] {
        guard let engine, let codes = try? await engine.contentLanguages(settings: settings) else { return [] }
        var out: [Product.LanguageKey] = []
        for code in codes {
            guard let name = try? await engine.fieldKey("name", language: code),
                  let description = try? await engine.fieldKey("description", language: code)
            else { continue }
            let title = (try? await engine.languageName(code)) ?? code
            out.append(Product.LanguageKey(language: code, title: title, name: name, description: description))
        }
        return out
    }

    /// EVERY key a product could hold, not only the shop's current languages.
    ///
    /// A shop that carried French last year still has `name_fr` on its older
    /// products. Reading and writing only today's languages would drop that
    /// text on the first save — deleting the shop's own words as a side effect
    /// of editing the margin.
    func allLanguageKeys() async -> [Product.LanguageKey] {
        var keys = catalogueLanguages
        let known = Set(keys.map(\.language))
        guard let engine, let supported = try? await engine.supportedContentLanguages() else { return keys }
        for code in supported where !known.contains(code) {
            guard let name = try? await engine.fieldKey("name", language: code),
                  let description = try? await engine.fieldKey("description", language: code)
            else { continue }
            keys.append(Product.LanguageKey(language: code, title: code, name: name, description: description))
        }
        return keys
    }

    /// Read one product for editing, with every language key it might carry.
    func productForEditing(_ id: String) async -> Product? {
        guard case .object(let record)? = productRows.first(where: { Self.recordId($0) == id })
        else { return nil }
        return Product.from(record, keys: await allLanguageKeys())
    }

    /// The papers that travel with a job, through the shared rule.
    ///
    /// Empty for a job nobody took from a product, which is most of them — and
    /// for a product with nothing attached.
    func documents(for job: Order) async -> [KhaytEngine.OrderDocument] {
        guard job.productId?.isEmpty == false, let engine else { return [] }
        return (try? await engine.orderDocuments(
            order: .object(["productId": .string(job.productId ?? "")]),
            products: productRows)) ?? []
    }

    // MARK: - Selling a piece off the shelf

    /// Sell something already printed, boxed and counted.
    ///
    /// ── THIS IS A SALE, NOT A JOB ─────────────────────────────────────────
    ///
    /// Every order this app has ever written is work the shop made for
    /// somebody. A piece off the shelf was made weeks ago for nobody in
    /// particular, and handing it across the counter is the moment it becomes
    /// money — so the order is created ALREADY DONE: completed, dated today,
    /// with no machine and nothing to queue.
    ///
    /// ── AND EVERYTHING LANDS ON THE SALE, WHICH IS ONE DECISION ───────────
    ///
    /// Its price, its cost AND its print hours. Cost moving with the sale is
    /// the shop's own choice — it keeps each sale's margin honest and matches
    /// how the catalogue already prices a piece — and the hours have to follow
    /// for the figures to stay true: `lib/cost-trends.js` divides revenue by
    /// hours, so revenue arriving with no hours behind it would inflate what
    /// the shop believes an hour of printing earns. The piece really did take
    /// those hours; they are being recorded when it sold rather than when it
    /// was made.
    ///
    /// The filament is NOT deducted again. It left the shelf when the batch
    /// was printed, and `materialDeducted` stays false on a record that never
    /// consumed anything.
    func sellFromShelf(_ product: Product, count: Int = 1) async {
        guard permitted("orders", "create") else { return }
        guard case .store(let build) = source, let engine, count > 0 else { return }
        let onShelf = stockCount(of: product.id)
        guard let onShelf, onShelf >= count else {
            writeProblem = words.callIt("mac.not_enough_on_shelf"); return
        }

        // COSTED, not just measured — the same call the new-job sheet makes,
        // so a shelf sale carries exactly the cost the catalogue prices with.
        let parts = await jobParts(from: product)
        var input = newJobInput(parts: parts,
                                project: product.anyName(),
                                clientId: nil,
                                margin: product.margin ?? defaultMargin,
                                discountPct: 0, shippingCost: 0, deposit: 0,
                                rush: false, asQuote: false, fromProduct: product,
                                rule: Self.priceRule(of: product))
        input["fromStock"] = JSONValue.bool(true)

        writeProblem = nil
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
            let orders = Self.rows(root, "printLog")
            let out = try await engine.newOrder(
                input, orders: orders, settings: Self.settings(root), now: Date(),
                tokens: (tracking: Self.randomBytes(16), quoteApproval: Self.randomBytes(16)),
                consumables: Self.rows(root, "consumables"))
            guard case .object(var record) = out.order else { return }

            // ALREADY DONE. Nothing about this waits on a machine, so it never
            // sits in the queue: a shelf sale that appears under Pending is a
            // job somebody will go looking for a printer to start.
            let now = StoreWriter.iso(Date())
            record["status"] = .string("completed")
            record["completedAt"] = .string(now)
            record["statusHistory"] = .array([
                .object(["status": .string("completed"), "at": .string(now)]),
            ])
            record["queuePos"] = .null
            record["machineId"] = .null
            record["dueDate"] = .null
            root["printLog"] = .array([.object(record)] + orders)

            // AND THE SHELF IS SMALLER, which the storefront has to be told:
            // it watches its OWN orders and cannot see a piece handed over a
            // counter. Re-dated for the same reason every count is — see
            // `recordStockCount`.
            // The invoice counter the order consumed travels with it, for the
            // reason `createJob` gives: one swap, both records.
            var settings = out.settings
            Self.putStockCount(onShelf - count, for: product.id, into: &settings, at: Date())
            root["settings"] = .object(settings)
            }
        } catch let refusal as MoveRefused {
            writeProblem = refusal.sentence
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// How many of a product this shop has sold off its shelf.
    ///
    /// Khayt's own sales only. A piece bought through the online store is the
    /// storefront's to count — the feed runs one way — so this is what the
    /// shop sold across the counter, and it says so rather than implying it is
    /// the whole picture.
    func soldFromShelf(_ productId: String) -> Int {
        orders.filter { $0.fromStock && $0.productId == productId }.count
    }

    /// The tiers a product offers, as the sheet shows them.
    ///
    /// A NAMED MARGIN, not a price. "Wholesale 20%" replaces the margin on the
    /// sheet and the price follows from the parts, so a tier stays right when
    /// filament gets dearer — which a stored price would not.
    struct PriceTier: Identifiable, Sendable, Hashable {
        var id: String { label + "/" + String(margin) }
        let label: String
        let margin: Double
    }

    static func tiers(of product: Product?) -> [PriceTier] {
        guard case .array(let rows)? = product?.rest["priceTiers"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row,
                  let label = plainString(o["label"])?.trimmingCharacters(in: .whitespaces),
                  !label.isEmpty,
                  let margin = plainNumber(o["margin"]) else { return nil }
            return PriceTier(label: label, margin: margin)
        }
    }

    /// A blank product with an id in Khayt's own shape — `uid('PROD')`, as the
    /// Electron editor mints it, so one written here is indistinguishable.
    func newProduct() -> Product {
        Product(id: Self.uid("PROD"), names: [:], descriptions: [:],
                margin: nil, group: "", category: "",
                createdAt: Self.localDay(), rest: [:])
    }

    /// A product that sells this model, with its first part already filled in.
    ///
    /// ── THE TWO SCREENS DID NOT MEET ───────────────────────────────────────
    ///
    /// The library held 83 models with their weights and print times parsed at
    /// import; the catalogue held products whose parts were typed in by hand.
    /// Nothing joined them, in either direction — and the one product in this
    /// shop's book shows what that costs:
    ///
    ///     "fileRef": "KING-Abdulaziz-ART-200mm-U1_PLA_4h32m.gcode"
    ///
    /// a filename, not a link. `lib/order-file-link.js` opens by naming exactly
    /// that: "an order carried a free-text `fileRef` — a filename somebody
    /// typed — so none of it joined up."
    ///
    /// So the part is filled by `lib/part-from-print-file.js`, which already
    /// does all of it: weight and time from what the slicer measured, material
    /// and layer height from the setup the shop has had most success with, and
    /// `printFileId` — the real join, which is what makes "for THIS part, with
    /// THESE settings, how far out is my estimate?" answerable later.
    ///
    /// `missing` is carried back rather than swallowed. A part the file could
    /// not answer for leaves fields at zero, and a zero that looks typed is
    /// worse than a blank somebody was told about.
    func productFromFile(_ file: LibraryFile) async -> Product? {
        // A MULTI-PLATE FILE is a part per plate, every plate to start with —
        // the sheet's Plates row takes any of them off. "If it's a 3MF with
        // multiple plates I should be able to pick which plate to price, all
        // or specific ones" (the shop, Sep 2026).
        let plateList = plates(of: file)
        var parts: [JSONValue] = []
        var note: String?
        if plateList.isEmpty {
            guard let filled = await partFields(from: file) else { return nil }
            parts = [.object(filled.part)]
            note = filled.note
        } else {
            for p in plateList {
                guard let filled = await partFields(from: file, plate: p.index) else { continue }
                parts.append(.object(filled.part))
                if note == nil { note = filled.note }
            }
            guard !parts.isEmpty else { return nil }
        }
        var product = newProduct()
        // The model's name in every language the catalogue carries — the same
        // name, because a model has one and a shop can correct it on the sheet.
        for key in await allLanguageKeys() {
            product.names[key.language] = file.title
        }
        // What one print of the model uses — magnets, inserts — rides on the
        // first part, so the product counts them once per copy and a job
        // taken from it costs and draws them.
        let uses = CalculatorModel.consumableRows(
            consumablesUsed(by: file.id).map { ($0.consumableId, $0.qty) }, shelf: consumables)
        if !uses.isEmpty, case .object(var first)? = parts.first {
            first["consumables"] = .array(uses)
            parts[0] = .object(first)
        }
        product.rest["parts"] = .array(parts)
        productNote = note
        return product
    }

    /// A library model, as one part of a product — the figures and the note
    /// that goes with them.
    ///
    /// Split out of `productFromFile` so the product sheet can fill a part
    /// from a model the shop CHOOSES, and not only make a whole product from a
    /// model it selected in the library. Reported from the running app: "in
    /// Catalogue I should be able to load the print file to calculate the
    /// price". Same rule both ways round, so a product built either way prices
    /// the same.
    ///
    /// `note` is what the shop has to be told: which figures are estimates
    /// from the geometry rather than measurements, and which are still blank.
    /// The two are different claims and are said separately. Nil when the
    /// file answered for everything.
    /// One plate of a sliced multi-plate 3MF, as the slicer recorded it.
    struct Plate: Equatable, Sendable {
        let index: Int
        let minutes: Double
        let grams: Double
        let material: String
        /// The shop's name for it in the slicer, when it typed one.
        var name: String? = nil
        /// What it uses of each spool, as the slicer recorded it.
        var filaments: [PlateFilament] = []
    }

    struct PlateFilament: Equatable, Sendable {
        let slot: String
        let material: String
        let hex: String?
        let grams: Double
    }

    /// The plates a model's file carries — two or more, or none.
    func plates(of file: LibraryFile) -> [Plate] {
        guard case .object(let r)? = row(for: file.id), case .object(let parsed)? = r["parsed"] else { return [] }
        return Self.plates(parsed: parsed)
    }

    /// The most plates, and filaments on one plate, this reads off a record.
    /// Far above anything a slicer writes; see `lib/mf-convert.js` MAX_PLATES.
    nonisolated static let maxPlates = 256
    nonisolated static let maxPlateFilaments = 64

    /// A figure off the book, as a finite number in `0…max` — or 0.
    ///
    /// `plainNumber` reads strings too, so `"inf"`, `"nan"` and `"1e400"` all
    /// come back as Doubles a crafted file can put in the book.
    static func sane(_ value: JSONValue?, max: Double) -> Double {
        guard let n = plainNumber(value), n.isFinite, n > 0 else { return 0 }
        return Swift.min(n, max)
    }

    /// A shop's text off the book, trimmed and cut to `max` characters.
    static func shortText(_ value: JSONValue?, max: Int) -> String? {
        guard let s = plainString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return String(s.prefix(max))
    }

    /// The plates a record's `parsed` carries.
    ///
    /// ── A CRAFTED INDEX MUST NOT TAKE THE APP DOWN ───────────────────────
    ///
    /// `Int(i)` trapped on a `slice_info` index of 1e20, "inf" or "nan" — and
    /// the value is SAVED in the book, so every later view of the model (the
    /// library inspector, the calculator's From a model, the product sheet)
    /// crashed the app again. An index that is not a whole number in
    /// 1…999,999, or that repeats one already read, is skipped; the figures
    /// are clamped finite; names and materials are cut short.
    static func plates(parsed: [String: JSONValue]) -> [Plate] {
        guard case .array(let rows)? = parsed["plates"] else { return [] }
        var seen = Set<Int>()
        var out: [Plate] = []
        for v in rows.prefix(maxPlates) {
            guard case .object(let o) = v, let i = plainNumber(o["index"]), i.isFinite,
                  i >= 1, i < 1_000_000, i == i.rounded() else { continue }
            let index = Int(saturating: i)
            guard seen.insert(index).inserted else { continue }
            var filaments: [PlateFilament] = []
            if case .array(let fs)? = o["filaments"] {
                for case .object(let f) in fs.prefix(maxPlateFilaments) {
                    filaments.append(PlateFilament(slot: shortText(f["id"], max: 16) ?? "",
                                                   material: shortText(f["type"], max: 40) ?? "",
                                                   hex: shortText(f["color"], max: 16),
                                                   grams: sane(f["grams"], max: 100_000)))
                }
            }
            out.append(Plate(index: index, minutes: sane(o["printTimeMins"], max: 525_600),
                             grams: sane(o["filamentGrams"], max: 100_000),
                             material: shortText(o["filamentType"], max: 40) ?? "",
                             name: shortText(o["name"], max: 80), filaments: filaments))
        }
        guard out.count > 1 else { return [] }
        // Only while they add up to the file's own totals: a file re-read by
        // the other app (totals rewritten, `plates` kept) or re-sliced since
        // is priced as a whole rather than from plates that no longer match.
        let mins = Self.plainNumber(parsed["printTimeMins"]) ?? 0
        let grams = Self.plainNumber(parsed["filamentGrams"]) ?? 0
        let sumMins = out.reduce(0) { $0 + $1.minutes }, sumGrams = out.reduce(0) { $0 + $1.grams }
        guard abs(sumMins - mins) <= Double(out.count), abs(sumGrams - grams) <= Double(out.count) * 0.2 else { return [] }
        return out
    }

    func partFields(from file: LibraryFile, plate: Int? = nil) async -> (part: [String: JSONValue], note: String?)? {
        productProblem = nil
        guard let engine, var rec = row(for: file.id) else {
            productProblem = words.callIt("mac.not_found"); return nil
        }
        // ONE PLATE: the record as the shared rule reads it, with that plate's
        // own figures in place of the whole file's.
        if let plate, let p = plates(of: file).first(where: { $0.index == plate }),
           case .object(var r) = rec {
            var parsed: [String: JSONValue] = [:]
            if case .object(let o)? = r["parsed"] { parsed = o }
            parsed["printTimeMins"] = .number(p.minutes)
            parsed["filamentGrams"] = .number(p.grams)
            if !p.material.isEmpty { parsed["filamentType"] = .string(p.material) }
            parsed.removeValue(forKey: "plates")
            r["parsed"] = .object(parsed)
            rec = .object(r)
        }
        guard let patch = try? await engine.partFieldsFromFile(rec) else {
            productProblem = words.callIt("mac.product_from_file_failed"); return nil
        }

        var part = patch.fields
        // The part's name is the model's, which is what a shop would have
        // typed. Everything else on it came from the file.
        part["name"] = .string(file.title)
        if let plate {
            part["name"] = .string(words.callIt("mac.plate_part", ["name": .string(file.title), "n": .number(Double(plate))]))
            part["plate"] = .number(Double(plate))
        }
        // `qty`, NOT `quantity`. Every consumer reads `qty` — the calculator's
        // per-part cost, the packaging split, the price tiers, the specs the
        // catalogue row shows — so `quantity` is a field nothing reads, with
        // the real one absent beside it.
        //
        // Benign only by accident: `Math.max(1, +part.qty || 1)` falls back to
        // one, and the value written here was always one. It would have stopped
        // being benign the moment anything wrote a different number.
        part["qty"] = .number(1)

        // ── WHAT THE FILE COULD NOT ANSWER, THE GEOMETRY OFTEN CAN ────────
        //
        // A shop's library is mostly UNSLICED models — the file this was found
        // on is a 15 MB 3MF with no weight, no time and no material recorded,
        // because nothing has sliced it yet. `partPatch` correctly reports both
        // as missing, and the product was then written with neither, which is
        // honest and not much use: a product with no weight has no cost, so it
        // has no price.
        //
        // This app can MEASURE the mesh and price it at the shop's OWN measured
        // rate, which the other app cannot do at all. So where the file cannot
        // answer, the geometry does — and the answer is LABELLED, because an
        // estimate that looks typed is the same bug as a zero that looks typed.
        var estimated: [String] = []
        if let e = estimates[file.id] {
            if Self.plainNumber(part["printWeight"]) ?? 0 <= 0, e.grams > 0 {
                part["printWeight"] = .number(e.grams)
                estimated.append(words.callIt("mac.weight"))
            }
            if Self.plainNumber(part["printTime"]) ?? 0 <= 0, e.hours > 0 {
                part["printTime"] = .number(e.hours)
                estimated.append(words.callIt("common.hours"))
            }
        }

        // Said plainly, and only when there is something to say.
        //
        // The ESTIMATED fields are named first and separately from the ones
        // still blank. They are different claims: one is a figure this app
        // worked out and stands behind, the other is a gap the shop has to
        // fill. Rolling them into one sentence would make the estimate sound
        // like a measurement, which is exactly what it is not.
        var note: String?
        if !estimated.isEmpty {
            let e = estimates[file.id]
            note = words.callIt(
                e?.isCalibrated == true ? "mac.product_estimated_calibrated"
                                        : "mac.product_estimated",
                ["fields": .string(estimated.joined(separator: ", ")),
                 "n": .number(Double(e?.jobs ?? 0))])
        }
        // ── WHAT IT COSTS TO MAKE, NOT ONLY WHAT IT WEIGHS ────────────────
        //
        // A part from the library carried the file's weight and time and
        // nothing else — no filament, no labour, no power, no wear, no
        // failure allowance — so the catalogue priced it at NOTHING: "it is
        // not calculating the price" (the shop, Sep 2026, on a 200 g, 9.5 h
        // model saved at 0). The product sheet gives a part it composes the
        // shop's rate defaults, but a part that ARRIVES from the library was
        // treated as an existing one and left blank. So they are filled here,
        // where every way from the library to the catalogue passes.
        if let defaults = try? await engine.printRateDefaults(settings: settingsDict) {
            for (key, value) in defaults where part[key] == nil { part[key] = .number(value) }
        }
        var costedWith: String?
        if part["filamentId"] == nil, let spool = Self.spool(for: part, file: rec, among: spools) {
            part["filamentId"] = .string(spool.id)
            part["material"] = .string(spool.material)
            part["spoolCost"] = .number(spool.cost ?? 0)
            part["spoolWeight"] = .number(max(1, spool.spoolWeight ?? 1000))
            costedWith = spool.material
        }

        let stillMissing = patch.missing.filter { field in
            Self.plainNumber(part[field]).map { $0 <= 0 } ?? true
        }
        if !stillMissing.isEmpty {
            let gap = words.callIt("mac.product_from_file_missing",
                                   ["fields": .string(stillMissing.joined(separator: ", "))])
            // APPENDED, not assigned: with two sentences, assigning wiped the
            // estimate note whenever nothing was left missing — the good case,
            // and the one where the shop most needs telling.
            note = note.map { $0 + " " + gap } ?? gap
        }
        if let costedWith {
            let said = words.callIt("mac.product_costed_with", ["spool": .string(costedWith)])
            note = note.map { $0 + " " + said } ?? said
        }
        return (part, note)
    }

    /// The spool a library part is costed with: the shop's spool of the
    /// material the slicer used, or — when the file says none, or the shop
    /// stocks none of it — its first costed spool, and the note says which.
    static func spool(for part: [String: JSONValue], file: JSONValue, among spools: [Spool]) -> Spool? {
        let costed = spools.filter { ($0.cost ?? 0) > 0 }
        guard !costed.isEmpty else { return nil }
        var wanted = plainString(part["material"]) ?? ""
        if wanted.isEmpty, case .object(let r) = file, case .object(let parsed)? = r["parsed"] {
            wanted = plainString(parsed["filamentType"]) ?? ""
        }
        let w = wanted.lowercased().trimmingCharacters(in: .whitespaces)
        if !w.isEmpty, let match = costed.first(where: {
            let m = ($0.materialType ?? $0.material).lowercased()
            return m == w || m.hasPrefix(w + " ") || m.hasPrefix(w + "+") || $0.material.lowercased().hasPrefix(w)
        }) { return match }
        return costed[0]
    }

    /// Open the product sheet on a product made from the selected model — or,
    /// with several selected, one product with each of them as a part.
    func productFromSelection() async {
        let chosen = selectedFiles
        if chosen.count > 1 {
            if let product = await productFromFiles(chosen, name: nil) { editingProduct = product }
        } else if let one = selectedFile ?? chosen.first {
            if let product = await productFromFile(one) { editingProduct = product }
        }
    }

    /// ONE product made of several models, each a part — a set, a kit, a
    /// project folder. Asked for by the shop (Sep 2026): "I should be able to
    /// add to the catalogue using the library". Each part is filled by the
    /// same rule as a single model (`partFields`), so a product built this way
    /// prices the same as one built part by part on the sheet.
    ///
    /// `name` is the product's name; nil takes the first model's. The notes
    /// about estimated or missing figures are kept, one per part, because a
    /// part the file could not answer for is still a part the shop must fill.
    func productFromFiles(_ files: [LibraryFile], name: String?) async -> Product? {
        guard !files.isEmpty else { return nil }
        var parts: [JSONValue] = []
        var notes: [String] = []
        for file in files {
            guard let filled = await partFields(from: file) else { continue }
            parts.append(.object(filled.part))
            if let note = filled.note { notes.append(file.title + ": " + note) }
        }
        guard !parts.isEmpty else { return nil }
        var product = newProduct()
        let title = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? files[0].title
        for key in await allLanguageKeys() { product.names[key.language] = title }
        product.rest["parts"] = .array(parts)
        productNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
        return product
    }

    /// A product for EACH of these models, written straight to the catalogue —
    /// for a shop adding a shelf of things it already sells. Each is priced by
    /// the shared rule as it is saved; the shop opens any of them to adjust.
    func addEachToCatalogue(_ files: [LibraryFile]) async {
        productProblem = nil
        var added = 0
        for file in files {
            guard let product = await productFromFile(file),
                  case .array(let parts)? = product.rest["parts"] else { continue }
            await saveProduct(product, parts: parts)
            if moveProblem == nil { added += 1 } else { break }
        }
        productNote = nil
        importNote = words.callIt("mac.catalogue_added_each", ["n": .number(Double(added))])
    }

    /// Every model in a project folder, at any depth under it.
    func files(inFolder path: String) -> [LibraryFile] {
        files.filter { Self.isUnder($0.groupName, path) }
    }

    /// A project folder as one product, named after the folder.
    func productFromFolder(_ path: String) async {
        let name = path.components(separatedBy: ImportGrouping.separator).last ?? path
        if let product = await productFromFiles(files(inFolder: path), name: name) { editingProduct = product }
    }

    /// Write it down. Follows `saveCustomer` exactly, including the undo.
    /// What this shop has actually realized on jobs like this one.
    ///
    /// NO MODEL IS INVOLVED. `buildComparables` is arithmetic over the shop's
    /// own finished jobs — so this needs no key, no consent and no network, and
    /// a shop that will never switch the assistant on still gets it.
    ///
    /// `settings` is passed because the margins are NET OF TAX: for an
    /// inclusive-VAT shop part of every price was the tax authority's and was
    /// never revenue, and a median computed on the gross is one a shop would
    /// price against and come out thin.
    func priceComparables(material: String) async -> KhaytEngine.PriceComparables? {
        guard let engine else { return nil }
        return try? await engine.priceComparables(orders: orderRows, material: material,
                                                  settings: settingsDict)
    }

    /// The same answer, unparsed — what the model is shown when asked to weigh
    /// it. Kept as the raw value rather than re-encoding the decoded struct,
    /// because the rule's own shape is what its prompt builder expects and a
    /// Swift round-trip is a chance to lose a field.
    func priceComparablesRaw(material: String) async -> JSONValue? {
        guard let engine else { return nil }
        return try? await engine.rawPriceComparables(orders: orderRows, material: material,
                                                     settings: settingsDict)
    }

    /// Price a product from the parts the sheet is holding.
    ///
    /// Through the shared rule, which is what `renderer/inventory.js` now
    /// prices with too. A product's price is COMPUTED — the calculator's
    /// per-part cost, the components, the margin, the shop's rounding — and two
    /// apps computing it separately is two prices for one product, with the one
    /// the customer sees decided by which app last saved it.
    /// What a part is costed at before anybody types anything — the shared
    /// rule's own figures, so a product made here is priced the way the other
    /// app would price it. See `ProductSheet.PartRow.rates`.
    func printRateDefaults() async -> [String: String]? {
        guard let engine, let defaults = try? await engine.printRateDefaults(settings: settingsDict) else { return nil }
        return defaults.mapValues { Money.fieldValue($0) }
    }

    /// One of those figures, as a number — `settings: [:]` for Khayt's own,
    /// before the shop's tariff.
    func printRateDefault(_ key: String, settings: [String: JSONValue]? = nil) async -> Double? {
        guard let engine else { return nil }
        return (try? await engine.printRateDefaults(settings: settings ?? settingsDict))?[key]
    }

    func priceProduct(parts: [JSONValue], margin: Double?,
                      components: JSONValue?, rule: PriceRule = PriceRule()) async -> KhaytEngine.ProductPricing? {
        guard let engine else { return nil }
        var record: [String: JSONValue] = ["parts": .array(parts)]
        if let margin { record["defaultMargin"] = .number(margin) }
        if let components { record["components"] = components }
        for (key, value) in rule.fields { record[key] = value }
        return try? await engine.priceProduct(.object(record),
                                              inventory: inventoryRows,
                                              settings: settingsDict,
                                              consumables: consumableRows)
    }

    /// A recommended margin, with the reason for it.
    struct PriceAdvice: Sendable {
        var margin: Double
        var rationale: String
    }

    /// Advice or a sentence. Not `Result<_, String>` — `String` is not an
    /// `Error`, and inventing an error type for something the shop simply has
    /// to READ buys nothing.
    enum PriceOutcome: Sendable {
        case advised(PriceAdvice)
        case refused(String)
    }

    /// Ask the model to weigh this shop's own comparables.
    ///
    /// The comparables are already on screen — computed here, net of tax, with
    /// nothing sent anywhere. This is the optional second opinion over them.
    func recommendMargin(comparables: KhaytEngine.PriceComparables,
                         raw: JSONValue, cost: Double, grams: Double,
                         hours: Double, material: String) async
        -> PriceOutcome {
        let job = JSONValue.object([
            "material": .string(material), "grams": .number(grams),
            "hours": .number(hours), "cost": .number(cost),
            "currency": .string(currency),
        ])
        do {
            let out = try await AiClient.recommendMargin(
                comparables: raw, job: job,
                fallback: comparables.suggestedMargin, shop: self)
            guard out.ok, let margin = out.suggestedMargin else {
                return .refused(out.problem ?? words.callIt("mac.ai_no_draft"))
            }
            return .advised(PriceAdvice(margin: margin,
                                        rationale: out.rationale ?? ""))
        } catch AiClient.Failure.notConsented {
            return .refused(words.callIt("mac.ai_price_not_consented"))
        } catch AiClient.Failure.noKey {
            return .refused(words.callIt("mac.ai_no_key"))
        } catch {
            return .refused(String(describing: error))
        }
    }

    // MARK: - Several prints that are one object

    /// The kit this job is filed under, if any.
    func kit(of id: Order.ID) -> KhaytEngine.PrintKit? {
        kits.first { $0.jobIds.contains(id) }
    }

    /// Read the kits back after the book changed. Called from `load`.
    func readKits(_ root: [String: JSONValue]) async {
        if case .array(let rows)? = Self.settings(root)["kits"] { kitDefs = rows }
        else { kitDefs = [] }
        kits = (try? await engine?.kits(orders: orderRows, defs: kitDefs)) ?? []
    }

    /// File every job named under one kit, creating it if the name is new.
    ///
    /// ONE WRITE for all of them, and the settings change in the same write:
    /// a kit whose definition reached the book while its jobs did not is a
    /// name attached to nothing, and the reverse is an orphan. Both are
    /// recoverable and neither should be produced by a crash in the middle.
    func fileJobs(_ ids: [Order.ID], inKitNamed name: String) async {
        guard !ids.isEmpty, let build = source.build, let engine else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // Through the engine, so a name matching one the shop already uses IS
        // that kit rather than a second one holding half the rollup.
        guard let resolved = try? await engine.resolveKitName(
            clean, known: kitDefs, newId: Self.mintKitId(clean)) else {
            writeProblem = words.callIt("mac.kit_unknown"); return
        }
        await writeKits(build, named: words.callIt("mac.file_in", ["name": .string(resolved.name)])) { root in
            var settings = Self.settings(root)
            var defs = Self.kitRows(settings)
            if !defs.contains(where: { Self.recordId($0) == resolved.id }) {
                defs.append(.object(["id": .string(resolved.id), "name": .string(resolved.name)]))
            }
            settings["kits"] = .array(defs)
            root["settings"] = .object(settings)
            Self.stampKit(&root, ids: Set(ids), to: resolved.id)
        }
    }

    // MARK: - What is already printed and on the shelf

    /// How many of a product the shop has printed, boxed and counted.
    ///
    /// ── THE SHOP OWNS THE COUNT; THE STOREFRONT OWNS WHAT IS LEFT ─────────
    ///
    /// Khayt says how many were COUNTED. The storefront says how many remain,
    /// because it is the thing watching orders. Re-applying Khayt's figure on
    /// every poll would resurrect units somebody had already bought — which is
    /// why `stockCountedAt` exists beside the number and why the number alone
    /// is not enough to decide with. A shop that sells three, prints three and
    /// re-counts publishes the same figure, and a comparison of numbers reads
    /// that as nothing having happened.
    ///
    /// Kept in `settings.storefront`, in the two maps the other app already
    /// writes — one contract, and deliberately NOT a field on the product
    /// record. `Product` is re-encoded whole on save, and this app has already
    /// dropped a product's part costs and re-priced it 50 → 13.74 that way; a
    /// count that lives outside that record cannot be lost to it.
    ///
    /// TWO MAPS RATHER THAN ONE, which is the other app's reasoning kept: a
    /// build that merges whole records cannot then half-write a count with
    /// somebody else's timestamp attached to it.
    func stockCount(of productId: String) -> Int? {
        Self.stockCount(of: productId, in: settingsValue)
    }

    /// The read, as a function of the settings alone — so the contract with
    /// the other app can be exercised without a book on disk.
    static func stockCount(of productId: String, in settings: JSONValue) -> Int? {
        guard case .object(let settings) = settings,
              case .object(let store)? = settings["storefront"],
              case .object(let counts)? = store["stockQty"],
              case .number(let n)? = counts[productId] else { return nil }
        // EMPTY IS NOT ZERO, which is the other app's own words for it: empty
        // means the shop does not stock this piece and a storefront must leave
        // its inventory alone entirely; zero means it stocks it and the batch
        // has sold out, which is a state it reverses next week. Reading one as
        // the other moves a customer's quoted date by weeks in whichever
        // direction is wrong.
        return Int(n)
    }

    /// When the shop last counted it. A storefront re-applies a figure only
    /// when this moves, so it is the half that makes the number safe to send.
    func stockCountedAt(of productId: String) -> String? {
        Self.stockCountedAt(of: productId, in: settingsValue)
    }

    static func stockCountedAt(of productId: String, in settings: JSONValue) -> String? {
        guard case .object(let settings) = settings,
              case .object(let store)? = settings["storefront"],
              case .object(let when)? = store["stockCountedAt"],
              case .string(let at)? = when[productId], !at.isEmpty else { return nil }
        return at
    }

    /// Record a count. Dated whenever the shop SAYS so, including when the
    /// number has not moved.
    ///
    /// That is the whole point and it is easy to get backwards: dating it on
    /// CHANGE reproduces the exact bug the field exists to fix — sell three,
    /// print three, re-count to the same figure, and the storefront is told
    /// nothing happened and keeps under-selling the shelf. So this is called
    /// from the counting sheet and from nowhere else, and never from a product
    /// save, which would re-assert every count whenever somebody opened a
    /// product to edit its price.
    ///
    /// Nil clears both, for a product that is no longer stocked. Zero is NOT
    /// nil: zero is a count, and a shop that has counted a shelf and found it
    /// empty has said something.
    func recordStockCount(_ count: Int?, for productId: String) async {
        guard case .store(let build) = source, !productId.isEmpty else { return }
        await writeKits(build, named: words.callIt("mac.stock_counted")) { root in
            var settings = Self.settings(root)
            Self.putStockCount(count, for: productId, into: &settings, at: Date())
            root["settings"] = .object(settings)
        }
    }

    /// The write, as a transform on the settings — testable, and the only
    /// place the shape of the two maps is decided.
    ///
    /// MERGED, not rebuilt. The other app reconstructs both maps from the
    /// dialog it just showed, which is right there because the dialog holds
    /// every product; here one product is being counted and the rest must be
    /// left exactly as they were.
    static func putStockCount(_ count: Int?, for productId: String,
                              into settings: inout [String: JSONValue], at now: Date) {
        var store: [String: JSONValue] = [:]
        if case .object(let existing)? = settings["storefront"] { store = existing }
        var counts: [String: JSONValue] = [:]
        if case .object(let existing)? = store["stockQty"] { counts = existing }
        var when: [String: JSONValue] = [:]
        if case .object(let existing)? = store["stockCountedAt"] { when = existing }

        if let count {
            counts[productId] = .number(Double(max(0, count)))
            // DATED ON EVERY CALL, because every call is a shop saying it
            // counted. See the note on `recordStockCount`.
            when[productId] = .string(StoreWriter.iso(now))
        } else {
            counts.removeValue(forKey: productId)
            when.removeValue(forKey: productId)
        }
        store["stockQty"] = .object(counts)
        store["stockCountedAt"] = .object(when)
        settings["storefront"] = .object(store)
    }

    /// Kit names one or two edits from this one, to ask about before filing.
    ///
    /// Asked by the view rather than inside `fileJobs`, because the answer is a
    /// QUESTION for the shop and not a decision this app may make: "Leg L" and
    /// "Leg R" are one edit apart and genuinely different.
    func nearKits(_ name: String) async -> [KhaytEngine.NearKitName] {
        guard let engine else { return [] }
        return (try? await engine.similarKitNames(name, known: kitDefs)) ?? []
    }

    /// Take jobs back out.
    ///
    /// Grouping after the fact means grouping the wrong things sometimes, and
    /// until this existed the only correction was disbanding the whole kit —
    /// which is why anyone would rather leave it wrong.
    ///
    /// A definition left pointing at nothing goes with them. The jobs are what
    /// a kit IS; with none left there is nothing to keep, and the name is
    /// clutter the shop reads past every time it files something.
    func unfileJobs(_ ids: [Order.ID]) async {
        guard !ids.isEmpty, let build = source.build else { return }
        await writeKits(build, named: words.callIt("mac.remove_from_kit")) { root in
            Self.stampKit(&root, ids: Set(ids), to: nil)
        }
        await sweepEmptyKits()
    }

    /// Drop kit names no job points at any more.
    ///
    /// A SECOND transaction, after the jobs have moved and the book has been
    /// read back, because the rule that answers this is asynchronous and the
    /// store write is not. That is the right way round anyway: taking jobs out
    /// is the shop's action, and sweeping up a name attached to nothing is a
    /// tidy-up. A crash between the two leaves an empty kit name — which is
    /// exactly the state `lib/print-kits.js` chose to report rather than act
    /// on, and one more filing puts it back to work.
    private func sweepEmptyKits() async {
        guard let build = source.build, let engine, !kitDefs.isEmpty else { return }
        let dead = Set((try? await engine.emptyKitIds(orders: orderRows, defs: kitDefs)) ?? [])
        guard !dead.isEmpty else { return }
        await writeKits(build, named: words.callIt("mac.remove_from_kit")) { root in
            var settings = Self.settings(root)
            settings["kits"] = .array(Self.kitRows(settings)
                .filter { !dead.contains(Self.recordId($0) ?? "") })
            root["settings"] = .object(settings)
        }
    }

    /// Rename a kit — and ADOPT an orphan.
    ///
    /// A kit whose definition was deleted still groups its jobs, and there was
    /// no way back: the jobs were stuck in something unnameable. Naming one
    /// writes the definition again.
    ///
    /// Refuses a name another kit already holds rather than merging into it.
    /// Merging would move somebody else's jobs on the strength of a typo, and
    /// "reuse the kit with this name" is a rule that belongs to FILING, where
    /// the shop has just chosen which jobs are involved.
    func renameKit(_ kitId: String, to name: String) async {
        guard let build = source.build else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let folded = clean.lowercased()
        if let taken = kitDefs.first(where: {
            Self.recordId($0) != kitId && Self.kitName($0)?.lowercased() == folded
        }), let other = Self.kitName(taken) {
            writeProblem = words.callIt("mac.kit_name_taken", ["name": .string(other)])
            return
        }
        await writeKits(build, named: words.callIt("mac.rename_kit")) { root in
            var settings = Self.settings(root)
            var defs = Self.kitRows(settings)
            if let at = defs.firstIndex(where: { Self.recordId($0) == kitId }) {
                guard case .object(var def) = defs[at] else { return }
                def["name"] = .string(clean)
                defs[at] = .object(def)
            } else {
                // The orphan, adopted.
                defs.append(.object(["id": .string(kitId), "name": .string(clean)]))
            }
            settings["kits"] = .array(defs)
            root["settings"] = .object(settings)
        }
    }

    /// Take every job out of a kit and forget the kit. The prints are untouched.
    func disbandKit(_ kitId: String) async {
        guard let build = source.build else { return }
        let ids = Set(kits.first { $0.id == kitId }?.jobIds ?? [])
        await writeKits(build, named: words.callIt("mac.disband_kit")) { root in
            Self.stampKit(&root, ids: ids, to: nil)
            var settings = Self.settings(root)
            let defs = Self.kitRows(settings)
            settings["kits"] = .array(defs.filter { Self.recordId($0) != kitId })
            root["settings"] = .object(settings)
        }
    }

    /// Put `kitId` on some jobs, or take it off, stamping only what changed.
    ///
    /// REMOVED rather than set to an empty string. `groupByKit` reads the field
    /// with a trim and treats blank as ungrouped, so an empty string would work
    /// — right up until the record syncs to a machine running a build that
    /// checks the key's presence instead.
    static func stampKit(_ root: inout [String: JSONValue],
                                 ids: Set<String>, to kitId: String?) {
        guard !ids.isEmpty, case .array(var rows)? = root["printLog"] else { return }
        var touched = false
        for i in rows.indices {
            guard case .object(var record) = rows[i],
                  let id = recordId(rows[i]), ids.contains(id) else { continue }
            let was = record["kitId"]
            if let kitId { record["kitId"] = .string(kitId) } else { record["kitId"] = nil }
            guard record["kitId"] != was else { continue }
            StoreWriter.stamp(&record)
            rows[i] = .object(record)
            touched = true
        }
        guard touched else { return }
        root["printLog"] = .array(rows)
    }

    /// The shared shape of every kit edit: one guarded write, then re-read.
    ///
    /// `named` is carried for the Edit menu's benefit the day these become
    /// undoable; the write itself is one transaction either way.
    private func writeKits(_ build: StoreReader.Build, named actionName: String,
                           change: @escaping (inout [String: JSONValue]) -> Void) async {
        // Kits are stock; every kit change asks the one area (the staff lock).
        guard permitted("inventory", "edit") else { writeProblem = moveProblem; return }
        do {
            try StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in change(&root) }
            writeProblem = nil
            await load(source)
        } catch {
            writeProblem = String(describing: error)
        }
    }

    /// A kit id from the name the shop typed, salted so two kits called the
    /// same thing on two machines do not collide into one after a sync.
    ///
    /// ── AND IT IS `uid`, NOT A STRING BUILT HERE ──────────────────────────
    ///
    /// Twice now this was written inline and twice `WordsAreTranslatedTests`
    /// refused it. That guard flags any short literal carrying an
    /// interpolation, because that is the shape of a unit written in Swift
    /// where the catalogue has a word for it — `"\(n) kg"` — and it cannot
    /// tell one from an id prefix. First it caught the English fallback "kit";
    /// with that gone it caught "KIT-" itself.
    ///
    /// The guard is not wrong either time, and the answer was already in this
    /// file: every other id in the app comes from `uid(_:)`, which takes the
    /// prefix as an ARGUMENT so no literal ever sits next to an interpolation.
    /// A kit id is an id like any other and had no business being special.
    ///
    /// The slug is still worth having — `KIT-dragon-…` is readable in a store
    /// somebody is debugging — and is dropped when the name leaves nothing,
    /// which is most Arabic names, since it keeps only ASCII.
    private static func mintKitId(_ name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let trimmed = slug.split(separator: "-").prefix(4).joined(separator: "-")
        return trimmed.isEmpty ? uid("KIT") : uid("KIT-" + trimmed)
    }

    private static func kitName(_ value: JSONValue) -> String? {
        guard case .object(let o) = value, case .string(let n)? = o["name"] else { return nil }
        return n
    }

    /// `settings.kits` — a collection that lives INSIDE settings rather than
    /// at the root, which is why `Shop.rows` cannot reach it.
    private static func kitRows(_ settings: [String: JSONValue]) -> [JSONValue] {
        if case .array(let rows)? = settings["kits"] { return rows }
        return []
    }

    func orderRow(_ id: Order.ID) -> JSONValue? {
        orderRows.first { Self.recordId($0) == id }
    }

    /// The tasks, set directly — for tests of what the SIGNATURE does, which
    /// needs two books that differ by one field and nothing else. A real change
    /// arrives through `load`, and this does not pretend otherwise.
    func setMaintTaskRowsForTesting(_ rows: [JSONValue]) { maintTaskRows = rows }

    /// What this machine is. A book written before Khayt knew about anything
    /// but filament printers has no `kind` on any machine, and the module reads
    /// that as FDM — correctly, because until now nothing else could be
    /// recorded. The fallback here is for the moment before the book loads.
    func kind(of machine: Machine) -> KhaytEngine.MachineKind? { machineKinds[machine.id] }

    /// What this spool, bottle or stack of sheets is measured in. Nil only for
    /// the instant before the book has loaded; every caller reads that as grams,
    /// which every item written before this existed genuinely is.
    func unit(of spool: Spool) -> KhaytEngine.InventoryUnit? { inventoryUnits[spool.id] }

    /// The units the editor can offer.
    func inventoryUnitChoices() async -> [KhaytEngine.InventoryUnit] {
        (try? await engine?.inventoryUnitChoices()) ?? []
    }

    /// The kinds the editor can offer. Asked when the sheet opens rather than
    /// held on the shop: it is five records and the sheet is not a hot path.
    func machineKindChoices() async -> [KhaytEngine.MachineKind] {
        (try? await engine?.machineKindChoices()) ?? []
    }

    /// The shop's address, resolved the way its name already is.
    var shopAddress: String { shopFieldValue("addr") }

    /// Every field an invoice asks the shop for, resolved the way the renderer
    /// resolves them.
    ///
    /// The document wants `biz`, `addr`, `tagline` and `footer`. It used to be
    /// handed the name and the address and nothing else, and its `shopField`
    /// answered the shop's NAME for the other two — so every invoice printed
    /// the name twice at the top and again in the footer, and the tagline the
    /// shop had typed into Settings appeared nowhere.
    var shopDocumentFields: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for base in ["biz", "addr", "tagline", "footer"] {
            out[base] = .string(shopFieldValue(base))
        }
        return out
    }

    private func shopFieldValue(_ base: String) -> String {
        for key in ["\(base)En", "\(base)Ar"] {
            if case .string(let v)? = settingsDict[key], !v.isEmpty { return v }
        }
        return ""
    }

    /// Whether this shop can reclaim the tax it pays on a purchase.
    ///
    /// A shop with no registration reclaims nothing, so asking it for the tax
    /// on a receipt would be asking for a number it cannot use — and recording
    /// one would understate its costs.
    /// Read from the profile the settings load already resolved, so this asks
    /// the same rule the invoice asks and gets the same answer.
    var reclaimsTax: Bool { taxProfile?.isRegistered == true }

    /// The combined tax percentage, or zero for a shop that is not registered.
    func taxPercent() async -> Double {
        guard let engine, case .object(let dict) = settingsValue,
              let profile = try? await engine.taxProfile(settings: dict) else { return 0 }
        return profile.totalPercent
    }

    /// The currency table the document formats against — the shop's whole
    /// table, from `lib/currencies.js`. It was a one-row stand-in that knew
    /// SAR, so a shop pricing in euros would have printed "EUR" where the
    /// document prints "€".
    var currencyTable: JSONValue {
        .object(currencies.mapValues {
            .object(["symbol": .string($0.symbol), "label": .string($0.label), "pos": .string($0.pos)])
        })
    }

    // MARK: - The catalogue

    /// Put the planned rate on each catalogue row so the table can sort by it.
    /// Only the one field changes; the rows are otherwise what `catalogue` said.
    func stampPerHour(_ report: KhaytEngine.ProfitPerHour?) {
        profitPerHour = report
        let rates = Dictionary((report?.rows ?? []).map { ($0.productId, $0.perHour) },
                               uniquingKeysWith: { first, _ in first })
        catalogueRows = catalogueRows.map { row in
            var row = row
            row.perHour = rates[row.id] ?? nil
            return row
        }
    }

    // MARK: - Taking a product off the catalogue

    /// Delete a product, and everything that pointed at it.
    ///
    /// ── WHAT A DELETE HAS TO DO BESIDES DELETING ──────────────────────────
    ///
    /// Dropping the row is the easy quarter of it. `renderer/inventory.js`
    /// also unlinks the jobs that named the product, drops it from any quote
    /// bundle, and removes its pictures from disk — and offers all of that
    /// back as one undo. A Mac delete that only dropped the row would leave a
    /// job pointing at a product that is not there, which is the shape of bug
    /// that shows up months later as a screen that cannot draw.
    ///
    /// PAST INVOICES ARE UNTOUCHED, and the sentence the shop is shown says
    /// so: an invoice is what was actually charged, and a catalogue tidy-up is
    /// not permission to rewrite it.
    func deleteProduct(_ id: String) async {
        guard permitted("inventory", "delete") else { return }
        productProblem = nil
        productNote = nil
        guard let build = source.build else {
            productProblem = words.callIt("mac.move_sample"); return
        }
        // The pictures, read BEFORE the record goes: afterwards there is
        // nothing left to read their names off.
        let pictureNames = await pictures(of: id).compactMap(\.path)
        let othersUse = pictureFilesOfOtherProducts(than: id)
        var removed: [String: JSONValue]?
        var unlinked: [String] = []
        var bundles: [String] = []
        do {
            try StoreWriter.update(build) { root in
                var rows = Self.rows(root, "products")
                guard let at = rows.firstIndex(where: { Self.recordId($0) == id }),
                      case .object(let was) = rows[at] else { return }
                removed = was
                rows.remove(at: at)
                root["products"] = .array(rows)

                // A job that named this product keeps everything else it has;
                // only the pointer goes.
                var log = Self.rows(root, "printLog")
                for i in log.indices {
                    guard case .object(var order) = log[i],
                          case .string(let named)? = order["productId"], named == id else { continue }
                    order["productId"] = .null
                    StoreWriter.stamp(&order)
                    if case .string(let orderId)? = order["id"] { unlinked.append(orderId) }
                    log[i] = .object(order)
                }
                if !unlinked.isEmpty { root["printLog"] = .array(log) }

                // And out of any quote bundle that listed it.
                var settings = Self.settings(root)
                if case .array(var list)? = settings["bundles"] {
                    var touched = false
                    for i in list.indices {
                        guard case .object(var bundle) = list[i],
                              case .array(let ids)? = bundle["productIds"] else { continue }
                        let kept = ids.filter { $0 != .string(id) }
                        guard kept.count != ids.count else { continue }
                        bundle["productIds"] = .array(kept)
                        if case .string(let bundleId)? = bundle["id"] { bundles.append(bundleId) }
                        list[i] = .object(bundle)
                        touched = true
                    }
                    if touched {
                        settings["bundles"] = .array(list)
                        root["settings"] = .object(settings)
                    }
                }
            }
            guard let removed else {
                productProblem = words.callIt("mac.move_gone"); return
            }
            // The bytes go LAST, and only once the record is gone: a picture
            // deleted beside a record that survived is a broken thumbnail on
            // every screen that draws the catalogue.
            for name in pictureNames where !name.isEmpty
                && ProductPhotos.mayTouch(name, productId: id, othersUse: othersUse) {
                ProductPhotos.delete(name, in: build)
            }
            registerProductUndo(removed, unlinked: unlinked, bundles: bundles, pictures: pictureNames)
            await load(source)
            productNote = words.callIt("pe.deleted")
        } catch {
            productProblem = String(describing: error)
        }
    }

    /// Put a deleted product back, with the jobs and bundles that named it.
    ///
    /// The pictures do NOT come back: their bytes were deleted, and an undo
    /// that silently restored a record naming files that are gone would put a
    /// broken thumbnail on the catalogue. The record is restored without them,
    /// which is honest and which the shop can see.
    private func registerProductUndo(_ record: [String: JSONValue], unlinked: [String],
                                     bundles: [String], pictures: [String]) {
        guard let undoManager, let build = source.build,
              case .string(let id)? = record["id"] else { return }
        var restored = record
        if !pictures.isEmpty {
            for key in ["images", "imagePath", "thumbnail"] { restored.removeValue(forKey: key) }
        }
        undoManager.setActionName(words.callIt("pe.deleted"))
        undoManager.registerUndo(withTarget: self) { shop in guard shop.permitted("inventory", "edit") else { return }
            do {
                try StoreWriter.update(build) { root in
                    var rows = Self.rows(root, "products")
                    guard !rows.contains(where: { Self.recordId($0) == id }) else { return }
                    rows.append(.object(restored))
                    root["products"] = .array(rows)

                    var log = Self.rows(root, "printLog")
                    var touchedLog = false
                    for i in log.indices {
                        guard case .object(var order) = log[i],
                              case .string(let orderId)? = order["id"], unlinked.contains(orderId) else { continue }
                        // Only a job still pointing at nothing: one re-pointed
                        // at another product since is someone's later choice.
                        switch order["productId"] {
                        case nil, .null?: break
                        default: continue
                        }
                        order["productId"] = .string(id)
                        StoreWriter.stamp(&order)
                        log[i] = .object(order)
                        touchedLog = true
                    }
                    if touchedLog { root["printLog"] = .array(log) }

                    var settings = Self.settings(root)
                    if case .array(var list)? = settings["bundles"], !bundles.isEmpty {
                        for i in list.indices {
                            guard case .object(var bundle) = list[i],
                                  case .string(let bundleId)? = bundle["id"], bundles.contains(bundleId) else { continue }
                            var ids: [JSONValue] = []
                            if case .array(let had)? = bundle["productIds"] { ids = had }
                            guard !ids.contains(.string(id)) else { continue }
                            ids.append(.string(id))
                            bundle["productIds"] = .array(ids)
                            list[i] = .object(bundle)
                        }
                        settings["bundles"] = .array(list)
                        root["settings"] = .object(settings)
                    }
                }
                Task { await shop.load(shop.source) }
            } catch {
                shop.productProblem = String(describing: error)
            }
        }
    }

    /// Put a deleted spool back, and make THAT undoable.
    ///
    /// `registerMoveUndo` restores fields onto records that are still there; a
    /// deleted spool is not, so it needs its own path.
    func registerSpoolUndo(_ record: [String: JSONValue]) {
        guard let undoManager, let build = source.build,
              case .string(let id)? = record["id"] else { return }
        undoManager.setActionName(words.callIt("inv.removed"))
        undoManager.registerUndo(withTarget: self) { shop in guard shop.permitted("inventory", "edit") else { return }
            do {
                try StoreWriter.update(build) { root in
                    var shelf = Self.rows(root, "inventory")
                    guard !shelf.contains(where: { Self.recordId($0) == id }) else { return }
                    shelf.append(.object(record))
                    root["inventory"] = .array(shelf)
                }
            } catch {
                shop.spendProblem = String(describing: error)
            }
        }
    }
}
