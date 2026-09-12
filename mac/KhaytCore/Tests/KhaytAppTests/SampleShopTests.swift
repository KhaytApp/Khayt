import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The sample shop is what every screen is designed against, so a branch it
/// cannot reach is a branch nobody ever looks at.
///
/// ── WHAT THIS IS FOR ───────────────────────────────────────────────────────
///
/// The first time the product catalogue was ever photographed it showed twenty
/// rows reading `35%`, twenty reading "Rounded from", and a robot gripper
/// weighing 12,882 g. None of that was a bug in the screen. Every sample
/// product carried the same margin and the same rounding rule, and the
/// quantities had been assigned at random — the product literally named "Shelf
/// brackets, 24" was a batch of 4, while a prosthetic socket trial, which is a
/// one-off by definition, was a batch of 24.
///
/// A column where every row agrees is a column that has never been tested, and
/// it *looks* fine. So does a spool shelf where nothing can compute a rate.
/// These tests do not check any particular figure — they check that the sample
/// shop still SPANS the cases the screens have to draw.
@MainActor
struct SampleShopTests {

    static func book() throws -> [String: JSONValue] {
        let url = Bundle.module.url(forResource: "sample-shop", withExtension: "json")!
        let raw = try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: url))
        guard case .object(let o) = raw else { throw Oops.shape }
        return o
    }

    enum Oops: Error { case shape }

    static func rows(_ key: String) throws -> [[String: JSONValue]] {
        guard case .array(let a)? = try book()[key] else { return [] }
        return a.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    static func number(_ row: [String: JSONValue], _ key: String) -> Double? {
        if case .number(let n)? = row[key] { return n }
        return nil
    }

    // MARK: - The catalogue

    /// The margin column drew `35%` twenty times. A shop prices a commodity
    /// bracket and a bespoke prosthetic differently, and the screen has to show
    /// that it can.
    @Test("the sample products do not all carry the same margin")
    func marginsDiffer() throws {
        let margins = try Self.rows("products").map { Self.number($0, "defaultMargin") }
        let set = Set(margins.compactMap { $0 })
        #expect(set.count >= 5,
                "every sample product priced at the same margin: \(set.sorted())")
        // And a product nobody set a margin on, so the "—" the table draws for an
        // absent margin is a thing somebody has seen.
        #expect(margins.contains(where: { $0 == nil }),
                "no sample product leaves its margin unset, so the '—' never renders")
    }

    /// Three prices in the catalogue explain themselves three different ways —
    /// "Rounded from …", "Calculated", "Your own price". Nineteen of twenty rows
    /// said the same one.
    @Test("the sample products reach all three reasons a price can be what it is")
    func everyPriceReasonIsReachable() async throws {
        let products = try Self.rows("products").map { JSONValue.object($0) }
        let rows = try await KhaytEngine().catalogue(products, language: "en", settings: [:])
        let reasons = Set(rows.map(\.reason))
        for wanted in ["pe.price_is_rounded", "pe.price_is_base", "pe.price_is_override"] {
            #expect(reasons.contains(wanted),
                    "no sample product ever shows '\(wanted)': \(reasons.sorted())")
        }
    }

    /// A product that says how many it is has to BE that many.
    ///
    /// This is the test the loose one below could not be. "Shelf brackets, 24"
    /// was a batch of 4 and "Signage letters, 12" a batch of 1, so the weight
    /// column was quietly answering a different question from the one the name
    /// asked. Nothing about the total hours was implausible enough to notice.
    @Test("a sample product that names a count is a batch of that many")
    func namedCountsMatchTheQuantity() throws {
        for p in try Self.rows("products") {
            guard case .string(let name)? = p["nameEn"],
                  case .array(let parts)? = p["parts"] else { continue }
            // The last run of digits in the name: "Cable chain, 40 links" → 40.
            let counts = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            // "Drone arm v4" is a version, not a count. Only a name with a comma
            // before the number is stating how many.
            guard name.contains(","), let said = counts.last else { continue }
            let qty = parts.reduce(0.0) { total, part in
                if case .object(let pt) = part { return total + (Self.number(pt, "qty") ?? 1) }
                return total
            }
            #expect(Int(qty) == said, "\(name) is a batch of \(Int(qty))")
        }
    }

    /// A batch of twenty-four one-hour prints is a day of machine time; a batch
    /// of twenty-four twenty-four-hour prints is most of a month. A floor, not a
    /// proof: it catches a generated absurdity, not a bad estimate.
    @Test("no sample product asks for more machine time than a month has")
    func batchesArePrintable() throws {
        for p in try Self.rows("products") {
            guard case .array(let parts)? = p["parts"] else { continue }
            var hours = 0.0, grams = 0.0
            for case .object(let pt) in parts {
                let q = Self.number(pt, "qty") ?? 1
                hours += (Self.number(pt, "printTime") ?? 0) * q
                grams += ((Self.number(pt, "printWeight") ?? 0)
                          + (Self.number(pt, "supportWeight") ?? 0)) * q
            }
            let name = { if case .string(let s)? = p["nameEn"] { return s } else { return "?" } }()
            #expect(hours <= 24 * 30, "\(name) takes \(Int(hours)) machine hours")
            // 20 kg is four of the biggest spools this shop stocks.
            #expect(grams <= 20_000, "\(name) weighs \(Int(grams)) g")
        }
    }

    // MARK: - The shelf

    /// A spool's rate per gram needs what it weighed NEW, and not one sample
    /// spool carried that — so the spool card fell to "what it cost" on all six,
    /// every fill bar read full, and the rate branch was never once drawn.
    @Test("every sample spool says what it weighed new, and none of them is full")
    func spoolsCanShowARate() throws {
        let spools = try Self.rows("inventory")
        #expect(!spools.isEmpty)
        for s in spools {
            let new = Self.number(s, "spoolWeight")
            #expect(new != nil, "a sample spool has no spoolWeight, so it can show no rate")
            if let new, let left = Self.number(s, "weight") {
                #expect(left <= new, "a spool with more left than it ever held")
            }
        }
        // Six untouched 1 kg spools is not a shop. The fill levels have to differ,
        // or a bar that draws the wrong percentage looks correct.
        let fill = Set(spools.compactMap { s -> Int? in
            guard let new = Self.number(s, "spoolWeight"), new > 0,
                  let left = Self.number(s, "weight") else { return nil }
            return Int((left / new * 100).rounded())
        })
        #expect(fill.count >= 4, "the sample spools all sit at the same fill: \(fill.sorted())")
    }

    /// The tax on a purchase is a real field now, and a book that carries none
    /// of it shows nothing of the work. It must also carry a purchase with NO
    /// tax — an import — because "absent is zero" is the rule that keeps every
    /// existing shop's numbers still.
    @Test("the sample shop has purchases with reclaimable tax, and one without")
    func vatIsBothPresentAndAbsent() throws {
        let spools = try Self.rows("inventory")
        let taxed = spools.filter { (Self.number($0, "vatAmount") ?? 0) > 0 }
        #expect(!taxed.isEmpty, "no sample spool records the tax inside its price")
        #expect(taxed.count < spools.count,
                "every sample spool reclaims tax, so the imported case never renders")
        for s in taxed {
            let vat = Self.number(s, "vatAmount") ?? 0
            let cost = Self.number(s, "cost") ?? 0
            #expect(vat < cost, "a spool whose tax is not less than its price")
        }
    }
}

