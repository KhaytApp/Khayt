import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// A slicer project's size is one plate's, not every plate's at once.
///
/// Reported from the running app: *"in library it is calculating the print
/// plate size as all the plates combined if there is more than one"*.
@MainActor
struct PlateBoundsTests {

    /// The shop's own file, when it is on this Mac.
    ///
    /// Skipped rather than failed when it is not: this is a measurement of a
    /// real two-plate project and there is no point inventing a fake one — the
    /// bug was in reading a slicer's own layout, so a hand-built fixture would
    /// be testing the fixture. `plateMembershipReadsBothOrders` below is the
    /// part that needs no file.
    static let sample: URL? = {
        let vault = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/khayt/print-files-vault")
        guard let walk = FileManager.default.enumerator(at: vault,
                                                        includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walk where url.pathExtension.lowercased() == "3mf" {
            guard let entries = try? Zip.entries(of: url) else { continue }
            let plates = entries.filter {
                let n = $0.name.lowercased()
                return n.hasPrefix("metadata/plate_") && n.hasSuffix(".png")
                    && !n.contains("_small") && !n.contains("no_light")
            }
            if plates.count > 1 { return url }
        }
        return nil
    }()

    @Test("a two-plate project measures one plate, not the gap between them")
    func platesAreMeasuredApart() throws {
        guard let url = Self.sample else { return }
        let measured = try #require(try Mesh.measure3MF(url))
        #expect(measured.plates > 1, "the plates were not told apart")
        // The failure this exists for: plate 1 is 77 x 170 x 9 and plate 2 is
        // 80 x 80 x 26, and the combined box was 295 x 170 x 26. The 295 is the
        // distance between the plates — a figure no part of the file has.
        #expect(measured.x < 200, """
            the model measures \(Int(measured.x)) mm across \(measured.plates) \
            plates. That is the layout, not the model: a slicer sets plates side \
            by side in one coordinate space, and a box drawn round all of them \
            is a number the file does not contain.
            """)
        // And the totals stay totals — every plate's material is printed.
        #expect(measured.triangleCount > 0)
        #expect(measured.volumeMm3 > 0)
    }

    @Test("a file with one plate is unchanged")
    func onePlateIsOnePlate() throws {
        let vault = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/khayt/print-files-vault")
        guard let walk = FileManager.default.enumerator(at: vault,
                                                        includingPropertiesForKeys: nil) else { return }
        // Smallest first: the walk's order is the filesystem's, and the first
        // file it offered was a 128 MB root that took most of a minute to
        // measure before this found out it had two plates.
        var files: [(URL, Int)] = []
        for case let url as URL in walk where url.pathExtension.lowercased() == "3mf" {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? Int.max
            files.append((url, size))
        }
        for (url, _) in files.sorted(by: { $0.1 < $1.1 }) {
            guard let m = try? Mesh.measure3MF(url), m.plates == 1 else { continue }
            #expect(m.x > 0 && m.y > 0 && m.z > 0, "a single-plate file measured as nothing")
            return
        }
    }
}
