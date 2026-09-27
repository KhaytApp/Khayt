import Foundation
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
                   machine: (String, String)? = nil) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .string(id), "status": .string(status), "project": .string(project),
                "client": .string(client), "clientId": .string(clientId), "date": day(placed),
                "price": .number(price), "paidAmount": .number(paid), "material": .string(material),
                "parts": .array([.object(["qty": .number(Double(qty))])]), "priority": .bool(false),
                "rev": .number(1),
            ]
            if let due { o["dueDate"] = day(due) }
            if let machine { o["machineId"] = .string(machine.0); o["machine"] = .string(machine.1) }
            return .object(o)
        }
        let x1c = ("M-X1C", "Bambu X1C"), mk4 = ("M-MK4", "Prusa MK4"), saturn = ("M-SAT", "Elegoo Saturn 4")

        return [
            "settings": .object([
                "shopName": .string(label), "currency": .string("USD"),
                "enableVat": .bool(false), "language": .string("en"),
            ]),
            "machines": .array([
                .object(["id": .string(x1c.0), "name": .string(x1c.1), "type": .string("fdm"),
                         "status": .string("printing"), "printerApi": .object(["type": .string("bambu")])]),
                .object(["id": .string(mk4.0), "name": .string(mk4.1), "type": .string("fdm"),
                         "status": .string("printing"), "printerApi": .object(["type": .string("prusalink")])]),
                .object(["id": .string(saturn.0), "name": .string(saturn.1), "type": .string("resin"),
                         "status": .string("idle"), "printerApi": .object(["type": .string("none")])]),
            ]),
            "clients": .array([
                .object(["id": .string("C-1"), "nameEn": .string("Acme Robotics"), "phone": .string("+15555550101"), "rev": .number(1)]),
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
                order("S-1045", "pending", "Terrain tiles", "Tabletop Guild", "C-4", placed: -4, due: -1, price: 120, paid: 60, material: "PLA", qty: 24),
                order("S-1046", "post", "Enclosure lid", "Acme Robotics", "C-1", placed: -5, due: 0, price: 95, paid: 95, material: "ABS", qty: 1),
                order("S-1047", "qc", "Bracket v3", "Omar Haddad", "C-5", placed: -6, due: 1, price: 60, paid: 0, material: "PETG", qty: 2),
                order("S-1038", "completed", "Planter", "Maya Chen", "C-3", placed: -9, due: -2, price: 35, paid: 35, material: "PLA", qty: 1),
                order("S-1036", "completed", "Gear housing", "Acme Robotics", "C-1", placed: -12, due: -5, price: 150, paid: 150, material: "Nylon", qty: 3),
                order("S-1031", "completed", "Crown models", "Northside Dental", "C-2", placed: -20, due: -14, price: 310, paid: 310, material: "Resin", qty: 8),
                order("S-1024", "completed", "Dice tower", "Tabletop Guild", "C-4", placed: -40, due: -33, price: 55, paid: 55, material: "PLA", qty: 1),
            ]),
            "inventory": .array([
                spool("SP-201", "Bambu", "PLA", "#1B1B1F", left: 180, of: 1000),
                spool("SP-202", "Polymaker", "PETG", "#2F6DB5", left: 640, of: 1000),
                spool("SP-203", "Prusament", "PLA", "#E8662A", left: 910, of: 1000),
                spool("SP-204", "eSun", "ABS", "#F2F2F0", left: 120, of: 1000),
                spool("SP-205", "Elegoo", "Resin", "#9AA3AD", left: 480, of: 1000),
                spool("SP-206", "Polymaker", "Nylon", "#C9B79C", left: 750, of: 750),
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

    private static func spool(_ id: String, _ brand: String, _ material: String, _ hex: String,
                              left: Double, of total: Double) -> JSONValue {
        .object(["id": .string(id), "brand": .string(brand), "material": .string(material),
                 "color": .string(hex), "weightRemaining": .number(left), "weightTotal": .number(total),
                 "rev": .number(1)])
    }

    /// Every collection held whole — the sample is the entire shop.
    static func scope(now: Date = Date()) -> BookScope.Taken {
        let store = book(now: now)
        var held: [String: BookScope.Taken.Held] = [:]
        for (key, value) in store where key != "settings" {
            if case .array(let rows) = value { held[key] = .init(whole: true, sent: rows.count, available: nil) }
        }
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
