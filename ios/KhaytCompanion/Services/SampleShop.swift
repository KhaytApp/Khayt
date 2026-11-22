import Foundation
import UIKit
import KhaytCore

/// A made-up print shop, so the app can be tried without one.
///
/// ── WHO IT IS FOR ───────────────────────────────────────────────────────
///
/// Everybody who installs the companion before they have Khayt on a Mac:
/// Apple's TestFlight reviewers, who cannot pair with anything, and anyone
/// who found the app on Reddit. Without it the app opens on a pairing screen
/// and nothing else, which is the same as not working.
///
/// ── WHAT IT IS ──────────────────────────────────────────────────────────
///
/// A book, shaped exactly like the one the Mac hands over — so every screen
/// reads it through the same rules as a real shop's, and nothing here is a
/// second, pretend code path. It lives on this phone only, sends nothing
/// anywhere, and its dates are built from today: "due tomorrow" and "late"
/// read true whichever day it is opened. Its three printers report live
/// progress (`liveReadings`), so live tracking can be seen without one.
enum SampleShop {
    static let label = "Sample Print Shop"

    static func book(now: Date = Date()) -> [String: JSONValue] {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        func day(_ offset: Int) -> JSONValue { .string(f.string(from: cal.date(byAdding: .day, value: offset, to: now)!)) }

        func order(_ id: String, _ status: String, _ project: String, _ client: String, _ clientId: String,
                   placed: Int, due: Int?, price: Double, paid: Double, material: String, qty: Int,
                   machine: (String, String)? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .string(id), "status": .string(status), "project": .string(project),
                "client": .string(client), "clientId": .string(clientId), "date": day(placed),
                "price": .number(price), "paidAmount": .number(paid), "material": .string(material),
                "parts": .array([.object(["qty": .number(Double(qty))])]), "priority": .bool(false),
                "rev": .number(1),
            ]
            if let due { o["dueDate"] = day(due) }
            if let machine { o["machineId"] = .string(machine.0); o["machine"] = .string(machine.1) }
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        let x1c = ("M-X1C", "Bambu X1C"), mk4 = ("M-MK4", "Prusa MK4"), saturn = ("M-SAT", "Elegoo Saturn 4")

        func careTask(_ id: String, _ machine: String, _ name: String, hours: Double = 0, days: Double = 0,
                      doneDaysAgo: Double, care: String, parts: [(String, Double)] = [],
                      extra: [String: JSONValue] = [:]) -> JSONValue {
            var t: [String: JSONValue] = [
                "id": .string(id), "machineId": .string(machine), "name": .string(name),
                "intervalHours": hours > 0 ? .number(hours) : .null,
                "intervalDays": days > 0 ? .number(days) : .null,
                "lastDoneHours": .number(0),
                "lastDoneAt": .string(StoreWriter.iso(now.addingTimeInterval(-doneDaysAgo * 86_400))),
                "careTaskId": .string(care), "rev": .number(1),
            ]
            if !parts.isEmpty {
                t["parts"] = .array(parts.map { .object(["id": .string($0.0), "qty": .number($0.1)]) })
            }
            for (k, v) in extra { t[k] = v }
            return .object(t)
        }

        return [
            "settings": .object([
                // `bizEn` / `bizAr` are the shop's name as the desk stores it —
                // what a customer message signs with. Without them the WhatsApp
                // update read "thank you for your order with ."
                "shopName": .string(label), "bizEn": .string(label), "bizAr": .string("ورشة الطباعة التجريبية"),
                "currency": .string("USD"),
                // What a kWh costs the shop, so a metered print shows its cost.
                "elecRate": .number(0.18),
                "enableVat": .bool(false), "language": .string("en"),
                // Counted stock for two of the catalogue; the rest is not stocked.
                "storefront": .object(["stockQty": .object(["PROD-S1": .number(6), "PROD-S2": .number(0)])]),
                // Two connectors, approved on the Mac: the signed Lamha sample
                // with its button on a job, and the signed Slack sample with a
                // narrower grant, so it is paused.
                // DEBUG builds only (tests, screenshots): a TestFlight or App
                // Store build's sample shop shows no connector until
                // khaytapp.com/privacy describes them.
                "plugins": shippedSampleConnectors,
            ]),
            // The catalogue: one with a picture, a rounded price, an override,
            // one never stocked — so every line of the screen is drawn.
            "products": .array([
                product("PROD-S1", "Desk lamp shade", "غطاء مصباح مكتب", group: "Home", base: 38.4,
                        extra: ["priceRound": .object(["step": .number(5), "mode": .string("up")]),
                                "thumbnail": .string(samplePicture(hue: 0.08))],
                        part: (hours: 6.5, grams: 180, material: "PLA")),
                product("PROD-S2", "Cable organiser (set of 4)", "منظم كابلات (٤ قطع)", group: "Office", base: 12,
                        extra: ["thumbnail": .string(samplePicture(hue: 0.55))],
                        part: (hours: 1.8, grams: 42, material: "PETG")),
                product("PROD-S3", "Custom name plate", "لوحة اسم مخصصة", group: "Gifts", base: 21.6,
                        extra: ["priceOverride": .number(25)], part: (hours: 2.4, grams: 55, material: "PLA")),
                product("PROD-S4", "Replacement knob", "مقبض بديل", group: "Parts", base: 6.5,
                        extra: [:], part: (hours: 0.6, grams: 9, material: "PETG")),
            ]),
            "machines": .array([
                .object(["id": .string(x1c.0), "name": .string(x1c.1), "type": .string("fdm"),
                         "status": .string("printing"), "printerApi": .object(["type": .string("bambu")])]),
                .object(["id": .string(mk4.0), "name": .string(mk4.1), "type": .string("fdm"),
                         "status": .string("printing"), "printerApi": .object(["type": .string("prusalink")])]),
                .object(["id": .string(saturn.0), "name": .string(saturn.1), "type": .string("resin"),
                         "status": .string("idle"), "printerApi": .object(["type": .string("none")])]),
            ]),
            // Printer care (`lib/maintenance.js`), dated from today so the
            // card always shows one task overdue and one due on the X1C, one
            // coming up, one inspected and pushed out, and parts falling due
            // on several different days.
            "machMaintTasks": .array([
                careTask("MT-S1", x1c.0, "Lubricate carbon rods", days: 30, doneDaysAgo: 50,
                         care: "carbon_rods", parts: [("oil", 1)]),
                careTask("MT-S2", x1c.0, "Replace carbon filter", days: 90, doneDaysAgo: 100,
                         care: "carbon_filter", parts: [("carbon_filter", 1)]),
                careTask("MT-S3", x1c.0, "Clean build plate", hours: 50, doneDaysAgo: 3, care: "plate"),
                careTask("MT-S4", mk4.0, "Clean and lubricate rods", days: 60, doneDaysAgo: 56,
                         care: "rods", parts: [("grease", 1)]),
                careTask("MT-S5", mk4.0, "Replace PTFE tube", days: 180, doneDaysAgo: 120,
                         care: "ptfe", parts: [("ptfe_tube", 1)]),
                careTask("MT-S6", saturn.0, "Replace FEP film", days: 60, doneDaysAgo: 30,
                         care: "fep", parts: [("fep_film", 1)]),
                careTask("MT-S7", saturn.0, "Change the IPA", days: 14, doneDaysAgo: 10,
                         care: "ipa", parts: [("ipa", 2)]),
                careTask("MT-S8", saturn.0, "Clean resin vat", days: 7, doneDaysAgo: 9, care: "vat",
                         extra: ["inspectedAt": .string(StoreWriter.iso(now.addingTimeInterval(-86_400))),
                                 "inspectedHours": .number(0),
                                 "deferUntilHours": .null,
                                 "deferUntilAt": .string(StoreWriter.iso(now.addingTimeInterval(3 * 86_400)))]),
            ]),
            "clients": .array([
                .object(["id": .string("C-1"), "nameEn": .string("Acme Robotics"), "phone": .string("+15555550101"), "rev": .number(1),
                         "plugins": .object([lamhaId: .object(["city": .string("Riyadh")])])]),
                .object(["id": .string("C-2"), "nameEn": .string("Northside Dental"), "email": .string("lab@example.com"), "rev": .number(1)]),
                .object(["id": .string("C-3"), "nameEn": .string("Maya Chen"), "phone": .string("+15555550142"), "rev": .number(1)]),
                .object(["id": .string("C-4"), "nameEn": .string("Tabletop Guild"), "rev": .number(1)]),
                .object(["id": .string("C-5"), "nameEn": .string("Omar Haddad"), "rev": .number(1)]),
            ]),
            "printLog": .array([
                order("S-1041", "printing", "Drone arm set", "Acme Robotics", "C-1", placed: -3, due: 1, price: 180, paid: 90, material: "PETG", qty: 4, machine: x1c),
                order("S-1042", "printing", "Cable clips", "Tabletop Guild", "C-4", placed: -2, due: 2, price: 45, paid: 0, material: "PLA", qty: 40, machine: mk4),
                order("S-1043", "pending", "Aligner trays", "Northside Dental", "C-2", placed: -1, due: 3, price: 260, paid: 0, material: "Resin", qty: 6),
                order("S-1044", "pending", "Phone stand", "Maya Chen", "C-3", placed: 0, due: 4, price: 25, paid: 25, material: "PLA", qty: 1),
                // Two models the shop may not sell prints of (`library()`), so
                // the job's page draws "Not licensed for sale" with both lines.
                order("S-1045", "pending", "Terrain tiles", "Tabletop Guild", "C-4", placed: -4, due: -1, price: 120, paid: 60, material: "PLA", qty: 24,
                      extra: ["parts": .array([
                          .object(["qty": .number(16), "printFileId": .string("PF-sample-terrain")]),
                          .object(["qty": .number(8), "printFileId": .string("PF-sample-tile-base")]),
                      ])]),
                order("S-1046", "post", "Enclosure lid", "Acme Robotics", "C-1", placed: -5, due: 0, price: 95, paid: 95, material: "ABS", qty: 1,
                      extra: ["plugins": .object([lamhaId: .object(["lamhaOrderId": .string("48213")])])]),
                order("S-1047", "qc", "Bracket v3", "Omar Haddad", "C-5", placed: -6, due: 1, price: 60, paid: 0, material: "PETG", qty: 2),
                // Two quotes waiting on the customer, so the Quotes list and
                // a quote's Approve and Decline can be seen. A quote has no
                // invoice number and no due day until it is approved.
                order("S-1049", "quote", "Trophy bases", "Omar Haddad", "C-5", placed: 0, due: nil, price: 85, paid: 0, material: "PLA", qty: 3,
                      extra: ["quoteExpiresAt": day(7)]),
                order("S-1048", "quote", "Prototype housing", "Acme Robotics", "C-1", placed: -2, due: nil, price: 340, paid: 0, material: "ABS", qty: 2,
                      extra: ["quoteExpiresAt": day(5)]),
                // Placed and finished today, so Home's This month and This
                // year have takings on the first day of a month or a year, and
                // Done today counts it.
                // Two finished prints a smart plug metered (`lib/print-energy.js`
                // `jobFields`), so the job page shows the energy and its cost —
                // one whole, one missing a few minutes and scaled up — and one
                // metered too little, which shows nothing.
                order("S-1038", "completed", "Planter", "Maya Chen", "C-3", placed: 0, due: 0, price: 35, paid: 35, material: "PLA", qty: 1,
                      machine: mk4,
                      extra: ["completedAt": .string(f.string(from: now) + "T08:30:00.000Z"),
                              "actualPrintTime": .number(2.6),
                              "actualEnergyWh": .number(318.4),
                              "actualEnergy": energy(coveredS: 9_540, spanS: 9_540, samples: 160)]),
                order("S-1036", "completed", "Gear housing", "Acme Robotics", "C-1", placed: -12, due: -5, price: 150, paid: 150, material: "Nylon", qty: 3,
                      machine: x1c,
                      extra: ["actualPrintTime": .number(9.4),
                              "actualEnergyWh": .number(1_712.6),
                              "actualEnergy": energy(coveredS: 33_100, spanS: 34_480, samples: 552, gaps: 1)]),
                order("S-1031", "completed", "Crown models", "Northside Dental", "C-2", placed: -20, due: -14, price: 310, paid: 310, material: "Resin", qty: 8,
                      machine: saturn,
                      extra: ["actualEnergyWh": .number(96.2),
                              "actualEnergy": energy(coveredS: 4_100, spanS: 10_800, samples: 70, gaps: 3)]),
                order("S-1024", "completed", "Dice tower", "Tabletop Guild", "C-4", placed: -40, due: -33, price: 55, paid: 55, material: "PLA", qty: 1),
            ]),
            // Three low, each bought from someone else, so the shopping list
            // (`lib/reorder.js shoppingList`) has three suppliers: the PLA by
            // the price list that sells it, the ABS and the resin by their
            // own supplier.
            "inventory": .array([
                spool("SP-201", "Bambu", "PLA", "#1B1B1F", left: 180, of: 1000, cost: 19.99),
                spool("SP-202", "Polymaker", "PETG", "#2F6DB5", left: 640, of: 1000, cost: 22.50),
                spool("SP-203", "Prusament", "PLA", "#E8662A", left: 910, of: 1000, cost: 29.99),
                spool("SP-204", "eSun", "ABS", "#F2F2F0", left: 120, of: 1000, cost: 18.00,
                      extra: ["supplierId": .string("SUP-2")]),
                spool("SP-205", "Elegoo", "Resin", "#9AA3AD", left: 150, of: 1000, cost: 35.00,
                      extra: ["supplierId": .string("SUP-3"), "reorderQty": .number(2000)]),
                spool("SP-206", "Polymaker", "Nylon", "#C9B79C", left: 750, of: 750, cost: 42.00),
            ]),
            "suppliers": .array([
                supplier("SUP-1", "Bambu Lab Store", prices: [("PLA", 19.99), ("PETG", 21.99)], leadDays: 6),
                supplier("SUP-2", "Filament Depot", prices: [], leadDays: 3),
                supplier("SUP-3", "Elegoo Official", prices: [], leadDays: 10),
            ]),
            // The calculator's saved presets and the consumables shelf, so the
            // sample prices a part the way a real shop's book would.
            "printers": .array([
                .object(["id": .string("PR-1"), "name": .string("Everyday PLA"),
                         "wearRate": .number(0.35), "powerDraw": .number(150), "elecRate": .number(0.18),
                         "laborRate": .number(20), "failureRate": .number(8),
                         "prepTime": .number(0.15), "postTime": .number(0.25), "rev": .number(1)]),
            ]),
            "consumables": .array([
                .object(["id": .string("CN-1"), "name": .string("Magnet 6×2 mm"), "cost": .number(0.12),
                         "stock": .number(240), "unit": .string("pcs"), "rev": .number(1)]),
                .object(["id": .string("CN-2"), "name": .string("M3 heat-set insert"), "cost": .number(0.08),
                         "stock": .number(500), "unit": .string("pcs"), "rev": .number(1)]),
            ]),
            "waitingList": .array([
                .object(["id": .string("W-11"), "project": .string("Custom cosplay helmet"),
                         "clientName": .string("Jordan Lee"), "status": .string("active"),
                         "material": .string("PLA"), "notes": .string("Wants it painted, by the 20th"),
                         "submittedAt": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 3600))),
                         "rev": .number(1)]),
                .object(["id": .string("W-12"), "project": .string("Replacement knob x10"),
                         "clientName": .string("Sam Rivera"), "status": .string("active"),
                         "submittedAt": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-26 * 3600))),
                         "rev": .number(1)]),
            ]),
        ]
    }

    /// The sample connectors' `settings.plugins` (`Connectors.swift`). Both
    /// are Khayt's real signed samples, reviewed by their signature like any
    /// other connector — the sample shop has no way round that.
    ///
    /// Lamha (`plugins/samples/lamha-shipping.json`, `lamhaManifestJSON`) is
    /// granted everything it asks for (`lib/plugin-manifest.js` `grantFor`),
    /// with its settings filled in as a shop would on the Mac, so it is active
    /// and its button shows on a job. Slack's grant is narrower than its
    /// manifest, so it is paused.
    static let lamhaId = "app.khayt.samples.lamha"

    /// What the sample shop's book holds: the sample connectors once
    /// `ConnectorLaunch.launched` (the one launch-day switch for connectors
    /// on the phone), or in DEBUG; none before.
    static var shippedSampleConnectors: JSONValue {
        #if DEBUG
        sampleConnectors
        #else
        ConnectorLaunch.launched ? sampleConnectors : .array([])
        #endif
    }

    /// What a sample connector's service would answer, so the sample shop can
    /// show the whole flow while sending nothing: Lamha's create-order reply
    /// (its `order_id` lands in the job's Lamha order field through the shared
    /// mapping). Nil for an action with no reply to show.
    static func simulatedReply(connectorId: String, actionId: String) -> JSONValue? {
        guard connectorId == lamhaId, actionId == "record" else { return nil }
        return .object(["success": .bool(true), "order_id": .number(48214)])
    }

    static var sampleConnectors: JSONValue {
        let lamha = (try? JSONValue.parse(Data(lamhaManifestJSON.utf8))) ?? .null
        let granted = (try? JSONValue.parse(Data(#"{"version":"1.1.1","fields":["config.carrierId","config.senderAddress","config.senderCity","config.senderName","config.senderPhone","customer.address","customer.email","customer.name","customer.phone","field.city","order.currency","order.date","order.id","order.number","order.qty","order.title","order.total"],"domains":["app.lamha.sa"],"scopes":["fields.write"]}"#.utf8))) ?? .null
        let lamhaEntry: JSONValue = .object([
            "id": .string(lamhaId), "version": .string("1.1.1"), "enabled": .bool(true),
            "manifest": lamha, "granted": granted,
            "config": .object(["senderName": .string("Khayt sample studio"), "senderPhone": .string("+966511234567"),
                               "senderCity": .string("Riyadh"), "senderAddress": .string("King Fahd Rd, Al Olaya"),
                               "carrierId": .string("7")]),
        ])
        let slack = (try? JSONValue.parse(Data(#"{"id":"app.khayt.samples.slack","version":"1.0.0","enabled":true,"manifest":{"khayt":{"manifest":1},"id":"app.khayt.samples.slack","name":{"en":"Slack alerts","ar":"تنبيهات Slack"},"description":{"en":"Posts a message to a Slack channel when a job comes in or is paid."},"publisher":"Khayt","version":"1.0.0","domains":["hooks.slack.com"],"secrets":[{"name":"webhookPath","label":{"en":"Webhook path (the part after /services/)"},"kind":"url"}],"events":[{"event":"order_created","url":"https://hooks.slack.com/services/{secret.webhookPath}","body":{"format":"json-template","template":{"text":"New job {order.number}: {order.title} for {customer.name} ({order.total} {order.currency})"}}},{"event":"payment_received","url":"https://hooks.slack.com/services/{secret.webhookPath}","body":{"format":"json-template","template":{"text":"Paid: {order.number} ({order.total} {order.currency})"}}}],"signature":"GKAez8Nc3hke6WN/yOF54cWiv+R8uttlIbxI9LGdOka5mNO5G7XglQivKIw4EDVaJIC2vRdW0k3dZePE5blPCQ=="},"granted":{"version":"1.0.0","fields":[],"domains":["hooks.slack.com"],"scopes":[]},"config":{}}"#.utf8))) ?? .null
        return .array([lamhaEntry, slack])
    }

    /// `plugins/samples/lamha-shipping.json`, byte for byte, so Khayt's
    /// signature over it verifies against the bundled signing key
    /// (`ConnectorsTests` checks it against the file).
    static let lamhaManifestJSON = #"""
{
  "khayt": {
    "manifest": 1
  },
  "id": "app.khayt.samples.lamha",
  "name": {
    "en": "Lamha shipping",
    "ar": "شحن لمحة"
  },
  "description": {
    "en": "Records a job as an order in your Lamha account, ready for you to book a courier there. It never books or pays for a shipment by itself.",
    "ar": "يسجّل العمل كطلب في حسابك على لمحة لتختار شركة الشحن هناك. لا يحجز شحنة ولا يدفع عنها بنفسه."
  },
  "publisher": "Khayt",
  "version": "1.1.1",
  "homepage": "https://khaytapp.com/developers/samples/",
  "domains": [
    "app.lamha.sa"
  ],
  "secrets": [
    {
      "name": "apiToken",
      "label": {
        "en": "Lamha API token",
        "ar": "رمز واجهة لمحة"
      },
      "kind": "token"
    }
  ],
  "settings": [
    {
      "key": "senderName",
      "label": {
        "en": "Sender name",
        "ar": "اسم المرسل"
      },
      "type": "text",
      "kind": "name",
      "required": true
    },
    {
      "key": "senderPhone",
      "label": {
        "en": "Sender phone",
        "ar": "جوال المرسل"
      },
      "type": "text",
      "kind": "phone",
      "required": true
    },
    {
      "key": "senderCity",
      "label": {
        "en": "Sender city",
        "ar": "مدينة المرسل"
      },
      "type": "text",
      "required": true
    },
    {
      "key": "senderAddress",
      "label": {
        "en": "Sender address",
        "ar": "عنوان المرسل"
      },
      "type": "text",
      "kind": "address",
      "required": true
    },
    {
      "key": "carrierId",
      "label": {
        "en": "Lamha carrier",
        "ar": "شركة الشحن في لمحة"
      },
      "type": "enum",
      "required": true,
      "options": [
        {
          "value": "2",
          "label": {
            "en": "Aramex (delivery)",
            "ar": "أرامكس (توصيل)"
          }
        },
        {
          "value": "24",
          "label": {
            "en": "Aramex (pickup from branch)",
            "ar": "أرامكس (استلام من الفرع)"
          }
        },
        {
          "value": "26",
          "label": {
            "en": "Aramex (international)",
            "ar": "أرامكس (دولي)"
          }
        },
        {
          "value": "7",
          "label": {
            "en": "SMSA (delivery)",
            "ar": "سمسا (توصيل)"
          }
        },
        {
          "value": "30",
          "label": {
            "en": "J&T Express V2",
            "ar": "جي آند تي إكسبرس V2"
          }
        },
        {
          "value": "3",
          "label": {
            "en": "J&T Express (free returns)",
            "ar": "جي آند تي إكسبرس (رجيع مجاني)"
          }
        },
        {
          "value": "27",
          "label": {
            "en": "iMile",
            "ar": "آي مايل"
          }
        },
        {
          "value": "4",
          "label": {
            "en": "iMile (free returns)",
            "ar": "آي مايل (رجيع مجاني)"
          }
        },
        {
          "value": "29",
          "label": {
            "en": "Delex",
            "ar": "ديلكس"
          }
        },
        {
          "value": "11",
          "label": {
            "en": "AyMakan",
            "ar": "أي مكان"
          }
        },
        {
          "value": "10",
          "label": {
            "en": "RedBox (lockers)",
            "ar": "ريدبوكس (خزائن)"
          }
        },
        {
          "value": "6",
          "label": {
            "en": "Delivery Now (free returns)",
            "ar": "ديليفري ناو (رجيع مجاني)"
          }
        },
        {
          "value": "18",
          "label": {
            "en": "Wepik (free returns)",
            "ar": "ويبك (رجيع مجاني)"
          }
        }
      ]
    }
  ],
  "fields": [
    {
      "key": "city",
      "label": {
        "en": "City (for shipping)",
        "ar": "المدينة (للشحن)"
      },
      "type": "text",
      "attach": "customer"
    },
    {
      "key": "lamhaOrderId",
      "label": {
        "en": "Lamha order",
        "ar": "طلب لمحة"
      },
      "type": "text",
      "attach": "order"
    }
  ],
  "actions": [
    {
      "id": "record",
      "label": {
        "en": "Send to Lamha",
        "ar": "إرسال إلى لمحة"
      },
      "placement": "order",
      "kind": "post",
      "url": "https://app.lamha.sa/api/v2/create-order",
      "auth": {
        "header": "X-LAMHA-TOKEN",
        "secret": "apiToken"
      },
      "body": {
        "format": "json-template",
        "template": {
          "order_id": "{order.number}",
          "reference_id": "{order.id}",
          "date": "{order.date}",
          "total": "{order.total}",
          "payment_method": "prepaid",
          "ShipmentCurrency": "{order.currency}",
          "create_shippment": false,
          "carrier_id": "{config.carrierId}",
          "parcels": "1",
          "shipper": {
            "name": "{config.senderName}",
            "phone": "{config.senderPhone}",
            "Country": "SA",
            "City": "{config.senderCity}",
            "AddressLine1": "{config.senderAddress}"
          },
          "customer": {
            "name": "{customer.name}",
            "phone": "{customer.phone}",
            "phone1": "{customer.phone}",
            "email": "{customer.email}",
            "Country": "SA",
            "City": "{field.city}",
            "AddressLine1": "{customer.address}"
          },
          "items": [
            {
              "name": "{order.title}",
              "quantity": "{order.qty}",
              "amount": "{order.total}",
              "weight": "1"
            }
          ]
        }
      },
      "response": {
        "fields": {
          "lamhaOrderId": [
            "order_id",
            "data.id"
          ]
        }
      }
    }
  ],
  "scopes": [
    "fields.write"
  ],
  "signature": "Yrl+4YztpCg/qMLyn02jTjz2ZjIopnzwq8iYgoCJjo3SR0jdp+mimck45SBVQc7YCX7qScjyzyMnFs6eEn0hAA=="
}

"""#

    /// A spool with what is left under all of its names, as the shop's own
    /// writers leave it: `weight` (the store's, which the shared rules read),
    /// `weightRemaining` and `weightTotal` (the wire's).
    private static func spool(_ id: String, _ brand: String, _ material: String, _ hex: String,
                              left: Double, of total: Double, cost: Double,
                              extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "brand": .string(brand), "material": .string(material),
            "color": .string(hex), "weight": .number(left), "weightRemaining": .number(left),
            "weightTotal": .number(total), "cost": .number(cost), "rev": .number(1)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    /// A supplier in the shape every app writes one (`BookWriter.addSupplier`).
    private static func supplier(_ id: String, _ name: String, prices: [(String, Double)], leadDays: Double) -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "vat": .string(""), "category": .string("filament"),
                 "phone": .string(""), "website": .string(""), "notes": .string(""),
                 "priceList": .array(prices.map { .object(["material": .string($0.0), "pricePerKg": .number($0.1)]) }),
                 "leadDays": .number(leadDays), "purchases": .array([]), "rev": .number(1)])
    }

    /// A smart plug's reading as `lib/print-energy.js` `jobFields` writes it.
    private static func energy(coveredS: Double, spanS: Double, samples: Int, gaps: Int = 0) -> JSONValue {
        .object(["source": .string("plug"), "coveredS": .number(coveredS), "spanS": .number(spanS),
                 "coverage": .number((min(1, coveredS / spanS) * 1000).rounded() / 1000),
                 "samples": .number(Double(samples)), "gaps": .number(Double(gaps)), "at": .null])
    }

    /// Every collection held whole — the sample is the entire shop.
    private static func product(_ id: String, _ en: String, _ ar: String, group: String, base: Double,
                                extra: [String: JSONValue], part: (hours: Double, grams: Double, material: String)) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "nameEn": .string(en), "nameAr": .string(ar), "group": .string(group),
            "basePrice": .number(base), "baseCost": .number((base / 1.3 * 100).rounded() / 100),
            "parts": .array([.object(["qty": .number(1), "printTime": .number(part.hours),
                                      "printWeight": .number(part.grams), "material": .string(part.material)])]),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    /// A small made-up picture, as a product record carries one.
    private static func samplePicture(hue: CGFloat) -> String {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let data = r.jpegData(withCompressionQuality: 0.7) { ctx in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.9, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            UIColor(hue: hue, saturation: 0.7, brightness: 0.55, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 30, y: 30, width: 60, height: 60))
        }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// The library copy (`LibraryCopy.slim`) behind the sample's jobs: one
    /// model for non-commercial use only and one whose bought licence ran out
    /// on New Year's Eve 2025, both on "Terrain tiles".
    static func library() -> [JSONValue] {
        [
            .object(["id": .string("PF-sample-terrain"), "rev": .number(1), "name": .string("Dungeon terrain tiles"),
                     "folder": .string("Tabletop"), "material": .string("PLA"), "licence": .string("cc-by-nc")]),
            .object(["id": .string("PF-sample-tile-base"), "rev": .number(1), "name": .string("Tile base"),
                     "folder": .string("Tabletop"), "material": .string("PLA"), "licence": .string("commercial"),
                     "licenceExpires": .string("2025-12-31")]),
        ]
    }

    static func scope(now: Date = Date()) -> BookScope.Taken {
        let store = book(now: now)
        var held: [String: BookScope.Taken.Held] = [:]
        for (key, value) in store where key != "settings" {
            if case .array(let rows) = value { held[key] = .init(whole: true, sent: rows.count, available: nil) }
        }
        #if DEBUG
        // `-KhaytPartialBook YES`: the sample as a phone holding only the
        // newest finished jobs, so the partial-book screens can be photographed.
        if UserDefaults.standard.bool(forKey: "KhaytPartialBook"), let jobs = held["printLog"] {
            held["printLog"] = .init(whole: false, sent: jobs.sent, available: jobs.sent + 120)
        }
        #endif
        return BookScope.Taken(collections: held, omitted: [], takenAt: StoreWriter.iso(now))
    }

    /// The sample printers, running: two printing on a slow loop, one idle.
    /// Progress follows the clock, so it moves while the screen is watched.
    static func liveReadings(now: Date = Date()) -> [MachineLiveStatus] {
        func running(_ id: String, _ name: String, _ type: String, cycle: Double, offset: Double,
                     file: String, nozzle: Int, bed: Int) -> MachineLiveStatus {
            let t = (now.timeIntervalSince1970 + offset).truncatingRemainder(dividingBy: cycle)
            let progress = Int((t / cycle * 100).rounded(.down))
            return MachineLiveStatus(id: id, name: name, hasPrinterApi: true, state: "printing",
                                     progress: max(1, progress), filename: file,
                                     timeRemaining: Int(cycle - t), tempNozzle: nozzle, tempBed: bed,
                                     error: nil, lastUpdated: ISO8601DateFormatter().string(from: now),
                                     apiType: type)
        }
        return [
            running("M-X1C", "Bambu X1C", "bambu", cycle: 3 * 3600, offset: 4000, file: "drone_arm_x4.3mf",
                    nozzle: 250, bed: 80),
            running("M-MK4", "Prusa MK4", "prusalink", cycle: 90 * 60, offset: 900, file: "cable_clips_x40.gcode",
                    nozzle: 215, bed: 60),
            MachineLiveStatus(id: "M-SAT", name: "Elegoo Saturn 4", hasPrinterApi: false, state: nil, progress: nil,
                              filename: nil, timeRemaining: nil, tempNozzle: nil, tempBed: nil, error: nil,
                              lastUpdated: nil, apiType: nil),
        ]
    }
}
