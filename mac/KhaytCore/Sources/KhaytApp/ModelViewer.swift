import SwiftUI
import AppKit
import KhaytCore

/// The inspector's viewer: the model drawn from the front, the top, the side
/// or iso (`ModelViewAngle`), and for a slicer project laid out on
/// several plates, one plate at a time.
///
/// THE RENDERER THE TILES USE (`MeshPreview`), asked for a side and a plate —
/// not a second way of reading a mesh. It streams the file and holds nothing,
/// so a 400 MB model is drawn without being resident; it is drawn off the
/// main thread (`PinWork`), and only for a file that is on this Mac.
struct ModelViewer: View {
    let shop: Shop
    let file: LibraryFile
    @State private var drawn: MeshPreview.Drawn?
    @State private var drawing = false
    @State private var failed = false

    /// The formats the renderer reads.
    static let drawable: Set<String> = ["stl", "obj", "3mf"]

    /// Is there a mesh this viewer could draw — a format it reads, and a file
    /// (not a page saved from the web, not an encrypted archive member).
    static func canDraw(_ file: LibraryFile) -> Bool {
        let name = file.sourceFile?.filename ?? file.archiveMember ?? file.externalPath ?? file.originalName ?? ""
        let ext = (file.sourceFile?.ext ?? (name as NSString).pathExtension).lowercased()
        return drawable.contains(ext) && !file.isWebOnly && !file.isLocked
    }

    private struct Key: Equatable {
        let id: String
        let url: URL?
        let angle: ModelViewAngle
        let plate: Int?
    }

    var body: some View {
        let w = shop.words
        let url = shop.modelFile(for: file)
        VStack(alignment: .leading, spacing: 8) {
            Picker(w.callIt("mac.mv_side_label"), selection: Binding(get: { shop.libraryViewAngle },
                                                                     set: { shop.libraryViewAngle = $0 })) {
                ForEach(ModelViewAngle.allCases, id: \.self) { angle in
                    Text(w.callIt(angle.key)).tag(angle)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help(w.callIt("mac.mv_help"))

            if let plates = drawn?.plates, !plates.isEmpty {
                Picker(w.callIt("mac.mv_plate"), selection: Binding(get: { drawn?.plate ?? plates[0] },
                                                                    set: { shop.libraryViewPlate = $0 })) {
                    ForEach(plates, id: \.self) { n in
                        Text(w.callIt("mac.plate_n", ["n": .string(w.numeral(n))])).tag(n)
                    }
                }
                .controlSize(.small)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                if let drawn, let image = NSImage(data: drawn.png) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .padding(8)
                        .accessibilityLabel(w.callIt("mac.mv_said", ["side": .string(w.callIt(shop.libraryViewAngle.key))]))
                } else if url == nil {
                    Text(w.callIt("mac.mv_not_here")).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding()
                } else if failed {
                    Text(w.callIt("mac.mv_failed")).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding()
                }
                if drawing { ProgressView().controlSize(.small) }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .task(id: Key(id: file.id, url: url, angle: shop.libraryViewAngle, plate: shop.libraryViewPlate)) {
            guard let url else { drawn = nil; return }
            drawing = true
            failed = false
            let angle = shop.libraryViewAngle, plate = shop.libraryViewPlate
            let result = await LibraryImport.offMain {
                try? MeshPreview.render(url, size: 480, angle: angle, plate: plate)
            }
            guard !Task.isCancelled else { return }
            drawing = false
            drawn = result
            failed = result == nil
        }
        .onChange(of: file.id) { _, _ in
            drawn = nil
            shop.libraryViewPlate = nil
        }
    }
}
