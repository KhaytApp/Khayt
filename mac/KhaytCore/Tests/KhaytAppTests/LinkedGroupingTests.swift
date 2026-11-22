import Foundation
import Testing
@testable import KhaytApp

/// The grouping a linked Google Drive folder got, against the folders that
/// were really in it (Oct 2026): "not smart enough to figure the correct
/// grouping". Every path below is one from the shop's own Drive.
struct LinkedGroupingTests {

    static let drive = URL(fileURLWithPath: "/Users/x/Library/CloudStorage/GoogleDrive-x/My Drive/Auto_Copied_Shared (1)")
    static func f(_ rel: String) -> URL { drive.appending(path: rel) }

    /// The linked folder's own placements, as the scan now files them.
    static func placed(_ rels: [String]) -> [String: ImportGrouping.Placement] {
        let urls = rels.map(f)
        let p = ImportGrouping.placements(for: urls, chosen: drive, includeChosen: false)
        return Dictionary(uniqueKeysWithValues: rels.map { ($0, p[f($0)]!) })
    }

    @Test("Call of Duty 4 survives the trim; the linked folder's name is not a group")
    func callOfDuty() {
        let rels = ["Aug26 Giga Tier/Aug26 Collectibles Tier/Call of Duty 4 /Mini Poster/STLs/Base_2.stl",
                    "Aug26 Giga Tier/Aug26 Collectibles Tier/Call of Duty 4 /Mini Poster/STLs/Frame.stl"]
        // Before: `Auto_Copied_Shared (1)/Aug26 Giga Tier/Mini Poster`.
        let before = ImportGrouping.V1.placements(for: rels.map(Self.f), chosen: Self.drive)[Self.f(rels[0])]
        #expect(before?.group == "Auto_Copied_Shared (1)/Aug26 Giga Tier/Mini Poster")
        let now = Self.placed(rels)[rels[0]]
        #expect(now?.group == "Aug26 Giga Tier/Call of Duty 4/Mini Poster",
                Comment(rawValue: now?.group ?? "nil"))
    }

    @Test("a World Cup key chain is filed under the World Cup, not the Drive")
    func worldCup() {
        let rels = ["2026 World Cup/2026 FIFA World Cup_Key Chain/WC_Key_v2_SPAIN.3mf",
                    "2026 World Cup/2026 FIFA World Cup_Key Chain/WC_Key_v2_BRAZIL.3mf"]
        let before = ImportGrouping.V1.placements(for: rels.map(Self.f), chosen: Self.drive)[Self.f(rels[0])]
        #expect(before?.group == "Auto_Copied_Shared (1)/2026 FIFA World Cup_Key Chain")
        #expect(Self.placed(rels)[rels[0]]?.group == "2026 World Cup/2026 FIFA World Cup Key Chain")
    }

    @Test("a Patreon folder repeating its parent folds into it, and Single STLs is packaging")
    func patreonRepeats() {
        let p = Self.placed(["Mumm-Ra/Mumm Ra - Patreon/Single STLs/head.stl",
                             "Mumm-Ra/Mumm Ra - Patreon/Single STLs/sword.stl",
                             "Ren/Ren - Patreon/Single Part STLs/a.stl",
                             "Ren/Ren - Patreon/Single Part STLs/b.stl",
                             "Maggie Simpson/Maggie Simpson - Patreon/Non Modified STLs/a.stl",
                             "Maggie Simpson/Maggie Simpson - Patreon/Single STLs/b.stl"])
        #expect(p["Mumm-Ra/Mumm Ra - Patreon/Single STLs/head.stl"]?.group == "Mumm-Ra")
        #expect(p["Ren/Ren - Patreon/Single Part STLs/a.stl"]?.group == "Ren")
        #expect(p["Maggie Simpson/Maggie Simpson - Patreon/Non Modified STLs/a.stl"]?.group == "Maggie Simpson")
        #expect(p["Maggie Simpson/Maggie Simpson - Patreon/Single STLs/b.stl"]?.title == nil,
                "packaging is not a model's name either")
    }

    @Test("a pack's sub-projects stay; its STL Files folder folds into the pack")
    func gridCube() {
        let p = Self.placed(["GridCube File Delivery/Gridcube STL Files/cube.stl",
                             "GridCube File Delivery/Gridcube STL Files/lid.stl",
                             "GridCube File Delivery/Modular Shelf System/shelf.stl",
                             "GridCube File Delivery/Modular Shelf System/leg.stl",
                             "GridCube File Delivery/Gridcube Accessories /hook.stl",
                             "GridCube File Delivery/Gridcube Accessories /tray.stl",
                             "GridCube File Delivery/Instructions and Gearlist/notes.stl"])
        #expect(p["GridCube File Delivery/Gridcube STL Files/cube.stl"]?.group == "GridCube File Delivery")
        #expect(p["GridCube File Delivery/Modular Shelf System/shelf.stl"]?.group
                == "GridCube File Delivery/Modular Shelf System")
        #expect(p["GridCube File Delivery/Gridcube Accessories /hook.stl"]?.group
                == "GridCube File Delivery/Gridcube Accessories", "a child that ADDS a word is its own project")
        #expect(p["GridCube File Delivery/Instructions and Gearlist/notes.stl"]?.group == "GridCube File Delivery")
    }

    @Test("free files, organisers and work boxes")
    func otherShapes() {
        let p = Self.placed(["Yosh Free Files/Life Size Pikachu/a.stl", "Yosh Free Files/Life Size Pikachu/b.stl",
                             "Yosh Free Files/Storm Breaker/axe.stl", "Yosh Free Files/Storm Breaker/handle.stl",
                             "WorkBox/STLs/box.stl", "WorkBox/STLs/lid.stl", "WorkBox/Documentation/x.stl",
                             "Organizers STL Pack/Organizers/a.stl", "Organizers STL Pack/Organizers/b.stl"])
        #expect(p["Yosh Free Files/Life Size Pikachu/a.stl"]?.group == "Yosh Free Files/Life Size Pikachu")
        #expect(p["WorkBox/STLs/box.stl"]?.group == "WorkBox")
        #expect(p["WorkBox/Documentation/x.stl"]?.group == "WorkBox")
        #expect(p["Organizers STL Pack/Organizers/a.stl"]?.group == "Organizers STL Pack")
    }

    @Test("a folder the shop imports still keeps its own name")
    func importKeepsRoot() {
        let root = URL(fileURLWithPath: "/Downloads/Kings")
        #expect(ImportGrouping.group(for: root.appending(path: "King Abdulaziz/STL/head.stl"), chosen: root)
                == "Kings/King Abdulaziz")
    }

    @Test("packaging made of several words is not a name; a real name with one of them is")
    func containers() {
        for name in ["STLs", "Single STLs", "Single Part STLs", "Non Modified STLs", "Colored 3mf Files",
                     "Uncolored 3mf for Bambu", "Pictures", "Media", "Documentation",
                     "Instructions and Gearlist", "files", "model_files", "3mf"] {
            #expect(ImportGrouping.meaningful(name) == nil, Comment(rawValue: name))
        }
        for name in ["Head and Shoulders", "Multi Tool", "Gear", "Call of Duty 4", "Mini Poster", "Gridcube STL Files"] {
            #expect(ImportGrouping.meaningful(name) != nil, Comment(rawValue: name))
        }
    }

    @Test("a download site's spelling is undone in the name")
    func displayNames() {
        #expect(ImportGrouping.display("snapmaker+U1+drawer+plate+holder+stand_stls")
                == "snapmaker U1 drawer plate holder stand")
        #expect(ImportGrouping.display("Pz4+-+G_stls") == "Pz4 - G")
        #expect(ImportGrouping.display("prusa-core-one-printable-drybox-model_files")
                == "prusa core one printable drybox")
        #expect(ImportGrouping.display("Hylian_Shield_-_Zelda_Cosplay_Prop_Kit_|_No_Supports,_No_AMS,_No_Glue")
                == "Hylian Shield - Zelda Cosplay Prop Kit")
        // The shop's own spelling is left exactly as it is.
        #expect(ImportGrouping.display("Mumm-Ra") == "Mumm-Ra")
        #expect(ImportGrouping.display("[FDM] Dragon_v2 final") == "[FDM] Dragon_v2 final")
    }

    @Test("over sixty, a wrapper goes before the project — and the sixty rule is untouched")
    func wrappersFirst() {
        let fitted = ImportGrouping.fitting(["Oct26 Giga Tier", "Oct26 Collectibles Tier",
                                             "Teenage Mutant Ninja Turtles", "Leonardo"])
        #expect(fitted == "Oct26 Giga Tier/Teenage Mutant Ninja Turtles/Leonardo", Comment(rawValue: fitted))
        #expect(fitted.utf16.count <= 60)
        // No wrapper: the old trim, exactly.
        #expect(ImportGrouping.fitting(["Saudi Kings Collection 2026", "Commissioned Reproductions",
                                        "King Abdulaziz Al Saud", "Head and Shoulders"])
                == "Saudi Kings Collection 2026/Head and Shoulders")
    }
}
