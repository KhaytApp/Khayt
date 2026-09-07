import Foundation

/// Khayt's business logic, typed, on one serialised queue.
///
/// Every screen in the Mac app asks this for a number. Nothing above it ever
/// sees a `JSValue`, and nothing below it is written twice: the arithmetic is
/// the same code the Electron app runs, and `MoneyParityTests` fails if the two
/// ever disagree.
///
/// A `JSContext` must be touched from one thread at a time, so the runtime is
/// confined to an actor. Calls are cheap — JSON across a boundary in the same
/// process — and none of them do I/O.
public actor KhaytEngine {
    private let runtime: JSRuntime

    /// The modules this engine exposes, in dependency order.
    static let modules = [
        "tax",
        "pricing",
        "payment-plan",
        "split-order",
        "business-scope",
        "order-progress",
        "loyalty",
        // How long a nozzle lasts, and what wears it out.
        //
        // THE DATA MODULE MUST COME FIRST. `nozzle-wear` reads it through
        // `require`, and under JavaScriptCore there is no require — it falls
        // back to `global.KhaytNozzleWearData`, which only exists if that file
        // has already run. Without it the module still LOADS and then throws on
        // the first call, which is a failure that arrives from inside a screen
        // with no clue why. Verified identical to Node's answer with it.
        "nozzle-wear-data",
        "nozzle-wear",
        // `filament-dryness` is NOT here. It reads `driedAt` — when a spool
        // was last DRIED — and belongs to Bed Ready's dry log, whose records
        // the `inventory` collection does not carry. Wiring it to the filament
        // shelf produced a column of dashes and would have produced a column of
        // wrong answers the moment anything filled that field in.
        // What one order is worth and what is owed on it, and which orders
        // count towards a period. Both lifted out of the renderer so this app
        // could use the same rules rather than invent a second opinion about
        // revenue.
        "order-money",
        // Gift cards. AFTER order-money, which it reads off the global to ask
        // what an order still owes — the question it used to answer itself, in
        // the renderer, with the credit notes left out.
        "gift-card",
        // Whether a model goes on a bed. Six numbers, and until it was lifted
        // out of `mf-convert` it could only be asked during a conversion — by
        // the one app that can run one.
        "print-fit",
        // Where a model came from and what may be done with it. Pure, and the
        // one place that decides whether a print may be sold.
        "model-licence",
        // ── THE CONVERTER ────────────────────────────────────────────────
        //
        // In dependency order, because each reads the one above it off the
        // global: the profiles and the two colour strategies first, then the
        // mixer, the mesh codec that needs it, and the converter last.
        //
        // `mf-convert` also reaches for `zip-read` and `zip-write`, and it does
        // NOT get them: both are built on Node's zlib and neither can exist
        // here. That is the whole design — `convertMembers` never touches a
        // zip, and Swift does the reading and writing at the two ends.
        "printer-profiles",
        "color-bands",
        "swap-pauses",
        "filament-mixer",
        "mf-mesh",
        "full-spectrum",
        "mf-convert",
        "kpi-rows",
        "kpi",
        // What needs a shop's attention, and the figures on the dashboard.
        // Pure, zero requires, and already assigning onto globalThis — so the
        // screen a shop opens on is the same arithmetic the Electron app shows,
        // not a Swift opinion about which orders are late.
        "attention",
        "dashboard-facts",
        // Two more things the shop is meant to chase, each with its own
        // selector rather than a branch inside `attention`: an invoice past
        // its due date and still unpaid, and a quote about to expire without
        // an answer. Both were settings this app could not set and rules it
        // did not run, so the toggle in the Operations pane would have been a
        // switch wired to nothing.
        "payment-reminder",
        "quote-followup",
        // Colour, in CIELAB and CIEDE2000. Pure, no DOM, and the only place
        // in the app that knows a printed colour is not an RGB average: two
        // spools mix in LINEAR light, and "closest" means perceptual distance
        // rather than the nearest hex triple.
        "color-mix",
        // Groups and categories. Pure, and bundled rather than ported because
        // the rule that matters is not the reading — it is that a name matching
        // one already in use IS that name and adopts its spelling. "Saudi Kings"
        // and "saudi kings" as two groups, each holding part of one collection,
        // is precisely the mess this module exists to prevent.
        "organise",
        // Not business logic — the one list of which store fields hold
        // credentials. Bundling it is what stops the Mac app from becoming a
        // sixth hand-maintained copy; SafeStorage encrypts exactly these.
        "store-secret-paths",
        // What happens to a job when its stage changes: what may move, and what
        // moving it costs. Lifted out of renderer/order-flows.js so this app can
        // move a job by the same rules rather than reimplement the most
        // consequential write in Khayt a second way.
        //
        // ASSEMBLY MUST COME FIRST. `order-status` consults `KhaytAssembly`
        // through a `typeof` guard, so without it the completion gate does not
        // crash — it silently stops gating, and this app would let a shop
        // complete an assembly whose parts have not passed QC while the Electron
        // app refuses. A missing module that changes an answer instead of
        // raising is the worst kind, so it is listed rather than guarded against.
        "assembly",
        "order-status",
        // What a finished job takes off the shelf: the grams, the hourly
        // consumables, the bought-in components, the packaging. Lifted out of
        // renderer/inventory.js because the move being shared is not enough —
        // a completion that silently failed to deduct would leave a shop
        // ordering filament it does not have.
        "order-deduction",
        // What a shop has been paid, and what that makes an order. One answer
        // to "is this paid" instead of the three that had drifted apart — the
        // smallest of which was the one that WROTE the field the others read.
        "order-payment",
        // Changing a job's own details, and remembering that it changed. Five
        // fields are recorded because those are the ones a customer can be told
        // a different answer about later.
        "order-edit",
        // A job that failed inspection: the fields the metrics count, the
        // defect the analytics table is built from, and the waste row.
        "qc-failure",
        // What one part of a job costs to make, and what a new job IS. The
        // record was written inline in logPrint, reading twenty form controls,
        // which is why only the Electron window could create one — and why this
        // app could not replace it.
        //
        // WORKING-WEEK FIRST: order-new estimates a due date from it and reaches
        // it through a global, so listing it after would give every new job a
        // default eight-hour day instead of the shop's own.
        "working-week",
        // What a print costs money at when nobody has said otherwise. BEFORE
        // calculator-cost, because it supplies four of the six things that
        // module adds up — and a caller that omits them gets a price with
        // material in it and no error at all.
        "print-rates",
        "calculator-cost",
        "order-new",
        // Which language a shop writes its customers' names in, and which of
        // them to show. Not the interface language: a shop that writes only
        // Arabic must not be shown the stale English name left over from setup.
        "content-languages",
        // The document a customer is handed, and the QR a Saudi tax invoice
        // must carry. INVOICE-LANGUAGE FIRST: the document asks it whether to
        // print a second language, through a global, so listing it after would
        // give every invoice the English-only answer.
        "invoice-language",
        "zatca-qr",
        // PRINT-DATE FIRST: the document's own date formatter reaches it
        // through a global, and without it every invoice this app printed
        // showed the raw ISO timestamp under DATE.
        "print-date",
        "invoice-document",
        // The currencies a shop can price in, and how a settings form is
        // saved. The save was a 240-line literal inside the Electron settings
        // page, which is why only that page could change a setting; lifted so
        // the Mac's Settings window writes the same record by the same clamps.
        "currencies",
        "settings-edit",
        // The expense book, a failed print written down by hand, and which
        // records fall in "this month". The three rules the Expenses, Waste
        // and Reports screens are built on; each was inline in a renderer
        // handler before, which is why only the Electron window had them.
        "date-range",
        "expense-book",
        "waste-entry",
        // A spool, as the shelf records it, and what correcting one means.
        // The two writers were inline in renderer/inventory.js, so only the
        // Electron window could add a spool or fix a weight — and a shop's
        // shelf drifts every day.
        "spool-edit",
        // A machine, and what picking a printer model fills in. NOZZLE-WEAR IS
        // ALREADY ABOVE and must be: the threshold falls back to what a nozzle
        // material is expected to last, and without it a shop gets a
        // maintenance figure of zero rather than one it can act on.
        // PRINTER-FACTS FIRST. The catalogue reaches it through a global and
        // falls back to nothing when it is absent — so without it every
        // printer comes back with no nozzle material, no hotend limit and no
        // chamber, and the machine sheet quietly offers a shop less than the
        // Electron one does. It does not raise; it just knows less.
        "printer-facts",
        "printer-catalog",
        "machine-edit",
        // What a shop's Telegram bot says when a job moves. Built inline in
        // renderer/integrations.js, so this app had no way to say it — which
        // is why it refused to finish a job for any shop with a bot.
        "telegram-message",
        // The shop's quarters. ORDER-MONEY AND TAX ARE ALREADY ABOVE, and both
        // must be: this consults them through their globals, and without them
        // it does not raise — it reports every order at its gross price and no
        // tax collected at all.
        "pnl-report",
        // Who owes the shop money and how long they have owed it. ORDER-MONEY
        // AND ORDER-PAYMENT ARE ALREADY ABOVE and must be: it reaches both
        // through globals, and without them every order reads as unpaid at its
        // gross price.
        "receivables",
        // Which of a shop's backups may be rotated away, and which is the
        // insurance it would want after a schema change.
        "upgrade-backup",
        // What a shop's own copy of its book looks like, and what must not be
        // in it. `redactSettingsForExport` is what stands between an
        // accountant and a shop's API keys, and it is data-driven so that
        // adding a shipping carrier does not quietly export the next one's
        // credentials — which is exactly why it is not rewritten here.
        "store",
        // What a printer is doing. `printer-status` first: `moonraker` reaches
        // its progress and ETA rules through a global, and without it a shop
        // would see 0% on every machine rather than an error.
        "printer-status",
        "moonraker",
        // The two other HTTP protocols whose reading is a module. Duet and
        // Repetier have modules too and are NOT here: both need a session
        // handshake before the first read, and building a handshake against a
        // machine nobody can point at is how a poller ships that has never
        // once been answered.
        "octoprint",
        "prusalink",
        // What the machine itself remembers. The nozzle-wear counter reads
        // completed ORDERS, so a machine that has extruded twelve kilos while
        // nineteen of its jobs were customer orders reports a fraction of its
        // real wear — and the replacement warning fires late, in the direction
        // that ruins parts.
        "moonraker-history",
        // What has just gone wrong with a printer: the thresholds, the
        // cooldowns and the stall clock. Pure, and already wrapped.
        "printer-alerts",
        // Whether an address is a printer on the shop's own network. Not
        // business logic — an SSRF guard — and shared for the same reason the
        // secret list is: a second, more forgiving copy in Swift is how the two
        // apps come to disagree about what they are willing to connect to.
        "printer-host",
        // Who the shop's best customers are and what it is asked for most.
        // ORDER-MONEY, CONTENT-LANGUAGES, BUSINESS-SCOPE AND DATE-RANGE ARE ALL
        // ALREADY ABOVE and must be: it reaches every one of them through a
        // global, and without them the lists do not raise — they report every
        // customer at zero and every name as an id.
        "top-lists",
        // The catalogue: what a product costs to sell and what its parts add up
        // to. CONTENT-LANGUAGES IS ALREADY ABOVE and must be — a product's name
        // is read through it, and the shop that keeps this book writes in two
        // languages.
        "product-price",
        "product-specs",
        // The merge engine. `applyDeltas` is what folds a chain from the cloud
        // onto a base, and it is the same function the Electron app merges
        // with — a second opinion about which of two edits wins is the one
        // thing sync must never have.
        "sync",
        // What this device holds that the cloud does not — the rule behind
        // "send what is only here". It sits beside `sync` because it builds the
        // payload `sync.applyDeltas` folds, and gets the answer wrong in a way
        // that costs a shop data if the two ever disagree about a rev.
        "cloud-outbox",
        // …and the other direction. AFTER `sync`, which it folds with.
        "cloud-inbox",
        // What counts as a Khayt store at all. Restoring a backup REPLACES a
        // shop's book, so the one thing that must not be a second opinion is
        // which files are allowed to do that — the renderer learned the hard
        // way that a salvaging normaliser says yes to a package.json.
        "store-validate",
        // What the shop has earned month by month, and what next month looks
        // like on that evidence. ORDER-MONEY IS ALREADY ABOVE and must be: the
        // series is built by handing `forecast` a money function, and one that
        // read `o.price` instead would count a foreign job at its face value
        // and every credit note at nothing.
        "forecast",
        // What a slicer's configs say a model is printed in. `colorsFromConfigs`
        // takes the config TEXT rather than an open zip, which is what lets it
        // be shared at all: `lib/zip-read.js` needs Buffer and zlib, and the
        // Mac opens a 3MF with its own reader.
        "thumbnail-extract",
        // What makes two library records the same MESH. Bundled so the key this
        // app writes is the key Khayt reads — three numbers joined by
        // punctuation is exactly what two implementations agree on until they
        // do not.
        //
        // `model-identity.js` itself is NOT here and cannot be: its
        // `contentHash` falls back to `require('crypto')`, and both drift
        // guards refuse a bundled module that names Node — rightly, since a
        // guarded require is still a require somebody will later unguard. The
        // pure half was split into `geometry-key.js` for that reason, and
        // `model-identity` re-exports it. Swift does the SHA-256.
        "geometry-key",
        // The shop's slicers, and which programs may be launched as one.
        //
        // The allowlist matters more than the list. A slicer path and its
        // argument template both live in `settings.slicers[]`, which arrives in
        // a restored backup and through cloud sync — so an entry somebody else
        // wrote decides what this app executes. `isAllowedSlicerBinary` is the
        // rule that says no, and it is shared rather than rewritten here for
        // exactly the reason a second, more forgiving copy in Swift is the way
        // two apps come to disagree about what they are willing to run. The
        // Electron app spent months not calling it at all.
        "slicers",
        // When this shop could have a new order printed, finished and posted —
        // and the snapshot a storefront quotes that from.
        //
        // ATTENTION IS ALREADY ABOVE and must be: the publisher asks it whether
        // a machine is printing, and a machine reported idle is a lane a
        // customer gets promised. `lead-time` before `lead-time-publish`, which
        // reaches it through a global for the same reason.
        //
        // This is the one thing only the Electron main process did. Every six
        // hours it published this shop's promise, and a storefront stops
        // quoting when it goes stale — so a Mac with Electron shut down took
        // the shop's delivery dates offline with it.
        "lead-time",
        "lead-time-publish",
    ]

    /// The languages whose strings are bundled.
    ///
    /// Two, not nine: these are 200KB each and the app only shows one at a time.
    /// English because it is the fallback, Arabic because it is the language the
    /// other half of this shop's customers read — and because right-to-left is a
    /// layout property, not a translation, so it has to be exercised now rather
    /// than retrofitted across a dozen finished screens.
    static let locales = ["en", "ar"]

    public init(bundle: Bundle? = nil) throws {
        runtime = try JSRuntime(modules: Self.modules, locales: Self.locales, bundle: bundle)
    }

    // MARK: - Words

    /// Khayt's own translation of a key, or nil when it has none.
    ///
    /// Never invents. A key this app needs and Khayt does not have belongs in the
    /// Mac app's own small catalogue, where it is visibly the app's own word
    /// rather than something silently diverging from the Electron build's.
    /// Every string Khayt has in a language.
    ///
    /// Fetched whole and once, rather than a key at a time: this crosses the
    /// bridge with four thousand strings, which is cheap once and absurd per
    /// label. The caller holds the result for the life of the language.
    public func translations(language: String) throws -> [String: String] {
        try raw("(globalThis.KhaytLocales||{})['\(language)']||{}", as: [String: String].self)
    }

    // MARK: - Tax

    /// The shop's tax profile, resolved the way every invoice resolves it.
    public func taxProfile(settings: [String: JSONValue]) throws -> TaxProfile {
        try runtime.call("KhaytTax", "profileFromSettings", [settings], as: TaxProfile.self)
    }

    /// Split a price into net and tax, honouring the profile's mode.
    public func computeTax(_ amount: Double, profile: TaxProfile) throws -> TaxSplit {
        try runtime.call("KhaytTax", "computeTax", [amount, profile], as: TaxSplit.self)
    }

    // MARK: - Payment plans

    /// A dated schedule. `total` is what is OUTSTANDING, never the gross price:
    /// passing the gross bills a deposit the customer has already handed over.
    public func buildSchedule(total: Double, deposit: Double = 0, installments: Int,
                              firstDueDate: String, intervalDays: Int) throws -> [Installment] {
        let arg: [String: JSONValue] = [
            "total": .number(total), "depositAmount": .number(deposit),
            "installments": .number(Double(installments)),
            "firstDueDate": .string(firstDueDate), "intervalDays": .number(Double(intervalDays)),
        ]
        return try runtime.call("KhaytPaymentPlan", "buildSchedule", [arg], as: [Installment].self)
    }

    // MARK: - Splitting a job

    /// Divide price, deposit and credit notes across machines by cost weight.
    /// The last share absorbs every remainder, so the parts add back up exactly.
    public func splitMoney(price: Double, paid: Double, credited: Double,
                           costs: [Double]) throws -> [SplitShare] {
        let arg: [String: JSONValue] = [
            "price": .number(price), "paid": .number(paid),
            "credited": .number(credited), "costs": .array(costs.map { .number($0) }),
        ]
        return try runtime.call("KhaytSplitOrder", "splitMoney", [arg], as: [SplitShare].self)
    }

    // MARK: - Quoting

    public func quoteTotal(_ input: [String: JSONValue]) throws -> QuoteTotal {
        try runtime.call("KhaytPricing", "quoteTotal", [input], as: QuoteTotal.self)
    }

    // MARK: - The dashboard

    /// What a shop needs to look at, and the state of the fleet.
    ///
    /// `attention` is passed IN because `dashboard-facts` is pure and refuses to
    /// reach for a global — the module says so, and honouring it here is what
    /// keeps one attention engine rather than two.
    /// `statusCache` is what the printers last said, keyed by machine id — the
    /// same shape `main.js` keeps. Without it every machine reads as neither
    /// live nor offline, so the fleet tile said `0/1` while the machine beside
    /// it was demonstrably printing.
    public func dashboardFacts(orders: [JSONValue], machines: [JSONValue],
                               settings: [String: JSONValue],
                               statusCache: [String: JSONValue] = [:]) throws -> DashboardFacts {
        // `nozzleWear` IS PASSED IN, and the whole nozzle category depends on
        // it: `attention` is pure and refuses to reach for a global, so a
        // caller that does not supply it gets no nozzle warnings at all — not
        // an error, just silence. That module's own comment says the warning
        // exists because it "existed on the machine card and NOWHERE on any
        // dashboard, which is the one screen a shop leaves open", and this app
        // had reproduced exactly that.
        try runtime.call2("KhaytDashboardFacts.dashboardFacts({orders: ARG0, machines: ARG1,"
                        + " settings: ARG2, statusCache: ARG3,"
                        // THE MODULE, not a function. `dashboardFacts` reads
                        // `inp.nozzleWear.nozzleWear` and wraps it itself; the
                        // renderer calls `selectAttention` DIRECTLY and passes
                        // a function, which is that module's contract. Same
                        // parameter name, two shapes, and handing over the
                        // wrong one produces no error — just no nozzle
                        // warnings, for ever.
                        + " nozzleWear: globalThis.KhaytNozzleWear,"
                        + " attention: globalThis.KhaytAttention})",
                          [.array(orders), .array(machines), .object(settings), .object(statusCache)],
                          as: DashboardFacts.self)
    }

    /// The shop's own spools, ranked by how close each is to a wanted colour.
    ///
    /// Every number here is `lib/color-mix.js`: sRGB to CIELAB, then CIEDE2000
    /// for the distance. None of it is a Swift opinion about colour, and that
    /// matters more here than in most places — the obvious implementation
    /// (Euclidean distance between hex triples) ranks a dark blue closer to
    /// black than to a slightly lighter blue, and a shop would be handed the
    /// wrong spool.
    public func nearestFilaments(to hex: String, among spools: [JSONValue],
                                 limit: Int = 8) throws -> [ColourMatch] {
        try runtime.call2("KhaytColor.nearest(ARG0, ARG1, {key: 'color', limit: ARG2})",
                          [.string(hex), .array(spools), .number(Double(limit))],
                          as: [ColourMatch].self)
    }

    /// Two colours mixed in linear light. `t` 0 is all of the first, 1 all of
    /// the second. Nil when either is not a colour.
    public func blend(_ a: String, _ b: String, _ t: Double) throws -> String? {
        try runtime.call2("KhaytColor.blend(ARG0, ARG1, ARG2)",
                          [.string(a), .string(b), .number(t)], as: String?.self)
    }

    /// An N-step gradient between two colours, both ends included. Empty when
    /// either end is not a colour — the module's own answer, not a guess.
    public func gradient(_ a: String, _ b: String, steps: Int) throws -> [String] {
        try runtime.call2("KhaytColor.gradient(ARG0, ARG1, ARG2)",
                          [.string(a), .string(b), .number(Double(steps))],
                          as: [String].self)
    }

    // MARK: - Where a model came from

    /// What a model's licence lets a shop do.
    ///
    /// `lib/model-licence.js`. `known` false means nobody has recorded one, and
    /// every field below it is then meaningless — a shop that has filled
    /// nothing in must not be told it may not sell its own work, so `sellable`
    /// is an OPTIONAL Bool and nil is a different sentence from false.
    public struct Standing: Decodable, Sendable {
        public let known: Bool
        public let licence: String
        public let source: String
        public let sellable: Bool?
        public let attribution: Bool
        public let derivatives: Bool?
    }

    public func licenceStanding(source: String?, licence: String?) throws -> Standing {
        try runtime.call2("KhaytModelLicence.standing({ source: ARG0, licence: ARG1 })",
                          [.string(source ?? ""), .string(licence ?? "")], as: Standing.self)
    }

    // MARK: - Converting a 3MF

    /// The printers a 3MF can be converted for.
    ///
    /// `lib/printer-profiles.js`'s own list, not a Swift copy of it: the ids
    /// are what `convertMembers` is given, and a second list here would be a
    /// menu offering a printer the converter cannot name.
    public struct PrinterProfile: Decodable, Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        /// How many filaments it can hold. Nil for a single-material machine
        /// that does not say.
        public let maxColors: Int?
    }

    public func printerProfiles() throws -> [PrinterProfile] {
        try runtime.call2("""
            KhaytPrinterProfiles.listProfiles().map((p) => (
              { id: p.id, name: p.name, maxColors: p.maxColors == null ? null : p.maxColors }
            ))
            """, [], as: [PrinterProfile].self)
    }

    /// What a converted 3MF should contain.
    ///
    /// `lib/mf-convert.js`'s `convertMembers`: members in, members out. The
    /// zip at either end is Swift's, because `zip-read` and `zip-write` are
    /// built on Node's zlib and cannot exist here — which is the reason this
    /// module could not be loaded at all until its decisions were given a door.
    ///
    /// A member the conversion did not touch comes back with NO data, only its
    /// name. That is not an omission: it means "copy the bytes that were
    /// already there", and it is what keeps a 400 MB mesh out of this process
    /// entirely. The caller must copy it from the file it read.
    public struct ConvertedMember: Decodable, Sendable {
        public let name: String
        /// The new contents, when this member was rewritten. Nil means the
        /// original bytes, unchanged.
        public let text: String?
    }

    public struct Conversion: Decodable, Sendable {
        public let ok: Bool
        public let error: String?
        public let members: [ConvertedMember]?
        public let report: JSONValue?
    }

    public func convertMembers(_ members: [JSONValue],
                               options: [String: JSONValue]) throws -> Conversion {
        try runtime.call2("""
            (function (members, opts) {
              const planned = KhaytMfConvert.convertMembers(members, opts);
              if (!planned.ok) return { ok: false, error: planned.error };
              return {
                ok: true,
                report: planned.report,
                // `data` is a Buffer in Node and a string here, so what comes
                // back is the TEXT of a rewritten member and nothing at all for
                // one that was left alone. A config is XML or JSON; the members
                // this rewrites are never binary.
                members: planned.members.map((m) => (
                  m.data == null ? { name: m.name } : { name: m.name, text: String(m.data) }
                )),
              };
            })(ARG0, ARG1)
            """, [.array(members), .object(options)], as: Conversion.self)
    }

    // MARK: - The shelf

    /// Which spools are running low, by id.
    ///
    /// `lib/order-deduction.js`, whose own comment is the reason: "one
    /// definition so the banner, the row badge, the reorder list and the
    /// deduction never disagree about the same spool." A Swift
    /// `weight <= 200` beside it would be a fifth opinion, and the one the
    /// shop reads on the shelf.
    public func lowStock(_ spools: [JSONValue],
                         settings: [String: JSONValue]) throws -> [String: Bool] {
        try runtime.call2("""
            (function (rows, settings) {
              const out = {};
              for (const s of rows || []) {
                if (s && s.id != null) out[String(s.id)] = !!KhaytOrderDeduction.isLowStock(s, settings);
              }
              return out;
            })(ARG0, ARG1)
            """, [.array(spools), .object(settings)], as: [String: Bool].self)
    }

    // MARK: - Will it fit

    /// The best a shop can do with the machines it owns.
    ///
    /// `lib/print-fit.js`. Not a Swift comparison of six numbers, because the
    /// tolerance, the height rule and whether turning it a quarter turn helps
    /// are all decisions — and the converter answers the same question from the
    /// same module, so a model this screen calls too big cannot be one the
    /// conversion report waves through.
    public struct Fit: Decodable, Sendable {
        /// `fits`, `rotate` or `none`.
        public let verdict: String
        public let machine: JSONValue?
        /// How many machines had a bed recorded to try. Zero means nothing is
        /// known, which is NOT the same as nothing fitting.
        public let checked: Int
    }

    public func bestFit(_ bounds: (x: Double, y: Double, z: Double),
                        among machines: [JSONValue]) throws -> Fit {
        try runtime.call2("KhaytPrintFit.bestFit({x: ARG0, y: ARG1, z: ARG2}, ARG3)",
                          [.number(bounds.x), .number(bounds.y), .number(bounds.z),
                           .array(machines)],
                          as: Fit.self)
    }

    // MARK: - Gift cards

    /// What every card is today — `active`, `used` or `expired` — keyed by id.
    ///
    /// `lib/gift-card.js`, not a Swift comparison of two date strings. The order
    /// it decides in is part of the answer: an expired card with nothing left on
    /// it reads EXPIRED, because that says why it cannot be used where "used"
    /// would suggest the customer had the benefit of it.
    ///
    /// ALL OF THEM IN ONE CROSSING, like `customerNames` and for the same
    /// reason — a table asking per row pays a context hop per row, and this one
    /// is drawn on every keystroke in the search field.
    public func giftCardStatuses(_ cards: [JSONValue], today: String) throws -> [String: String] {
        try runtime.call2("""
            (function (cards, today) {
              const out = {};
              for (const c of cards || []) {
                if (c && c.id != null) out[String(c.id)] = KhaytGiftCard.status(c, today);
              }
              return out;
            })(ARG0, ARG1)
            """, [.array(cards), .string(today)], as: [String: String].self)
    }

    /// What a new card should be, or why it cannot be issued.
    ///
    /// `error` is a KEY rather than a sentence, so the window says it in the
    /// shop's own language.
    public struct IssuedCard: Decodable, Sendable {
        public let ok: Bool
        public let card: JSONValue?
        public let error: String?
    }

    public func newGiftCard(_ input: [String: JSONValue], id: String, now: String,
                            existing: [JSONValue]) throws -> IssuedCard {
        try runtime.call2("""
            (function (input, ctx) { return KhaytGiftCard.newCard(input, ctx); })(
                ARG0, { id: ARG1, now: ARG2, existing: ARG3 })
            """,
            [.object(input), .string(id), .string(now), .array(existing)],
            as: IssuedCard.self)
    }

    /// Invoices the shop is meant to chase for payment.
    ///
    /// `owedOf` is a FUNCTION in the module's signature — deliberately, so
    /// currency conversion stays with the caller — and a function cannot cross
    /// the JSON bridge. What crosses is a table of id to outstanding balance,
    /// already converted by `order-money`, and the closure is written here in
    /// JavaScript around it. Same trick as `kpis` above.
    ///
    /// The `.map` is a projection and not arithmetic: `daysOverdue` is the
    /// module's own, so the figure on screen is the one it selected on.
    public func invoicesToChase(orders: [JSONValue], settings: [String: JSONValue],
                                owed: [String: Double], now: Date = Date()) throws -> [Chase] {
        try runtime.call2(
            "KhaytPaymentReminder.selectInvoicesDueForReminder(ARG0, ARG1,"
          + " function (o) { return ARG2[o.id] || 0; }, ARG3)"
          + ".map(function (o) { return {id: o.id, name: o.project || '',"
          + " days: KhaytPaymentReminder.daysOverdue(o, ARG3)}; })",
            [.array(orders), .object(settings),
             .object(owed.mapValues(JSONValue.number)),
             .number(now.timeIntervalSince1970 * 1000)],
            as: [Chase].self)
    }

    /// Quotes about to expire without an answer.
    public func quotesToChase(orders: [JSONValue], settings: [String: JSONValue],
                              now: Date = Date()) throws -> [Chase] {
        try runtime.call2(
            "KhaytQuoteFollowUp.selectQuotesDueForFollowUp(ARG0, ARG1, ARG2)"
          + ".map(function (q) { return {id: q.id, name: q.project || '',"
          + " days: KhaytQuoteFollowUp.daysUntilExpiry(q, ARG2)}; })",
            [.array(orders), .object(settings),
             .number(now.timeIntervalSince1970 * 1000)],
            as: [Chase].self)
    }

    /// The headline figures for a period.
    ///
    /// Three shared modules in one expression, which is the point:
    /// `order-money` says what an order earned and what is owed on it,
    /// `kpi-rows` says which orders count and what "on time" means, and `kpi`
    /// adds them up. None of it is arithmetic written in Swift.
    ///
    /// The money function is written HERE, in JavaScript, because a function
    /// cannot cross the JSON bridge — and because these are the same calls the
    /// renderer makes, from the same module.
    public func kpis(orders: [JSONValue], clients: [JSONValue],
                     settings: [String: JSONValue], range: String,
                     language: String) throws -> Kpis {
        let script = KPI_SCRIPT
        return try runtime.call2(script,
                                 [.array(orders), .array(clients), .object(settings),
                                  .string(range), .string("\u{2014}"), .string(language)],
                                 as: Kpis.self)
    }

    // A note kept from when this was not yet possible:
    //
    // It takes rows a caller has already scoped to a date range, converted to
    // base currency and marked completed/on-time — `renderer/analytics.js` does
    // that in `rowsFor(range)`, which is private to the renderer. Handing it
    // `{orders, settings}` compiles, runs, and returns every figure as ZERO,
    // which is how this app briefly showed a shop "0 SAR revenue" beside a
    // toolbar reading 52,691.57.
    //
    // Revenue and margin wait until that normalising is lifted into `lib/`
    // where both apps can share it. A bridge method that quietly answers zero
    // is worse than no bridge method.

    // MARK: - The shop floor

    /// How worn ONE machine's nozzle is, from the grams it has actually printed.
    ///
    /// `nozzleWear(printLog, machine, settings)` — POSITIONAL, and one machine at
    /// a time. Handed a single options object instead it takes that object as
    /// the print log, finds it is not an array, loops over nothing, and reports
    /// every nozzle as 0 of the DEFAULT 5,000g threshold rather than the one the
    /// machine actually carries. It looked right on screen. Checked against the
    /// source, not inferred from the name, after `KhaytKpi.computeKpis` had
    /// already cost this app a screenful of zeros the same way.
    // MARK: - What the shop has earned, month by month

    /// One month of the shop's takings.
    public struct RevenueMonth: Decodable, Sendable, Equatable, Identifiable {
        /// `year * 12 + month`, from the module — a sortable key that does not
        /// go through a date and cannot pick up a timezone on the way.
        public let key: Int
        /// Already formatted by the module, so both apps label a month the same.
        public let label: String
        public let revenue: Double
        public var id: Int { key }
    }

    public struct RevenueOutlook: Decodable, Sendable, Equatable {
        public let history: [RevenueMonth]
        public let projection: [Projected]
        public let nextMonth: Double
        /// How next month compares with last, as a percentage — nil when there
        /// is no last month to compare with. A shop's first month has no trend
        /// and saying "up 100%" would be inventing one.
        public let trendPct: Double?
        /// `trend`, `average` or `none`. `none` means too little to say
        /// anything, and the screen says nothing rather than drawing a flat line
        /// through two points and calling it a forecast.
        public let method: String

        public struct Projected: Decodable, Sendable, Equatable, Identifiable {
            public let key: Int
            public let label: String
            public let projected: Double
            public var id: Int { key }
        }
    }

    /// The last `months` complete months of revenue, and what the next ones look
    /// like on that evidence.
    ///
    /// `renderer/analytics.js` draws its own chart from this exact call, with
    /// this exact money function — so the Mac's dashboard and Khayt's analytics
    /// screen are reading the same numbers rather than two opinions about
    /// revenue.
    ///
    /// The money function is written in JavaScript inside the bridge for the
    /// same reason `kpis` does it: a function cannot cross the JSON bridge, and
    /// the alternative is this app having its own idea of what an order earned.
    ///
    /// `now` is milliseconds. The module buckets by month in UTC and never asks
    /// a clock.
    public func revenueOutlook(orders: [JSONValue], clients: [JSONValue],
                               settings: [String: JSONValue],
                               now: Double, months: Int = 6,
                               periods: Int = 1) throws -> RevenueOutlook {
        try runtime.call2("""
        (function () {
          var ctx = { settings: ARG2, clients: ARG1 };
          var M = globalThis.KhaytOrderMoney;
          return globalThis.KhaytForecast.forecast(ARG0, {
            now: ARG3, months: ARG4, periods: ARG5,
            revenueOf: function (o) { return M.orderNetRevenueBase(o, ctx); }
          });
        })()
        """,
        [.array(orders), .array(clients), .object(settings),
         .number(now), .number(Double(months)), .number(Double(periods))],
        as: RevenueOutlook.self)
    }

    // MARK: - What a model is printed in

    /// The filament colours a 3MF's slicer configs describe.
    public struct Colours: Decodable, Sendable, Equatable {
        public let colors: [JSONValue]
        public let swapCount: Int
    }

    /// Reads the CONFIG TEXT, not a zip — see `lib/thumbnail-extract.js`. Three
    /// slicer formats and their precedence live there, and re-implementing them
    /// is how two apps come to disagree about what a model is printed in.
    public func coloursFromConfigs(sliceInfo: String, projectSettings: String,
                                   modelSettings: String, prusa: String) throws -> Colours {
        try runtime.call2("""
        globalThis.KhaytThumb.colorsFromConfigs({
          sliceInfo: ARG0, projectSettings: ARG1, modelSettings: ARG2, prusa: ARG3
        })
        """,
        [.string(sliceInfo), .string(projectSettings), .string(modelSettings), .string(prusa)],
        as: Colours.self)
    }

    // MARK: - Is this the same model

    /// The key for "the same mesh, however it was packaged".
    ///
    /// `triangleCount:volume:XxYxZ`, rounded the way `lib/model-identity.js`
    /// rounds it — which is the reason this crosses the bridge at all rather
    /// than being three numbers joined in Swift. A format agreed by two
    /// implementations is a format that drifts, and this one is compared
    /// against records the other app wrote.
    ///
    /// Returns nil for geometry with no substance, so an unmeasured model never
    /// acquires an identity another unmeasured one would share.
    public func geometryKey(triangleCount: Int, volumeMm3: Double,
                            x: Double, y: Double, z: Double) throws -> String? {
        try runtime.call2("""
        (globalThis.KhaytGeometryKey.geometryKey({
          triangleCount: ARG0, volumeMm3: ARG1, bbox: { x: ARG2, y: ARG3, z: ARG4 }
        }) || null)
        """,
        [.number(Double(triangleCount)), .number(volumeMm3),
         .number(x), .number(y), .number(z)],
        as: String?.self)
    }

    // MARK: - The shop's slicers

    /// One slicer as the shop has it configured.
    public struct Slicer: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let path: String
        public let args: String

        /// Spelled out because `Decodable` alone synthesises only `init(from:)`,
        /// and the settings pane builds these rather than decoding them.
        public init(id: String, name: String, path: String, args: String = "") {
            self.id = id
            self.name = name
            self.path = path
            self.args = args
        }
    }

    /// Every slicer this shop has set up, in `lib/slicers.js`'s reading of the
    /// settings — including the legacy single `settings.slicer`, which shops
    /// that predate the list still carry.
    public func slicers(settings: [String: JSONValue]) throws -> [Slicer] {
        try runtime.call2("KhaytSlicers.listSlicers(ARG0)", [.object(settings)], as: [Slicer].self)
    }

    /// The one to reach for when nobody has said which: `defaultSlicerId`, or
    /// the first configured.
    public func defaultSlicer(settings: [String: JSONValue]) throws -> Slicer? {
        try runtime.call2("(KhaytSlicers.defaultSlicer(ARG0) || null)",
                          [.object(settings)], as: Slicer?.self)
    }

    /// A friendly name for a slicer, guessed from its path.
    ///
    /// `Snapmaker_Orca` → "Snapmaker Orca", `orca-slicer.exe` → "OrcaSlicer".
    /// Shared because the name a shop is offered when Khayt finds a slicer and
    /// the name the Mac offers must be the same name, or one shop's settings
    /// read differently in its two apps.
    public func slicerDisplayName(path: String) throws -> String {
        try runtime.call2("KhaytSlicers.slicerDisplayName(ARG0)", [.string(path)], as: String.self)
    }

    /// MAY THIS PROGRAM BE LAUNCHED AS A SLICER?
    ///
    /// Asked of every path before it is run, never assumed from the fact that
    /// it is in the settings. The path arrives in a restored backup or a cloud
    /// sync, so it is somebody else's input; the argument template beside it is
    /// too. Positive allowlist — the name has to look like a slicer — because a
    /// denylist of interpreters cannot be complete: `awk`, `find`, `xargs`,
    /// `make`, `git` and `busybox` each run an arbitrary command from their own
    /// arguments and not one of them is a shell.
    public func mayLaunchAsSlicer(path: String) throws -> Bool {
        try runtime.call2("KhaytSlicers.isAllowedSlicerBinary(ARG0)",
                          [.string(path)], as: Bool.self)
    }

    // MARK: - What the shop can promise

    /// The snapshot a storefront quotes this shop's delivery dates from — or
    /// nil when the shop has not turned that on.
    ///
    /// Returned as RAW JSON rather than a Swift struct, deliberately. What
    /// comes back goes straight into `PUT /v1/shops/{id}/lead-time` and is read
    /// by a storefront this app knows nothing about; decoding it into named
    /// Swift fields would quietly drop anything the module adds later, and the
    /// symptom would be a storefront missing a field rather than a build error
    /// here.
    ///
    /// `today` must be the shop's LOCAL day and `nowIso` the injected clock —
    /// `lib/lead-time.js` never asks one. A UTC-derived day from a +03:00 shop
    /// just after midnight promises yesterday.
    public func leadTimeSnapshot(settings: [String: JSONValue], printLog: [JSONValue],
                                 machines: [JSONValue], today: String, nowIso: String,
                                 statusCache: [String: JSONValue] = [:]) throws -> JSONValue? {
        let out = try runtime.call2(
            "KhaytLeadTimePublish.buildSnapshot({settings: ARG0, printLog: ARG1, machines: ARG2,"
          + " today: ARG3, nowIso: ARG4, statusCache: ARG5})",
            [.object(settings), .array(printLog), .array(machines),
             .string(today), .string(nowIso), .object(statusCache)],
            as: JSONValue.self)
        if case .null = out { return nil }
        return out
    }

    public func nozzleWear(orders: [JSONValue], machine: JSONValue,
                           settings: [String: JSONValue]) throws -> NozzleWear {
        try runtime.call2("KhaytNozzleWear.nozzleWear(ARG0, ARG1, ARG2)",
                          [.array(orders), machine, .object(settings)], as: NozzleWear.self)
    }

    // MARK: - Groups

    /// One of the shop's group names, and how many things carry it.
    ///
    /// `counts` returns pairs — `["Saudi Kings", 7]` — rather than objects, so
    /// this decodes positionally. Keeping the JS shape rather than reshaping it
    /// in the bridge means one less place for the two to drift.
    public struct GroupCount: Decodable, Sendable, Equatable {
        public let name: String
        public let count: Int
        public init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            name = try row.decode(String.self)
            count = try row.decode(Int.self)
        }
    }

    /// The names a shop has actually used, most-used first, with counts.
    ///
    /// One call for the whole library rather than one per row: building a
    /// JSContext call is cheap and doing it four hundred times to draw a sidebar
    /// is not.
    public func groupCounts(_ records: [JSONValue]) throws -> [GroupCount] {
        try runtime.call("KhaytOrganise", "counts", [JSONValue.array(records), "group"],
                         as: [GroupCount].self)
    }

    /// The patch that files a record under a name — `{group, folder}`, both set.
    ///
    /// Shared rather than ported precisely because of `unify`: a name matching
    /// one the shop already uses adopts that spelling, so "saudi kings" typed
    /// into the box files a model with the Saudi Kings rather than beside them.
    /// `folder` is written alongside `group` because records from earlier builds
    /// have only `folder`, and `bedready-library.js` still reads it directly.
    public func fileUnderGroup(_ name: String, known: [String]) throws -> [String: JSONValue] {
        let patch: [String: JSONValue] = ["group": .string(name)]
        let knownNames: [String: JSONValue] = ["group": .array(known.map { .string($0) })]
        return try runtime.call("KhaytOrganise", "assign",
                                [JSONValue.object([:]), patch, knownNames],
                                as: [String: JSONValue].self)
    }

    /// The name one record is filed under. `folder` wins over `group` — see the
    /// module header: it is a sync decision, not an accident.
    public func groupOf(_ record: JSONValue) throws -> String {
        try runtime.call("KhaytOrganise", "groupOf", [record], as: String.self)
    }

    // MARK: - Order progress

    /// How far along an order is, for the tracker a customer sees. An unknown
    /// status reports "started" rather than "nothing has happened".
    public func progressIndex(status: String) throws -> Int {
        try runtime.call("KhaytOrderProgress", "progressIndex", [status], as: Int.self)
    }

    /// Escape hatch for logic not yet given a typed method. Deliberately
    /// awkward to reach for: anything a screen needs twice belongs above.
    /// Every store field that holds a credential, from the same list the
    /// Electron app encrypts from. Not a Swift copy: a Swift copy is how the
    /// two apps come to disagree about which secrets are protected, and being
    /// on one list and not another has already leaked a webhook key here.
    ///
    /// `machines[].printerApi.apiKey` means "for every element of machines".
    public func secretPaths() throws -> [String] {
        try runtime.value("KhaytStoreSecretPaths", "SECRET_PATHS", as: [String].self)
    }

    // MARK: - Moving a job

    /// May this job move to `status`?
    ///
    /// This is the half of the status rules a screen that only SHOWS work
    /// needs: it is what greys out a drop target before anything is dragged
    /// onto it. Performing the move — stamping `completedAt`, deducting the
    /// filament and the packaging, settling the hold, moving the customer's
    /// tier — is `apply()` in the same module, and this app does not call it
    /// yet. The board shows where the work is piling up; the rules it would
    /// need to move a card now exist in one place rather than two.
    ///
    /// `orders` is the whole log because a WIP limit is a fact about a column,
    /// not about a job.
    public func statusGate(order: JSONValue, to status: String,
                           orders: [JSONValue],
                           settings: [String: JSONValue]) throws -> StatusGate {
        let ctx: JSONValue = .object(["orders": .array(orders), "settings": .object(settings)])
        return try runtime.call("KhaytOrderStatus", "gate",
                                [order, status, ctx], as: StatusGate.self)
    }

    /// Where this move would reach outside the shop's own book.
    ///
    /// Ask BEFORE moving anything. A webhook, a Telegram message, an email or a
    /// portal refresh cannot be sent from here and cannot be sent later, so a
    /// move that would trigger one has to be refused rather than half-made. An
    /// empty list is the common case: a shop with no integrations configured.
    public func outbound(order: JSONValue, to status: String,
                         settings: [String: JSONValue],
                         clients: [JSONValue]) throws -> [Outbound] {
        try runtime.call2("KhaytOrderStatus.outboundFor(ARG0, ARG1, {settings: ARG2, clients: ARG3})",
                          [order, .string(status), .object(settings), .array(clients)],
                          as: [Outbound].self)
    }

    /// Move a job to a stage, and take what it costs off the shelf.
    ///
    /// Both shared modules in one expression, which is the point: `order-status`
    /// says what happens to the job and asks for the deductions, `order-deduction`
    /// performs them on the spools and consumable rows it is handed. None of it
    /// is arithmetic written in Swift, and none of it is a second opinion about
    /// whether a job is finished.
    ///
    /// The three collections come back changed. Write all three or none — the
    /// job saying "completed" while the spools still hold its filament is a shop
    /// that has been told it has stock it has already used.
    ///
    /// `holdReason` is why a job is being put on hold, and is only ever read
    /// when it is. Nil means "say nothing about it"; an empty string means "no
    /// reason given", which is a different thing from the last hold's reason
    /// being left behind.
    ///
    /// `qcNotes` records a PASS on a job leaving inspection. Nil means the
    /// completion was not an inspection and the QC fields are left alone —
    /// pretending otherwise would make a shop's pass rate a fiction.
    public func moveJob(order: JSONValue, to status: String,
                        orders: [JSONValue], settings: [String: JSONValue],
                        inventory: [JSONValue], consumables: [JSONValue],
                        machines: [JSONValue],
                        now: Date, today: String,
                        holdReason: String? = nil,
                        qcNotes: String? = nil) throws -> JobMove {
        let qc: JSONValue = qcNotes.map {
            .object(["outcome": .string("pass"), "notes": .string($0)])
        } ?? .null
        return try runtime.call2(MOVE_SCRIPT,
                          [order, .string(status), .array(orders), .object(settings),
                           .array(inventory), .array(consumables), .array(machines),
                           .number(now.timeIntervalSince1970 * 1000), .string(today),
                           holdReason.map(JSONValue.string) ?? .null, qc],
                          as: JobMove.self)
    }

    /// Hand a finished job over: `deliveredAt`, and the status left alone.
    public func markDelivered(order: JSONValue, now: Date) throws -> Handover {
        try runtime.call2(
            "(function(){ var o = ARG0;"
          + " var r = KhaytOrderStatus.markDelivered(o, { now: ARG1 });"
          + " return { ok: r.ok, order: r.ok ? o : null }; })()",
            [order, .number(now.timeIntervalSince1970 * 1000)], as: Handover.self)
    }

    /// Change a job's due date and priority, and write the edit down.
    ///
    /// `dueDate` nil clears it — a job with no due date is a real answer.
    /// Returns the order unchanged and no effects when nothing actually moved,
    /// so an editor opened and closed again writes no revision.
    public func editJob(order: JSONValue, dueDate: String?, priorityLevel: String,
                        now: Date, editId: String) throws -> JobEdited {
        try runtime.call2(
            "(function(){ var o = ARG0;"
          + " var r = KhaytOrderEdit.applyEdit(o, { dueDate: ARG1, priorityLevel: ARG2 },"
          + "                                 { now: ARG3, id: ARG4 });"
          + " return { order: o, changed: Object.keys(r.changes).length > 0 }; })()",
            [order, dueDate.map(JSONValue.string) ?? .null, .string(priorityLevel),
             .number(now.timeIntervalSince1970 * 1000), .string(editId)],
            as: JobEdited.self)
    }

    /// The priority a job is at, however old the record is.
    public func priority(of order: JSONValue) throws -> String {
        try runtime.call("KhaytOrderEdit", "priorityOf", [order], as: String.self)
    }

    /// Record a QC failure: the order, the defect, and the waste row.
    ///
    /// The waste row comes BACK rather than being pushed into a list, because
    /// this app writes the collection itself, inside the same swap as the
    /// order — three records that must land together or not at all.
    public func recordQcFailure(order: JSONValue, failureType: String, severity: String,
                                reason: String, weight: Double, inspector: String?,
                                inventory: [JSONValue], now: Date,
                                wasteId: String, defaultReason: String,
                                settings: [String: JSONValue] = [:],
                                machines: [JSONValue] = [], today: String = "") throws -> QcFailure {
        try runtime.call2(QC_FAILURE_SCRIPT,
                          [order, .string(failureType), .string(severity), .string(reason),
                           .number(weight), inspector.map(JSONValue.string) ?? .null,
                           .array(inventory), .number(now.timeIntervalSince1970 * 1000),
                           .string(wasteId), .string(defaultReason),
                           .object(settings), .array(machines), .string(today)],
                          as: QcFailure.self)
    }

    // MARK: - The document a customer is handed

    /// May a ZATCA QR be drawn for this shop, and if not, which field is missing?
    ///
    /// A QR missing a required tag SCANS and is invalid, which is worse than no
    /// QR at all: a code that reads invites no question.
    public func zatcaReadiness(settings: [String: JSONValue],
                               sellerName: String) throws -> StatusGate.Reason? {
        struct Readiness: Decodable { let ok: Bool; let missing: [String] }
        let r = try runtime.call2("KhaytZatcaQr.readiness(ARG0, ARG1)",
                                  [.object(settings), .string(sellerName)], as: Readiness.self)
        guard !r.ok else { return nil }
        return StatusGate.Reason(code: "zatca_not_ready",
                                 params: ["missing": .array(r.missing.map(JSONValue.string))])
    }

    /// The QR payload: five BER-TLV tags, base64'd.
    public func zatcaPayload(sellerName: String, vatNumber: String, timestamp: String,
                             total: String, vatAmount: String) throws -> String {
        try runtime.call2(
            "KhaytZatcaQr.buildTLV({sellerName: ARG0, vatNumber: ARG1, timestamp: ARG2,"
          + " total: ARG3, vatAmount: ARG4}, {})",
            [.string(sellerName), .string(vatNumber), .string(timestamp),
             .string(total), .string(vatAmount)], as: String.self)
    }

    /// The invoice, as HTML.
    ///
    /// The same four hundred lines the Electron window prints.
    ///
    /// The document takes FUNCTIONS — how to escape, how to format money, what
    /// a label is called — and a function cannot cross a JSON bridge. So they
    /// are built in JavaScript, from the locale catalogue this runtime already
    /// has loaded, and only the DATA comes from Swift. See `INVOICE_SCRIPT`.
    public func invoiceHtml(order: JSONValue, settings: [String: JSONValue],
                            clients: [JSONValue], currencies: [String: JSONValue],
                            language: String, money: [String: JSONValue],
                            sellerName: String, sellerAddress: String) throws -> InvoiceDocument {
        try runtime.call2(INVOICE_SCRIPT,
                          [order, .object(settings), .array(clients), .object(currencies),
                           .string(language), .object(money),
                           .string(sellerName), .string(sellerAddress)],
                          as: InvoiceDocument.self)
    }

    // MARK: - The shop's own settings

    /// The settings as a save leaves them.
    ///
    /// `form` carries only the keys a screen showed; every other setting keeps
    /// its value. That is the rule's one deliberate difference from the
    /// Electron page, and it is what lets a Business tab save the phone number
    /// without zeroing the WIP limits it never displayed.
    public func applySettings(_ settings: [String: JSONValue], form: [String: JSONValue],
                              year: Int) throws -> [String: JSONValue] {
        try runtime.call2("KhaytSettingsEdit.apply(ARG0, ARG1, {year: ARG2})",
                          [.object(settings), .object(form), .number(Double(year))],
                          as: [String: JSONValue].self)
    }

    /// The settings after a country is chosen for tax rules: name, rate,
    /// pricing convention and registration label together, with the legacy
    /// VAT fields kept in step.
    public func chooseTaxCountry(_ settings: [String: JSONValue], code: String) throws -> [String: JSONValue] {
        try runtime.call2("KhaytSettingsEdit.chooseCountry(ARG0, ARG1)",
                          [.object(settings), .string(code)], as: [String: JSONValue].self)
    }

    /// The tax rules Khayt knows by country, keyed by ISO code.
    public func taxPresets() throws -> [String: TaxProfile] {
        try runtime.value("KhaytTax", "PRESETS", as: [String: TaxProfile].self)
    }

    /// The currencies a shop can price in.
    public func currencies() throws -> [String: Currency] {
        try runtime.value("KhaytCurrencies", "CURRENCIES", as: [String: Currency].self)
    }

    /// The languages the shop writes its own text in — one or two, never none.
    public func contentLanguages(settings: [String: JSONValue]) throws -> [String] {
        try runtime.call2("KhaytContentLanguages.contentLangs(ARG0)", [.object(settings)], as: [String].self)
    }

    /// The store key for one of the shop's text fields in one language:
    /// `bizEn`, `bizAr`, `biz_fr`. Asked rather than assumed, because the
    /// suffix rule is the whole back-compatibility story of that module.
    public func fieldKey(_ base: String, language: String) throws -> String {
        try runtime.call2("KhaytContentLanguages.fieldKey(ARG0, ARG1)",
                          [.string(base), .string(language)], as: String.self)
    }

    /// One of the shop's own text fields — its name, tagline, address — in the
    /// language asked for, by the same fallback every Khayt document uses:
    /// that language only if the shop writes in it, then the shop's own
    /// languages, then anything filled in at all.
    public func shopText(_ base: String, settings: [String: JSONValue], language: String) throws -> String {
        try runtime.call2("(KhaytContentLanguages.read(ARG0, ARG1, ARG2, ARG0) || '')",
                          [.object(settings), .string(base), .string(language)], as: String.self)
    }

    /// A language's own name — "Deutsch", not "German".
    public func languageName(_ code: String) throws -> String {
        try runtime.call2("KhaytContentLanguages.languageName(ARG0)", [.string(code)], as: String.self)
    }

    // MARK: - What the shop spent, and what it wasted

    /// Whether a record's date falls in a period — the same rule every list in
    /// Khayt filters through.
    public func inRange(_ date: String, period: String, now: Date) throws -> Bool {
        try runtime.call2("KhaytDateRange.inRange(ARG0, ARG1, {now: new Date(ARG2)})",
                          [.string(date), .string(period), .number(now.timeIntervalSince1970 * 1000)],
                          as: Bool.self)
    }

    /// One expense, as the book records it. `refused` names the field when the
    /// rule will not build one — an amount that is not positive is the only case.
    public func newExpense(_ input: [String: JSONValue], id: String, today: String) throws -> Written {
        try runtime.call2("KhaytExpenseBook.newExpense(ARG0, {id: ARG1, today: ARG2})",
                          [.object(input), .string(id), .string(today)], as: Written.self)
    }

    /// Whether a category has gone past its monthly budget, AFTER the expense
    /// is in the list handed here. Nil when it has not, or has no budget.
    public func overBudget(_ expenses: [JSONValue], category: String, month: String,
                           budgets: [String: JSONValue]) throws -> Overspend? {
        try runtime.call2("KhaytExpenseBook.overBudget(ARG0, ARG1, ARG2, ARG3)",
                          [.array(expenses), .string(category), .string(month), .object(budgets)],
                          as: Overspend?.self)
    }

    /// Budget against actual, one row per category that has a budget.
    public func budgetProgress(_ byCategory: [String: Double],
                               budgets: [String: JSONValue]) throws -> [BudgetRow] {
        try runtime.call2("KhaytExpenseBook.budgetProgress(ARG0, ARG1)",
                          [.object(byCategory.mapValues(JSONValue.number)), .object(budgets)],
                          as: [BudgetRow].self)
    }

    /// A failed print written down by hand.
    ///
    /// `inventory` COMES BACK CHANGED when the entry deducts: the grams come
    /// off the spool it names, and the entry records which spool, so deleting
    /// it can put them back. Write both, or the shelf and the log disagree.
    public func newWasteEntry(_ input: [String: JSONValue], id: String, today: String,
                              inventory: [JSONValue]) throws -> WasteWritten {
        try runtime.call2(
            "(function(){var inv = ARG3; var out = KhaytWasteEntry.newEntry(ARG0, {id: ARG1, today: ARG2, inventory: inv});"
          + " return {entry: out.entry, refused: out.refused, inventory: inv};})()",
            [.object(input), .string(id), .string(today), .array(inventory)], as: WasteWritten.self)
    }

    /// What wasted grams of a material cost, from the spool they came off.
    public func wasteCost(material: String, grams: Double, inventory: [JSONValue]) throws -> Double {
        try runtime.call2("KhaytWasteEntry.costOf(ARG0, ARG1, ARG2)",
                          [.string(material), .number(grams), .array(inventory)], as: Double.self)
    }

    /// Take an entry out of the log and put its grams back on its spool.
    /// Both collections come back changed.
    public func removeWasteEntry(_ wasteLog: [JSONValue], id: String,
                                 inventory: [JSONValue]) throws -> WasteRemoved {
        try runtime.call2(
            "(function(){var log = ARG0, inv = ARG2;"
          + " var gone = KhaytWasteEntry.removeEntry(log, ARG1, {inventory: inv});"
          + " return {removed: !!gone, wasteLog: log, inventory: inv};})()",
            [.array(wasteLog), .string(id), .array(inventory)], as: WasteRemoved.self)
    }

    /// The shop's quarters: what it earned, what it spent, what it kept.
    public func pnlByPeriod(orders: [JSONValue], expenses: [JSONValue],
                            settings: [String: JSONValue], clients: [JSONValue],
                            currencies: [String: JSONValue], now: Date) throws -> [PnlPeriod] {
        try runtime.call2(
            "KhaytPnl.pnlByPeriod(ARG0, ARG1, {settings: ARG2, clients: ARG3, currencies: ARG4, now: new Date(ARG5)})",
            [.array(orders), .array(expenses), .object(settings), .array(clients),
             .object(currencies), .number(now.timeIntervalSince1970 * 1000)],
            as: [PnlPeriod].self)
    }

    // MARK: - The shelf

    /// A new spool, as the shelf records it. `refused` is `material` when it
    /// has none — a spool no job can be matched to.
    public func newSpool(_ input: [String: JSONValue], id: String, today: String) throws -> SpoolWritten {
        try runtime.call2("KhaytSpoolEdit.newSpool(ARG0, {id: ARG1, today: ARG2})",
                          [.object(input), .string(id), .string(today)], as: SpoolWritten.self)
    }

    /// Correct a spool.
    ///
    /// BOTH COME BACK CHANGED. The spool is corrected, and the shop's colour
    /// library — a setting — learns any colour variant that was named. Write
    /// them together, or the next editor offers a list that has forgotten what
    /// was just typed.
    public func editSpool(_ spool: JSONValue, input: [String: JSONValue],
                          settings: [String: JSONValue], today: String) throws -> SpoolEdited {
        try runtime.call2(
            "(function(){var s = ARG0, set = ARG2;"
          + " var out = KhaytSpoolEdit.applyEdit(s, ARG1, {today: ARG3, settings: set});"
          + " return {spool: s, settings: set, refused: out.refused, colourAdded: out.colourAdded};})()",
            [spool, .object(input), .object(settings), .string(today)], as: SpoolEdited.self)
    }

    /// The colour variants a shop has named for a material.
    public func spoolColours(settings: [String: JSONValue], material: String) throws -> [String] {
        try runtime.call2("KhaytSpoolEdit.coloursFor(ARG0, ARG1)",
                          [.object(settings), .string(material)], as: [String].self)
    }

    // MARK: - The machines

    /// A new machine: an id, a name, and the next colour along.
    public func newMachine(_ input: [String: JSONValue], id: String, count: Int) throws -> MachineWritten {
        try runtime.call2("KhaytMachineEdit.newMachine(ARG0, {id: ARG1, count: ARG2})",
                          [.object(input), .string(id), .number(Double(count))], as: MachineWritten.self)
    }

    /// Correct a machine — only the fields `input` carries.
    public func editMachine(_ machine: JSONValue, input: [String: JSONValue],
                            settings: [String: JSONValue]) throws -> MachineWritten {
        try runtime.call2(
            "(function(){var m = ARG0;"
          + " var out = KhaytMachineEdit.applyEdit(m, ARG1, {settings: ARG2});"
          + " return {machine: m, refused: out.refused};})()",
            [machine, .object(input), .object(settings)], as: MachineWritten.self)
    }

    /// What picking a printer model fills in: the bed, the colours, the power,
    /// and — the point of the catalogue knowing it — what the nozzle is made
    /// of, with the expected life that goes with it. A threshold the shop has
    /// already typed is never rewritten.
    public func applyPrinterModel(_ machine: JSONValue, catalogId: String,
                                  settings: [String: JSONValue]) throws -> MachineWritten {
        try runtime.call2(
            "(function(){var m = ARG0, entry = KhaytPrinterCatalog.get(ARG1);"
          + " if (!entry) return {machine: m, refused: 'unknown_model'};"
          + " KhaytMachineEdit.applySpecs(m, KhaytPrinterCatalog.toMachineSpecs(entry),"
          + "   KhaytPrinterCatalog.displayName(entry), {settings: ARG2});"
          + " return {machine: m};})()",
            [machine, .string(catalogId), .object(settings)], as: MachineWritten.self)
    }

    /// The nozzle fitments Khayt's wear model knows, with their own labels and
    /// what each is expected to last.
    ///
    /// Asked rather than listed in Swift. A hand-written list here said
    /// "steel" where the data says "stainless", so the sample shop's U1 —
    /// which is stainless — matched nothing and the picker came out blank.
    /// A material added to the wear data now appears here on its own.
    public func nozzleMaterials() throws -> [NozzleMaterial] {
        try runtime.call2(
            "Object.keys(KhaytNozzleWearData.NOZZLE_LIFE_G).map(function (k) {"
          + " var row = KhaytNozzleWearData.NOZZLE_LIFE_G[k];"
          + " return {key: k, label: row.label, grams: row.grams};})", [], as: [NozzleMaterial].self)
    }

    /// The printers Khayt knows, as a screen offers them.
    public func printerCatalog() throws -> [CatalogPrinter] {
        try runtime.call2(
            "KhaytPrinterCatalog.list().map(function (p) {"
          + " return {id: p.id, name: KhaytPrinterCatalog.displayName(p),"
          + "  vendor: p.vendor,"
          + "  specs: KhaytMachineEdit.specsLine(KhaytPrinterCatalog.toMachineSpecs(p), {chamber: ARG0})};})",
            [.string("chamber")], as: [CatalogPrinter].self)
    }

    /// What the shop's Telegram bot would say about this move, or nil when the
    /// shop has not asked for one — no bot configured, or not this move.
    public func telegramMessage(order: JSONValue, newStatus: String,
                                settings: [String: JSONValue],
                                currency: String) throws -> TelegramMessage? {
        // `fmtPrice` is the renderer's, moved here rather than approximated.
        // This message goes to a CUSTOMER, so "9.69 SAR" from one device and
        // "$ 9.69" from another is the shop speaking with two voices about the
        // same job — and a currency whose symbol sits in front was printed
        // behind by the old one-liner, for every shop not using riyals.
        try runtime.call2("""
            KhaytTelegramMessage.forStatus(ARG0, ARG1, {
              settings: ARG2,
              fmtPrice: function (n) {
                var table = (globalThis.KhaytCurrencies || {}).CURRENCIES || {};
                var cur = table[ARG3] || table.SAR || { symbol: ARG3, pos: 'after' };
                var num = (Math.round((+n || 0) * 100) / 100).toFixed(2);
                // U+202F, the narrow no-break space renderer/currency.js uses:
                // it keeps the symbol against the figure across a line break.
                return cur.pos === 'before'
                  ? cur.symbol + '\u{202F}' + num
                  : num + '\u{202F}' + cur.symbol;
              }
            })
            """,
            [order, .string(newStatus), .object(settings), .string(currency)],
            as: TelegramMessage?.self)
    }

    /// Who owes the shop money, and how long they have owed it.
    public func receivables(orders: [JSONValue], settings: [String: JSONValue],
                            clients: [JSONValue], currencies: [String: JSONValue],
                            language: String, now: Date) throws -> Receivables {
        try runtime.call2(
            "KhaytReceivables.aged(ARG0, {settings: ARG1, clients: ARG2, currencies: ARG3,"
          + " language: ARG4, now: new Date(ARG5)})",
            [.array(orders), .object(settings), .array(clients), .object(currencies),
             .string(language), .number(now.timeIntervalSince1970 * 1000)],
            as: Receivables.self)
    }

    /// Which of a shop's backups routine housekeeping may delete.
    ///
    /// A pre-upgrade backup is not one: it carries a prefix and is the shop's
    /// insurance against a schema change, and rotating it away would mean the
    /// insurance survived exactly as long as nobody needed it. The rule is
    /// `lib/upgrade-backup.js`'s, so both apps rotate the same folder the same
    /// way rather than each deleting what the other was keeping.
    public func rotatableBackups(_ filenames: [String]) throws -> [String] {
        try runtime.call2("KhaytUpgradeBackup.partitionForRotation(ARG0).rotatable",
                          [.array(filenames.map(JSONValue.string))], as: [String].self)
    }

    /// Who the shop's best customers are, and what it is asked for most.
    ///
    /// The rollups are `lib/top-lists.js`'s, and so is the filter in front of
    /// them: which orders fall in the period, which count as trade, and which
    /// are voided are `date-range` and `business-scope`'s answers. Deciding any
    /// of that in Swift would be a second opinion about who a shop's biggest
    /// customer is, and nobody notices a disagreement like that until two
    /// people are looking at two screens.
    ///
    /// The two lists are fed DIFFERENT sets, deliberately. Customers are ranked
    /// over what completed and was billed; products over every order in the
    /// period whatever became of it, because a part quoted twenty times and
    /// made twice is a fact about the shop worth seeing.
    public func topLists(orders: [JSONValue], products: [JSONValue], clients: [JSONValue],
                         settings: [String: JSONValue], currencies: [String: JSONValue],
                         language: String, period: String, limit: Int = 8,
                         now: Date = Date()) throws -> TopLists {
        try runtime.call2(
            "(function (orders, ctx, period, at, limit) {"
          + "  var now = new Date(at);"
          + "  var ranged = orders.filter(function (o) {"
          + "    return o && KhaytDateRange.inRange(o.date, period, { now: now });"
          + "  });"
          + "  var completed = ranged.filter(function (o) {"
          + "    return o.status === 'completed' && !o.voidedAt"
          + "        && KhaytBusinessScope.countsForBusiness(o);"
          + "  });"
          + "  return { clients: KhaytTopLists.topClients(completed, ctx, { limit: limit }),"
          + "           products: KhaytTopLists.topProducts(ranged, ctx, { limit: limit }) };"
          + "})(ARG0, {settings: ARG1, clients: ARG2, products: ARG3, currencies: ARG4, language: ARG5},"
          + "   ARG6, ARG7, ARG8)",
            [.array(orders), .object(settings), .array(clients), .array(products),
             .object(currencies), .string(language), .string(period),
             .number(now.timeIntervalSince1970 * 1000), .number(Double(limit))],
            as: TopLists.self)
    }

    /// The two lists, and one row of either.
    public struct TopLists: Decodable, Sendable {
        public let clients: [TopRow]
        public let products: [TopRow]
    }

    public struct TopRow: Decodable, Sendable, Identifiable, Hashable {
        /// The record's own id. The renderer's lists threw it away — they build
        /// a list item — but a table a person can click needs it, and a name is
        /// not a key: two customers called Ahmed are two customers.
        public let id: String
        public let name: String
        public let count: Int
        public let revenue: Double
    }

    // MARK: - What the printer is doing

    /// The Moonraker objects worth asking for, as one query string.
    public func moonrakerQuery() throws -> String {
        try runtime.call2("KhaytMoonraker.QUERY", [], as: String.self)
    }

    /// Which extruder is printing, when it is not toolhead zero.
    ///
    /// Nil for a single-head machine — and nil is the answer that means "the
    /// reading you already have is the right one", so only the machines that
    /// need it pay for a second request.
    public func moonrakerActiveExtruder(_ reply: [String: JSONValue]) throws -> String? {
        // The empty string stands in for null across the bridge, because a
        // `null` decodes as a decoding failure rather than as an absence.
        let name = try runtime.call2("(KhaytMoonraker.activeExtruder(ARG0) || '')",
                                     [.object(reply)], as: String.self)
        return name.isEmpty ? nil : name
    }

    /// What a Klipper machine is doing, from its own answer.
    ///
    /// Four corrections live inside `lib/moonraker.js`, each found on a real
    /// printer: layers before bytes, the live toolhead rather than head zero,
    /// `print_duration` rather than `total_duration`, and an ETA that refuses
    /// to extrapolate from noise. None of them is re-decided here.
    public func moonrakerStatus(_ reply: [String: JSONValue],
                                hot: [String: JSONValue]?, hotName: String?) throws -> PrinterStatus {
        try runtime.call2("KhaytMoonraker.readStatus(ARG0, ARG1, ARG2)",
                          [.object(reply),
                           hot.map(JSONValue.object) ?? .null,
                           hotName.map(JSONValue.string) ?? .null],
                          as: PrinterStatus.self)
    }

    /// What an OctoPrint server is doing.
    ///
    /// `printer` is null when `/api/printer` answered 409 — which is not a
    /// fault, it is OctoPrint running with the printer switched off, and
    /// `/api/job` answers fine in exactly that state. `lib/octoprint.js`.
    public func octoprintStatus(printer: [String: JSONValue]?,
                                job: [String: JSONValue]) throws -> PrinterStatus {
        try runtime.call2("KhaytOctoprint.readStatus(ARG0, ARG1)",
                          [printer.map(JSONValue.object) ?? .null, .object(job)],
                          as: PrinterStatus.self)
    }

    /// What a PrusaLink printer is doing.
    ///
    /// `job` is null when `/api/v1/job` answered 204 — nothing is printing, and
    /// a missing filename must not cost the temperatures the first request did
    /// return. `lib/prusalink.js`.
    public func prusalinkStatus(status: [String: JSONValue],
                                job: [String: JSONValue]?) throws -> PrinterStatus {
        try runtime.call2("KhaytPrusalink.readStatus(ARG0, ARG1)",
                          [.object(status), job.map(JSONValue.object) ?? .null],
                          as: PrinterStatus.self)
    }

    /// Is this string the address of a printer on the shop's own network?
    ///
    /// `lib/printer-host.js`, split out of the Electron app's host guard for
    /// exactly this. A public address here is server-side request forgery with
    /// a printer card as the pretext, and the numeric spellings are the sharp
    /// part: `2130706433`, `0x7f000001`, `127.1` and `0177.0.0.1` all reach
    /// loopback and none of them looks like a dotted quad.
    public func printerHostAllowed(_ host: String) throws -> Bool {
        try runtime.call2("KhaytPrinterHost.isAllowedPrinterHost(KhaytPrinterHost.sanitizePrinterHost(ARG0))",
                          [.string(host)], as: Bool.self)
    }

    /// The host with everything that is not a hostname taken out.
    public func printerHost(_ host: String) throws -> String {
        try runtime.call2("KhaytPrinterHost.sanitizePrinterHost(ARG0)", [.string(host)], as: String.self)
    }

    /// What a machine is doing, as every adapter reports it.
    public struct PrinterStatus: Decodable, Sendable, Equatable {
        public let state: String
        public let progress: Int
        /// `layers` or `bytes` — which signal the percentage came from, because
        /// bytes are not work and a shop reading an ETA deserves to know which.
        ///
        /// NIL FOR EVERY OTHER PROTOCOL, and that is the honest answer rather
        /// than a default: Moonraker is the only one that chooses between two
        /// signals. OctoPrint's `completion` and PrusaLink's `progress` are
        /// percentages their own servers computed, and labelling either "by
        /// file position" would be inventing a fact about someone else's
        /// firmware.
        public let progressSource: String?
        public let filename: String
        public let timeRemaining: Double?
        public let tempNozzle: Double?
        public let tempBed: Double?
        public let type: String
    }

    /// What has just gone wrong with a printer, and what to remember for next
    /// time.
    ///
    /// `lib/printer-alerts.js` — the thresholds, the cooldowns and the stall
    /// clock, all of it. `enable` replaces the module's Telegram toggles,
    /// because the transport here is a notification on the machine the shop is
    /// sitting at: a shop with no bot would otherwise be told nothing at all,
    /// including that its printer went offline mid-print at two in the morning.
    public func printerAlerts(was: [String: JSONValue], now current: [String: JSONValue],
                              settings: [String: JSONValue], machines: [JSONValue],
                              state: JSONValue, enable: Alerting,
                              at: Date = Date()) throws -> PrinterAlerts {
        try runtime.call2(
            "KhaytPrinterAlerts.computePrinterAlerts(ARG0, ARG1, ARG2, ARG3,"
          + " { alertState: ARG4, machines: ARG5, enable: ARG6 })",
            [.object(was), .object(current), .object(settings), .number(at.timeIntervalSince1970 * 1000),
             state, .array(machines),
             .object(["error": .bool(enable.error), "offline": .bool(enable.offline),
                      "stall": .bool(enable.stall)])],
            as: PrinterAlerts.self)
    }

    /// Which of the three a caller wants to hear about.
    public struct Alerting: Sendable {
        public var error: Bool
        public var offline: Bool
        public var stall: Bool
        /// The module's own defaults: a machine that faulted or went quiet is
        /// worth interrupting somebody for; a print that has not moved might
        /// just be a long layer.
        public static let sensible = Alerting(error: true, offline: true, stall: false)
        public init(error: Bool, offline: Bool, stall: Bool) {
            self.error = error; self.offline = offline; self.stall = stall
        }
    }

    public struct PrinterAlerts: Decodable, Sendable {
        public let alerts: [Alert]
        /// The cooldown and stall bookkeeping, opaque and owned by the module.
        /// The caller's only job is to hand the same value back next time.
        public let state: JSONValue

        public struct Alert: Decodable, Sendable, Hashable, Identifiable {
            public var id: String { machineId + ":" + type }
            public let machineId: String
            /// `offline`, `error` or `stall`.
            public let type: String
            /// The module's own sentence. Read for the log; the Mac writes its
            /// own for the notification, because this one is English.
            public let message: String
            public let state: String
            public let filename: String
            public let progress: Double
        }
    }

    // MARK: - What the printer itself remembers

    /// The machine's own job history, mapped.
    ///
    /// `lib/moonraker-history.js`, and the mapping is where the corrections
    /// are: a toolchanger reports `filament_type` once per TOOL, quoted, so a
    /// four-head job reads as a material nobody stocks and the abrasiveness
    /// match misses it entirely. The slicer's thumbnails are dropped here too —
    /// a hundred base64 previews in a store file that syncs is not a history.
    public func printerHistoryJobs(_ raw: [String: JSONValue]) throws -> [JSONValue] {
        try runtime.call2("KhaytMoonrakerHistory.mapJobs(ARG0)", [.object(raw)], as: [JSONValue].self)
    }

    /// Old jobs and new, by job id, newest first. Importing twice adds nothing.
    public func mergePrinterHistory(_ existing: [JSONValue], _ incoming: [JSONValue]) throws -> [JSONValue] {
        try runtime.call2("KhaytMoonrakerHistory.merge(ARG0, ARG1)",
                          [.array(existing), .array(incoming)], as: [JSONValue].self)
    }

    /// What has gone through the machine since a date. `""` means all of it.
    public func printerHistoryTotals(_ jobs: [JSONValue], since: String) throws -> HistoryTotals {
        try runtime.call2("KhaytMoonrakerHistory.totalsSince(ARG0, ARG1)",
                          [.array(jobs), .string(since)], as: HistoryTotals.self)
    }

    public struct HistoryTotals: Decodable, Sendable {
        public let grams: Double
        public let hours: Double
        public let jobs: Int
    }

    /// The shop's book as a file it can hand to somebody else.
    ///
    /// `redactSecrets` is not optional here, and there is no second method
    /// without it. A store copy carries the shop's credentials — which is right
    /// for a backup, where they never leave the Mac, and wrong for a file
    /// emailed to an accountant. The redaction is `lib/store.js`'s, including
    /// the data-driven sweep over shipping and BNPL providers that exists so
    /// that adding a carrier does not quietly export the next one's key.
    public func redactedExport(_ store: [String: JSONValue]) throws -> [String: JSONValue] {
        try runtime.call2("KhaytStore.buildExportPayload(ARG0, { redactSecrets: true })",
                          [.object(store)], as: [String: JSONValue].self)
    }

    /// Is this file a Khayt store, and is it whole?
    ///
    /// The question a restore has to answer BEFORE it destroys anything.
    /// `looksLikeStore` is the half that matters most: `normalizeStoreSnapshot`
    /// SALVAGES — handed a file that is not ours it recognises nothing and
    /// returns a truthy empty object — so "did it parse" was never the test.
    /// The renderer's own restore refused a falsy snapshot and nothing else,
    /// and picking the wrong `.json` in Settings → Import was enough to zero
    /// all thirty-one collections under a "restored successfully" toast.
    ///
    /// Both halves are asked, and both must pass: a file that is recognisably
    /// ours but whose `printLog` is a string is a truncated or hand-edited
    /// backup, and a shop restoring one wants to be told, not salvaged.
    public func storeIsRestorable(_ snapshot: [String: JSONValue]) throws -> RestoreVerdict {
        try runtime.call2(
            "(function (s) {"
          + "  if (!KhaytStoreValidate.looksLikeStore(s))"
          + "    return { ok: false, ours: false, errors: [], warnings: [] };"
          + "  var v = KhaytStoreValidate.validateStoreSnapshot(s);"
          + "  return { ok: !!v.ok, ours: true, errors: v.errors || [], warnings: v.warnings || [] };"
          + "})(ARG0)",
            [.object(snapshot)], as: RestoreVerdict.self)
    }

    /// What `storeIsRestorable` found.
    public struct RestoreVerdict: Decodable, Sendable {
        /// Safe to put in place of the shop's book.
        public let ok: Bool
        /// It is a Khayt store. False means the shop picked the wrong file,
        /// which is a different sentence from "your backup is damaged".
        public let ours: Bool
        public let errors: [String]
        public let warnings: [String]
    }

    // MARK: - Who the shop's customers are

    /// A customer's name, in the language the shop writes.
    ///
    /// Not the interface language. `read` tries the language asked for ONLY if
    /// the shop writes in it, then the shop's own languages, then anything
    /// filled in at all — so an English interface shows a Turkish shop its
    /// Turkish name rather than the stale `nameEn` from setup.
    public func customerName(_ client: JSONValue, language: String,
                             settings: [String: JSONValue]) throws -> String {
        try runtime.call2("(KhaytContentLanguages.read(ARG0, 'name', ARG1, ARG2) || '')",
                          [client, .string(language), .object(settings)], as: String.self)
    }

    /// The other language's name, straight from the module.
    ///
    /// NOT deduped: a record with one name filled in comes back with the SAME
    /// string, because the fallback has already put that one field in both.
    /// `customerNames` blanks it for a caller that wants a second line;
    /// this one hands back what the module said.
    public func customerAltName(_ client: JSONValue, language: String,
                                settings: [String: JSONValue]) throws -> String {
        try runtime.call2("(KhaytContentLanguages.readAlt(ARG0, 'name', ARG1, ARG2) || '')",
                          [client, .string(language), .object(settings)], as: String.self)
    }

    // MARK: - The catalogue

    /// What a product costs to sell, and why that number and not another.
    ///
    /// `lib/product-price.js`. A typed `priceOverride` beats everything,
    /// including rounding — and ZERO is a real override (a giveaway, a sample,
    /// a part priced inside a bundle), so the test is "is there a number here",
    /// never "is it truthy".
    public func productPrice(_ product: JSONValue, basePrice: Double) throws -> ProductPrice {
        try runtime.call2("KhaytProductPrice.finalPrice(ARG0, ARG1)",
                          [product, .number(basePrice)], as: ProductPrice.self)
    }

    public struct ProductPrice: Decodable, Sendable, Hashable {
        public let base: Double
        public let final: Double
        /// `override`, `rounded` or `base`.
        public let source: String
    }

    /// What a product's parts add up to: hours, grams and the materials.
    public func productSpecs(_ product: JSONValue) throws -> ProductSpecs {
        try runtime.call2("KhaytProductSpecs.productSpecs(ARG0)", [product], as: ProductSpecs.self)
    }

    public struct ProductSpecs: Decodable, Sendable, Hashable {
        public let printHours: Double?
        public let weightGrams: Double?
        public let material: String
    }

    /// Every product's name, price and specs in one crossing.
    ///
    /// One call for the whole catalogue rather than three per row — the same
    /// reason `customerNames` exists.
    public func catalogue(_ products: [JSONValue], language: String,
                          settings: [String: JSONValue]) throws -> [CatalogueRow] {
        try runtime.call2("""
            (function (rows, lang, settings) {
              return rows.map(function (p) {
                var price = KhaytProductPrice.finalPrice(p, +p.basePrice || 0);
                var specs = KhaytProductSpecs.productSpecs(p);
                return {
                  id: String(p.id || ''),
                  name: KhaytContentLanguages.read(p, 'name', lang, settings) || '',
                  description: KhaytContentLanguages.read(p, 'description', lang, settings) || '',
                  base: price.base, final: price.final, source: price.source,
                  // The module picks the key; this app translates it. Passing a
                  // translator that returns its own argument is what turns
                  // `describe` from a sentence into a decision — and the
                  // decision is the part that must not be made twice.
                  reason: KhaytProductPrice.describe(price, function (k) { return k; }),
                  margin: p.defaultMargin == null ? null : +p.defaultMargin,
                  printHours: specs.printHours, weightGrams: specs.weightGrams,
                  material: specs.material,
                  parts: (p.parts || []).length
                };
              });
            })(ARG0, ARG1, ARG2)
            """,
                          [.array(products), .string(language), .object(settings)],
                          as: [CatalogueRow].self)
    }

    public struct CatalogueRow: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let description: String
        public let base: Double
        public let final: Double
        public let source: String
        /// The locale key for why this price and not another, chosen by
        /// `lib/product-price.js`'s own `describe` — not re-derived here.
        public let reason: String
        public let margin: Double?
        public let printHours: Double?
        public let weightGrams: Double?
        public let material: String
        public let parts: Int

        public init(id: String, name: String, description: String, base: Double, final: Double,
                    source: String, reason: String, margin: Double?, printHours: Double?,
                    weightGrams: Double?, material: String, parts: Int) {
            self.id = id; self.name = name; self.description = description
            self.base = base; self.final = final; self.source = source
            self.reason = reason
            self.margin = margin; self.printHours = printHours; self.weightGrams = weightGrams
            self.material = material; self.parts = parts
        }
    }

    // MARK: - What the cloud holds

    /// Every collection a store carries — `ARRAY_COLLECTIONS` from
    /// `lib/store-validate.js`, read rather than listed a second time. A
    /// comparison that did not know about a collection would report two books
    /// as agreeing about it.
    public func storeCollections() throws -> [String] {
        try runtime.call2("KhaytStoreValidate.ARRAY_COLLECTIONS", [], as: [String].self)
    }

    /// Fold a chain of deltas onto a base, the way a pull does.
    ///
    /// `KhaytSync.applyDeltas` MUTATES the snapshot and returns a report, so
    /// the folded store is returned explicitly here — a rule that mutates and
    /// does not return has done its work inside JavaScriptCore and thrown it
    /// away, which is a trap this app has already fallen into once.
    ///
    /// `appendOnly: []` matches `foldDeltas` in cloud-backend.js exactly.
    /// AND IT SAYS WHAT IT DID. `applyDeltas` returns `{applied, skipped,
    /// removed}` and the first version of this threw that away — so a fold that
    /// applied NOTHING was indistinguishable from one that worked, and the
    /// comparison built on it would have reported the whole book as "newer
    /// here" with nothing to say otherwise. A number nobody can check is not
    /// evidence.
    /// What this device holds that the cloud does not, ready to send.
    ///
    /// One crossing, and the rule on the other side of it is
    /// `lib/cloud-outbox.js` — deliberately NOT the desktop's
    /// `changesSincePush`, which measures against a cursor this app never
    /// wrote and would happily send a stale record over a newer one. See the
    /// module's own note.
    /// The whole store, with every credential masked, as the cloud may hold it.
    ///
    /// Not a courtesy: a host that reads the store from DISK holds the real
    /// `__enc__` secrets, where the desktop's renderer is handed masks and has
    /// always pushed masks. See `forCloud` in `lib/cloud-outbox.js`.
    public func storeForCloud(_ store: [String: JSONValue]) throws -> [String: JSONValue] {
        try runtime.call2("KhaytCloudOutbox.forCloud(ARG0)", [.object(store)],
                          as: [String: JSONValue].self)
    }

    public func changesToSend(local: [String: JSONValue],
                              server: [String: JSONValue]) throws -> Outbox {
        try runtime.call2("KhaytCloudOutbox.changesToSend(ARG0, ARG1)",
                          [.object(local), .object(server)], as: Outbox.self)
    }

    /// Merge the cloud's store into this device's book.
    ///
    /// `lib/cloud-inbox.js`, which is the desktop's own `pullMerge` — the same
    /// rule, not a second one. It decides record by record with the higher-rev
    /// rule, adds to the ledgers rather than overwriting them, and does not
    /// touch settings at all.
    ///
    /// THE STORE COMES BACK. The rule mutates the object it is handed, and what
    /// it is handed on this side of the bridge is a copy — so a merge whose
    /// result was dropped would look exactly like a merge that found nothing.
    public func mergeFromCloud(local: [String: JSONValue],
                               server: [String: JSONValue]) throws -> Merged {
        try runtime.call2("KhaytCloudInbox.merge(ARG0, ARG1)",
                          [.object(local), .object(server)], as: Merged.self)
    }

    public struct Merged: Decodable, Sendable {
        /// The local book with the cloud folded into it.
        public let store: [String: JSONValue]
        /// Records the cloud's copy wrote into this book.
        public let applied: Int
        /// Records this book already had at the same or a higher rev, plus
        /// every ledger entry that was left alone. Normal, and not a fault.
        public let skipped: Int
        /// Records a deletion elsewhere took out of this book.
        public let removed: Int
        /// Local edits thrown away because the record was deleted elsewhere.
        /// Delete wins — but a shop is told, which is what this is for.
        public let conflicts: [JSONValue]

        public init(store: [String: JSONValue], applied: Int, skipped: Int,
                    removed: Int, conflicts: [JSONValue]) {
            self.store = store
            self.applied = applied
            self.skipped = skipped
            self.removed = removed
            self.conflicts = conflicts
        }

        public var changed: Int { applied + removed }
    }

    public func foldDeltas(base: [String: JSONValue],
                           deltas: [[String: JSONValue]]) throws -> Folded {
        try runtime.call2("""
            (function (base, payloads) {
              var applied = 0, skipped = 0, removed = 0;
              for (var i = 0; i < payloads.length; i++) {
                var r = KhaytSync.applyDeltas(base, payloads[i], { appendOnly: [] }) || {};
                applied += r.applied || 0;
                skipped += r.skipped || 0;
                removed += r.removed || 0;
              }
              return { store: base, applied: applied, skipped: skipped, removed: removed };
            })(ARG0, ARG1)
            """,
                          [.object(base), .array(deltas.map(JSONValue.object))],
                          as: Folded.self)
    }

    /// The folded store, and what folding it changed.
    /// A delta payload, in the shape `KhaytSync.applyDeltas` consumes.
    ///
    /// `settingsDiffer` is not part of the payload and never goes on the wire:
    /// settings are one object rather than revisioned records, so a delta has
    /// nowhere to put them. It is here so the screen can say that out loud
    /// instead of dropping a shop's setting change without a word.
    public struct Outbox: Codable, Sendable {
        public let deltas: [JSONValue]
        public let tombstones: [JSONValue]
        public let cursor: JSONValue
        public let settingsDiffer: Bool

        public init(deltas: [JSONValue], tombstones: [JSONValue],
                    cursor: JSONValue, settingsDiffer: Bool) {
            self.deltas = deltas
            self.tombstones = tombstones
            self.cursor = cursor
            self.settingsDiffer = settingsDiffer
        }

        public var isEmpty: Bool { deltas.isEmpty && tombstones.isEmpty }
        public var count: Int { deltas.count + tombstones.count }

        /// Only the three fields the fold reads. Sending `settingsDiffer` would
        /// put a fact about this device into a payload every other device folds.
        public var wire: [String: JSONValue] {
            ["deltas": .array(deltas), "tombstones": .array(tombstones), "cursor": cursor]
        }
    }

    public struct Folded: Decodable, Sendable {
        public let store: [String: JSONValue]
        /// Records the chain wrote into the base.
        public let applied: Int
        /// Records the chain carried that the base already had at the same or a
        /// higher rev — normal, and not a fault.
        public let skipped: Int
        /// Records a tombstone in the chain deleted.
        public let removed: Int
    }

    /// Which jobs are late — the attention engine's answer, as a set of ids.
    ///
    /// NOT "unpaid and past its due date", which is what this app worked out
    /// for itself and which is a different question with a much larger answer.
    /// A job that is completed and delivered is not late because its invoice is
    /// unpaid, and a QUOTE has no deadline to miss at all: on the sample book
    /// the Swift rule said eleven and `attention` says two, and both numbers
    /// were on screen at once — the badges from one, the dashboard tile from
    /// the other.
    public func lateOrders(_ orders: [JSONValue], machines: [JSONValue],
                           settings: [String: JSONValue], now: Date = Date()) throws -> Set<String> {
        let ids: [String] = try runtime.call2(
            "Array.from(KhaytDashboardFacts.dashboardFacts({orders: ARG0, machines: ARG1,"
          + " settings: ARG2, now: ARG3, attention: globalThis.KhaytAttention}).lateIds)",
            [.array(orders), .array(machines), .object(settings),
             .number(now.timeIntervalSince1970 * 1000)],
            as: [String].self)
        return Set(ids)
    }

    /// What every order still owes, in the shop's base currency, keyed by id.
    ///
    /// ONE CROSSING for the whole book. `orderOwedBase` is the rule that
    /// decides whether a customer gets chased, and it subtracts more than a
    /// Swift `price - paidAmount` does: a credit note and a gift-card
    /// redemption both pay an order down, and a foreign-currency order is
    /// converted rather than reported at its face value.
    public func owedByOrder(_ orders: [JSONValue], settings: [String: JSONValue],
                            clients: [JSONValue],
                            currencies: [String: JSONValue]) throws -> [String: Double] {
        try runtime.call2("""
            (function (rows, ctx, known) {
              var out = {};
              for (var i = 0; i < rows.length; i++) {
                var o = rows[i];
                if (!o || !o.id) continue;
                out[o.id] = KhaytOrderMoney.orderOwedBase(o, ctx, known);
              }
              return out;
            })(ARG0, {settings: ARG1, clients: ARG2}, ARG3)
            """,
                          [.array(orders), .object(settings), .array(clients), .object(currencies)],
                          as: [String: Double].self)
    }

    /// Every customer's name at once, in the shop's own language.
    ///
    /// ONE CROSSING, not one per row. The two functions above take a single
    /// client and were written for a sheet; a table of thirty-one customers
    /// asking thirty-one times is the reason the list had a Swift fallback
    /// instead — and that fallback was `nameEn` first, which is the shape the
    /// repo's own content-language guard exists to forbid. An Arabic shop saw
    /// its customers listed in English on one screen and in Arabic on another.
    ///
    /// Returned keyed by id, so a caller can look up whatever it is holding.
    public func customerNames(_ clients: [JSONValue], language: String,
                              settings: [String: JSONValue]) throws -> [String: Named] {
        try runtime.call2("""
            (function (rows, lang, settings) {
              var out = {};
              for (var i = 0; i < rows.length; i++) {
                var c = rows[i];
                if (!c || !c.id) continue;
                var name = KhaytContentLanguages.read(c, 'name', lang, settings) || '';
                var alt = KhaytContentLanguages.readAlt(c, 'name', lang, settings) || '';
                // A record with one name filled in reads the SAME string twice:
                // `readAlt` returns the other content language's field, and the
                // fallback has already put that one field in both. The renderer
                // does not dedupe either — it simply has nowhere that shows
                // both. Empty here means "no second line", so a view can render
                // `alt` without checking.
                out[c.id] = { name: name, alt: alt === name ? '' : alt };
              }
              return out;
            })(ARG0, ARG1, ARG2)
            """,
                          [.array(clients), .string(language), .object(settings)],
                          as: [String: Named].self)
    }

    /// A record's name, and the other language's if the shop writes two.
    public struct Named: Decodable, Sendable, Hashable {
        public let name: String
        public let alt: String
        public init(name: String, alt: String) { self.name = name; self.alt = alt }
    }

    // MARK: - Taking a job

    /// What one part of a job costs to make.
    ///
    /// Material, machine wear, electricity, labour and the failure allowance —
    /// the figure every price is built on top of, and the same function the
    /// calculator screen and the phone's quote endpoint both call.
    /// `machine` supplies the two cost inputs a printer knows about itself, its
    /// power draw and its wear rate — the same two `applyMachineToCalculator`
    /// applies in the Electron calculator, and no others.
    ///
    /// THE RATES ARE NOT OPTIONAL. `computePartBaseCost` adds up six things and
    /// returns a number whether or not it was given them, so a caller that
    /// leaves out wear, power, labour and the failure allowance is quoted the
    /// material and nothing else: 20.40 on a job Khayt's own calculator prices
    /// at 109.43. This app did exactly that, reading five `settings.default*`
    /// keys Khayt has never written. `KhaytPrintRates` is where the real
    /// figures live.
    ///
    /// Anything the PART carries wins over the rates, because a rate is what to
    /// assume and the part is what somebody said.
    public func partCost(_ part: JSONValue, inventory: [JSONValue],
                         settings: [String: JSONValue],
                         machine: JSONValue? = nil, preset: JSONValue? = nil) throws -> Double {
        try runtime.call2("""
            KhaytCalculatorCost.computePartBaseCost(
              Object.assign({}, KhaytPrintRates.ratesFor({ machine: ARG3, preset: ARG4 }), ARG0),
              { inventory: ARG1, settings: ARG2 })
            """,
                          [part, .array(inventory), .object(settings),
                           machine ?? .null, preset ?? .null], as: Double.self)
    }

    /// The same figure, in the four parts a shop can argue with.
    ///
    /// `material`, `machine`, `labor` and `buffer` sum to exactly what
    /// `partCost` returns — the module folds extra materials and packaging into
    /// the material bucket for precisely that reason. Shown rather than kept,
    /// because a price that quietly grew fivefold needs to be able to say where
    /// it went.
    public func partBreakdown(_ part: JSONValue, inventory: [JSONValue],
                              settings: [String: JSONValue],
                              machine: JSONValue? = nil,
                              preset: JSONValue? = nil) throws -> CostParts {
        try runtime.call2("""
            KhaytCalculatorCost.computePartBreakdown(
              Object.assign({}, KhaytPrintRates.ratesFor({ machine: ARG3, preset: ARG4 }), ARG0),
              { inventory: ARG1, settings: ARG2 })
            """,
                          [part, .array(inventory), .object(settings),
                           machine ?? .null, preset ?? .null], as: CostParts.self)
    }

    /// Everything about what a part costs, in ONE crossing: the figure, the four
    /// buckets, and **the rates it was worked out at**.
    ///
    /// The rates come back because they have to be written down. The Electron
    /// calculator stores all seven on every part it saves, and its editor reads
    /// them straight back into the form — `$('#wearRate').value = part.wearRate
    /// || ''`. A part saved without them opens there with every rate field
    /// blank, and the next save re-costs it at nothing. So a job taken on this
    /// Mac and edited in Khayt would have lost its price, quietly, on somebody
    /// else's machine.
    public func costPart(_ part: JSONValue, inventory: [JSONValue],
                         settings: [String: JSONValue],
                         machine: JSONValue? = nil, preset: JSONValue? = nil) throws -> CostedPart {
        try runtime.call2("""
            (function (part, inventory, settings, machine, preset) {
              var rates = KhaytPrintRates.ratesFor({ machine: machine, preset: preset });
              // The part's own values beat the rates, and this merged object is
              // what BOTH the figure and the record are made from — so what gets
              // written down is what was charged, not a second guess at it.
              var costed = Object.assign({}, rates, part);
              var ctx = { inventory: inventory, settings: settings };
              return {
                cost: KhaytCalculatorCost.computePartBaseCost(costed, ctx),
                parts: KhaytCalculatorCost.computePartBreakdown(costed, ctx),
                rates: {
                  wearRate: +costed.wearRate || 0, powerDraw: +costed.powerDraw || 0,
                  elecRate: +costed.elecRate || 0, prepTime: +costed.prepTime || 0,
                  postTime: +costed.postTime || 0, laborRate: +costed.laborRate || 0,
                  failureRate: +costed.failureRate || 0
                }
              };
            })(ARG0, ARG1, ARG2, ARG3, ARG4)
            """,
                          [part, .array(inventory), .object(settings),
                           machine ?? .null, preset ?? .null], as: CostedPart.self)
    }

    public struct CostedPart: Decodable, Sendable, Hashable {
        public let cost: Double
        public let parts: CostParts
        public let rates: Rates
    }

    /// The seven figures a part is costed at, in the shape the book stores them
    /// — the same seven `renderer/build.js` writes on every part it saves.
    public struct Rates: Decodable, Sendable, Hashable {
        public let wearRate: Double
        public let powerDraw: Double
        public let elecRate: Double
        public let prepTime: Double
        public let postTime: Double
        public let laborRate: Double
        public let failureRate: Double

        /// As a record writes them down.
        public var fields: [String: JSONValue] {
            ["wearRate": .number(wearRate), "powerDraw": .number(powerDraw),
             "elecRate": .number(elecRate), "prepTime": .number(prepTime),
             "postTime": .number(postTime), "laborRate": .number(laborRate),
             "failureRate": .number(failureRate)]
        }
    }

    /// What a part costs, split the way the calculator splits it.
    public struct CostParts: Decodable, Sendable, Hashable {
        /// Filament, plus any extra materials and the packaging share.
        public let material: Double
        /// Wear and electricity.
        public let machine: Double
        /// Preparation and finishing.
        public let labor: Double
        /// The failure allowance, on the sum of the other three.
        public let buffer: Double

        public var total: Double { material + machine + labor + buffer }
    }

    /// A new job, as the book records it.
    ///
    /// `settings` COMES BACK CHANGED: allocating an invoice number and a quote
    /// sequence advances counters the shop owns, and an allocation nobody
    /// writes down hands the same number to the next job. Write both.
    public func newOrder(_ input: [String: JSONValue], orders: [JSONValue],
                         settings: [String: JSONValue], now: Date,
                         tokens: (tracking: [UInt8], quoteApproval: [UInt8])) throws -> NewOrder {
        let bytes = { (b: [UInt8]) in JSONValue.array(b.map { .number(Double($0)) }) }
        return try runtime.call2(NEW_ORDER_SCRIPT,
                                 [.object(input), .array(orders), .object(settings),
                                  .number(now.timeIntervalSince1970 * 1000),
                                  .object(["tracking": bytes(tokens.tracking),
                                           "quoteApproval": bytes(tokens.quoteApproval)])],
                                 as: NewOrder.self)
    }

    // MARK: - Money received

    /// Whether this order counts as paid, partly paid or unpaid.
    ///
    /// The stored `paymentStatus` field is an answer that was true when it was
    /// written. This is the answer now, by the rule every report reads it with.
    public func paymentStatus(of order: JSONValue) throws -> String {
        try runtime.call("KhaytOrderPayment", "statusOf", [order], as: String.self)
    }

    /// Where recording a payment would reach outside the shop's own book.
    ///
    /// Ask before writing anything, for the same reason a status change does: a
    /// `payment_received` webhook or a receipt email cannot be sent from here
    /// and cannot be sent afterwards.
    public func paymentOutbound(order: JSONValue, settings: [String: JSONValue],
                                clients: [JSONValue]) throws -> [Outbound] {
        try runtime.call2("KhaytOrderPayment.outboundFor(ARG0, {settings: ARG1, clients: ARG2})",
                          [order, .object(settings), .array(clients)], as: [Outbound].self)
    }

    /// Record what a customer has paid, and what that makes the order.
    ///
    /// The status is DERIVED here, never taken from the caller — a stored
    /// status that disagrees with the arithmetic is how an order sits in
    /// receivables after it was settled.
    public func recordPayment(order: JSONValue, amount: Double, method: String,
                              paidAt: String, today: String) throws -> PaymentRecorded {
        try runtime.call2(PAYMENT_SCRIPT,
                          [order, .number(amount), .string(method), .string(paidAt), .string(today)],
                          as: PaymentRecorded.self)
    }

    /// Undo a payment: the money was never received, or was recorded against
    /// the wrong job.
    public func clearPayment(order: JSONValue) throws -> PaymentRecorded {
        try runtime.call2("(function(){var o = ARG0; var r = KhaytOrderPayment.clearPayment(o);"
                        + " return { order: o, effects: r.effects.map(function(e){ return e.type; }) };})()",
                          [order], as: PaymentRecorded.self)
    }

    public func raw<T: Decodable>(_ script: String, as type: T.Type) throws -> T {
        let value = try runtime.evaluate("JSON.stringify(\(script))")
        guard let json = value.toString(), let data = json.data(using: .utf8) else {
            throw KhaytJSError.unexpectedResult(script)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// The invoice, and the vocabulary it is written in.
///
/// Every helper here is the smallest honest version of the renderer's: `t`
/// reads the catalogue this runtime already loaded, `escapeHtml` escapes the
/// five characters that matter in an attribute, and money is two decimals.
///
/// `shopField` answers with what Swift resolved through the content languages,
/// because which language a shop writes in is the app's question and it has
/// already asked it.
///
/// `safeCssColor` and `safeBizLogo` REFUSE rather than pass through: a document
/// that goes to a customer must not carry an arbitrary URL or an unvalidated
/// colour out of the settings file.
private let INVOICE_SCRIPT = """
(function () {
  var order = ARG0, settings = ARG1, clients = ARG2, currencies = ARG3;
  var language = ARG4, money = ARG5, sellerName = ARG6, sellerAddress = ARG7;

  var ARABIC_DIGITS = '\u{0660}\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}\u{0667}\u{0668}\u{0669}';
  var locales = globalThis.KhaytLocales || {};
  function say(lang, key, vars) {
    var table = locales[lang] || locales.en || {};
    var s = table[key] || (locales.en || {})[key] || key;
    if (vars) for (var k in vars) s = s.split('{' + k + '}').join(String(vars[k]));
    return s;
  }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function money2(n) {
    var v = +n;
    return (isFinite(v) ? v : 0).toFixed(2);
  }

  var ctx = {
    settings: settings, clients: clients, CURRENCIES: currencies,
    i18n: { current: language, tIn: function (l, k, v) { return say(l, k, v); } },
    t: function (k, v) { return say(language, k, v); },
    escapeHtml: esc,
    fmtMoney: money2,
    // formatPrintDate is NOT overridden: turning an ISO string into a date a
    // customer reads is the document's own rule, and this app printed
    // "2026-07-02T14:32:00.000Z" under DATE for as long as it had its own.
    shopField: function (base) { return base === 'addr' ? sellerAddress : sellerName; },
    // Refused rather than passed through: this document goes to a customer.
    safeBizLogo: function () { return ''; },
    safeCssColor: function (v, fallback) {
      return /^#[0-9a-fA-F]{3,8}$/.test(String(v || '')) ? String(v) : fallback;
    },
    // renderClientSub is NOT overridden: the contact line under the bill-to
    // name is the document's own rule, and a host that supplies its own prints
    // a different invoice. Khayt stopped passing one for the same reason.
    BRAND_MARK_SVG: '',
    orderCurrency: function (o) { return o.currency || settings.currency || 'SAR'; },
    clientCurrency: function () { return settings.currency || 'SAR'; },
    payStatus: function (o) {
      return globalThis.KhaytOrderPayment
        ? globalThis.KhaytOrderPayment.statusOf(o)
        : (o.paymentStatus || 'unpaid');
    },
    hijriDate: function () { return ''; },
    toArabicNumerals: function (s) {
      return String(s).replace(/[0-9]/g, function (d) { return ARABIC_DIGITS[+d]; });
    },
  };
  for (var key in money) ctx[key] = money[key];
  return KhaytInvoiceDocument.invoiceHtml(order, ctx);
})()
"""

/// A new job, and the counters taking it advanced.
private let NEW_ORDER_SCRIPT = """
(function () {
  var settings = ARG2;
  var order = KhaytOrderNew.newOrder(ARG0,
    { settings: settings, orders: ARG1, now: ARG3, tokens: ARG4 });
  return { order: order, settings: settings };
})()
"""

/// A failed inspection, as the shared rule writes it.
private let QC_FAILURE_SCRIPT = """
(function () {
  var order = ARG0, inventory = ARG6;
  var r = KhaytQcFailure.record(order, {
    failureType: ARG1, severity: ARG2, reason: ARG3, weight: ARG4, inspector: ARG5
  }, { inventory: inventory, now: ARG7, wasteId: ARG8, defaultReason: ARG9,
       settings: ARG10, machines: ARG11, today: ARG12 });
  // THE SHELF COMES BACK. A failed print takes its filament off the spools it
  // was printing from, and the rule mutates the array it is handed — which is
  // a copy on this side of the bridge. Returning the order and the waste row
  // and dropping the inventory would deduct inside JavaScriptCore and throw
  // the result away, which is exactly how the shelf came to overstate stock in
  // the first place.
  return { order: order, waste: r.waste, inventory: inventory,
           deducted: r.deducted, spools: r.spools };
})()
"""

/// Recording a payment, and what the order becomes.
private let PAYMENT_SCRIPT = """
(function () {
  var order = ARG0, amount = ARG1, method = ARG2, paidAt = ARG3, today = ARG4;
  var r = KhaytOrderPayment.recordPayment(order, { amount: amount, method: method, paidAt: paidAt },
                                          { today: today });
  return { order: order, effects: r.effects.map(function (e) { return e.type; }) };
})()
"""

/// Moving a job, as the two shared modules do it between them.
///
/// EVERY EFFECT IS CLASSIFIED, and the default case is `unhandled` rather than
/// "ignore". `apply()` returns an ordered list of what a move asks for, and a
/// list this app silently walked past would be how a future effect — a new
/// notification, a new record — goes missing on the Mac and nowhere else.
///
///   performed  this app does it, here or in the write that follows
///   cosmetic   a toast or a redraw; nothing outside this book depends on it
///   outbound   leaves the shop entirely — see below
///   unhandled  reported to the caller, which refuses the move
///
/// `apply()` asks for the webhook, the Telegram message, the email and the
/// portal refresh on EVERY move, because whether any of them reaches anybody
/// depends on what the shop has configured and it is not this module's business
/// to know. `outboundFor()` is what knows, and the caller asks it first: a move
/// that would actually reach somebody is refused before this runs. So finding
/// them here means the shop has none of it switched on, and they are named
/// rather than dropped.
private let MOVE_SCRIPT = """
(function () {
  var order = ARG0, status = ARG1, orders = ARG2, settings = ARG3;
  var inventory = ARG4, consumables = ARG5, machines = ARG6, now = ARG7, today = ARG8;
  var holdReason = ARG9, qc = ARG10;

  var gate = KhaytOrderStatus.gate(order, status, { orders: orders, settings: settings });
  if (!gate.ok) return { ok: false, gate: gate };

  var moveCtx = { now: now, inventory: inventory };
  // Present only when there is something to say, because the rules distinguish
  // "no reason given" from "nobody mentioned the reason".
  if (holdReason !== null) moveCtx.holdReason = holdReason;
  // Only a pass reaches here. A failure is a waste entry and a decision about
  // scrapping or reprinting, and it does not end in `completed`.
  if (qc !== null) moveCtx.qc = qc;
  var moved = KhaytOrderStatus.apply(order, status, moveCtx);
  var notices = moved.notices.slice();
  var performed = [], cosmetic = [], outbound = [], unhandled = [], activity = null;

  var COSMETIC = {
    render: 1, toast_updated: 1, toast_updated_undoable: 1,
    // A congratulation when a customer reaches a new tier. Nothing is written.
    tier_check: 1,
    // Writes a local HTML file for the customer to look at. Going stale is not
    // the same as being missed, and it reaches nobody.
    export_status_page: 1
  };
  // Asked for on every move; reaches somebody only when the shop has it
  // configured, which the caller has already checked.
  var OUTBOUND = { webhook: 1, order_webhook: 1, telegram: 1, email: 1, republish_portal: 1 };

  for (var i = 0; i < moved.effects.length; i++) {
    var e = moved.effects[i];
    if (e.type === 'deduct_filament') {
      var d = KhaytOrderDeduction.deductForOrder(order, {
        settings: settings, inventory: inventory, consumables: consumables,
        machines: machines, today: today
      });
      notices = notices.concat(d.notices);
      performed.push(e.type);
    } else if (e.type === 'deduct_packaging') {
      var p = KhaytOrderDeduction.deductPackaging(order, { consumables: consumables });
      notices = notices.concat(p.notices);
      performed.push(e.type);
    } else if (e.type === 'activity_log') {
      activity = e.text;
      performed.push(e.type);
    } else if (e.type === 'save') {
      performed.push(e.type);
    } else if (e.type === 'ensure_survey_token') {
      // The token is minted by the caller, which has a random source.
      performed.push(e.type);
    } else if (COSMETIC[e.type]) {
      cosmetic.push(e.type);
    } else if (OUTBOUND[e.type]) {
      outbound.push(e.type);
    } else {
      unhandled.push(e.type);
    }
  }

  return {
    ok: true, gate: gate, order: order, inventory: inventory, consumables: consumables,
    notices: notices, activity: activity,
    performed: performed, cosmetic: cosmetic, outbound: outbound, unhandled: unhandled
  };
})()
"""

/// The one expression that puts the three modules together.
///
/// `cost` is the parts, the way the renderer computes it. The renderer adds
/// shipping through `convertToBase`; this does not, because an order in this
/// store has no `shippingCost` and inventing a conversion for a field that is
/// never set would be a difference waiting to appear.
private let KPI_SCRIPT = """
(function () {
  var ctx = { settings: ARG2, clients: ARG1 };
  var M = globalThis.KhaytOrderMoney;
  var b = globalThis.KhaytKpiRows.bounds(ARG3);
  return globalThis.KhaytKpi.computeKpis(globalThis.KhaytKpiRows.kpiRows({
    orders: ARG0, from: b[0], to: b[1],
    money: function (o) {
      return {
        revenue: M.orderNetRevenueBase(o, ctx),
        cost: (o.parts || []).reduce(function (s, p) {
          return s + (+p.unitCost || 0) * (+p.qty || 1);
        }, 0),
        outstanding: M.orderOwedBase(o, ctx)
      };
    },
    // Resolved from `clientId` through the content-language rule, exactly as
    // `renderer/analytics.js` does it. This used to read `o.client`, a
    // free-text field a job may carry INSTEAD of a link, which grouped a shop's
    // customers by whatever was typed and in whichever language it was typed
    // in.
    //
    // Nothing on screen shows it yet: `Kpis` decodes the ten figures and drops
    // `topClients`, and the shop's real top-customer list comes from
    // `topLists` below, which rolls up by `clientId` inside the module. This is
    // corrected rather than left wrong so that surfacing the list later is a
    // decoding change and not a silent one — the trap is a field that looks
    // populated and is not.
    clientName: function (o) {
      if (!o.clientId) return "";
      var c = null;
      for (var i = 0; i < ARG1.length; i++) {
        if (ARG1[i] && ARG1[i].id === o.clientId) { c = ARG1[i]; break; }
      }
      if (!c) return "";
      return globalThis.KhaytContentLanguages.read(c, 'name', ARG5, ARG2) || "";
    },
    unassigned: ARG4
  }));
})()
"""
