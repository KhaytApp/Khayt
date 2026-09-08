import Foundation
import Testing
@testable import KhaytCore

/// Which picture Finder should show for a 3MF.
///
/// The names below are the real contents of one shop's library, read out of the
/// files rather than imagined: ten projects, every one of them carrying
/// `Metadata/plate_1.png`, not one of them carrying the thumbnail the 3MF
/// specification describes.
struct ThreeMFTests {

    /// A single-plate OrcaSlicer project — nine of the ten look like this.
    static let onePlate = [
        "[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model",
        "3D/_rels/3dmodel.model.rels", "3D/Objects/object_1.model",
        "Metadata/project_settings.config", "Metadata/model_settings.config",
        "Metadata/layer_config_ranges.xml",
        "Metadata/plate_1.png", "Metadata/plate_1_small.png",
    ]

    @Test("the plate render, not the small copy of it")
    func single() {
        #expect(ThreeMF.preview(among: Self.onePlate) == "Metadata/plate_1.png")
    }

    /// The tenth file in that library. Every one of these is a real member name.
    @Test("ten plates, and the first one wins")
    func manyPlates() {
        var names = ["3D/3dmodel.model"]
        for n in 1...10 {
            names += ["Metadata/plate_\(n).png", "Metadata/plate_\(n)_small.png",
                      "Metadata/plate_no_light_\(n).png",
                      "Metadata/top_\(n).png", "Metadata/pick_\(n).png"]
        }
        // Shuffled, because zip order is not a promise.
        #expect(ThreeMF.preview(among: names.shuffled()) == "Metadata/plate_1.png")
    }

    @Test("the format's own thumbnail beats a slicer's plate")
    func specWins() {
        let names = Self.onePlate + ["Metadata/thumbnail.png"]
        #expect(ThreeMF.preview(among: names) == "Metadata/thumbnail.png")
    }

    /// THE ONES THAT MUST NOT BE PICKED.
    ///
    /// `pick_1.png` is a mask of flat colour the slicer uses for hit-testing.
    /// Shown in Finder it is a meaningless block of colour that looks like a
    /// broken thumbnail — worse than no thumbnail, which at least says "no
    /// preview" honestly.
    @Test("a mask, a plan view and an unlit render are not previews")
    func notPictures() {
        for wrong in ["Metadata/pick_1.png", "Metadata/top_1.png",
                      "Metadata/plate_no_light_1.png", "Metadata/plate_1_small.png"] {
            #expect(ThreeMF.plateNumber(of: wrong) == nil, "\(wrong) was taken for a plate")
            #expect(ThreeMF.preview(among: ["3D/3dmodel.model", wrong]) == nil,
                    "\(wrong) was offered as the preview")
        }
    }

    @Test("a 3MF with no picture says so")
    func none() {
        #expect(ThreeMF.preview(among: ["3D/3dmodel.model", "[Content_Types].xml"]) == nil)
        #expect(ThreeMF.preview(among: []) == nil)
    }

    /// THE BUG THIS RULE REPLACED.
    ///
    /// The importer took the biggest `Metadata/*.png`. On two of the ten files
    /// in one real library the biggest is the slicer's top-down plan view, not
    /// the plate render — a plan view of a flat object compresses badly, so it
    /// outweighs the picture by two to one. Both member lists below are real.
    @Test("the biggest picture is the wrong picture")
    func biggestIsNotBest() {
        // PF-mtjwtfgg7FZ: top_1.png is 111 KB, plate_1.png is 56 KB.
        let sizes = ["Metadata/plate_1.png": 56, "Metadata/plate_1_small.png": 5,
                     "Metadata/plate_no_light_1.png": 6, "Metadata/top_1.png": 111,
                     "Metadata/pick_1.png": 5]
        let biggest = sizes.max { $0.value < $1.value }!.key
        #expect(biggest == "Metadata/top_1.png", "the fixture no longer shows the bug")
        #expect(ThreeMF.preview(among: Array(sizes.keys)) == "Metadata/plate_1.png")
    }

    @Test("case is not a promise either")
    func casing() {
        #expect(ThreeMF.preview(among: ["METADATA/THUMBNAIL.PNG"]) == "METADATA/THUMBNAIL.PNG")
        #expect(ThreeMF.preview(among: ["Metadata/Plate_2.png"]) == "Metadata/Plate_2.png")
    }
}
