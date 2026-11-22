import Foundation
import KhaytCore

/// Finding the slicers a Mac already has.
///
/// Khayt scans for these on the desktop so a shop does not have to type a path
/// into a settings field; without it, the Mac app's slicer list can only be
/// filled in by hand, which is the kind of setup step that gets skipped and
/// then blamed on the app.
///
/// ── THE SCAN AND THE PERMISSION ARE ONE QUESTION ──────────────────────────
///
/// A bundle is offered only if `isAllowedSlicerBinary` — the same rule that
/// decides whether it may be LAUNCHED — says yes to its name. Two lists is how
/// a shop gets shown a slicer that the guard then refuses to run. main.js had
/// exactly that, a `SLICER_APP_RE` beside the allowlist, until they were
/// collapsed.
///
/// main.js also carries a table of eighteen known bundles. That table is not
/// reproduced here: every entry in it also passes the allowlist by name, so it
/// buys nothing but a second place to add a slicer to. What it does buy in
/// Electron is a hard-coded binary name for bundles whose executable is spelled
/// differently from the app — and `CFBundleExecutable` answers that from the
/// bundle itself, which cannot go out of date.
enum SlicerFinder {

    /// Where a Mac keeps applications. `~/Applications` is the one people
    /// forget: it is where an app dragged out of a DMG by a user without
    /// administrator rights lands.
    static var searched: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
    }

    /// Every slicer on this Mac, as `{name, path}` — the path being the
    /// executable inside the bundle, because that is the shape
    /// `settings.slicers[]` holds and what a slicer wants on a command line.
    static func installed(in directories: [URL] = searched,
                          allowed: (String) -> Bool,
                          name: (String) -> String) -> [(name: String, path: String)] {
        var found: [(name: String, path: String)] = []
        var seen = Set<String>()
        for directory in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for entry in entries.sorted() {
                guard entry.lowercased().hasSuffix(".app"), allowed(entry) else { continue }
                let bundle = directory.appending(path: entry)
                guard let executable = executable(in: bundle) else { continue }
                guard seen.insert(executable.path).inserted else { continue }
                found.append((name: name(entry), path: executable.path))
            }
        }
        return found
    }

    /// The binary inside a `.app`, from its own `Info.plist`.
    ///
    /// `CFBundleExecutable` rather than the bundle's name: Snapmaker's app is
    /// "Snapmaker Orca.app" and its binary "Snapmaker_Orca", and a dozen vendor
    /// forks each differ in their own way. Asking the bundle cannot go stale.
    static func executable(in bundle: URL) -> URL? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any],
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty
        else { return nil }
        let executable = bundle.appending(path: "Contents/MacOS/\(name)")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }
}
