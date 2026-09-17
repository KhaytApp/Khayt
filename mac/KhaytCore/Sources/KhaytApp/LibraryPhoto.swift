import Foundation
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import KhaytCore

/// A photograph of the thing, as it came off the bed.
///
/// ── THE HALF THIS APP COULD READ AND NOT WRITE ────────────────────────────
///
/// A library record carries `userPhoto`, and `Shop.thumbnail(for:)` already
/// prefers it over a generated preview — "a photograph the shop took beats a
/// generated thumbnail: it is the print as it came off the bed, which is what
/// someone is trying to recognise". Every part of that was true except that
/// this app had no way to take one. A photo could only be attached in the other
/// app, so for a shop whose only app is this one the better picture was one it
/// could display and never obtain.
///
/// ── THE SAME BYTES THE OTHER APP WOULD HAVE WRITTEN ───────────────────────
///
/// `renderer/printfiles.js` stages it with `resizeImage(file, 480, 0.82)` and
/// stores the result inline as a `data:image/jpeg;base64,…` URI. Both apps read
/// the same book and either may draw this, so the numbers are matched rather
/// than chosen — and the scaling is `ProductPhotos.jpeg`, which already matches
/// the same canvas for product pictures. One encoder, two callers: a second one
/// here would be a second answer to what a photograph looks like.
@MainActor
enum LibraryPhoto {

    /// `resizeImage(file, 480, 0.82)` in `renderer/printfiles.js`. Not choices.
    static let maxDim = 480
    static let quality = 0.82

    /// Read a picked file and return what goes in the record, or throw.
    ///
    /// Reuses `ProductPhotos`' limits and failures whole: the same 8 MB ceiling
    /// on the source, the same refusal to enlarge a small picture, the same
    /// flattening onto white because JPEG carries no alpha and a transparent
    /// PNG encoded straight to JPEG comes out on black.
    static func dataURI(of url: URL) throws -> String {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        if let size, size > ProductPhotos.maxSourceBytes { throw ProductPhotos.Failure.tooBig(size) }
        // `CGImageSource` rather than `NSImage`, for the reason `ProductPhotos`
        // gives: an NSImage of a 6000px photo is a representation the size of
        // the file, and this only ever needs pixels.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProductPhotos.Failure.notAnImage
        }
        guard let jpeg = ProductPhotos.jpeg(image, maxDim: maxDim, quality: quality) else {
            throw ProductPhotos.Failure.couldNotEncode
        }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    /// The picture kinds worth offering. Whatever a phone or a camera writes.
    static let kinds: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .gif, .bmp, .webP]
}

/// The photograph on a model's page: what there is, and how to change it.
///
/// Drop a picture on it, or choose one. Both, because a shop that has just
/// taken the photo on its phone has it in Photos or in a folder, and dragging
/// is the shorter road — while a menu is the one somebody finds without being
/// told it is there.
struct PhotoSection: View {
    let shop: Shop
    let file: LibraryFile
    @State private var choosing = false
    @State private var dropTarget = false

    private var has: Bool { (file.userPhoto?.hasPrefix("data:") ?? false) }

    var body: some View {
        let words = shop.words
        DetailSection(words.callIt("mac.lp_photo")) {
            VStack(alignment: .leading, spacing: 8) {
                if has, let image = Self.image(from: file.userPhoto) {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // The drop target IS the empty state. A separate "drag here"
                    // strip under a button is two ways to say one thing.
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(dropTarget ? Khayt.brand : Khayt.hairline,
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(height: 76)
                        .overlay {
                            Text(words.callIt("mac.lp_drop"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                }
                HStack(spacing: 10) {
                    Button(words.callIt(has ? "mac.lp_replace" : "mac.lp_add")) { choosing = true }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(!shop.canMoveJobs)
                    if has {
                        Button(words.callIt("mac.lp_remove")) {
                            shop.clearLibraryPhoto(file.id)
                        }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(!shop.canMoveJobs)
                    }
                }
                // Said once, and only where there is no photo yet: with one on
                // screen the reason is self-evident.
                if !has {
                    Text(words.callIt("mac.lp_why"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard shop.canMoveJobs, let url = urls.first else { return false }
            shop.setLibraryPhoto(file.id, from: url)
            return true
        } isTargeted: { dropTarget = $0 }
        .fileImporter(isPresented: $choosing, allowedContentTypes: LibraryPhoto.kinds) { result in
            guard case .success(let url) = result else { return }
            // A file the panel handed over is one this app may read, but the
            // scoped access still has to be asked for and given back.
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            shop.setLibraryPhoto(file.id, from: url)
        }
    }

    /// The stored data URI, back as a picture.
    static func image(from uri: String?) -> NSImage? {
        guard let uri, let comma = uri.firstIndex(of: ","), uri.hasPrefix("data:image/"),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }
}
