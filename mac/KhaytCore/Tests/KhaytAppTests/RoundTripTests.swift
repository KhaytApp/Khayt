import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// Opening a record and pressing Save must not change it.
///
/// ── THE FAULT THIS GUARDS ──────────────────────────────────────────────────
///
/// A Mac editor reads a record into a draft and writes the draft back, and a
/// draft is narrower than a book. The machine sheet read only
/// `yyyy-MM-dd'T'HH:mm` downtime stamps, so a book holding
/// `2026-07-05T08:00:00.000Z` opened as now→now and SAVING DELETED the window
/// (#1670). The same shape was everywhere: `"150"` watts read as a number
/// and written back as one, a colour name read as the fallback grey, a
/// spool's ISO `openedAt` re-spelled as a day, a supplier's zero-priced quote
/// dropped, a job's ISO due date re-spelled and logged as an edit nobody
/// made, a part's `"2.5"` hours saved as 0 and the part re-costed at the
/// shop's default rates.
///
/// The book below is written to be awkward on purpose — every shape a real
/// book can hold because another writer put it there: ISO stamps with and
/// without fractions and offsets, local datetimes, bare days; numbers as
/// strings; `null` beside missing beside `""`; enum values this build has no
/// menu item for; fields this app does not model, on every record. Each
/// editor's own open→save mapping is run over it, and the saved record must
/// equal the stored one when nothing was edited — and differ ONLY in the
/// edited field when one was.
@MainActor
struct RoundTripTests {

    // MARK: - The book

