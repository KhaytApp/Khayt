import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - A marketplace's cut

    /// The marketplaces a shop can sell through, named.
    ///
    /// Asked of the rule rather than listed here: `lib/integrations-registry.js`
    /// and `lib/platform-fees.js` already agree on what a platform is called,
    /// and a third list in Swift is how three things come to disagree.
    func platforms() async -> [KhaytEngine.Platform] {
        guard let engine else { return [] }
        let ids = (try? await engine.platformIds()) ?? []
        var out: [KhaytEngine.Platform] = []
        for id in ids {
            // `try?` on a call that already returns an optional flattens to
            // one level, so this is the platform or nothing.
            if let p = try? await engine.platform(id, settings: settingsDict) { out.append(p) }
        }
        return out
    }

    /// The quote lines a marketplace adds, ready for the form.
    func feeLines(for platformId: String) async -> [ExtraLine] {
        guard let engine,
              let rows = try? await engine.platformFeeLines(platformId, settings: settingsDict)
        else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row,
                  let label = Self.plainString(o["label"]), !label.isEmpty else { return nil }
            var line = ExtraLine()
            line.label = label
            line.platformId = Self.plainString(o["platformId"])
            if case .number(let pct)? = o["pct"] { line.pct = pct }
            else if case .number(let amount)? = o["amount"] { line.amount = amount }
            return line
        }
    }

    /// The shop's own lines, in the order they were typed, followed by the
    /// picked marketplace's — or by nothing, when the picker is cleared.
    ///
    /// The shop's lines are never reordered and never dropped: somebody typed
    /// them, and a picker that quietly rewrote them would be a picker nobody
    /// could use twice.
    func applyingPlatform(_ platformId: String?, to lines: [ExtraLine]) async -> [ExtraLine] {
        let kept = lines.filter { $0.platformId == nil }
        guard let platformId, !platformId.isEmpty else { return kept }
        return kept + (await feeLines(for: platformId))
    }

    /// Which marketplace these lines already carry, if any.
    static func platformOn(_ lines: [ExtraLine]) -> String? {
        lines.compactMap(\.platformId).first
    }

    func previewQuote(baseCost: Double, margin: Double, discountPct: Double,
                      shippingCost: Double, rush: Bool,
                      agreedAmount: Double = 0, rule: PriceRule = PriceRule(),
                      extraLines: [ExtraLine] = []) async -> QuoteTotal? {
        guard let engine else { return nil }
        var input = CalculatorPart.quoteInput(baseCost: baseCost, margin: margin, discountPct: discountPct,
                                              shippingCost: shippingCost, rush: rush,
                                              agreedAmount: agreedAmount, settings: settingsDict)
        // Half-written rows are dropped rather than sent as zeroes: a zero
        // amount is a line on the customer's invoice reading "Design fee 0.00".
        let charges = extraLines.filter(\.isWorthKeeping)
        if !charges.isEmpty { input["extraLines"] = .array(charges.map(\.row)) }
        for (key, value) in rule.fields { input[key] = value }
        return try? await engine.quoteTotal(input)
    }

    /// The cart and the money, in the shape `lib/order-new.js` takes.
    /// The parts of a job, as the book records them.
    ///
    /// Pulled out of `newJobInput` so a test can call THIS rather than restate
    /// it: what a saved part carries is the whole question, and the answer has
    /// to be checkable without standing up a window.
    static func partRows(_ parts: [NewJobSheet.Draft], spools: [Spool],
                         unnamed: String) -> [JSONValue] {
        var rows: [JSONValue] = []
        for p in parts {
            var row: [String: JSONValue] = [
                "name": .string(p.name.isEmpty ? unnamed : p.name),
                "printWeight": .number(Double(p.grams) ?? 0),
                "printTime": .number(Double(p.hours) ?? 0),
                "qty": .number(Double(max(1, p.qty))),
                // What the shared cost model said, frozen: a job priced today
                // must not re-cost itself at next year's filament prices.
                "unitCost": .number(p.cost),
                "baseCost": .number(p.cost * Double(max(1, p.qty))),
            ]
            // What the customer agreed for this part, per unit. The cost above
            // is still the cost: the shared rule charges the agreed figure
            // instead of cost plus margin, and measures the margin against
            // what it really cost. See lib/price-agreements.js.
            if let agreed = p.agreedPrice { row["agreedPrice"] = .number(agreed) }
            // The bought-in pieces the part uses (a product's magnets), so the
            // job is costed with them and completing it draws them off the
            // shelf. See `ModelConsumables.swift`.
            if case .array(let uses)? = p.raw["consumables"], !uses.isEmpty {
                row["consumables"] = .array(uses)
            }
            // The rates this part was costed at, written down beside the cost.
            //
            // Not bookkeeping. `renderer/build.js` reads them straight back into
            // its form — `$('#wearRate').value = part.wearRate || ''` — so a
            // part saved without them opens in Khayt's editor with every rate
            // field blank, and the next save re-costs the job at nothing. A job
            // taken here would have lost its price on somebody else's machine,
            // with nothing said on either.
            if let rates = p.rates {
                for (key, value) in rates.fields { row[key] = value }
            }
            if let spoolId = p.spoolId, let spool = spools.first(where: { $0.id == spoolId }) {
                row["filamentId"] = .string(spool.id)
                row["material"] = .string(spool.material)
                row["spoolCost"] = .number(spool.cost ?? 0)
                row["spoolWeight"] = .number(max(1, spool.spoolWeight ?? 1000))
            }
            rows.append(.object(row))
        }
        return rows
    }

    /// What a product's components add to a job taken from it — the figure
    /// `lib/order-new.js` folds into the saved price, so the sheet's preview
    /// shows the price the job is saved at. Zero for a product with none.
    func jobComponentsCost(of product: Product, assemblyQty: Double? = nil) async -> Double {
        guard let engine, let components = product.rest["components"] else { return 0 }
        let qty = assemblyQty ?? Double(Self.assemblyQty(of: product))
        return (try? await engine.jobComponentsCost(components, assemblyQty: max(1, qty),
                                                    consumables: consumableRows)) ?? 0
    }

    /// How many assemblies a product's job makes, as a whole 1…999.
    static func assemblyQty(of product: Product) -> Int {
        guard let n = plainNumber(product.rest["assemblyQty"]), n.isFinite, n >= 1 else { return 1 }
        return min(999, Int(saturating: n.rounded()))
    }

    func newJobInput(parts: [NewJobSheet.Draft], project: String, clientId: String?,
                     margin: Double, discountPct: Double, shippingCost: Double,
                     deposit: Double, rush: Bool, asQuote: Bool,
                     fromProduct product: Product? = nil,
                     assemblyQty: Double? = nil,
                     rule: PriceRule = PriceRule(),
                     extraLines: [ExtraLine] = []) -> [String: JSONValue] {
        var input: [String: JSONValue] = [
            "parts": .array(Self.partRows(parts, spools: spools,
                                          unnamed: words.callIt("mac.a_part"))),
            "project": .string(project),
            "margin": .number(margin),
            "discountPct": .number(discountPct),
            "shippingCost": .number(shippingCost),
            "depositAmount": .number(deposit),
            "rushEnabled": .bool(rush),
            "asQuote": .bool(asQuote),
        ]
        if let clientId { input["clientId"] = .string(clientId) }
        // The charges that are not printing. Dropped when half-written, for
        // the reason `previewQuote` gives.
        let charges = extraLines.filter(\.isWorthKeeping)
        if !charges.isEmpty { input["extraLines"] = .array(charges.map(\.row)) }
        // The last word on the total — rounded to a step, or typed — travels
        // to the rule, which writes how the price was reached on the record.
        for (key, value) in rule.fields { input[key] = value }
        // ── WHAT THE PRODUCT BRINGS WITH IT ───────────────────────────────
        //
        // The components (magnets, screws, a box) and the assembly count are
        // the product's, not the parts' — they are what turns printed pieces
        // into the thing the customer buys, and the shared rule prices and
        // deducts them. Carried here because a job taken from a product and
        // then missing its packaging would under-price every sale and leave
        // the consumable count wrong on the shelf.
        if let product {
            input["productId"] = .string(product.id)
            if let components = product.rest["components"] { input["components"] = components }
            if let qty = product.rest["assemblyQty"] { input["assemblyQty"] = qty }
            // The sheet's own count wins: it is what the shop saw priced.
            if let assemblyQty { input["assemblyQty"] = .number(assemblyQty) }
        }
        return input
    }

    /// One saved preset, as a screen reads it.
    struct Preset: Identifiable, Hashable, Sendable {
        let id: String
        var name: String
        /// The seven figures, keyed as the book keys them.
        var rates: [String: Double] = [:]

        static let rateKeys = ["wearRate", "powerDraw", "elecRate",
                               "laborRate", "failureRate", "prepTime", "postTime"]

        @MainActor static func from(_ value: JSONValue) -> Preset? {
            guard case .object(let o) = value, case .string(let id)? = o["id"], !id.isEmpty else { return nil }
            var p = Preset(id: id, name: Shop.plainString(o["name"]) ?? id)
            for key in rateKeys { if let v = Shop.plainNumber(o[key]) { p.rates[key] = v } }
            return p
        }

        var record: JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "name": .string(name)]
            for key in Self.rateKeys { o[key] = .number(rates[key] ?? 0) }
            return .object(o)
        }
    }

    var presets: [Preset] { presetRows.compactMap(Preset.from) }

    /// A preset written over the stored row `was` — see `savePreset`.
    static func presetRow(_ preset: Preset, over was: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(let written) = preset.record else { return was }
        var out = was
        if let stored = Preset.from(.object(was)), case .object(let baseline) = stored.record {
            let kept = RoundTrip.keepUntouched(written: written, baseline: baseline, stored: was)
            for key in written.keys { out[key] = kept[key] }
        } else {
            for (key, value) in written { out[key] = value }
        }
        return out
    }

    /// Save a preset, matching the other app's rule: a name already in use is
    /// REPLACED rather than duplicated, compared without case, and the id is
    /// kept so anything pointing at it still does.
    func savePreset(name: String, rates: [String: Double]) async -> String? {
        guard permitted("settings", "edit") else { return moveProblem }
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, let build = source.build else {
            moveProblem = words.callIt(source.build == nil ? "mac.move_sample" : "mac.product_need_name")
            return nil
        }
        do {
            var id = ""
            try StoreWriter.update(build) { root in
                id = Self.writePreset(into: &root, name: wanted, rates: rates)
            }
            await load(source)
            return id
        } catch {
            moveProblem = String(describing: error)
            return nil
        }
    }

    /// The preset write, against the book as it is on disk — the Calculator's
    /// "Save preset" and the first-run setup's electricity figure both land
    /// here. A name already in use (without case) is saved OVER that preset:
    /// in place, keeping every field of it this app does not model (the other
    /// app's presets carry more than the seven rates) and every rate that did
    /// not change, as the book spells it. Returns the preset's id.
    @discardableResult
    static func writePreset(into root: inout [String: JSONValue], name: String,
                            rates: [String: Double]) -> String {
        var rows: [JSONValue] = []
        if case .array(let had)? = root["printers"] { rows = had }
        let existing = rows.compactMap(Preset.from).first { $0.name.lowercased() == name.lowercased() }
        let id = existing?.id ?? "PRNTR-\(UUID().uuidString.prefix(8))"
        var preset = Preset(id: id, name: name)
        preset.rates = rates
        if let at = rows.firstIndex(where: { recordId($0) == id }),
           case .object(let was) = rows[at] {
            rows[at] = .object(presetRow(preset, over: was))
        } else {
            rows.append(preset.record)
        }
        root["printers"] = .array(rows)
        return id
    }

    /// The field marking the preset the first-run setup made — so running
    /// the setup again finds it whatever language its name was written in.
    static let setupPresetMarker = "khaytSetupPreset"

    /// The first-run setup's electricity tariff, into the preset it made.
    ///
    /// ── KEEPING AN OLD ONE IN STEP ───────────────────────────────────────
    ///
    /// The tariff is the shop's own now (`settings.elecRate`), and the setup
    /// calls this with `openers: nil`: it no longer makes a preset, it only
    /// updates one an earlier setup made, whose tariff would otherwise beat
    /// the new answer wherever that preset is picked.
    ///
    /// ── ONLY THE TARIFF ──────────────────────────────────────────────────
    ///
    /// The setup asks one question — what a kWh costs — and used to answer it
    /// by writing all seven rates: Khayt's openers plus the tariff, saved over
    /// the same-named preset. A shop that had since set its own labour rate
    /// and failure allowance on "Shop rates" and re-ran the setup had all six
    /// reset to the openers (#1675). So a preset already there keeps every
    /// rate it has and only `elecRate` changes; the openers are used only for
    /// a preset made fresh, where there is nothing else to start from.
    ///
    /// ── FOUND BY A MARKER, NOT BY ONE NAME ────────────────────────────────
    ///
    /// The name is the localised "Shop rates", so the setup run in English
    /// and then in Arabic made two presets. The preset carries
    /// `setupPresetMarker`; one without it (made before the marker existed)
    /// is matched by any of the names the setup has used (`aliases`), and
    /// gains the marker. Its name is left as it is.
    ///
    /// ── THE SAME BOUND AS EVERY OTHER READER ─────────────────────────────
    ///
    /// The preset's tariff BEATS the shop's wherever the preset is picked, so
    /// it is held to the rule the shop's own is read by (`shopTariff`): NaN,
    /// Infinity or negative writes nothing, and above `maxElecRate` is clamped
    /// to it — before, this wrote whatever it was handed.
    ///
    /// Returns the preset's id, or nil when there was none and the openers
    /// could not be read, or the tariff was refused.
    @discardableResult
    static func writeSetupPreset(into root: inout [String: JSONValue], name: String,
                                 aliases: [String], tariff raw: Double,
                                 openers: [String: Double]?) -> String? {
        guard let tariff = boundedTariff(raw) else { return nil }
        var rows: [JSONValue] = []
        if case .array(let had)? = root["printers"] { rows = had }
        let names = Set(([name] + aliases).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        func marked(_ row: JSONValue) -> Bool {
            if case .object(let o) = row { return o[setupPresetMarker] == .bool(true) }
            return false
        }
        func named(_ row: JSONValue) -> Bool {
            guard let p = Preset.from(row) else { return false }
            return names.contains(p.name.trimmingCharacters(in: .whitespaces).lowercased())
        }
        if let at = rows.firstIndex(where: marked) ?? rows.firstIndex(where: named),
           case .object(let was) = rows[at], let id = Preset.from(rows[at])?.id {
            var row = withTariff(tariff, over: was)
            row[setupPresetMarker] = .bool(true)
            rows[at] = .object(row)
            root["printers"] = .array(rows)
            return id
        }
        guard let openers else { return nil }
        var preset = Preset(id: "PRNTR-\(UUID().uuidString.prefix(8))", name: name)
        preset.rates = openers
        preset.rates["elecRate"] = tariff
        guard case .object(var row) = preset.record else { return nil }
        row[setupPresetMarker] = .bool(true)
        rows.append(.object(row))
        root["printers"] = .array(rows)
        return preset.id
    }

    /// The most a kWh can cost — `KhaytPrintRates.MAX_ELEC_RATE`, the one
    /// bound every reader of a shop tariff clamps to (lib/print-rates.js says
    /// why 10,000). Swift needs it in a static, engine-less writer, so it is
    /// restated here and `ElecRateParityTests` pins it to the JavaScript.
    static let maxElecRate: Double = 10_000

    /// A tariff by `shopTariff`'s rules: nil for NaN, Infinity or negative;
    /// clamped to `maxElecRate` above it.
    static func boundedTariff(_ v: Double) -> Double? {
        guard v.isFinite, v >= 0 else { return nil }
        return min(v, maxElecRate)
    }

    /// A preset row with its tariff set to `tariff`, or REMOVED for nil —
    /// every other field exactly as the book spells it. Setting goes through
    /// `presetRow` (the #1676 round-trip rule); removing takes only the key
    /// away, because `Preset.record` writes an absent rate as 0, and 0 is a
    /// tariff (a free kWh) rather than "say nothing, use the shop's".
    static func withTariff(_ tariff: Double?, over was: [String: JSONValue]) -> [String: JSONValue] {
        guard let tariff else {
            var row = was
            row.removeValue(forKey: "elecRate")
            return row
        }
        guard var preset = Preset.from(.object(was)) else { return was }
        preset.rates["elecRate"] = tariff
        return presetRow(preset, over: was)
    }

    /// Keep the preset the first-run setup made (`setupPresetMarker`) in step
    /// with the shop's tariff, after the shop changes it in Settings ›
    /// Business.
    ///
    /// A setup before the shop-wide tariff saved the answer ONLY as that
    /// preset, and a preset's tariff beats the shop's — so a shop that later
    /// changed its price in Settings was still charged the old one wherever
    /// "Shop rates" was picked. A new price is written onto the preset; a
    /// cleared one takes the tariff off it, so it falls back to the shop's
    /// (and then to Khayt's). Only the MARKED preset: one the shop named
    /// "Shop rates" by hand is its own figure. No marked preset, no write.
    static func keepSetupPresetInStep(_ root: inout [String: JSONValue], tariff: Double?) {
        guard case .array(var rows)? = root["printers"],
              let at = rows.firstIndex(where: {
                  if case .object(let o) = $0 { return o[setupPresetMarker] == .bool(true) }
                  return false
              }),
              case .object(let was) = rows[at] else { return }
        let row = withTariff(tariff.flatMap(boundedTariff), over: was)
        guard row != was else { return }
        rows[at] = .object(row)
        root["printers"] = .array(rows)
    }

    static func lanBook(from root: [String: JSONValue]) -> [String: JSONValue] {
        ["printLog": root["printLog"] ?? .array([]),
         "waitingList": root["waitingList"] ?? .array([]),
         "settings": root["settings"] ?? .object([:]),
         "machines": root["machines"] ?? .array([])]
    }

    static func pricingBook(from root: [String: JSONValue]) -> [String: JSONValue] {
        ["settings": root["settings"] ?? .object([:]),
         "printers": root["printers"] ?? .array([]),
         "inventory": root["inventory"] ?? .array([]),
         "printLog": root["printLog"] ?? .array([])]
    }

    /// Every key the tier registry knows. Asked for by name so a feature this
    /// app has not heard of is simply never gated, rather than silently off.
    /// ── WHY `purchasing` JOINED THE LIST AND `loyalty` DID NOT ───────────
    ///
    /// Both are Professional features in `lib/feature-tiers.js`. What decides
    /// whether this app gates one is not the tier table but what the OTHER app
    /// actually shows: gating something Khayt draws for a Simple shop would
    /// hide it here and nowhere else, which is the same disagreement the modes
    /// exist to prevent, from the other end.
    ///
    /// `renderer/index.html` carries `pro-only` on the purchase-order section,
    /// the suppliers card and the auto-draft switch — so a Simple shop sees no
    /// purchase orders there, and saw all of them here. It does NOT carry it on
    /// the loyalty settings card, so a Simple shop CAN switch the rewards
    /// programme on in that window; hiding it here would take away something
    /// the shop has and is using.
    static let gatedFeatures = ["analytics", "expenses", "maintenance", "purchasing", "zatca"]

    /// Does this shop's mode include it? Unknown keys are on: a screen this
    /// app added and forgot to classify must not vanish.
    func has(_ feature: String) -> Bool {
        Self.gatedFeatures.contains(feature) ? features.contains(feature) : true
    }

    /// How loudly a sync line should be said.
    ///
    /// A TONE rather than a colour, because `Shop` does not import SwiftUI and
    /// should not: the model says what the state IS and each window decides
    /// how it looks. That also stopped the two shells inheriting one file's
    /// private styling.
    enum SyncTone { case quiet, normal, attention }

    /// One line for every state sync can be in.
    ///
    /// ── LIFTED OUT OF THE RETIRED SHELL ───────────────────────────────────
    ///
    /// It was `Provenance.syncLine`, private to a type in `Sidebar.swift` —
    /// the window the app stopped opening with in 4.0.0-alpha.12. So the
    /// shipping shell showed no sync state at all, and nothing outside that
    /// one file read `syncStatus`.
    ///
    /// Locked is the one worth reading twice: it is not a fault, it is a shop
    /// that has not typed its passphrase since the app opened, and the data
    /// key deliberately lives no longer than that.
    var syncLine: (text: String, symbol: String, tone: SyncTone) {
        switch syncStatus {
        case .off:
            (words.callIt("mac.sync_off"), "icloud.slash", .quiet)
        case .locked:
            (words.callIt("mac.sync_locked"), "lock.icloud", .normal)
        case .idle:
            (words.callIt("mac.sync_on"), "icloud", .quiet)
        case .syncing:
            (words.callIt("mac.sync_sending"), "icloud.and.arrow.up", .normal)
        case .waiting:
            (words.callIt("mac.sync_waiting"), "clock.arrow.circlepath", .quiet)
        case .synced(let when):
            (words.callIt("mac.sync_done", ["time": .string(Shop.clockText(when))]),
             "checkmark.icloud", .quiet)
        case .failing:
            // ATTENTION, not late: it is going to be tried again and nothing
            // has been lost — the change is still in the book. Those two are
            // the difference between "this needs you when you have a moment"
            // and "this has failed".
            (words.callIt("mac.sync_retrying"), "exclamationmark.icloud", .attention)
        }
    }

    /// The time of day, in the shop's own locale.
    static func clockText(_ when: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: when)
    }

    /// The feature a whole SCREEN needs, or nil for one everybody has.
    ///
    /// ── WHY THIS IS A FUNCTION AND NOT AN `if` IN THE SIDEBAR ─────────────
    ///
    /// It was two `if`s in the sidebar, and they were in the wrong sidebar.
    /// The gate was written for the shell the app used to open with; the
    /// redesigned one has shipped by default since 4.0.0-alpha.12 and asks
    /// nothing, so a Simple shop saw Expenses and Reports exactly as a
    /// Professional one did — while the rule, the book and the old shell's
    /// gate were all correct, which is what made it so hard to place.
    ///
    /// The menu bar and the restore path never asked either, so hiding the row
    /// alone would still have left ⌘-menu and a reopened window going straight
    /// to the screen. "Simple does not include this" has to mean it cannot be
    /// reached, not that one list omits it.
    ///
    /// So the answer lives here once, and everything that can navigate asks.
    /// The waste log is deliberately absent: it is not gated in
    /// `lib/feature-tiers.js` either.
    static func gate(of shelf: Shelf) -> String? {
        switch shelf {
        case .expenses: "expenses"
        case .reports: "analytics"
        default: nil
        }
    }

    /// Can this shop reach that screen at all?
    func canShow(_ shelf: Shelf) -> Bool {
        // The operator lock first: a screen the person signed in may not see
        // is not reachable by ANY path that asks here — the sidebars, the menu
        // bar, a window restoring onto it, and the content switch itself.
        if let area = Self.lockArea(of: shelf), !lockAllows(area, "view") { return false }
        guard let gate = Self.gate(of: shelf) else { return true }
        return has(gate)
    }

    /// What this shop's mode includes, asked of the shared rule.
    ///
    /// Internal rather than private so a test can drive it with a mode the
    /// bundled sample book does not have. Nothing proved that Simple actually
    /// HID anything through this path: every test loaded the sample, which
    /// carries no mode at all and is therefore Professional, and asserted that
    /// everything was present. So the one thing the feature exists to do was
    /// the one thing untested, and someone reading the screen could not tell
    /// whether it worked.
    func readFeatures() async {
        guard let engine else { features = Set(Self.gatedFeatures); return }
        let mode = Self.plainString(settingsDict["mode"])
        var on: Set<String> = []
        for key in Self.gatedFeatures {
            if (try? await engine.featureEnabled(key, mode: mode)) ?? true { on.insert(key) }
        }
        features = on
    }

    var settingsDict: [String: JSONValue] {
        if case .object(let s) = settingsValue { return s }
        return [:]
    }

    /// Take a new job, or quote for one.
    ///
    /// THE ORDER AND THE SETTINGS ARE WRITTEN TOGETHER. Creating a job consumes
    /// an invoice number from a counter the shop owns; saving the order without
    /// the counter hands the same number to the next job, and saving the counter
    /// without the order burns one for nothing. One swap, both records.
    func createJob(_ input: [String: JSONValue]) async {
        moveProblem = nil
        moveNotices = []
        guard permitted("orders", "create") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return
        }

        var created: String?
        var quoted = false
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                // The shelf the product's components are costed from — the
                // catalogue prices them, so the job has to.
                let out = try await engine.newOrder(
                    input, orders: orders, settings: Self.settings(root), now: Date(),
                    tokens: (tracking: Self.randomBytes(16), quoteApproval: Self.randomBytes(16)),
                    consumables: Self.rows(root, "consumables"))

                guard case .object(let record) = out.order,
                      case .string(let id)? = record["id"] else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_refused"))
                }
                // Newest first, the way every screen reads the book.
                root["printLog"] = .array([out.order] + orders)
                root["settings"] = .object(out.settings)
                Self.appendActivity(&root,
                                    text: "\(id)" + (record["project"].flatMap(Self.plainString).map { $0.isEmpty ? "" : " · \($0)" } ?? ""),
                                    ref: id, settings: out.settings, root: root,
                                    action: Self.plainString(record["status"]) == "quote"
                                            ? "quote_created" : "order_created")
                created = id
                quoted = Self.plainString(record["status"]) == "quote"
            }
            lastCreated = created
            if created != nil { Telemetry.feature(quoted ? .quoteCreated : .orderCreated, in: self) }
            await load(source)
            // Put the person on the job they just took.
            if let created {
                selection = created
                shelf = .jobs(nil)
            }
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    nonisolated static func plainString(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    /// Bytes for the tokens the shared rule cannot mint itself.
    static func randomBytes(_ n: Int) -> [UInt8] {
        (0..<n).map { _ in UInt8.random(in: 0...255) }
    }

    // MARK: - Money received

    /// The payment methods Khayt offers, in its own order.
    ///
    /// Not a Swift opinion about how a Saudi shop is paid: the list is
    /// `renderer/order-flows.js`'s, and the words are Khayt's own
    /// (`pay.method.*`), so the two apps offer one set of choices.
    static let paymentMethods = ["cash", "mada", "transfer", "stcpay", "applepay", "visa", "other"]

    /// Of everywhere a change would reach, the ones this app cannot carry.
    ///
    /// ONE ANSWER FOR BOTH DOORS. This lived inside the status-move path, and
    /// `recordPayment` had no equivalent — it refused whenever a payment would
    /// reach ANYBODY, including through the three channels this app sends on
    /// every move. So a shop with a webhook switched on could move a job and
    /// could not record the money for it, and the sentence it was given named
    /// a channel the app was perfectly able to use.
    ///
    /// A loop rather than a `filter`, because asking the module whether a
    /// provider can be carried is a call into the engine actor, and an `await`
    /// cannot happen inside a synchronous closure.
    static func channelsThisAppCannotSend(_ reaches: [Outbound],
                                          settings: [String: JSONValue],
                                          engine: KhaytEngine) async -> [Outbound] {
        let canSend: Set<String> = ["telegram", "webhooks", "event_webhook"]
        var out: [Outbound] = []
        for reach in reaches {
            if canSend.contains(reach.channel) { continue }
            // Email only where the provider is one this app has a door for.
            // `settings` is needed as well as the provider name because SMTP is
            // a door with a lock on it: `custom` with no relay typed in is a
            // shop that started configuring and stopped, and offering to send
            // through it would open a connection to the empty string.
            if reach.channel == "email",
               await canEmailThrough(reach.via ?? "", settings: settings, engine: engine) {
                continue
            }
            // The customer's tracking link. `PortalClient` PUTs it.
            if reach.channel == "portal" { continue }
            out.append(reach)
        }
        return out
    }

    /// Record what a customer has paid.
    ///
    /// One record changes, not three — but through the same door as a move, so
    /// the ownership check, the atomic swap and the undo are the ones already
    /// proven rather than a second set written for money.
    func recordPayment(_ id: Order.ID, amount: Double, method: String, paidAt: Date) async {
        guard permitted("invoicing", "edit") else { return }
        var owed: [KhaytEngine.WebhookDelivery] = []
        var mail: OrderEmail?
        let wrote = await writeToOneOrder(id, named: words.callIt("pay.modal_title"), as: .person("invoicing", "edit")) { order, engine, root in
            let settings = Self.settings(root)
            let clients = Self.rows(root, "clients")
            let reaches = (try? await engine.paymentOutbound(
                order: order, settings: settings, clients: clients)) ?? []
            // ONLY what this app genuinely cannot carry — the same question a
            // move asks. It used to refuse on ANY reach, so a shop with a
            // webhook switched on could move a job and not record the money
            // for it.
            let cannotSend = await Self.channelsThisAppCannotSend(
                reaches, settings: settings, engine: engine)
            if !cannotSend.isEmpty {
                throw MoveRefused(sentence: self.words.outboundRefusal(cannotSend))
            }

            // A payment is not a status change and Khayt writes no log line for
            // one, so neither does this.
            let done = try await engine.recordPayment(
                order: order, amount: amount, method: method,
                paidAt: Self.localDay(paidAt), today: Self.localDay(), settings: settings)

            // ── AND WHAT THE PAYMENT OWES OUTWARD ─────────────────────────
            //
            // Built HERE, inside the write, for the reason a move builds its
            // own here: the settings, the subscriptions and the customer's
            // name are the ones on disk. Built from the order AS RECORDED, so
            // a consumer is told the balance after the money rather than
            // before it. Sending is the caller's job.
            //
            // Not sending these is why the refusal existed at all — letting
            // the payment through without them would trade a loud refusal for
            // a silent non-send, which is the worse of the two.
            if let asked = done.webhookEffects, !asked.isEmpty {
                owed = (try? await engine.webhookDeliveries(
                    order: done.order, effects: asked, settings: settings,
                    shopName: Self.plainString(settings["bizEn"])
                        ?? Self.plainString(settings["bizAr"]) ?? "Khayt",
                    clientName: Self.emailClientName(for: Self.asObject(done.order) ?? [:],
                                                     in: clients),
                    currency: Self.shopCurrencyOf(settings),
                    at: ISO8601DateFormatter().string(from: Date()),
                    nowMs: Date().timeIntervalSince1970 * 1000)) ?? []
            }
            // ── AND THE RECEIPT EMAIL ─────────────────────────────────────
            //
            // The refusal above lets a payment through when the shop's email
            // provider is one this app can send on — and then this sent only
            // the webhooks, so a shop with "a payment arrives" switched on was
            // never refused AND its customer was never written to (Oct 2026).
            // The rule asks for it as an `email` effect; it is built through
            // the same module a move's email is, from the order as recorded.
            mail = await Self.paymentEmail(
                after: done, settings: settings, clients: clients, engine: engine,
                statusLabel: self.words.callIt("mac.payment_received_label"))
            return OneOrderEdit(order: done.order)
        }
        // After the write, like a move's: a delivery that went out for a
        // payment the book then refused to keep would be a lie told outward.
        guard wrote else { return }
        Telemetry.feature(.paymentRecorded, in: self)
        if let mail { await post(mail) }
        if !owed.isEmpty { await fire(owed) }
        // The customer's page shows the balance. A payment is counted as one
        // this app CAN carry to the portal (`channelsThisAppCannotSend`
        // waves it through), and then nothing carried it: the page went on
        // asking for money already paid.
        await republishPortalIfPublished(id)
    }

    /// The email a recorded payment owes the customer, or nil when it owes
    /// none — the rule did not ask (nothing was paid), the shop has not switched
    /// "a payment arrives" on, or the customer has no address.
    static func paymentEmail(after done: PaymentRecorded, settings: [String: JSONValue],
                             clients: [JSONValue], engine: KhaytEngine,
                             statusLabel: String) async -> OrderEmail? {
        guard done.effects.contains("email") else { return nil }
        return try? await engine.orderEmail(
            order: done.order, newStatus: "payment_received",
            settings: settings, clients: clients,
            shopName: plainString(settings["bizEn"]) ?? plainString(settings["bizAr"]) ?? "Khayt",
            clientName: emailClientName(for: asObject(done.order) ?? [:], in: clients),
            statusLabel: statusLabel)
    }

    /// The priority a job is at, however old its record is.
    ///
    /// Read through the shared rule rather than off `order.priority`, because
    /// an older record carries only the boolean and a newer one only the level.
    func priorityOf(_ job: Order?) -> String {
        guard let job else { return "normal" }
        if let level = job.priorityLevel, Self.priorityLevels.contains(level) { return level }
        return job.priority ? "high" : "normal"
    }

    /// The priority levels, in the order a shop escalates.
    static let priorityLevels = ["normal", "high", "urgent"]

    /// Change a job's due date and priority.
    ///
    /// Two fields, not thirty: the ones a shop floor actually adjusts. Every
    /// other field the order editor writes is left exactly as it was, which the
    /// shared rule guarantees rather than this app promising it.
    ///
    /// `fields` holds only what the shop changed — `EditJobSheet.fields`.
    func editJob(_ id: Order.ID, fields: [String: JSONValue]) async {
        guard permitted("orders", "edit") else { return }
        await writeToOneOrder(id, named: words.callIt("mac.edit_job"), as: .person("orders", "edit")) { order, engine, _ in
            let out = try await engine.editJob(
                order: order, fields: fields,
                now: Date(), editId: Self.uid("edit"))
            // Nothing moved: return the order untouched so the write path finds
            // no change, stamps nothing and syncs nothing.
            return OneOrderEdit(order: out.order)
        }
    }

    /// Mark a job as not business — a test, a gift, something for the shop
    /// itself — or as business again. It leaves revenue, order counts and the
    /// reports; it still wears the nozzle and still took the machine's time.
    func setNonBusiness(_ id: Order.ID, _ on: Bool) async {
        await writeToOneOrder(id, named: words.callIt("mac.not_business"), as: .person("orders", "edit")) { order, engine, _ in
            OneOrderEdit(order: try await engine.setNonBusiness(order, on: on))
        }
    }

    /// Mark many finished jobs Not business in ONE write and one undo — the
    /// Triage card "19 finished jobs were charged nothing".
    ///
    /// The ids are checked again inside the write against the rule that
    /// chose them (`selectUnpricedFinished`), so a job priced or voided on
    /// another machine since the card was drawn is left alone.
    func markNotBusiness(_ ids: [Order.ID]) async {
        moveProblem = nil
        guard permitted("orders", "edit") else { return }
        guard !ids.isEmpty else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return
        }
        let actionName = words.callIt("mac.not_business")
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                let changed = try await Self.markedNotBusiness(orders, ids: ids, engine: engine)
                Self.write(&root, "printLog", changed: changed, before: orders, into: &undo)
            }
            registerMoveUndo(undo, named: actionName)
            await load(source)
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// The patch `markNotBusiness` writes, with no store in it: the asked-for
    /// jobs that the rule STILL counts as finished and charged nothing, each
    /// marked by the shared setter. Anything else is left out.
    static func markedNotBusiness(_ orders: [JSONValue], ids: [Order.ID],
                                  engine: KhaytEngine) async throws -> [JSONValue] {
        let still = Set(try await engine.unpricedFinished(orders: orders).ids)
        let wanted = Set(ids).intersection(still)
        var changed: [JSONValue] = []
        for order in orders {
            guard let id = recordId(order), wanted.contains(id) else { continue }
            changed.append(try await engine.setNonBusiness(order, on: true))
        }
        return changed
    }

    /// Change one part of a job, and re-cost it.
    ///
    /// ── WHY THE RATES ARE WRITTEN BACK, NOT JUST THE COST ──────────────────
    ///
    /// The Electron calculator stores all seven rates on every part it saves and
    /// its editor reads them straight back into the form. A part saved without
    /// them opens there with every rate field blank and the next save re-costs
    /// it at nothing — so a part edited here and then opened in Khayt would lose
    /// its price, quietly, on somebody else's machine. `costPart` returns the
    /// rates for exactly this reason and they go back on the record.
    ///
    /// The cost is NOT taken from whatever was on the part before. A shop that
    /// corrects a weight has corrected the price of the job, and leaving the old
    /// figure there would be a job whose parts no longer add up to its total.
    ///
    /// `opened` is the sheet's fields as it opened the part. Only what differs
    /// from it is written, and the part is re-costed only when a figure the
    /// cost is made from changed — at the PART'S OWN RATES (its labour, power,
    /// wear and failure figures), not the shop's defaults: costing from grams
    /// and hours alone is the fault that re-priced the catalogue's portrait
    /// from 50 to 13.74, and this path did it to a job's part on every save.
    func editPart(_ orderId: Order.ID, partId: String, _ now: EditPartSheet.Opened,
                  opened: EditPartSheet.Opened?) async {
        guard now != opened else { return }
        let recost = opened.map {
            $0.grams != now.grams || $0.hours != now.hours || $0.qty != now.qty || $0.spoolId != now.spoolId
        } ?? true
        // Costed, and written, by the one call the sheet's preview makes — so
        // the figure on screen is the figure saved, and the spool fields the
        // cost was worked out from are the ones that land on the part.
        let (spool, costed): (Spool?, KhaytEngine.CostedPart?) = recost
            ? await partEditCost(raw: rawPart(orderId, partId: partId), now, opened: opened)
            : (nil, nil)

        await writeToOneOrder(orderId, named: words.callIt("mac.edit_part"), as: .person("orders", "edit")) { order, _, _ in
            OneOrderEdit(order: Self.orderWithPartEdited(
                order, partId: partId, now, opened: opened, spool: spool, costed: costed))
        }
    }

    /// The spool an edited part is costed at — and whose four fields
    /// (`filamentId`, `material`, `spoolCost`, `spoolWeight`) the save then
    /// writes — or nil, to cost it at what the part already carries.
    ///
    /// - A spool CHOSEN in the sheet (or no sheet state at all): that spool.
    /// - The spool the part names, still on the shelf: that spool, at today's
    ///   price — and its price is written with the cost, so the part never
    ///   carries a `spoolCost` its own `unitCost` was not worked out from.
    /// - The spool the part names is GONE: the part's own stored
    ///   `spoolCost`/`spoolWeight`. The sheet opens such a part on the first
    ///   roll of the same material, for want of anything better to show; a
    ///   weight corrected there used to be costed at THAT roll's price while
    ///   the part went on naming the old one. A spool nobody picked is not
    ///   one to re-cost at.
    /// - It names none, and carries no price of its own: the spool the sheet
    ///   shows, written whole (id included), since there is nothing else to
    ///   cost at.
    static func partCostSpool(_ now: EditPartSheet.Opened, opened: EditPartSheet.Opened?,
                              raw: [String: JSONValue]?, spools: [Spool]) -> Spool? {
        guard let id = now.spoolId else { return nil }
        let shown = spools.first { $0.id == id }
        guard let opened, opened.spoolId == id else { return shown }
        if let named = plainString(raw?["filamentId"]), let spool = spools.first(where: { $0.id == named }) {
            return spool
        }
        if plainNumber(raw?["spoolCost"]) != nil { return nil }
        return shown
    }

    /// What an edited part will cost, worked out exactly as `editPart` saves
    /// it: the spool from `partCostSpool`, and the part's own rates (`raw`)
    /// beating the machine's. The sheet's preview calls THIS, so the price on
    /// the button cannot differ from the one written.
    func partEditCost(raw: [String: JSONValue]?, _ now: EditPartSheet.Opened,
                      opened: EditPartSheet.Opened?) async -> (spool: Spool?, costed: KhaytEngine.CostedPart?) {
        let spool = Self.partCostSpool(now, opened: opened, raw: raw, spools: spools)
        let costed = await costedPart(spoolId: spool?.id, grams: Double(now.grams) ?? 0,
                                      hours: Double(now.hours) ?? 0, qty: now.qty,
                                      extra: raw ?? [:])
        return (spool, costed)
    }

    /// A part as the book holds it, every field.
    func rawPart(_ orderId: Order.ID, partId: String) -> [String: JSONValue]? {
        guard case .object(let order)? = orderRows.first(where: {
            if case .object(let o) = $0, case .string(let id)? = o["id"] { return id == orderId }
            return false
        }), case .array(let rows)? = order["parts"] else { return nil }
        for row in rows {
            if case .object(let part) = row, case .string(let id)? = part["id"], id == partId { return part }
        }
        return nil
    }

    /// `orderWithPartEdited`, writing only the fields that differ from what
    /// the sheet opened with. A field the shop did not change stays as the
    /// book spells it — 12.34567 g is not rounded to the 12.35 the box shows.
    static func orderWithPartEdited(_ order: JSONValue, partId: String,
                                    _ now: EditPartSheet.Opened, opened: EditPartSheet.Opened?,
                                    spool: Spool?, costed: KhaytEngine.CostedPart?) -> JSONValue {
        guard let opened else {
            return orderWithPartEdited(order, partId: partId, name: now.name, spool: spool,
                                       grams: Double(now.grams) ?? 0, hours: Double(now.hours) ?? 0,
                                       qty: now.qty, costed: costed)
        }
        guard case .object(var record) = order,
              case .array(var rows)? = record["parts"] else { return order }
        for i in rows.indices {
            guard case .object(var part) = rows[i],
                  case .string(let id)? = part["id"], id == partId else { continue }
            if now.name != opened.name { part["name"] = .string(now.name) }
            if now.grams != opened.grams { part["printWeight"] = .number(max(0, Double(now.grams) ?? 0)) }
            if now.hours != opened.hours { part["printTime"] = .number(max(0, Double(now.hours) ?? 0)) }
            if now.qty != opened.qty { part["qty"] = .number(Double(max(1, now.qty))) }
            // `spool` is the one the cost was worked out from (`partCostSpool`),
            // so its fields go down whenever it is given — not only when the
            // choice changed, or a part re-costed at today's price kept the
            // price it was bought at beside a cost that did not use it.
            if let spool {
                part["filamentId"] = .string(spool.id)
                part["material"] = .string(spool.material)
                part["spoolCost"] = .number(spool.cost ?? 0)
                // At least one gram: the cost model divides by this.
                part["spoolWeight"] = .number(max(1, spool.spoolWeight ?? 1000))
            }
            if let costed {
                part["unitCost"] = .number(costed.cost)
                part["baseCost"] = .number(costed.cost)
                for (key, value) in costed.rates.fields { part[key] = value }
            }
            rows[i] = .object(part)
        }
        record["parts"] = .array(rows)
        return .object(record)
    }

    /// The patch itself, with no store and no clock in it.
    ///
    /// Pulled out of `editPart` so it can be tested: a Shop write needs a real
    /// store on disk and an ownership record, and nothing in this suite has
    /// ever built one — which would have left the two things that lose money
    /// here (re-costing, and writing the rates back) with no test at all.
    static func orderWithPartEdited(_ order: JSONValue, partId: String, name: String,
                                    spool: Spool?, grams: Double, hours: Double, qty: Int,
                                    costed: KhaytEngine.CostedPart?) -> JSONValue {
        guard case .object(var record) = order,
              case .array(var rows)? = record["parts"] else { return order }

        for i in rows.indices {
            guard case .object(var part) = rows[i],
                  case .string(let id)? = part["id"], id == partId else { continue }

            part["name"] = .string(name)
            part["printWeight"] = .number(max(0, grams))
            part["printTime"] = .number(max(0, hours))
            part["qty"] = .number(Double(max(1, qty)))

            if let spool {
                part["filamentId"] = .string(spool.id)
                part["material"] = .string(spool.material)
                part["spoolCost"] = .number(spool.cost ?? 0)
                // At least one gram: the cost model divides by this.
                part["spoolWeight"] = .number(max(1, spool.spoolWeight ?? 1000))
            }
            if let costed {
                part["unitCost"] = .number(costed.cost)
                part["baseCost"] = .number(costed.cost)
                for (key, value) in costed.rates.fields { part[key] = value }
            }
            rows[i] = .object(part)
        }
        record["parts"] = .array(rows)
        return .object(record)
    }

    /// How long one part took, from the record rather than the decoded model.
    ///
    /// `Order.Part` does not carry `printTime` — nothing on screen needed it
    /// until a part could be edited, and adding it to the model would change
    /// what every other reader of that type decodes. The record has always had
    /// it.
    func partHours(_ orderId: Order.ID, partId: String) async -> Double? {
        guard case .object(let order)? = orderRows.first(where: {
            if case .object(let o) = $0, case .string(let id)? = o["id"] { return id == orderId }
            return false
        }), case .array(let rows)? = order["parts"] else { return nil }

        for row in rows {
            guard case .object(let part) = row,
                  case .string(let id)? = part["id"], id == partId else { continue }
            if case .number(let hours)? = part["printTime"] { return hours }
            return nil
        }
        return nil
    }

    /// What the library file this part was printed from says it weighs and takes.
    ///
    /// Nil when the part was never linked to one — a job auto-logged from a
    /// printer's own history knows a filename and nothing about the library.
    func partSuggestion(fileId: String?) async -> KhaytEngine.PartFromFile? {
        guard let engine, let fileId, let rec = row(for: fileId) else { return nil }
        return try? await engine.partFromFile(rec)
    }

    /// Hand a finished job over.
    ///
    /// Not a status change: a delivered job stays `completed` and carries a
    /// `deliveredAt`. Setting a status here would take it out of the very
    /// column the action feeds — see `KhaytOrderStatus.stageOf`.
    func markDelivered(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("queue.delivered"), as: .person("orders", "edit")) { order, engine, _ in
            let out = try await engine.markDelivered(order: order, now: Date())
            guard out.ok, let changed = out.order else {
                throw MoveRefused(sentence: self.words.callIt("mac.not_finished_yet"))
            }
            // The same line Khayt and Bed Ready write.
            return OneOrderEdit(order: changed, activity: "\(id) → delivered")
        }
    }

    /// The parcel left the shop.
    ///
    /// Like `markDelivered`, this does not move the status — a job in the post
    /// is finished work, and giving it a status of its own would take it out of
    /// every figure that counts finished work. `lib/order-status.js` owns the
    /// rule; this is the same call Khayt makes.
    func markShipped(_ id: Order.ID) async {
        var owed: [KhaytEngine.WebhookDelivery] = []
        let wrote = await writeToOneOrder(id, named: words.callIt("queue.shipped"), as: .person("orders", "edit")) { order, engine, root in
            let out = try await engine.markShipped(order: order, now: Date())
            guard out.ok, let changed = out.order else {
                throw MoveRefused(sentence: self.words.callIt("mac.not_finished_yet"))
            }
            owed = await Self.shippedDeliveries(before: order, after: changed, root: root, engine: engine)
            return OneOrderEdit(order: changed, activity: "\(id) → shipped")
        }
        if wrote, !owed.isEmpty { await fire(owed) }
    }

    /// The `order_shipped` webhook a parcel leaving owes, or none.
    ///
    /// The Mac shipped jobs and told no subscriber: Khayt's Ship dialog fires
    /// `order_shipped`, and a shop's fulfilment automation listening for it
    /// heard nothing from this app (Oct 2026). Only on the edge INTO shipped —
    /// a job already in the post, re-stamped, is not a second parcel, and a
    /// consumer counting parcels would count it twice.
    static func shippedDeliveries(before: JSONValue, after: JSONValue,
                                  root: [String: JSONValue],
                                  engine: KhaytEngine) async -> [KhaytEngine.WebhookDelivery] {
        if case .object(let was) = before, let at = was["shippedAt"], at != .null { return [] }
        let settings = Self.settings(root)
        return (try? await engine.webhookDeliveries(
            order: after,
            effects: [WebhookEffect(kind: "webhook", event: "order_shipped", newStatus: nil)],
            settings: settings,
            shopName: plainString(settings["bizEn"]) ?? plainString(settings["bizAr"]) ?? "Khayt",
            clientName: emailClientName(for: asObject(after) ?? [:], in: rows(root, "clients")),
            currency: shopCurrencyOf(settings),
            at: ISO8601DateFormatter().string(from: Date()),
            nowMs: Date().timeIntervalSince1970 * 1000)) ?? []
    }

    /// Hand a finished job to a carrier: who, which service, and the tracking
    /// number — `lib/shipment.js`, the Electron Ship dialog's own rule.
    ///
    /// Only a finished job not yet handed over, which is `markShipped`'s gate:
    /// a parcel cannot leave before the thing in it is made.
    func ship(_ id: Order.ID, carrier: String, service: String?, trackingNumber: String) async {
        var owed: [KhaytEngine.WebhookDelivery] = []
        let wrote = await writeToOneOrder(id, named: words.callIt("ship.title"), as: .person("orders", "edit")) { order, engine, root in
            guard case .object(let o) = order, o["status"] == .string("completed"),
                  o["deliveredAt"] == nil || o["deliveredAt"] == .null else {
                throw MoveRefused(sentence: self.words.callIt("mac.not_finished_yet"))
            }
            let shipped = try await engine.shipmentCreate(order: order, carrier: carrier, service: service,
                                                          trackingNumber: trackingNumber, at: Date())
            owed = await Self.shippedDeliveries(before: order, after: shipped, root: root, engine: engine)
            return OneOrderEdit(order: shipped, activity: "\(id) → shipped")
        }
        if wrote, !owed.isEmpty { await fire(owed) }
        // And the customer's page, which shows the parcel (order-flows.js
        // republishes after shipping, so the page shows the carrier and number).
        if wrote { await republishPortalIfPublished(id) }
    }

    /// A parcel already sent: a corrected tracking number, or a status picked
    /// by hand. Never moves it backwards — `carriers.advanceShippingStatus`.
    func updateShipment(_ id: Order.ID, status: String?, trackingNumber: String) async {
        let wrote = await writeToOneOrder(id, named: words.callIt("ship.manage_title"), as: .person("orders", "edit")) { order, engine, _ in
            OneOrderEdit(order: try await engine.shipmentUpdate(order: order, status: status,
                                                                trackingNumber: trackingNumber, at: Date()).order)
        }
        if wrote { await republishPortalIfPublished(id) }
    }

    /// The carriers the Ship sheet offers, Manual last and always there.
    func carriersToShipWith() async -> [KhaytEngine.CarrierChoice] {
        guard let engine else { return [] }
        return (try? await engine.carriersToShipWith(settings: .object(settingsDict))) ?? []
    }

    /// Undo a payment: the money was never received, or was recorded against
    /// the wrong job. Nothing leaves the shop, so nothing is refused.
    func clearPayment(_ id: Order.ID) async {
        let wrote = await writeToOneOrder(id, named: words.callIt("mac.clear_payment"), as: .person("invoicing", "edit")) { order, engine, _ in
            OneOrderEdit(order: try await engine.clearPayment(order: order).order)
        }
        // The customer's page showed it paid, as recording it republished it.
        if wrote { await republishPortalIfPublished(id) }
    }

    /// The shape both money edits share: one order, changed by the shared rules,
    /// written and stamped inside the same swap every other edit uses.
    /// True when the edit reached the book — what lets a caller send what the
    /// edit owes outward only for a change that was actually kept.
    ///
    /// `gate` is REQUIRED: what the edit is, to the staff lock. Every money
    /// and order edit funnels through here, and before the alpha.62 review
    /// half of them asked nothing — a viewer could clear a payment.
    @discardableResult
    func writeToOneOrder(_ id: Order.ID, named actionName: String, as gate: LockGate,
                                 change: @escaping (JSONValue, KhaytEngine, [String: JSONValue])
                                 async throws -> OneOrderEdit) async -> Bool {
        moveProblem = nil
        moveNotices = []
        guard permitted(gate) else { return false }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return false
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return false
        }

        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                guard let target = orders.first(where: { Self.recordId($0) == id }) else {
                    throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
                }
                let edit = try await change(target, engine, root)
                Self.write(&root, "printLog", changed: [edit.order], before: orders, into: &undo)
                // The shared rules ask for this and it is the app's to write. A
                // handover that reached the book but not the log would be the
                // one status change a shop most often has to explain later,
                // recorded nowhere.
                if let text = edit.activity {
                    Self.appendActivity(&root, text: text, ref: id,
                                        settings: Self.settings(root), root: root)
                }
            }
            registerMoveUndo(undo, named: actionName)
            await load(source)
            return true
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
            return false
        } catch {
            moveProblem = String(describing: error)
            return false
        }
    }

    /// One order after a rule changed it, and the line it asked for in the log.
    struct OneOrderEdit {
        let order: JSONValue
        var activity: String? = nil
    }

    // MARK: - Money an old defect took off the book

    /// What the affected orders are understating by, in total.
    var depositsUnaccounted: Double {
        (erasedDeposits.reduce(0) { $0 + $1.lost } * 100).rounded() / 100
    }

    /// Put one order's paid figure back.
    ///
    /// Through `writeToOneOrder` like every other money edit, so it takes the
    /// same ownership check, the same atomic swap and the same undo — a repair
    /// a shop cannot take back would be a worse thing to offer than none.
    ///
    /// The REPAIR is the shared rule's: this app does not decide what the
    /// figure should be, and the rule refuses an order that no longer looks
    /// affected, which is what makes a list read a minute ago harmless.
    func restoreDeposit(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("dep.restore_btn"), as: .person("invoicing", "edit")) { _, engine, root in
            let out = try await engine.restoreDeposit(orders: Self.rows(root, "printLog"),
                                                      orderId: id, settings: Self.settings(root))
            guard out.ok, let repaired = out.order else {
                throw MoveRefused(sentence: self.words.callIt("mac.deposit_not_affected"))
            }
            // A money figure changing under a shop's feet is exactly what the
            // activity log is for.
            return OneOrderEdit(order: repaired,
                                activity: "\(id) → " + self.words.callIt("dep.restored"))
        }
    }

    // MARK: - Paying over months

    /// Write a plan onto a job: three payments, a month apart, covering what is
    /// still owed.
    ///
    /// Every figure here comes from `lib/payment-plan.js` and
    /// `lib/order-money.js`. What is OWED — not the price — is the rule's own
    /// subtraction, gift cards and credit notes included: a plan built on
    /// price − paidAmount bills a customer for a credit note they were already
    /// given, and one built on the gross price bills the deposit twice.
    func makePlan(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("inst.generate"), as: .person("invoicing", "edit")) { order, engine, root in
            let owed = try await engine.owedRaw(order: order, settings: Self.settings(root))
            guard case .object(var record) = order else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
            }
            guard owed > 0 else {
                // Two different refusals, because they need two different
                // answers: a job with no price needs one typing in, and a
                // settled job needs nothing at all.
                let price = (Self.plainNumber(record["price"]) ?? 0)
                throw MoveRefused(sentence: self.words.callIt(
                    price > 0 ? "inst.nothing_owed" : "inst.need_price"))
            }
            let plan = try await engine.monthlyPlan(owed: owed, today: Self.localDay())
            guard !plan.isEmpty else {
                throw MoveRefused(sentence: self.words.callIt("inst.nothing_owed"))
            }
            record["instalments"] = .array(plan.map { row in
                .object([
                    "id": .string(Self.uid("INS")),
                    "amount": .number(row.amount),
                    "dueDate": .string(row.dueDate),
                    "note": .string(""),
                    "paid": .bool(false),
                    "paidAt": .null,
                ])
            })
            // The cash the job holds RIGHT NOW. The plan covers the balance, so
            // its rows are money on top of this rather than instead of it —
            // without this figure, collecting the plan in full either erases the
            // deposit or leaves it owed forever. Written only here, by the
            // generator, exactly as Khayt writes it.
            record["instalmentBase"] = .number((Self.plainNumber(record["paidAmount"]) ?? 0))
            return OneOrderEdit(order: .object(record),
                                activity: "\(id) → " + self.words.callIt("inst.title"))
        }
    }

    /// Collect one payment of a plan — or put it back.
    ///
    /// ── UNCOLLECTING DOES NOT TAKE THE MONEY BACK ─────────────────────────
    ///
    /// `collectionTotals` never returns less than the job already holds, and
    /// that is deliberate: `paidAmount` is the authoritative cash figure and can
    /// have grown since the plan was made — a payment taken at the counter and
    /// typed straight in. Lowering it here would destroy that cash. So clearing
    /// a row clears the ROW, and the notice says where the cash figure is
    /// corrected. An immediate mis-tap is ⌘Z, which puts both back.
    func collect(_ id: Order.ID, rowId: String, collected: Bool) async {
        await writeToOneOrder(id, named: words.callIt("inst.mark_paid"), as: .person("invoicing", "edit")) { order, engine, root in
            guard case .object(var record) = order,
                  case .array(let rows)? = record["instalments"] else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
            }
            let today = Self.localDay()
            var written: [JSONValue] = []
            var found = false
            for row in rows {
                guard case .object(var entry) = row else { written.append(row); continue }
                if case .string(let rid)? = entry["id"], rid == rowId {
                    found = true
                    entry["paid"] = .bool(collected)
                    // The day it was collected, cleared when it is put back:
                    // a row reading "not collected" with a collection date on
                    // it is a row two readers would answer differently.
                    entry["paidAt"] = collected ? .string(today) : .null
                }
                written.append(.object(entry))
            }
            guard found else { throw MoveRefused(sentence: self.words.callIt("mac.move_gone")) }

            let held = (Self.plainNumber(record["paidAmount"]) ?? 0)
            // The ORDER, not its price: a gift card and a credit note decide
            // when a plan's collections settle it, and so does tax added on top.
            let totals = try await engine.collectionTotals(
                order: .object(record), instalments: written, settings: Self.settings(root))
            record["instalments"] = .array(written)
            record["paidAmount"] = .number(totals.paidAmount)
            record["paymentStatus"] = .string(totals.paymentStatus)
            if !collected && totals.paidAmount >= held {
                self.moveNotices = [self.words.callIt("mac.plan_cash_stays")]
            }
            return OneOrderEdit(order: .object(record))
        }
    }

    /// Take the plan off a job.
    ///
    /// The plan goes; the money does not. Cash already collected stays on
    /// `paidAmount` because it was received — a schedule is an agreement about
    /// WHEN, not a record of what arrived. `instalmentBase` goes with the plan:
    /// it is meaningless without one, and a stale base left behind would be
    /// added to the next plan's collections.
    func dropPlan(_ id: Order.ID) async {
        await writeToOneOrder(id, named: words.callIt("common.remove"), as: .person("invoicing", "edit")) { order, _, _ in
            guard case .object(var record) = order else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_gone"))
            }
            record["instalments"] = .null
            record["instalmentBase"] = .null
            return OneOrderEdit(order: .object(record))
        }
    }

    /// What one job still owes, by the rule every other owed figure uses.
    ///
    /// Asked of the engine rather than subtracted here: `orderOwedRaw` takes
    /// gift cards and credit notes off as well as the cash, and it is the same
    /// figure the masthead and the Spending screen already show — a second
    /// subtraction would give the plan sheet an opinion of its own about what a
    /// customer owes.
    /// What a payment against this job can be — `KhaytOrderPayment.cashDue`.
    func cashDue(_ id: Order.ID) async -> KhaytEngine.CashDue? {
        guard let engine,
              let raw = orderRows.first(where: { Self.recordId($0) == id }) else { return nil }
        return try? await engine.cashDue(order: raw, settings: settingsDict)
    }

    func owedOn(_ id: Order.ID) async -> Double? {
        guard let engine,
              let raw = orderRows.first(where: { Self.recordId($0) == id }) else { return nil }
        return try? await engine.owedRaw(order: raw, settings: settingsDict)
    }

    // MARK: - Gift cards

    /// A code somebody can read down a telephone: no I/O/0/1, nothing to
    /// mishear. Only a SUGGESTION — the sheet lets it be typed over, and the
    /// shared rule has the final say on whether it is allowed.
    static func giftCardCode() -> String {
        let alphabet = Array("ACDEFGHJKLMNPQRTUVWXY2346789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    /// Issue one, through `lib/gift-card.js`.
    ///
    /// The rule builds the record and refuses the bad ones; this writes what it
    /// returns. Nothing is written when it refuses, so a rejected code leaves
    /// the book exactly as it was.
    /// Returns nil when the card was issued, or what to tell the shop.
    func issueGiftCard(code: String, balance: Double,
                       issuedTo: String?, expires: Date?) async -> String? {
        guard permitted("invoicing", "create") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine else { return "the engine is not loaded" }

        var input: [String: JSONValue] = [
            "code": .string(code),
            "initialBalance": .number(balance),
        ]
        if let issuedTo {
            input["issuedTo"] = .string(issuedTo)
            input["issuedToName"] = .string(clientNames[issuedTo]?.name ?? "")
        }
        if let expires { input["expiresAt"] = .string(Self.localDay(expires)) }

        let made: KhaytEngine.IssuedCard
        do {
            made = try await engine.newGiftCard(input, id: Self.uid("GC"),
                                                now: Self.isoNow(), existing: giftCardRows)
        } catch {
            return String(describing: error)
        }
        guard made.ok, let card = made.card else {
            // The rule answers with a key; the window owns the language.
            return words.callIt(made.error ?? "giftCardCodeInvalid")
        }

        do {
            try StoreWriter.update(storeURL: build.storeURL,
                                   owns: { StoreLock.weOwnIt(build) },
                                   whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }) { root in
                var rows: [JSONValue] = []
                if case .array(let existing)? = root["giftCards"] { rows = existing }
                rows.append(card)
                root["giftCards"] = .array(rows)
            }
        } catch {
            return String(describing: error)
        }
        await load(source)
        return nil
    }

    /// The same, for a file that arrived some other way.
    func addModelToLibrary(_ url: URL) async {
        guard permitted("inventory", "create") else { return }
        importing = true
        defer { importing = false }
        do {
            let added = try await LibraryImport.add(url, shop: self)
            Telemetry.feature(.libraryImport, in: self)
            let key = added.movedIn ? "mac.model_moved" : "mac.model_added"
            importNote = added.measured
                ? words.callIt(key,
                               ["name": .string(added.name),
                                "n": .number(Double(added.triangleCount ?? 0))])
                : words.callIt(key + "_plain", ["name": .string(added.name)])
        } catch let refusal as LibraryImport.Failure {
            importProblem = refusal.description
        } catch {
            importProblem = String(describing: error)
        }
    }

    // MARK: - Points a customer has earned

    /// Whether the shop runs a rewards programme at all.
    ///
    /// Off unless the shop turned it on, and then nothing below is drawn. A
    /// points line on a customer who earns none is a screen inventing a
    /// programme the shop never agreed to.
    var loyaltyOn: Bool {
        if case .bool(true)? = settingsDict["loyaltyEnabled"] { return true }
        return false
    }

    /// Where one customer stands: earned, spent, and left to spend.
    ///
    /// ── WHY THIS APP COULD NOT ANSWER IT ──────────────────────────────────
    ///
    /// The sum lived in `renderer/clients.js`, so a customer's points existed
    /// only in the other window — while the programme went on accruing them
    /// for a shop working here. It is `lib/loyalty.js` now, and this asks it.
    func loyalty(of clientId: String) async -> KhaytEngine.LoyaltyStanding? {
        guard loyaltyOn, let engine, !clientId.isEmpty else { return nil }
        return try? await engine.loyalty(orders: orderRows, ledger: loyaltyRows,
                                         clientId: clientId, settings: settingsDict,
                                         clients: clientRows)
    }
}
