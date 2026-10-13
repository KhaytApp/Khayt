import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's linked Google Drive, sorted into prints (Oct 2026): "Some
/// folders have multiple prints and I want them as a main group if they are
/// an independent print." Every path below is a shape from that Drive's own
/// listing — names only, as the classifier sees them.
struct PrintSortTests {

    static let drive = URL(fileURLWithPath: "/Users/x/Library/CloudStorage/GoogleDrive-x/My Drive/Auto_Copied_Shared (1)")

    static func plan(_ models: [String], images: [String] = [],
                     answers: PrintSort.Answers = PrintSort.Answers()) -> PrintSort.Plan {
        PrintSort.plan(root: drive, models: models.map { drive.appending(path: $0) },
                       images: images.map { drive.appending(path: $0) }, answers: answers)
    }

    static func group(_ plan: PrintSort.Plan, _ rel: String) -> String? { plan.placed[rel]?.group }

    // MARK: - The real shapes

    static let yosher = "Aug26 Giga Tier/Aug26 Super Yosher Tier/Aug26 Yosher Tier"
    static let buzz = yosher + "/Life Size Buzz Lightyear"
    static let gambit = yosher + "/Life Size Gambit"

    static let buzzModels = [
        buzz + "/STLs/4 feet Size/Wing/Wing_L_1.stl", buzz + "/STLs/4 feet Size/Wing/Wing_L_2.stl",
        buzz + "/STLs/4 feet Size/Body/Body_1.stl", buzz + "/STLs/4 feet Size/Body/Body_2.stl",
        buzz + "/STLs/Toy size 30cm/Arm/Arm_1.stl", buzz + "/STLs/Toy size 30cm/Arm/Arm_2.stl",
        buzz + "/Colored 3MFs/Buzz Lightyear Body_4ft.3mf", buzz + "/Colored 3MFs/Buzz Lightyear Head_4ft.3mf",
        buzz + "/Uncolored 3MFs/Buzz Lightyear Body_4ft.3mf", buzz + "/Uncolored 3MFs/Buzz Lightyear Head_4ft.3mf",
        gambit + "/STLs/LARGE CUTS/torso_1.stl", gambit + "/STLs/LARGE CUTS/torso_2.stl",
        gambit + "/STLs/SMALL CUTS/arm left/arm_1.stl", gambit + "/STLs/SMALL CUTS/arm left/arm_2.stl",
        gambit + "/Gambit 3mf files Colored/Gambit_1.3mf", gambit + "/Gambit 3mf files (Not Colored)/Gambit_1.3mf",
    ]
    static let buzzImages = [
        buzz + "/Renders/back.jpg", buzz + "/Renders/Buzz Lightyear.jpg", buzz + "/Renders/front.jpg",
        buzz + "/Renders/Size.jpg", gambit + "/Renders/life size.png",
    ]

    @Test("Life Size Buzz Lightyear: tiers are collections, STLs/3MFs are formats, Renders are pictures, 4 feet Size is a part")
    func buzzLightyear() {
        let p = Self.plan(Self.buzzModels, images: Self.buzzImages)
        #expect(p.roles["Aug26 Giga Tier"] == .collection)
        #expect(p.roles[Self.yosher] == .collection)
        #expect(p.roles[Self.buzz] == .print)
        #expect(p.roles[Self.buzz + "/STLs"] == .format)
        #expect(p.roles[Self.buzz + "/Colored 3MFs"] == .format)
        #expect(p.roles[Self.buzz + "/Uncolored 3MFs"] == .format)
        #expect(p.roles[Self.buzz + "/Renders"] == .assets)
        #expect(p.roles[Self.buzz + "/STLs/4 feet Size"] == .part)
        #expect(Self.group(p, Self.buzzModels[0]) == "Life Size Buzz Lightyear/4 feet Size")
        #expect(Self.group(p, Self.buzzModels[4]) == "Life Size Buzz Lightyear/Toy size 30cm")
        #expect(Self.group(p, Self.buzzModels[6]) == "Life Size Buzz Lightyear", "the 3MFs are the print's own")
        // Capitals spoken normally; the 3mf folders that repeat the print are formats.
        #expect(Self.group(p, Self.buzzModels[10]) == "Life Size Gambit/Large Cuts")
        #expect(p.roles[Self.gambit + "/Gambit 3mf files (Not Colored)"] == .format)
        #expect(p.placed[Self.buzzModels[0]]?.collection == "Aug26 Giga Tier", "the collection is a tag")
        // Never a tier in a group.
        #expect(p.placed.values.allSatisfy { !($0.group ?? "").contains("Tier") })
    }

