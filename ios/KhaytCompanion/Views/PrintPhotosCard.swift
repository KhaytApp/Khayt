import SwiftUI
import PhotosUI

/// The job's photos of the finished print, as the Mac and the desktop keep
/// them (`JobPrintPhotos`): the shop's own, and the printer's snapshot at the
/// end of a print. The full-size files stay on the computer; a phone the Mac
/// enrolled can send it one more (`KhaytAPIClient.addJobPhoto`).
struct PrintPhotosCard: View {
    let photos: [JobPrintPhoto]
    /// Nil when this phone cannot add one (not enrolled, the sample shop).
    var add: ((Data) async -> JobPhotoUpload)?

    @State private var showing: JobPrintPhoto?
    @State private var showCamera = false
    @State private var cameraImage: UIImage?
    @State private var picked: PhotosPickerItem?
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("printphotos.title").uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .khaytTracking(1.05)
                .foregroundStyle(KhaytDesign.note)
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            if let image = UIImage(data: photo.thumb) {
                                Button { showing = photo } label: {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 84, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(alignment: .bottomLeading) {
                                            if let source = photo.source { Self.badge(source).padding(4) }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(photo.source.map { L10n.tr("printphotos.one") + ", " + Self.words($0) }
                                                    ?? L10n.tr("printphotos.one"))
                            }
                        }
                    }
                }
                Text(L10n.tr(add == nil ? "printphotos.note" : "printphotos.note.add"))
                    .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
                if add != nil { addRow }
                if let problem {
                    Text(problem)
                        .font(.khayt(12.5, .medium, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.late)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .sheet(isPresented: $showCamera) { LabelCameraPicker(image: $cameraImage) }
        .onChange(of: cameraImage) { _, image in
            guard let image else { return }
            cameraImage = nil
            Task { await send(image) }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await send(image)
                } else {
                    problem = L10n.tr("printphotos.why.not_image")
                }
            }
        }
        .sheet(item: $showing) { photo in
            VStack(spacing: 14) {
                if let image = UIImage(data: photo.thumb) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(L10n.tr("printphotos.one"))
                }
                if let source = photo.source {
                    Label(Self.words(source), systemImage: Self.symbol(source))
                        .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.ink)
                }
                Text(L10n.tr("printphotos.full_on_computer"))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .presentationDetents([.medium, .large])
        }
    }
    private var addRow: some View {
        HStack(spacing: 16) {
            if sending {
                ProgressView()
                Text(L10n.tr("printphotos.sending"))
                    .foregroundStyle(KhaytDesign.note)
            } else {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { problem = nil; showCamera = true } label: {
                        Label(L10n.tr("printphotos.take"), systemImage: "camera")
                    }
                }
                PhotosPicker(selection: $picked, matching: .images) {
                    Label(L10n.tr("printphotos.pick"), systemImage: "photo")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
        .foregroundStyle(KhaytDesign.brand)
    }

    /// Drawn upright and sized as the customer-page photos are (the Mac's cap
    /// is 8 MB; this stays well under it), then sent.
    private func send(_ image: UIImage) async {
        guard let add else { return }
        guard let jpeg = OrderPhotoPrep.upright(image) else {
            problem = L10n.tr("printphotos.why.not_image")
            return
        }
        sending = true
        problem = nil
        let reply = await add(jpeg)
        sending = false
        if case .refused = reply { problem = reply.sentence }
    }
    static func words(_ source: JobPrintPhoto.Source) -> String {
        L10n.tr("printphotos.source." + source.rawValue)
    }

    static func symbol(_ source: JobPrintPhoto.Source) -> String {
        switch source {
        case .printer: return "printer"
        case .shop: return "desktopcomputer"
        case .phone: return "iphone"
        }
    }

    /// A small mark on the thumbnail: who took it.
    static func badge(_ source: JobPrintPhoto.Source) -> some View {
        Image(systemName: symbol(source))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(Circle().fill(.black.opacity(0.55)))
            .accessibilityHidden(true)
    }
}


