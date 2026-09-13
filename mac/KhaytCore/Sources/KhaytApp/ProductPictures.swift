import SwiftUI
import UniformTypeIdentifiers
import KhaytCore

/// A product's pictures, in the sheet that writes the product.
///
/// ── WHY A LABEL BESIDE EVERY PICTURE AND NOT JUST MORE SLOTS ──────────────
///
/// The catalogue held one picture, so a shop selling a printed part chose
/// between a render, a photo of the real thing, a scale shot and a detail of
/// the finish. More slots fixes the count and leaves the question a customer is
/// actually asking: *is that a render, or is that what arrives?* Guessing wrong
/// is a refund, so every picture says what it is, and the words come from
/// `lib/product-images.js` rather than a Swift enum — one edit in `lib/` adds a
/// kind to both apps instead of two that can disagree.
///
/// The strip is ordered, and the order is a decision: the first picture is what
/// the catalogue grid, the storefront and the invoice use. Said in words under
/// the strip, because it is not guessable from a row of thumbnails.
struct ProductPictureStrip: View {
    let shop: Shop
    let productId: String
    @Binding var pictures: [StagedPicture]
    /// Paths whose files should be unlinked — but only if the sheet is SAVED.
    @Binding var removed: [String]

    @State private var kinds: [KhaytEngine.ProductImageKind] = []
    @State private var problem: String?
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(shop.words.callIt("mac.pictures"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(shop.words.callIt("mac.add_picture")) { picking = true }
                    .buttonStyle(.link).font(.callout)
            }

            if pictures.isEmpty {
                Text(shop.words.callIt("mac.no_pictures"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(pictures.enumerated()), id: \.element.id) { index, picture in
                            PictureCard(shop: shop, kinds: kinds, picture: picture,
                                        isPrimary: index == 0,
                                        kind: kindBinding(picture.id),
                                        makePrimary: { promote(picture.id) },
                                        remove: { drop(picture.id) })
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(height: 132)
                Text(shop.words.callIt("mac.main_picture_is"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The question the labels exist to answer, in the shared
                // wording both apps use.
                Text(shop.words.callIt("pe.kind_hint"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { kinds = (try? await shop.engine?.productImageKinds()) ?? [] }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await add(urls) }
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    // MARK: - Changing the strip

    /// Scale and stage every picked file.
    ///
    /// One bad file does not stop the rest: a shop selecting eight photos and
    /// one screenshot of a PDF should get eight pictures and a sentence, not an
    /// empty strip.
    private func add(_ urls: [URL]) async {
        problem = nil
        var failures = 0
        for url in urls {
            // The sandbox hands these over scoped, and the scope has to be
            // taken before the file can be read at all.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let prepared = try ProductPhotos.prepare(url)
                // The id comes from the shared rule because the FILENAME is
                // built from it, and both apps have to spell that the same way.
                let minted = try? await shop.engine?.productImageId(
                    productId, index: pictures.count + failures)
                pictures.append(StagedPicture(
                    id: minted.flatMap { $0 } ?? UUID().uuidString,
                    // Unlabelled arrives as a render: of the two guesses, it is
                    // the one that cannot mislead a customer into expecting a
                    // photo of a real part.
                    kind: kinds.first?.key ?? "render",
                    caption: "", thumbnail: prepared.thumbnail, path: "",
                    bytes: prepared.full))
            } catch {
                failures += 1
                problem = error.localizedDescription
            }
        }
    }

    private func promote(_ id: String) {
        guard let at = pictures.firstIndex(where: { $0.id == id }), at > 0 else { return }
        pictures.insert(pictures.remove(at: at), at: 0)
    }

    /// Take a picture out of the strip, and remember the file to unlink.
    ///
    /// Only a picture that is ALREADY on disk goes on the removal list. One
    /// picked in this sitting has no file yet, and putting its empty path there
    /// would ask the unlink to delete the products folder's own directory
    /// entry for "".
    private func drop(_ id: String) {
        guard let at = pictures.firstIndex(where: { $0.id == id }) else { return }
        let gone = pictures.remove(at: at)
        if !gone.path.isEmpty { removed.append(gone.path) }
    }

    private func kindBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { pictures.first { $0.id == id }?.kind ?? "" },
            set: { next in
                guard let at = pictures.firstIndex(where: { $0.id == id }) else { return }
                pictures[at].kind = next
            }
        )
    }
}

/// One picture: what it looks like, what it is, and what can be done to it.
private struct PictureCard: View {
    let shop: Shop
    let kinds: [KhaytEngine.ProductImageKind]
    let picture: StagedPicture
    let isPrimary: Bool
    @Binding var kind: String
    let makePrimary: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                if let image = Self.decode(picture.thumbnail) {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 84, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: 84, height: 64)
                        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                }
                if isPrimary {
                    // Which one the customer sees, marked rather than implied
                    // by position alone — a strip that scrolls can be looked at
                    // with its first card off the left edge.
                    Text(shop.words.callIt("pe.primary"))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Khayt.brand))
                        .foregroundStyle(.white)
                        .padding(3)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            Picker("", selection: $kind) {
                ForEach(kinds) { k in
                    // The shared locale's word where the shop has one, and the
                    // rule's own English where it does not — the same fallback
                    // the Electron editor uses.
                    Text(shop.words.callIt("pe.kind_" + k.key, fallback: k.label)).tag(k.key)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 90)
            .help(kinds.first { $0.key == kind }?.hint ?? "")
        }
        .contextMenu {
            Button(shop.words.callIt("mac.make_main"), action: makePrimary).disabled(isPrimary)
            Button(shop.words.callIt("mac.remove_picture"), role: .destructive, action: remove)
        }
    }

    /// A `data:image/…;base64,…` thumbnail as the store holds it.
    static func decode(_ uri: String) -> NSImage? {
        guard let comma = uri.firstIndex(of: ","), uri.hasPrefix("data:") else { return nil }
        let base64 = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}