    @Test("the same print under two parents is one group")
    func zoroTwice() {
        let models = [
            "Yosh Sept26 Rewards/Sept26 Giga Tier/Sept26 Super Yosher Tier/Sept26 Yosher Tier/Life Size Zoro/STLs/LIFE SIZE/KATANA/k1.stl",
            "Yosh Sept26 Rewards/Sept26 Giga Tier/Sept26 Super Yosher Tier/Sept26 Yosher Tier/Life Size Zoro/STLs/LIFE SIZE/KATANA/k2.stl",
            "Yosh Sept26 Rewards/Sept26 Giga Tier/Sept26 Super Yosher Tier/Sept26 Yosher Tier/Life Size Zoro/STLs/6 INCH/z.stl",
            "Yosh Sept26 Rewards/Sept26 Giga Tier/Sept26 Super Yosher Tier/Sept26 Yosher Tier/Life Size Zoro/STLs/6 INCH/z2.stl",
            "Yosh Sept26 Rewards/Sept26 Giga Tier/Sept26 Super Yosher Tier/Sept26 Yosher Tier/Eevee Buddy/STLs/e1.stl",
            "Yosh Sept26 Rewards/Sept26 Giga Tier/Sept26 Super Yosher Tier/Sept26 Yosher Tier/Eevee Buddy/STLs/e2.stl",
            "Yosh Sept26 Rewards/Life size Zoro/STLs/WAIST AND LEG/w1.stl",
            "Yosh Sept26 Rewards/Life size Zoro/STLs/WAIST AND LEG/w2.stl",
        ]
        let p = Self.plan(models)
        let tops = Set(models.compactMap { Self.group(p, $0)?.components(separatedBy: "/").first })
        // ONE spelling — the first path met's — for both.
        #expect(tops == ["Life size Zoro", "Eevee Buddy"], Comment(rawValue: "\(tops)"))
        #expect(Self.group(p, models[0]) == "Life size Zoro/Life Size")
        #expect(Self.group(p, models[6]) == "Life size Zoro")
    }

    @Test("GridCube: Themes is a collection of prints, Gridcube STL Files is the Gridcube print")
    func gridCube() {
        let models = [
            "GridCube File Delivery/Themes/Cherry Blossom/3MF /cb.3mf",
            "GridCube File Delivery/Themes/Cherry Blossom/Print files/cb.stl",
            "GridCube File Delivery/Themes/Cyber/3MF files/cy.3mf",
            "GridCube File Delivery/Themes/Cyber/printing_orientation/cy.stl",
            "GridCube File Delivery/Gridcube STL Files/cube.stl",
            "GridCube File Delivery/Gridcube STL Files/lid.stl",
            "GridCube File Delivery/Gridcube STL Files/Non LED Version/n.stl",
            "GridCube File Delivery/Gridcube STL Files/Panels for Large Printers/p1.stl",
            "GridCube File Delivery/Gridcube STL Files/Panels for Large Printers/p2.stl",
        ]
        let images = ["GridCube File Delivery/Themes/Cherry Blossom/Renders/Kallex.663.png",
                      "GridCube File Delivery/Themes/Cyber/Renders/Kallex.1.png",
                      "GridCube File Delivery/Media/Photos/a.jpg"]
        let p = Self.plan(models, images: images)
        #expect(p.roles["GridCube File Delivery"] == .collection)
        #expect(p.roles["GridCube File Delivery/Themes"] == .collection)
        #expect(p.roles["GridCube File Delivery/Themes/Cherry Blossom"] == .print)
        #expect(p.roles["GridCube File Delivery/Themes/Cyber/printing_orientation"] == .format)
        #expect(Self.group(p, models[0]) == "Cherry Blossom")
        #expect(Self.group(p, models[2]) == "Cyber")
        #expect(p.roles["GridCube File Delivery/Gridcube STL Files"] == .print)
        #expect(Self.group(p, models[4]) == "Gridcube", "the print's name without its packaging")
        #expect(p.placed[models[0]]?.collection == "GridCube File Delivery")
    }

