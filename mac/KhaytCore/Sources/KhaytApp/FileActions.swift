import SwiftUI
import AppKit

/// What a shop wants to do with a model it has just found.
///
/// All of it read-only, and all of it handing off to the rest of the Mac rather
/// than reimplementing it: Finder shows the file, and whatever the shop has set
/// as its slicer opens it. A library you can look at but not get to the file
/// from is a catalogue, not a tool.
enum FileActions {

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Open a model in one of the shop's own slicers.
    ///
    /// ── WHY NOT JUST `NSWorkspace.open` ───────────────────────────────────
    ///
    /// `open` above hands the file to whatever macOS has registered for the
    /// extension, which for a `.3mf` is as likely to be a viewer as the slicer
    /// the shop actually prints from. A shop with four slicers installed — and
    /// this one has four — has already told Khayt which of them it means.
    ///
    /// ── THE PATH IS NOT TRUSTED, EVEN THOUGH IT IS IN THE SETTINGS ───────
    ///
    /// `settings.slicers[]` arrives in a restored backup and through cloud
    /// sync, so the executable named there was chosen by whoever wrote that
    /// book. `mayLaunch` is the shared allowlist — the name has to look like a
    /// slicer — and it is asked here rather than assumed from the fact that the
    /// entry exists. The Electron app had that rule for months and called it
    /// nowhere; this is the caller.
    ///
    /// Launched as an APPLICATION rather than as a binary. The stored path
    /// points inside the bundle (`…/Snapmaker Orca.app/Contents/MacOS/…`)
    /// because that is what a slicer needs on the command line, and running it
    /// that way on macOS gives a second, dockless copy of an app the shop may
    /// already have open. `NSWorkspace` is asked for the bundle instead, which
    /// reuses the running one and opens the file in it.
    static func openInSlicer(_ url: URL, slicerPath: String,
                             mayLaunch: (String) -> Bool) -> String? {
        guard mayLaunch(slicerPath) else { return "notAllowed" }
        let executable = URL(fileURLWithPath: slicerPath)
        guard FileManager.default.fileExists(atPath: executable.path) else { return "missing" }

        let bundle = appBundle(containing: executable)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: bundle,
                                configuration: configuration) { _, _ in }
        return nil
    }

    /// The `.app` an executable lives inside, or the executable itself.
    ///
    /// `/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca` →
    /// `/Applications/Snapmaker Orca.app`. A path that is not inside a bundle —
    /// a Homebrew build, a Linux-style install someone copied over — is handed
    /// back unchanged, and `NSWorkspace` will say no to it rather than this
    /// guessing.
    ///
    /// THE OUTERMOST BUNDLE, not the first one found walking up. Slicers ship
    /// helper apps inside themselves — updaters, crash reporters — and a stored
    /// path that points into one would otherwise launch the helper and report
    /// success. Written the other way first, and the test caught it.
    static func appBundle(containing executable: URL) -> URL {
        var candidate = executable
        var outermost: URL?
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension.lowercased() == "app" { outermost = candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return outermost ?? executable
    }
}

/// The menu on a model, in the grid and in the inspector alike.
///
/// The two entries that need the file are absent — not disabled — when it is not
/// on this Mac. A greyed-out "Reveal in Finder" invites a shop to keep clicking
/// it; the reason is said once, in the inspector, where there is room for it.
struct ModelActions: View {
    let file: LibraryFile
    let shop: Shop

    var body: some View {
        if let url = shop.modelFile(for: file) {
            Button(shop.words.callIt("mac.quick_look")) { shop.previewing = url }
            Divider()
            Button(shop.words.callIt("mac.reveal_in_finder")) { FileActions.reveal(url) }
            Button(shop.words.callIt("mac.open")) { FileActions.open(url) }
            // The shop's OWN slicer, above the system's idea of one. A .3mf
            // opens in a viewer as readily as in the thing the shop prints
            // from, and this shop has four slicers installed and has already
            // said which it means.
            // CONVERT, beside the slicers rather than under Edit: a maker
            // converts a file in order to open it in one of them, and this is
            // where they already are.
            //
            // Only for a 3MF. An STL carries no printer settings to rewrite, so
            // offering it would be offering to do nothing.
            if (file.sourceFile?.ext ?? "").lowercased() == "3mf", !shop.printerProfiles.isEmpty {
                Menu(shop.words.callIt("mac.convert_for")) {
                    ForEach(shop.printerProfiles) { profile in
                        Button(profile.name) {
                            Task { await shop.convertModel(file, targetId: profile.id) }
                        }
                    }
                    Divider()
                    // The vendor's settings stripped rather than replaced — a
                    // clean 3MF any slicer opens, which is the answer when the
                    // printer is not on the list.
                    Button(shop.words.callIt("mac.standard_3mf")) {
                        Task { await shop.convertModel(file, targetId: nil) }
                    }
                }
                .disabled(shop.converting)
            }
            if let first = shop.defaultSlicer {
                Button(shop.words.callIt("mac.open_in", ["name": .string(first.name)])) {
                    Task { await shop.openInSlicer(url, slicer: first) }
                }
                // The rest behind one item rather than four in the top level:
                // a shop reaches for its default nearly every time.
                let rest = shop.slicers.filter { $0.id != first.id }
                if !rest.isEmpty {
                    Menu(shop.words.callIt("mac.open_in_other")) {
                        ForEach(rest) { slicer in
                            Button(slicer.name) {
                                Task { await shop.openInSlicer(url, slicer: slicer) }
                            }
                        }
                    }
                }
            }
            Divider()
        } else if let dir = shop.directory(for: file) {
            Button(shop.words.callIt("mac.reveal_folder")) { FileActions.reveal(dir) }
            Divider()
        }
        Button(shop.words.callIt("mac.copy_name")) { FileActions.copy(file.title) }
        if let original = file.sourceFile?.originalName ?? file.originalName {
            Button(shop.words.callIt("mac.copy_file_name")) { FileActions.copy(original) }
        }
    }
}