    static let book: [String: JSONValue] = {
        let json = #"""
        {
          "clients": [{
            "id": "CLI-1", "nameEn": "Sara ", "nameAr": null, "phone": 966500000001,
            "email": "", "cr": null, "defaultDiscount": "10", "source": "tiktok-live",
            "createdAt": "2026-01-02T10:00:00+03:00", "marketingOptOut": "yes",
            "messageLang": null, "loyaltyTier": {"level": 2},
            "priceList": [
              {"product": "bracket", "price": "25", "note": null, "sku": "BR-1"},
              {"product": "", "price": 0, "legacy": true}
            ],
            "recurring": {"enabled": true, "interval": "yearly",
                          "nextDue": "2026-10-05T00:00:00.000Z", "leadDays": "3",
                          "templateOrderId": "O-1", "cloneStatus": "quote"},
            "commLog": [{"channel": "phone", "note": "called", "at": "2026-09-01T09:00:00Z", "quick": true}]
          }],
          "suppliers": [{
            "id": "sup-1", "name": "Filament Co ", "category": "resin", "phone": 5551234,
            "leadDays": 2.5, "website": null, "notes": "",
            "priceList": [
              {"material": "PLA", "pricePerKg": "80", "currency": "SAR"},
              {"material": "", "pricePerKg": 0}
            ],
            "purchases": [{"id": "p1", "date": "2026-08-01", "amount": "120"}],
            "accountNo": "ACC-9"
          }],
          "products": [{
            "id": "PROD-1", "nameEn": " Vase ", "nameAr": "مزهرية", "descEn": null,
            "defaultMargin": "30", "group": null, "category": "Home",
            "parts": [{
              "id": "PART-1", "name": "Body", "printWeight": "12.34567", "printTime": 2.5,
              "qty": "2", "filamentId": "INV-1", "material": "PLA", "spoolCost": 80,
              "spoolWeight": 1000, "laborRate": "90", "prepTime": null, "plate": 1,
              "fileRef": "vase.3mf"
            }],
            "priceTiers": [{"label": "Wholesale", "margin": "20", "minQty": 10}, {"label": "", "margin": 5}],
            "docs": [
              {"filename": "a.pdf", "originalName": "A.pdf", "size": "100",
               "packWithOrder": false, "mime": "application/pdf"},
              {"originalName": "orphan"}
            ],
            "priceRound": {"step": 0, "mode": "up"}, "priceOverride": "",
            "storefrontBadge": "new"
          }],
          "inventory": [
            {"id": "INV-1", "material": "PLA", "color": "#f80", "cost": "85", "weight": 750,
             "spoolWeight": "1000", "openedAt": "2026-05-01T09:30:00.000Z",
             "purchasedAt": "2026-04-30", "unit": "g", "vatAmount": 12, "lot": null,
             "printTemp": "210", "dryBox": "B2"},
            {"id": "INV-2", "material": "PLA", "color": "#112233", "cost": 60, "weight": 400,
             "spoolWeight": 1000}
          ],
          "consumables": [{
            "id": "CNS-1", "name": "Glue", "stock": "5", "unit": null, "cost": 12.5,
            "category": null, "isPackaging": false, "supplierSku": "G-7"
          }],
          "machines": [{
            "id": "M-1", "name": "U1", "color": "orange", "nozzleDiameter": "0.6",
            "powerDraw": "150", "targetHoursPerDay": "8", "maxColors": 4,
            "nozzle": {"material": "hardened", "installedAt": "2026-03-01T08:00:00.000Z",
                       "gramsThreshold": "5000", "serial": "NZ-1"},
            "printerApi": {"type": "moonraker", "host": "u1.local", "port": "7125",
                           "apiKey": "__enc__abc", "tls": false},
            "webcam": {"enabled": true, "snapshotUrl": "http://u1.local/webcam/?action=snapshot",
                       "rotate": 90, "flipH": false, "flipV": false, "fps": 5},
            "downtimeBlocks": [
              {"from": "2026-07-05T08:00:00.000Z", "to": "2026-07-06T18:00:00+03:00", "reason": "Lens"},
              {"from": "2026-09-10T14:00", "to": "2026-09-10T16:30:00", "reason": "", "note": "belt"}
            ],
            "smartPlug": {"type": "shelly", "host": "10.0.0.9", "delayMin": "5", "autoOff": true,
                          "token": "__enc__tok", "relay": 1},
            "depreciation": {"price": "3000", "purchaseDate": "2026-01-15T00:00:00.000Z",
                             "life": "5", "lifeUnit": "months", "method": "declining",
                             "residual": null, "monthlyHours": 200},
            "loaded": [{"slot": 0, "hex": "#ff8800", "material": "PLA", "brand": "X"}],
            "chassis": {"serial": "U1-0001"}
          }],
          "machMaintTasks": [{
            "id": "T-1", "machineId": "M-1", "name": "Nozzle ", "intervalHours": "250",
            "intervalDays": 0, "lastDoneHours": 10, "lastDoneAt": "2026-06-01T00:00:00Z",
            "checklist": ["wipe"]
          }],
          "waTemplates": [{
            "id": "WATPL-1", "name": "Ready ", "body": "Hello {{client}}\n",
            "milestone": "packed-later", "lang": "fr", "author": "iOS"
          }],
          "printers": [{
            "id": "PRNTR-1", "name": "Bench", "wearRate": "0.75", "powerDraw": 150,
            "elecRate": 0.18, "laborRate": "90", "failureRate": 10, "prepTime": 0.1,
            "postTime": 0.1, "machineId": "M-1"
          }],
          "printLog": [{
            "id": "O-1", "date": "2026-09-01T10:00:00.000Z", "project": "Vases", "status": "pending",
            "dueDate": "2026-10-05T21:00:00.000Z", "priorityLevel": "low", "priority": true,
            "price": 100, "paidAmount": 0, "paymentStatus": "unpaid", "printTime": 2.5,
            "notes": "",
            "parts": [
              {"id": "PT-1", "name": "Body", "printWeight": 12.34567, "printTime": "2.5",
               "qty": 1, "filamentId": "INV-2", "material": "PLA", "laborRate": "90",
               "unitCost": 10, "colour": "#112233"}
            ]
          }],
          "settings": {
            "vatRate": "15", "enableVat": true, "invPrefix": "INV-", "bizEn": "Acme ",
            "phone": 966500000000, "footerEn": null,
            "ntfy": {"enabled": true, "server": "https://ntfy.sh ", "topic": "shop",
                     "events": {"error": true}, "priority": 4},
            "telegram": {"chatId": 12345, "notifyOnComplete": "true", "botToken": "__enc__bt"},
            "emailConfig": {"provider": "smtp", "smtpHost": "mail.x", "smtpPort": "587",
                            "smtpSecure": false, "triggers": ["completed"], "replyTo": "a@b"},
            "fixedCosts": [{"id": "fc1", "name": "Rent", "amount": "1200", "dueDay": 1},
                           {"name": "Power", "amount": 300}],
            "slicers": [{"id": "s1", "name": "Orca", "path": "/Applications/Orca.app",
                         "args": "", "flavour": "orca"}],
            "defaultSlicerId": "s1",
            "slicer": {"path": "/Applications/Orca.app", "args": "", "legacy": true},
            "storefront": {"note": "Hi", "leadTime": 3, "minOrder": "50", "depositPct": 30,
                           "shipping": [{"label": "Riyadh", "price": "25", "zone": "R"}],
                           "promos": [{"code": "EID", "type": "pct", "value": 10,
                                       "expires": "", "maxUses": 0, "uses": 3},
                                      {"code": "", "type": "fixed", "value": 0}],
                           "theme": "dark"}
          }
        }
        """#
        let data = Data(json.utf8)
        guard case .object(let root) = try! JSONDecoder().decode(JSONValue.self, from: data) else {
            fatalError("the fixture is not an object")
        }
        return root
    }()

    static func rows(_ key: String) -> [[String: JSONValue]] {
        guard case .array(let list)? = book[key] else { return [] }
        return list.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    static func first(_ key: String) -> [String: JSONValue] { rows(key)[0] }

    static var settings: [String: JSONValue] {
        if case .object(let s)? = book["settings"] { return s } else { return [:] }
    }

    static func decode<T: Decodable>(_ raw: [String: JSONValue], as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(JSONValue.object(raw)))
    }

    static var spools: [Spool] { rows("inventory").compactMap { try? decode($0, as: Spool.self) } }

    /// Every key whose value differs, for a failure that says which field.
    static func diff(_ a: [String: JSONValue], _ b: [String: JSONValue]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }

    // MARK: - Reading what the book holds

    /// A record whose numbers are strings, or whose phone is a number, was
    /// SKIPPED — absent from every screen, so it could not even be opened.
    @Test("a record with numbers as strings still opens")
    func awkwardRecordsDecode() throws {
        let client = try #require(Client.decoding(Self.first("clients")))
        #expect(client.phone == "966500000001")
        #expect(client.defaultDiscount == 10)
        let machine = try Self.decode(Self.first("machines"), as: Machine.self)
        #expect(machine.powerDraw == 150)
        #expect(machine.printerApi?.port == 7125)
        #expect(machine.smartPlug?.delayMin == 5)
        #expect(Self.spools.count == 2)
        #expect(Self.spools[0].cost == 85)
        let consumable = try Self.decode(Self.first("consumables"), as: Consumable.self)
        #expect(consumable.stock == 5)
    }

    @Test("a three-digit colour and an ISO schedule day open as themselves")
    func widerShapesRead() {
        #expect(NSColor(hex: "#f80")?.hexString == "#FF8800")
        #expect(NSColor(hex: "#ff880080")?.hexString == "#FF8800")
        let day = Recurring.day("2026-10-05T00:00:00.000Z")
        #expect(day != nil)
    }

    // MARK: - Customers

    @Test("a customer opened and saved is unchanged")
    func customerUntouched() throws {
        let raw = Self.first("clients")
        let client = try #require(Client.decoding(raw))
        let saved = Shop.customerRecord(saving: CustomerSheet.saving(CustomerSheet.opening(client)), over: raw)
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")
    }

    @Test("a customer with one field edited changes only that field")
    func customerOneEdit() throws {
        let raw = Self.first("clients")
        let client = try #require(Client.decoding(raw))
        var opened = CustomerSheet.opening(client)
        opened.draft = opened.draft.with(\.email, "sara@example.com")
        let saved = Shop.customerRecord(saving: CustomerSheet.saving(opened), over: raw)
        #expect(Self.diff(saved, raw) == ["email"])
        // A price row added is an edit to the LIST, which is written as the
        // sheet makes it (blank rows dropped, as the other app drops them) —
        // but every row still carries the fields the other app gave it.
        var more = CustomerSheet.opening(client)
        more.agreements.append(.init(PriceAgreement(product: "hook", price: 5)))
        let grown = Shop.customerRecord(saving: CustomerSheet.saving(more), over: raw)
        #expect(Self.diff(grown, raw) == ["priceList"])
        guard case .array(let list)? = grown["priceList"], case .object(let kept)? = list.first else {
            Issue.record("no price list"); return
        }
        #expect(kept["sku"] == .string("BR-1"), "the agreement lost the field the other app wrote")
    }

    // MARK: - Suppliers

    @Test("a supplier opened and saved is unchanged")
    func supplierUntouched() throws {
        let raw = Self.first("suppliers")
        let supplier = try #require(Supplier(row: .object(raw)))
        let saving = SupplierSheet.saving(supplier, lead: SupplierSheet.leadText(supplier))
        let saved = Shop.supplierRecord(saving: saving, over: raw)
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")
    }

    @Test("a supplier with its notes edited keeps its quotes and lead time")
    func supplierOneEdit() throws {
        let raw = Self.first("suppliers")
        var supplier = try #require(Supplier(row: .object(raw)))
        supplier.notes = "ships Sundays"
        let saved = Shop.supplierRecord(
            saving: SupplierSheet.saving(supplier, lead: SupplierSheet.leadText(supplier)), over: raw)
        #expect(Self.diff(saved, raw) == ["notes"])
    }

    // MARK: - Products

    static let keys = [
        Product.LanguageKey(language: "en", title: "English", name: "nameEn", description: "descEn"),
        Product.LanguageKey(language: "ar", title: "العربية", name: "nameAr", description: "descAr"),
    ]

    static func productSave(_ opened: ProductSheet.Opened) -> [String: JSONValue] {
        let payload = ProductSheet.payload(opened, spools: spools)
        var record = payload.product.record(keys: keys)
        record["parts"] = .array(payload.parts)
        record["priceTiers"] = .array(payload.tiers)
        record["docs"] = .array(payload.docs)
        return record
    }

    @Test("a product opened and saved is unchanged")
    func productUntouched() {
        let raw = Self.first("products")
        let opened = ProductSheet.opening(Product.from(raw, keys: Self.keys))
        let written = Self.productSave(opened)
        let saved = Shop.productRecord(written: written, baseline: written, priced: [:], over: raw)
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")
    }

    @Test("a product with its category edited keeps its parts, tiers and papers")
    func productOneEdit() {
        let raw = Self.first("products")
        let opened = ProductSheet.opening(Product.from(raw, keys: Self.keys))
        let baseline = Self.productSave(opened)
        var edited = opened
        edited.draft.category = "Garden"
        let saved = Shop.productRecord(written: Self.productSave(edited), baseline: baseline,
                                       priced: [:], over: raw)
        #expect(Self.diff(saved, raw) == ["category"])
    }

    // MARK: - Spools

    @Test("a spool opened and saved is unchanged")
    func spoolUntouched() async throws {
        let engine = try KhaytEngine()
        let raw = Self.first("inventory")
        let form = SpoolSheet.Form.opening(Self.spools[0], unit: "g")
        let input = form.input(isNew: false, reclaimsTax: true)
        let out = try await Shop.editedSpool(.object(raw), input: input, opened: input,
                                             settings: Self.settings, today: "2026-09-29", engine: engine)
        guard case .object(let saved) = out.spool else { Issue.record("no spool"); return }
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")
    }

    @Test("a spool with its lot edited changes only the lot")
    func spoolOneEdit() async throws {
        let engine = try KhaytEngine()
        let raw = Self.first("inventory")
        let form = SpoolSheet.Form.opening(Self.spools[0], unit: "g")
        var edited = form
        edited.lot = "L-42"
        let out = try await Shop.editedSpool(
            .object(raw), input: edited.input(isNew: false, reclaimsTax: true),
            opened: form.input(isNew: false, reclaimsTax: true),
            settings: Self.settings, today: "2026-09-29", engine: engine)
        guard case .object(let saved) = out.spool else { Issue.record("no spool"); return }
        #expect(Self.diff(saved, raw) == ["lot"], "changed: \(Self.diff(saved, raw))")
    }

    // MARK: - Consumables

    @Test("a consumable opened and saved is unchanged, and one edit is one change")
    func consumableRoundTrip() async throws {
        let engine = try KhaytEngine()
        let raw = Self.first("consumables")
        let form = ConsumableSheet.Form.opening(try Self.decode(raw, as: Consumable.self))
        let out = try await Shop.editedConsumable(.object(raw), input: form.input,
                                                  opened: form.input, engine: engine)
        guard case .object(let saved) = out.consumable else { Issue.record("no item"); return }
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")

        var edited = form
        edited.cost = 14
        let changed = try await Shop.editedConsumable(.object(raw), input: edited.input,
                                                      opened: form.input, engine: engine)
        guard case .object(let after) = changed.consumable else { Issue.record("no item"); return }
        #expect(Self.diff(after, raw) == ["cost"], "changed: \(Self.diff(after, raw))")
    }

    // MARK: - Machines

    static func machineSave(_ form: MachineSheet.Form, opened: MachineSheet.Form,
                            engine: KhaytEngine) async throws -> [String: JSONValue] {
        let raw = first("machines")
        let out = try await Shop.editedMachine(
            .object(raw), record: .object(raw),
            input: await Shop.sanitisingWebcam(form.input(), engine: engine),
            opened: await Shop.sanitisingWebcam(opened.input(), engine: engine),
            settings: settings, engine: engine)
        guard case .object(let saved)? = out.machine else { return [:] }
        return saved
    }

    @Test("a machine opened and saved is unchanged")
    func machineUntouched() async throws {
        let engine = try KhaytEngine()
        let raw = Self.first("machines")
        let form = MachineSheet.Form.opening(try Self.decode(raw, as: Machine.self), kind: "fdm")
        let saved = try await Self.machineSave(form, opened: form, engine: engine)
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")
    }

    @Test("a machine renamed keeps its downtime, depreciation, nozzle and colour")
    func machineOneEdit() async throws {
        let engine = try KhaytEngine()
        let raw = Self.first("machines")
        let form = MachineSheet.Form.opening(try Self.decode(raw, as: Machine.self), kind: "fdm")
        var edited = form
        edited.name = "U1 left"
        let saved = try await Self.machineSave(edited, opened: form, engine: engine)
        #expect(Self.diff(saved, raw) == ["name"], "changed: \(Self.diff(saved, raw))")
    }

    // MARK: - Jobs

    static func order() throws -> Order { try decode(first("printLog"), as: Order.self) }

    @Test("a job opened in the edit sheet and saved sends nothing")
    func jobUntouched() async throws {
        let order = try Self.order()
        let opened = EditJobSheet.opening(order, priority: Shop().priorityOf(order))
        let fields = EditJobSheet.fields(opened: opened, hasDueDate: opened.hasDueDate,
                                         dueDate: opened.dueDate ?? Date(), priority: opened.priority,
                                         price: nil)
        #expect(fields.isEmpty, "sent \(fields.keys.sorted())")
        let engine = try KhaytEngine()
        let out = try await engine.editJob(order: .object(Self.first("printLog")), fields: fields,
                                           now: Date(), editId: "e1")
        #expect(out.changed == false)
        #expect(out.order == .object(Self.first("printLog")))
    }

    @Test("a job's priority edited leaves its ISO due date alone")
    func jobOneEdit() async throws {
        let order = try Self.order()
        let opened = EditJobSheet.opening(order, priority: Shop().priorityOf(order))
        let fields = EditJobSheet.fields(opened: opened, hasDueDate: true,
                                         dueDate: opened.dueDate ?? Date(), priority: "urgent", price: nil)
        #expect(fields.keys.sorted() == ["priorityLevel"])
        // Moving the due date to another day is still an edit.
        let moved = EditJobSheet.fields(opened: opened, hasDueDate: true,
                                        dueDate: (opened.dueDate ?? Date()).addingTimeInterval(86_400 * 2),
                                        priority: opened.priority, price: nil)
        #expect(moved.keys.sorted() == ["dueDate"])
    }

    // MARK: - A job's part

    @Test("a part opened names ITS spool and its string hours, and one edit is one change")
    func partRoundTrip() throws {
        let rawOrder = Self.first("printLog")
        guard case .array(let parts)? = rawOrder["parts"], case .object(let rawPart) = parts[0] else {
            Issue.record("no part"); return
        }
        let order = try Self.order()
        let opened = EditPartSheet.opening(order.parts[0], raw: rawPart, spools: Self.spools)
        #expect(opened.spoolId == "INV-2", "opened on \(opened.spoolId ?? "nil"), not the part's own spool")
        #expect(opened.hours == "2.5")
        let same = Shop.orderWithPartEdited(.object(rawOrder), partId: "PT-1", opened, opened: opened,
                                            spool: nil, costed: nil)
        #expect(same == .object(rawOrder))
        var edited = opened
        edited.name = "Body v2"
        guard case .object(let after) = Shop.orderWithPartEdited(
                .object(rawOrder), partId: "PT-1", edited, opened: opened, spool: nil, costed: nil),
              case .array(let list)? = after["parts"], case .object(let part) = list[0] else {
            Issue.record("no part after"); return
        }
        #expect(Self.diff(part, rawPart) == ["name"])
    }

    // MARK: - Maintenance tasks, templates, presets

    @Test("a maintenance task opened and saved is unchanged")
    func maintenanceUntouched() {
        let raw = Self.first("machMaintTasks")
        let opened = MaintenanceTaskEdit.Opened(name: "Nozzle ", intervalHours: 250, intervalDays: 0)
        let saved = MaintenanceTaskEdit.edited(raw, name: opened.name, intervalHours: opened.intervalHours,
                                               intervalDays: opened.intervalDays, opened: opened)
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")
        let renamed = MaintenanceTaskEdit.edited(raw, name: "Nozzle swap", intervalHours: 250,
                                                 intervalDays: 0, opened: opened)
        #expect(Self.diff(renamed, raw) == ["name"])
    }

    @Test("a message template opened and saved is unchanged")
    func templateUntouched() throws {
        let raw = Self.first("waTemplates")
        let template = try #require(MessageTemplate.from([.object(raw)]).first)
        let saved = Shop.templateRow(id: template.id, name: template.name, body: template.body,
                                     milestone: template.milestone, lang: template.lang,
                                     over: raw, opened: template)
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")
    }

    @Test("a preset saved over with the same rates is unchanged")
    func presetUntouched() throws {
        let raw = Self.first("printers")
        let preset = try #require(Shop.Preset.from(.object(raw)))
        let saved = Shop.presetRow(preset, over: raw)
        #expect(Self.diff(saved, raw).isEmpty, "changed: \(Self.diff(saved, raw))")
    }

    // MARK: - Settings

    static func settingsSaved(form: [String: JSONValue], engine: KhaytEngine) async throws -> [String: JSONValue] {
        var root: [String: JSONValue] = ["settings": .object(settings)]
        try await Shop.applySettings(to: &root, form: form, opened: form, country: nil, engine: engine)
        return Shop.settings(root)
    }

    @Test("every settings pane opened and saved leaves the settings unchanged")
    func settingsUntouched() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let s = Self.settings
        let forms: [(String, [String: JSONValue])] = [
            ("business", BusinessPane.Draft.read(s, shop: shop).form()),
            ("invoice", InvoicePane.Draft.read(s, shop: shop).form()),
            ("payments", PaymentsPane.Draft.read(s, shop: shop).form()),
            ("operations", OperationsPane.Draft.read(s, shop: shop).form()),
            ("preferences", PreferencesPane.Draft.read(s, shop: shop).form()),
            ("integrations", IntegrationsPane.Draft.read(s).form()),
            ("ntfy", ["ntfy": .object(NtfySettings.form(NtfySettings.Draft.read(s)))]),
            ("email", ["emailConfig": .object(EmailSettings.form(EmailSettings.Draft.read(s)))]),
            ("telegram", ["telegram": .object(TelegramSettings.form(TelegramSettings.Draft.read(s)))]),
            ("fixed costs", ["fixedCosts": FixedCostsSettings.form(FixedCostsSettings.read(s))]),
        ]
        for (pane, form) in forms {
            let saved = try await Self.settingsSaved(form: form, engine: engine)
            // Every key the book HAS is as it was. A key it lacks may be filled
            // with the rule's default, as every settings save always has.
            let kept = saved.filter { s[$0.key] != nil }
            #expect(Self.diff(kept, s).isEmpty, "\(pane) changed: \(Self.diff(kept, s))")
        }
    }

    @Test("a settings pane with one field edited changes only that field")
    func settingsOneEdit() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let s = Self.settings
        var root: [String: JSONValue] = ["settings": .object(s)]
        let opened = NtfySettings.Draft.read(s)
        var edited = opened
        edited.topic = "shop-2"
        try await Shop.applySettings(to: &root, form: ["ntfy": .object(NtfySettings.form(edited))],
                                     opened: ["ntfy": .object(NtfySettings.form(opened))],
                                     country: nil, engine: engine)
        let saved = Shop.settings(root).filter { s[$0.key] != nil }
        #expect(Self.diff(saved, s) == ["ntfy"])
        guard case .object(let n)? = saved["ntfy"], case .object(let was)? = s["ntfy"] else { return }
        let had = n.filter { was[$0.key] != nil }
        #expect(Self.diff(had, was) == ["topic"], "ntfy changed: \(Self.diff(had, was))")
    }

    @Test("the slicer list, saved reports and web store settings survive an untouched save")
    func settingsListsUntouched() throws {
        let s = Self.settings
        let slicers = [KhaytEngine.Slicer(id: "s1", name: "Orca", path: "/Applications/Orca.app")]
        let fields = Shop.slicerFields(slicers, defaultId: "s1")
        let saved = Shop.settingsKeys(fields, opened: fields, over: s)
        #expect(Self.diff(saved, s).isEmpty, "changed: \(Self.diff(saved, s))")

        guard case .object(let sf)? = s["storefront"] else { Issue.record("no storefront"); return }
        let draft = StorefrontDraft(s)
        let kept = Shop.storefront(draft, opened: draft, over: sf)
        #expect(Self.diff(kept, sf).isEmpty, "changed: \(Self.diff(kept, sf))")
        var edited = draft
        edited.note = "Hello"
        #expect(Self.diff(Shop.storefront(edited, opened: draft, over: sf), sf) == ["note"])
    }

    // MARK: - The ratchet

    /// Every function in the app that saves a record an editor opened.
    ///
    /// A new `save…`/`edit…` fails this test until it is listed: either with
    /// the test above that proves its untouched round trip, or as exempt with
    /// the reason it cannot lose what it did not show. Writing that sentence
    /// is the review; a sentence that will not come is a round trip to write.
    static let covered: [String: String] = [
        "saveCustomer": "customerUntouched",
        "saveSupplier": "supplierUntouched",
        "saveProduct": "productUntouched",
        "saveSpool": "spoolUntouched",
        "saveConsumable": "consumableRoundTrip",
        "saveMachine": "machineUntouched",
        "editJob": "jobUntouched",
        "editPart": "partRoundTrip",
        "editMaintenanceTask": "maintenanceUntouched",
        "saveTemplate": "templateUntouched",
        "savePreset": "presetUntouched",
        "saveSettings": "settingsUntouched",
        "saveLanSettings": "settingsUntouched",
        "saveSlicers": "settingsListsUntouched",
        "saveReports": "settingsListsUntouched",
        "saveStorefront": "settingsListsUntouched",
    ]

    static let exempt: [String: String] = [
        "saveBucket": "writes six strings the pane shows verbatim and selects the bucket; nothing is parsed or defaulted except an empty region, which the other app also writes as auto",
        "saveCloudLibrary": "the caller of saveBucket, above; it adds only a secret that is sealed when typed",
        "editFiles": "a library edit hands one closure per field the shop changed; it never re-encodes a record",
        "saveSeen": "the LAN server's replay list, a file of its own; not a record in the book",
        "saveInstead": "Send Feedback's fallback: writes a zip to Downloads; reads the book, never writes it",
    ]

    @Test("every save path is round-trip tested or says why it need not be")
    func everySavePathIsCovered() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        let pattern = try Regex(#"func ((?:save|edit)[A-Z][A-Za-z]*)\("#)
        var found = Set<String>()
        for file in files {
            let text = try String(contentsOf: dir.appending(path: file), encoding: .utf8)
            for match in text.matches(of: pattern) {
                if let name = match.output[1].substring { found.insert(String(name)) }
            }
        }
        let listed = Set(Self.covered.keys).union(Self.exempt.keys)
        let unlisted = found.subtracting(listed).sorted()
        #expect(unlisted.isEmpty, "not round-trip tested and not exempt: \(unlisted)")
        let stale = listed.subtracting(found).sorted()
        #expect(stale.isEmpty, "listed but no longer in the app: \(stale)")

        let me = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        for (function, test) in Self.covered {
            #expect(me.contains("func \(test)("), "\(function) names a test that does not exist: \(test)")
        }
    }

    /// The sheets hand the save the form they OPENED with. A sheet that stops
    /// passing it silently goes back to re-spelling everything it shows.
    @Test("the sheets pass what they opened with")
    func sheetsPassOpened() {
        let wants: [(String, String)] = [
            ("MachineSheet.swift", "shop.saveMachine(input, id: id, catalogId: catalogId, opened: was)"),
            ("SpoolSheet.swift", "shop.saveSpool(input, id: id, opened: was)"),
            ("ConsumableSheet.swift", "shop.saveConsumable(input, id: id, opened: was)"),
            ("EditPartSheet.swift", "shop.editPart(orderId, partId: part.id, now, opened: was)"),
            ("CustomerSheet.swift", "Self.saving(Opened("),
            ("ProductSheet.swift", "let opened = Self.opening(existing)"),
            ("SupplierSheet.swift", "Self.saving(draft, lead: lead)"),
            ("EditJobSheet.swift", "Self.fields(opened: opened"),
            ("ServiceLog.swift", "opened: opened)"),
            ("TemplateSheet.swift", "opened: isNew ? nil : template"),
            ("WebStore.swift", "shop.saveStorefront(store, opened: storeSaved)"),
            ("OnlinePane.swift", "opened: Shop.lanForm("),
        ]
        for (file, needle) in wants {
            let text = EmptyStateTests.source(file)
            #expect(!text.isEmpty, "\(file) moved")
            #expect(text.contains(needle), "\(file) no longer passes what it opened with")
        }
    }
}