    @Test("2026 World Cup holds three independent prints")
    func worldCup() {
        let models = ["2026 World Cup/2026 FIFA World Cup_Can Opener/a.3mf", "2026 World Cup/2026 FIFA World Cup_Can Opener/b.3mf",
                      "2026 World Cup/2026 FIFA World Cup_Key Chain/c.3mf", "2026 World Cup/2026 FIFA World Cup_Key Chain/d.3mf",
                      "2026 World Cup/2026 FIFA World Cup_Key Chain & Can Opener/e.3mf",
                      "2026 World Cup/2026 FIFA World Cup_Key Chain & Can Opener/f.3mf"]
        let p = Self.plan(models)
        #expect(p.roles["2026 World Cup"] == .collection)
        #expect(Self.group(p, models[0]) == "2026 FIFA World Cup Can Opener", "the year is kept")
        #expect(Self.group(p, models[2]) == "2026 FIFA World Cup Key Chain")
        #expect(Self.group(p, models[4]) == "2026 FIFA World Cup Key Chain & Can Opener")
        #expect(p.placed[models[0]]?.collection == "2026 World Cup")
    }

    @Test("Mumm-Ra/Mumm Ra - Patreon/Single STLs is one print, called by the outer name")
    func patreon() {
        let models = ["Mumm-Ra/Mumm Ra - Patreon/Single STLs/head.stl", "Mumm-Ra/Mumm Ra - Patreon/Single STLs/sword.stl",
                      "Mumm-Ra/Mumm Ra - Patreon/Mumm-Ra.3mf",
                      "Kang/Kang & Kodos - Patreon/Kang/Single Parts STLs/k1.stl",
                      "Kang/Kang & Kodos - Patreon/Kang/Single Parts STLs/k2.stl",
                      "Kang/Kang & Kodos - Patreon/Kodos/Single Parts STLs/o1.stl",
                      "Kang/Kang & Kodos - Patreon/Kodos/Single Parts STLs/o2.stl"]
        let images = ["Mumm-Ra/Mumm Ra - Patreon/Pictures/1.jpg",
                      "Kang/Kang & Kodos - Patreon/Kang/Pictures/1.jpg", "Kang/Kang & Kodos - Patreon/Kodos/Pictures/1.jpg"]
        let p = Self.plan(models, images: images)
        #expect(p.roles["Mumm-Ra"] == .print)
        #expect(p.roles["Mumm-Ra/Mumm Ra - Patreon"] == .format)
        #expect(models.prefix(3).allSatisfy { Self.group(p, $0) == "Mumm-Ra" })
        // Kang and Kodos are two prints, not one called Kang.
        #expect(p.roles["Kang/Kang & Kodos - Patreon"] == .collection)
        #expect(Self.group(p, models[3]) == "Kang")
        #expect(Self.group(p, models[5]) == "Kodos")
    }

    @Test("Organizers STL Pack/Organizers: a pack of downloads, each its own print")
    func organizers() {
        let models = ["Organizers STL Pack/Organizers/1810109_Desk_Organizer/files/a.stl",
                      "Organizers STL Pack/Organizers/1810109_Desk_Organizer/files/b.stl",
                      "Organizers STL Pack/Organizers/Nun_Missile_Wagon/files/c.stl",
                      "Organizers STL Pack/Organizers/Nun_Missile_Wagon/files/d.stl",
                      "Organizers STL Pack/Organizers/Apple Organizer/e.stl",
                      "Organizers STL Pack/Organizers/Apple Organizer/f.stl",
                      "Organizers STL Pack/Organizers/Cable organizer _@stl_zone/g.stl",
                      "Organizers STL Pack/Organizers/Cable organizer _@stl_zone/h.stl"]
        let images = ["Organizers STL Pack/Organizers/1810109_Desk_Organizer/images/1.jpg",
                      "Organizers STL Pack/Organizers/Nun_Missile_Wagon/images/2.jpg"]
        let p = Self.plan(models, images: images)
        #expect(p.roles["Organizers STL Pack"] == .collection)
        #expect(p.roles["Organizers STL Pack/Organizers"] == .collection)
        #expect(Self.group(p, models[0]) == "Desk Organizer", "the site's number and underscores gone")
        #expect(Self.group(p, models[2]) == "Nun Missile Wagon")
        #expect(Self.group(p, models[4]) == "Apple Organizer")
        #expect(Self.group(p, models[6]) == "Cable organizer", "the shop handle is not part of the name")
        #expect(p.placed[models[0]]?.collection == "Organizers STL Pack")
    }