extension SampleShopTests {

    /// The Arabic catalogue read half in English.
    ///
    /// Ten of twenty sample products carried no `nameAr` at all, so a shop
    /// looking at Khayt in Arabic — the market this app is for — saw ten rows
    /// of English in a right-to-left table. Nothing was broken: the language
    /// fallback did exactly what it should, ten times in a row.
    ///
    /// A few stay in English on purpose, because a Riyadh shop does keep some
    /// technical names as they came ("HVAC duct adapter"), and because that
    /// fallback is itself a thing worth having seen once.
    @Test("the sample catalogue is mostly Arabic, and not entirely")
    func mostProductsHaveAnArabicName() throws {
        let products = try Self.rows("products")
        let named = products.filter {
            if case .string(let s)? = $0["nameAr"] { return !s.trimmingCharacters(in: .whitespaces).isEmpty }
            return false
        }
        #expect(named.count * 4 >= products.count * 3,
                "only \(named.count) of \(products.count) sample products have an Arabic name")
        #expect(named.count < products.count,
                "every product is translated, so the language fallback never renders")
    }
}

extension SampleShopTests {

    /// The sample shop was three filament printers and nothing else, so no
    /// screen had ever drawn any other kind of machine — the nozzle row, the
    /// wear block and the band's "cannot ask" line were all only ever seen in
    /// the one case they were written for.
    @Test("the sample shop runs more than filament printers")
    func moreThanFilament() async throws {
        let machines = try Self.rows("machines").map { JSONValue.object($0) }
        let kinds = try await KhaytEngine().machineKinds(machines)
        let seen = Set(kinds.values.map(\.kind))
        #expect(seen.contains("fdm"))
        #expect(seen.count >= 3,
                "one kind of machine draws one version of every machine screen: \(seen.sorted())")
        // And at least one Khayt cannot poll, which is the case that must not
        // look like a printer that has stopped answering.
        #expect(kinds.values.contains { !$0.polled },
                "nothing here exercises 'Khayt has no protocol for this'")
        #expect(kinds.values.contains { $0.polled })
    }

    /// The shelf was six spools of filament, so no screen had ever drawn a
    /// quantity in anything but grams — and every one of them wrote the gram
    /// after the number by hand.
    @Test("the sample shelf holds more than filament")
    func moreThanGrams() async throws {
        let rows = try Self.rows("inventory").map { JSONValue.object($0) }
        let units = try await KhaytEngine().inventoryUnits(rows, settings: [:])
        let seen = Set(units.values.map(\.unit))
        #expect(seen.contains("g"))
        #expect(seen.count >= 3,
                "one unit on the shelf draws one version of every stock screen: \(seen.sorted())")
        // Each measure prices in its own denominator, which is the one place
        // the gram assumption was load bearing rather than cosmetic.
        let rates = Set(units.values.map(\.rateKey))
        #expect(rates.count >= 3, "every item priced per kilo: \(rates.sorted())")
    }

    /// Low means something different per unit, and the shelf has to be able to
    /// show that: two sheets left is low, and 180 g of the same number is not.
    @Test("something on the sample shelf is low in a unit that is not grams")
    func lowInAnotherUnit() async throws {
        let rows = try Self.rows("inventory").map { JSONValue.object($0) }
        let units = try await KhaytEngine().inventoryUnits(rows, settings: [:])
        let lowNonGram = try Self.rows("inventory").contains { item in
            guard case .string(let id)? = item["id"], let u = units[id], u.unit != "g",
                  case .number(let left)? = item["weight"] else { return false }
            return left <= u.low
        }
        #expect(lowNonGram, "nothing exercises a threshold that is not the gram one")
    }

    /// The setups panel draws three verdicts and one refusal, and the versions
    /// panel only appears for a file that has more than one. Until this file
    /// carried any setups at all, none of that had ever been drawn.
    @Test("the sample library reaches every setup verdict, and a file nothing works on")
    func setupSpread() async throws {
        let files = try Self.rows("printFiles")
        let engine = try KhaytEngine()
        var verdicts: Set<String> = []
        var sawNothingWorks = false
        var sawUntried = false
        var withSetups = 0

        for file in files {
            let read = try await engine.printSetups(.object(file))
            guard read.total > 0 else { continue }
            withSetups += 1
            for setup in read.setups {
                verdicts.insert(setup.status)
                if setup.ok == 0 && setup.failed == 0 { sawUntried = true }
            }
            if read.recommendedId == nil { sawNothingWorks = true }
        }

        #expect(withSetups > 0, "no sample file records what it was printed with")
        #expect(verdicts == ["known-good", "needs-test", "failed"],
                Comment(rawValue: "the sample reaches only \(verdicts.sorted())"))
        // The panel says "change something" rather than naming the least broken
        // setup. That branch needs a file where everything has failed.
        #expect(sawNothingWorks, "every sample file has something that works, so the no-good-setup line is never drawn")
        // Never printed is not a score of nought, and the two are drawn
        // differently.
        #expect(sawUntried, "no sample setup is untried, so that caption is never drawn")
        #expect(withSetups < files.count,
                "every file records its settings, which is not what a real library looks like")
    }

    @Test("exactly one kind of sample file offers a choice of version")
    func versionSpread() async throws {
        let files = try Self.rows("printFiles")
        let engine = try KhaytEngine()
        var many = 0
        var implicitOnly = 0

        for file in files {
            let read = try await engine.printVersions(.object(file))
            if read.many { many += 1 }
            if read.versions.count == 1, read.versions[0].implicit { implicitOnly += 1 }
        }

        #expect(many > 0, "no sample file has versions, so the panel is never drawn")
        // And most do not, which is why the panel is hidden for a single
        // version rather than drawn as a list of one.
        #expect(implicitOnly > 0, "every sample file has versions, so a print that has only ever been one thing is never drawn")
    }

    /// The consumables card draws three different reasons an item is on it,
    /// and refuses to name a quantity for a fourth. Until this file carried any
    /// consumables at all, none of that had ever been drawn.
    ///
    /// `now` is PINNED. The usage rate is measured over a trailing window, so
    /// a guard run against `Date()` passes today and reports "no rate" in a
    /// month when the sample's own jobs have aged out of it — which would make
    /// this test quietly stop checking the thing it exists for.
    @Test("the sample shelf reaches every reason a consumable is reordered")
    func consumableSpread() async throws {
        let shelf = try Self.rows("consumables")
        #expect(!shelf.isEmpty, "no consumables — the card is never drawn")

        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-05T00:00:00Z"))
        let needs = try await KhaytEngine().consumableNeeds(
            consumables: shelf.map { JSONValue.object($0) },
            orders: try Self.rows("printLog").map { JSONValue.object($0) },
            now: now)

        #expect(needs.contains { $0.low && $0.stock == 0 },
                "nothing on the sample shelf has run out")
        #expect(needs.contains { $0.low && $0.stock > 0 },
                "nothing is below its minimum without being empty")
        // The case a shop cannot see by looking at the rack: still above its
        // minimum, but the rate eats it inside the lead time.
        #expect(needs.contains { !$0.low && ($0.daysLeft ?? .infinity) > 0 },
                "nothing is listed for its forecast alone")
        // And one the rule will not put a number against, because no rate and
        // no minimum is not a quantity — inventing one lands on a purchase order.
        #expect(needs.contains { $0.suggestQty == 0 },
                "every sample item gets a suggested quantity, so the refusal is never drawn")
        // Something with a measurable rate, or every figure on the card is zero.
        #expect(needs.contains { $0.perDay > 0 },
                "no sample job consumes a consumable, so no rate is ever computed")

        // Not everything is on the list: a well-stocked shelf must be able to
        // stay off it, or the card is just a list of the consumables table.
        let listed = Set(needs.map(\.id))
        let all = Set(shelf.compactMap { row -> String? in
            if case .string(let id)? = row["id"] { return id } else { return nil }
        })
        #expect(!all.subtracting(listed).isEmpty,
                "every sample consumable is being reordered, which cannot be right")
    }

    /// The maintenance card draws four statuses and two clocks. Until this
    /// file carried any tasks at all, none of those branches had ever been
    /// drawn, let alone looked at.
    @Test("the sample shop reaches all four maintenance statuses")
    func maintenanceSpread() async throws {
        let tasks = try Self.rows("machMaintTasks")
        #expect(!tasks.isEmpty, "no maintenance tasks — the card is never drawn")

        let jobs = try Self.rows("printLog").map { JSONValue.object($0) }
        let taskValues = tasks.map { JSONValue.object($0) }
        var seen: Set<String> = []
        var machinesWithTasks: Set<String> = []
        let engine = try KhaytEngine()

        for machine in try Self.rows("machines") {
            guard case .string(let id)? = machine["id"] else { continue }
            let card = try await engine.maintenance(
                machineId: id, tasks: taskValues, jobs: jobs,
                machine: .object(machine), now: Date())
            if !card.tasks.isEmpty { machinesWithTasks.insert(id) }
            for task in card.tasks { seen.insert(task.status) }
        }

        // A status the card can draw but the sample cannot reach is a status
        // nobody has looked at.
        #expect(seen == ["ok", "warning", "due", "overdue"],
                Comment(rawValue: "the sample reaches only \(seen.sorted())"))

        // And a machine with none, so the card's other branch — leaving the
        // section out entirely rather than drawing an empty heading — is drawn
        // too. Most shops have set no tasks up at all.
        let machineIds = try Self.rows("machines")
        let all = Set(machineIds.compactMap { row -> String? in
            if case .string(let id)? = row["id"] { return id } else { return nil }
        })
        #expect(!all.subtracting(machinesWithTasks).isEmpty,
                "every sample machine has tasks, so the no-tasks card is never drawn")
    }

    /// A task whose status depends on the wall clock drifts: one set to be
    /// "due" when this file was written reads "overdue" a month later, and the
    /// case it was added to cover stops being covered.
    @Test("a date-driven sample task cannot drift out of the case it covers")
    func dateTasksAreStable() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for task in try Self.rows("machMaintTasks") {
            guard let days = Self.number(task, "intervalDays"), days > 0,
                  case .string(let last)? = task["lastDoneAt"],
                  let done = iso.date(from: last) else { continue }
            // Already past 1.5x the interval, so it stays overdue however long
            // after this file was written the app is opened.
            let elapsed = Date().timeIntervalSince(done) / 86_400
            #expect(elapsed > days * 1.5,
                    "a date-driven sample task must be far enough past due to stay overdue")
        }
    }

    @Test("every machine in the sample shop says which kind it is")
    func everyMachineSaysSo() throws {
        for m in try Self.rows("machines") {
            guard case .string(let kind)? = m["kind"] else {
                Issue.record("a sample machine has no kind, so it is read as FDM by default rather than by choice")
                continue
            }
            #expect(!kind.isEmpty)
        }
    }
}