    @Test("Call of Duty 4 /Concert Poster/STLsConcert: the print, its sizes, and glued packaging")
    func callOfDuty() {
        let base = "Aug26 Giga Tier/Aug26 Collectibles Tier/Call of Duty 4 "
        let models = [base + "/Concert Poster/STLsConcert/a.stl", base + "/Concert Poster/STLsConcert/b.stl",
                      base + "/Mini Poster/STLs/c.stl", base + "/Mini Poster/STLs/d.stl",
                      "Aug26 Giga Tier/Aug26 Collectibles Tier/Zard Buddy /STLs/z1.stl",
                      "Aug26 Giga Tier/Aug26 Collectibles Tier/Zard Buddy /STLs/z2.stl"]
        let images = [base + "/RENDERS/1.png", "Aug26 Giga Tier/Aug26 Collectibles Tier/Zard Buddy /Renders/1.png"]
        let p = Self.plan(models, images: images)
        #expect(p.roles["Aug26 Giga Tier/Aug26 Collectibles Tier"] == .collection)
        #expect(p.roles[base] == .print)
        #expect(p.roles[base + "/Concert Poster"] == .part)
        #expect(p.roles[base + "/Concert Poster/STLsConcert"] == .format)
        #expect(Self.group(p, models[0]) == "Call of Duty 4/Concert Poster")
        #expect(Self.group(p, models[2]) == "Call of Duty 4/Mini Poster")
        #expect(Self.group(p, models[4]) == "Zard Buddy")
    }

    @Test("a print of one model is that model, titled by the print")
    func printOfOne() {
        let p = Self.plan(["Yosh Free Files/Iron Spiderman/spidey.stl", "Yosh Free Files/Storm Breaker/a.stl",
                           "Yosh Free Files/Storm Breaker/Stomrbreaker new STLs/b.stl",
                           "Yosh Free Files/Storm Breaker/Stomrbreaker new STLs/c.stl"])
        #expect(p.placed["Yosh Free Files/Iron Spiderman/spidey.stl"] ==
                PrintSort.Placement(group: nil, title: "Iron Spiderman", collection: "Yosh Free Files",
                                    print: "Yosh Free Files/Iron Spiderman"))
        // Its loose model and its newer version are one print, the version a level of it.
        #expect(Self.group(p, "Yosh Free Files/Storm Breaker/a.stl") == "Storm Breaker")
        #expect(Self.group(p, "Yosh Free Files/Storm Breaker/Stomrbreaker new STLs/b.stl") == "Storm Breaker/Stomrbreaker new")
    }

    @Test("names: packaging, handles, site numbers, orderings and shouting undone — and never empty")
    func names() {
        #expect(PrintSort.cleanName("Mumm Ra - Patreon") == "Mumm Ra")
        #expect(PrintSort.cleanName("Gridcube STL Files") == "Gridcube")
        #expect(PrintSort.cleanName("Hex3D - Krampus Mug_@stl_zone") == "Hex3D - Krampus Mug")
        #expect(PrintSort.cleanName("Hair_Dryer_Holder_Bathroom_Organizer_-_6814716") == "Hair Dryer Holder Bathroom Organizer")
        #expect(PrintSort.cleanName("02_Drawers") == "Drawers")
        #expect(PrintSort.cleanName("WAIST AND LEG") == "Waist and Leg")
        #expect(PrintSort.cleanName("MK World Display Set") == "MK World Display Set", "an acronym is not shouting")
        #expect(PrintSort.cleanName("2026 World Cup") == "2026 World Cup")
        #expect(PrintSort.cleanName("STLs") == "STLs", "nothing left means the name as written")
        #expect(PrintSort.cleanName("Yosh Free Files", keepWrapping: true) == "Yosh Free Files")
        #expect(PrintSort.fit(String(repeating: "Long ", count: 20)).utf16.count <= 60)
    }

    @Test("a group never passes sixty: the part level goes before the print is cut")
    func sixty() {
        let printName = "A Very Long Print Name That Takes Most Of The Room"
        let models = ["\(printName)/Renders/x.png", "\(printName)/STLs/Concert Poster Size/a.stl",
                      "\(printName)/STLs/Concert Poster Size/b.stl", "\(printName)/STLs/Mini/c.stl",
                      "\(printName)/STLs/Mini/d.stl"].filter { !$0.hasSuffix(".png") }
        let p = Self.plan(models, images: ["\(printName)/Renders/x.png"])
        #expect(Self.group(p, models[0]) == printName)
        #expect(p.placed.values.allSatisfy { ($0.group ?? "").utf16.count <= 60 })
    }

    // MARK: - The assistant's answers laid over the heuristic

    @Test("an answer overrides the heuristic where it was given, and only where it can hold")
    func answersOverlay() {
        let models = ["2026 World Cup/2026 FIFA World Cup_Can Opener/a.3mf", "2026 World Cup/2026 FIFA World Cup_Can Opener/b.3mf",
                      "2026 World Cup/2026 FIFA World Cup_Key Chain/c.3mf", "2026 World Cup/2026 FIFA World Cup_Key Chain/d.3mf"]
        var answers = PrintSort.Answers()
        answers.roles["2026 World Cup"] = .print
        answers.roles["2026 World Cup/2026 FIFA World Cup_Key Chain"] = .collection    // cannot hold inside a print
        answers.roles["2026 World Cup/2026 FIFA World Cup_Can Opener"] = .assets       // it holds models
        answers.names["2026 World Cup"] = "World Cup 2026"
        let p = Self.plan(models, answers: answers)
        #expect(p.roles["2026 World Cup"] == .print)
        #expect(p.roles["2026 World Cup/2026 FIFA World Cup_Key Chain"] == .part)
        #expect(p.roles["2026 World Cup/2026 FIFA World Cup_Can Opener"] == .part)
        #expect(Self.group(p, models[0]) == "World Cup 2026/2026 FIFA World Cup Can Opener")
        // With nothing said, the heuristic.
        #expect(Self.group(Self.plan(models), models[0]) == "2026 FIFA World Cup Can Opener")
    }

    @Test("the assistant's reply is read through the shared rule: unknown paths and roles are dropped")
    func readsTheReplyThroughTheRule() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(true),
                                                            "features": .object(["library": .bool(true)])])]
        // What Anthropic sends back for a forced tool call — the provider is stubbed by its reply.
        let reply: JSONValue = .object([
            "stop_reason": .string("tool_use"),
            "usage": .object(["input_tokens": .number(1200), "output_tokens": .number(300)]),
            "content": .array([.object([
                "type": .string("tool_use"), "name": .string("sort_library_folders"),
                "input": .object(["folders": .array([
                    .object(["path": .string("2026 World Cup"), "role": .string("print"), "name": .string("World/Cup")]),
                    .object(["path": .string("Elsewhere"), "role": .string("print")]),
                    .object(["path": .string("2026 World Cup/Key Chain"), "role": .string("wizard")]),
                ])]),
            ])]),
        ])
        let read = try await engine.aiLibraryRead(settings: settings, response: reply,
                                                  sentPaths: ["2026 World Cup", "2026 World Cup/Key Chain"])
        #expect(read.ok)
        #expect(read.roles == ["2026 World Cup": "print"])
        #expect(read.names == ["2026 World Cup": "World - Cup"])
        #expect(read.dropped == 2)
        // The cost goes into the same ledger the desktop keeps.
        let ledger = try await engine.aiUsageRecord(ledger: .object([:]), task: "library", model: "claude-opus-5",
                                                    usage: try #require(read.usage), now: Date())
        guard case .object(let months) = ledger, case .object(let month)? = months.values.first,
              case .object(let row)? = month["library"] else { Issue.record("no ledger row"); return }
        #expect(row["calls"] == .number(1))
        #expect(row["input"] == .number(1200))
        if case .number(let cost)? = row["cost"] { #expect(cost > 0) } else { Issue.record("no cost") }
        // A refusal is an answer with nothing in it, never a throw.
        let refused = try await engine.aiLibraryRead(settings: settings,
                                                     response: .object(["stop_reason": .string("refusal"), "content": .array([])]),
                                                     sentPaths: ["a"])
        #expect(!refused.ok && refused.roles.isEmpty)
    }

    @Test("nothing is asked unless the shop turned it on; when it did, only names and counts go")
    func consentAndPayload() async throws {
        let engine = try KhaytEngine()
        let entries = SortCache.units(Self.plan(Self.buzzModels, images: Self.buzzImages)).flatMap(\.entries)
        let off: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(true),
                                                       "features": .object(["quote": .bool(true)])])]
        await #expect(throws: (any Error).self) {
            _ = try await engine.aiLibraryRequest(settings: off, entries: entries.map(\.json), apiKey: "k")
        }
        let on: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(true),
                                                      "features": .object(["library": .bool(true)])])]
        let request = try await engine.aiLibraryRequest(settings: on, entries: entries.map(\.json), apiKey: "k")
        let body = String(describing: request.body)
        #expect(body.contains("Life Size Buzz Lightyear/STLs/4 feet Size"))
        #expect(body.contains("sort_library_folders"))
        #expect(!body.contains("front.jpg") || body.contains("Renders"), "pictures appear only as a folder's name")
        // The old toggle does not switch it on.
        let migrated = try await engine.aiFeatures(settings: ["ai": .object(["enabled": .bool(true)])])
        #expect(migrated.first { $0.id == "library" }?.enabled == false)
    }

    // MARK: - The cache

    @Test("an answered folder is never sent twice — until its tree changes")
    func cache() {
        let p = Self.plan(Self.buzzModels, images: Self.buzzImages)
        let units = SortCache.units(p)
        #expect(units.count == 1, "one top-level folder, one unit")
        var answers = PrintSort.Answers()
        answers.roles[Self.buzz] = .print
        answers.names[Self.buzz] = "Buzz Lightyear (life size)"
        answers.roles["Not/In/This/Unit"] = .print
        var root: [String: JSONValue] = ["settings": .object([:])]
        SortCache.store([(unit: units[0], answers: answers)], into: &root)
        guard case .object(let settings)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(SortCache.isCached(units[0], in: settings))
        let back = SortCache.answers(settings, for: units)
        #expect(back.roles == [Self.buzz: .print], "only the unit's own folders are kept")
        #expect(back.names[Self.buzz] == "Buzz Lightyear (life size)")
        // A new folder under it: a new signature, asked again — and until the
        // new answer comes, the old one stands for the folders still there,
        // so nothing flips back to the heuristic in between (alpha.67 review).
        let grown = SortCache.units(Self.plan(Self.buzzModels + [Self.buzz + "/STLs/New Size/x.stl"], images: Self.buzzImages))
        #expect(!SortCache.isCached(grown[0], in: settings))
        #expect(SortCache.answers(settings, for: grown).roles == [Self.buzz: .print])
        #expect(SortCache.answers(settings, for: grown).names[Self.buzz] == "Buzz Lightyear (life size)")
        // A folder renamed away is not in the unit, and its answer is not used.
        let renamed = SortCache.units(Self.plan(Self.buzzModels.map {
            $0.replacingOccurrences(of: "Life Size Buzz Lightyear", with: "Buzz LS") }))
        #expect(SortCache.answers(settings, for: renamed) == PrintSort.Answers())
        // And the sorted plan of a walk reads it back.
        let sorted = Shop.sortedPlan(root: Self.drive, models: Self.buzzModels.map { Self.drive.appending(path: $0) },
                                     images: Self.buzzImages.map { Self.drive.appending(path: $0) }, settings: settings)
        #expect(Self.group(sorted, Self.buzzModels[0]) == "Buzz Lightyear (life size)/4 feet Size")
    }

    @Test("requests are batched by top-level folder, and a big one is split")
    func batches() {
        func unit(_ key: String, _ n: Int) -> SortCache.Unit {
            SortCache.Unit(key: key, signature: key,
                           entries: (0..<n).map { SortCache.Entry(path: "\(key)/\($0)", models: 1, folders: [], samples: []) })
        }
        let b = SortCache.batches([unit("a", 40), unit("b", 50), unit("c", 100), unit("d", 320)], limit: 150)
        #expect(b.map(\.count) == [90, 150, 150, 20, 100])
        #expect(b.allSatisfy { $0.count <= 150 })
    }

    // MARK: - Pictures

    @Test("a print's picture: its own name, then a hero shot, then its renders, then anything in it")
    func pictureRanking() {
        let p = Self.plan(Self.buzzModels, images: Self.buzzImages)
        let pics = PrintSort.pictures(of: Self.buzz, in: p.tree, roles: p.roles, name: "Life Size Buzz Lightyear")
        #expect(pics.first == Self.buzz + "/Renders/Buzz Lightyear.jpg")
        #expect(pics.dropFirst().first == Self.buzz + "/Renders/front.jpg")
        let gambit = PrintSort.pictures(of: Self.gambit, in: p.tree, roles: p.roles, name: "Life Size Gambit")
        #expect(gambit == [Self.gambit + "/Renders/life size.png"])
        // A pack's media folder, sorted by print.
        let g = Self.plan(["Pack Delivery/Accessories/Drawers/a.stl", "Pack Delivery/Accessories/Drawers/b.stl",
                           "Pack Delivery/Accessories/Shelves/c.stl", "Pack Delivery/Accessories/Shelves/d.stl"],
                          images: ["Pack Delivery/Media/Renders/Drawers/r.png"])
        #expect(PrintSort.pictures(of: "Pack Delivery/Accessories/Drawers", in: g.tree, roles: g.roles, name: "Drawers")
                == ["Pack Delivery/Media/Renders/Drawers/r.png"])
        #expect(PrintSort.pictures(of: "Pack Delivery/Accessories/Shelves", in: g.tree, roles: g.roles, name: "Shelves").isEmpty)
    }

    @Test("a model wears a picture only when it is named exactly as the model")
    func modelPictures() {
        let p = Self.plan([Self.buzz + "/STLs/Body.stl", Self.buzz + "/STLs/Head.stl"],
                          images: [Self.buzz + "/Renders/body.png", Self.buzz + "/Renders/front.jpg"])
        let own = PrintSort.modelPictures(of: Self.buzz, in: p.tree, models: p.models(ofPrint: Self.buzz))
        #expect(own == [Self.buzz + "/STLs/Body.stl": Self.buzz + "/Renders/body.png"])
    }

    @Test("pictures are bounded: too big is passed over, looked-at prints are skipped, a pass is capped")
    func pictureCaps() {
        let small = URL(fileURLWithPath: "/x/small.jpg"), big = URL(fileURLWithPath: "/x/big.jpg")
        let sizes = [small: 400_000, big: 30_000_000]
        #expect(PrintPhotos.pick([big, small], size: { sizes[$0] ?? 0 }) == small)
        #expect(PrintPhotos.pick([big], size: { sizes[$0] ?? 0 }) == nil)
        #expect(PrintPhotos.pick([small], size: { _ in 0 }) == nil, "a size the drive will not tell is not fetched")
        let p = Self.plan(Self.buzzModels, images: Self.buzzImages)
        let all = PrintPhotos.jobs([p], looked: [])
        #expect(all.count == 2)
        let buzzJob = try? #require(all.first { $0.print.hasSuffix("Life Size Buzz Lightyear") })
        #expect(buzzJob?.group == "Life Size Buzz Lightyear")
        #expect(buzzJob?.candidates.first?.lastPathComponent == "Buzz Lightyear.jpg")
        #expect(PrintPhotos.jobs([p], looked: Set(all.map(\.print))).isEmpty)
        #expect(PrintPhotos.jobs([p], looked: [], limit: 1).count == 1)
        var root: [String: JSONValue] = [:]
        PrintPhotos.markLooked([all[0].print, all[0].print], into: &root)
        guard case .object(let s)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(PrintPhotos.looked(s) == [all[0].print])
    }

    // MARK: - Refiling what is already in the book

    static func row(_ id: String, _ rel: String, group: String, name: String,
                    extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name),
                                      "externalPath": .string(drive.appending(path: rel).standardizedFileURL.path),
                                      "group": .string(group), "folder": .string(group)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("the refile moves only what the app filed, tags the collection once, and settles")
    func regroupProtections() {
        let p = Self.plan(Self.buzzModels, images: Self.buzzImages)
        let m = Self.buzzModels
        var rows: [JSONValue] = [
            // alpha.66's group, written with its marker.
            Self.row("a", m[0], group: "Aug26 Giga Tier/Life Size Buzz Lightyear/4 feet Size/Wing", name: "Wing_L_1",
                     extra: ["autoGroup": .string("Aug26 Giga Tier/Life Size Buzz Lightyear/4 feet Size/Wing")]),
            // Dragged by the shop into a group of its own.
            Self.row("b", m[1], group: "Favourites", name: "Wing_L_2",
                     extra: ["autoGroup": .string("Aug26 Giga Tier/Life Size Buzz Lightyear/4 feet Size/Wing")]),
            // A tag the shop already gave it, in another case.
            Self.row("c", m[2], group: "Old", name: "Body_1",
                     extra: ["autoGroup": .string("Old"), "tags": .array([.string("aug26 giga tier")])]),
            // A name the shop typed.
            Self.row("d", m[10], group: "Old", name: "My torso", extra: ["autoGroup": .string("Old")]),
        ]
        let changes = LinkedRegroup.changes(rows: rows, plan: p)
        let by = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        #expect(by["a"]?.group == "Life Size Buzz Lightyear/4 feet Size")
        // In the spelling the book already uses for it (row c): one tag, not two chips.
        #expect(by["a"]?.tag == "aug26 giga tier")
        #expect(by["b"] == nil, "the shop's own group")
        #expect(by["c"]?.tag == nil, "the tag is there already, in the shop's spelling")
        #expect(by["d"]?.group == "Life Size Gambit/Large Cuts" && by["d"]?.name == nil, "the shop's name stays")
        var root: [String: JSONValue] = ["printFiles": .array(rows)]
        LinkedRegroup.apply(changes, to: &root)
        if case .array(let r)? = root["printFiles"] { rows = r }
        #expect(LinkedRegroup.changes(rows: rows, plan: p).isEmpty, "a second refile finds nothing to do")
        guard case .object(let a)? = rows.first else { Issue.record("no row"); return }
        #expect(a["tags"] == .array([.string("aug26 giga tier")]))
        #expect(a["autoGroup"] == .string("Life Size Buzz Lightyear/4 feet Size"))
    }

    @Test("a name the app gave is renamed when the print is renamed; one the shop typed is not")
    func autoNames() {
        let models = ["Yosh Free Files/Iron Spiderman/spidey.stl", "Yosh Free Files/Storm Breaker/a.stl",
                      "Yosh Free Files/Storm Breaker/b.stl"]
        let rows: [JSONValue] = [
            Self.row("a", models[0], group: "", name: "Iron Spiderman", extra: ["autoName": .string("Iron Spiderman"),
                                                                                "autoGroup": .string("")]),
        ]
        var answers = PrintSort.Answers()
        answers.names["Yosh Free Files/Iron Spiderman"] = "Iron Spider-Man"
        let changes = LinkedRegroup.changes(rows: rows, plan: Self.plan(models, answers: answers))
        #expect(changes.first?.name == "Iron Spider-Man")
        let typed: [JSONValue] = [Self.row("a", models[0], group: "", name: "Spidey for Ahmed",
                                           extra: ["autoName": .string("Iron Spiderman"), "autoGroup": .string("")])]
        #expect(LinkedRegroup.changes(rows: typed, plan: Self.plan(models, answers: answers)).first?.name == nil)
    }

    @Test("the once-per-book refile is a new version, so alpha.66 books are sorted into prints")
    func versionBumped() {
        #expect(LinkedRegroup.version >= 3, "4 since loose models are sorted too")
    }

    @Test("the preview counts what Apply would do, and what stays the shop's")
    func previewCounts() {
        let p = Self.plan(Self.buzzModels, images: Self.buzzImages)
        let rows: [JSONValue] = [
            Self.row("a", Self.buzzModels[0], group: "X", name: "Wing_L_1", extra: ["autoGroup": .string("X")]),
            Self.row("b", Self.buzzModels[1], group: "Mine", name: "Wing_L_2"),
        ]
        let c = Shop.sortCounts([p], rows: rows)
        #expect(c.moved == 1 && c.tagged == 1 && c.kept == 1)
        #expect(c.collections == 1)
    }
}
