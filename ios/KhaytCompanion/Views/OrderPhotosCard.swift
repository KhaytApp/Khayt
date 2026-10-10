import SwiftUI
import PhotosUI

/// The order page's photos: what the customer sees on their tracking page, and
/// the button that adds the finished part to it.
struct OrderPhotosCard: View {
    @EnvironmentObject private var api: KhaytAPIClient

    let access: KhaytAPIClient.PhotoAccess

    @State private var photos: [KhaytAPIClient.OrderPhoto] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var problem: String?
    @State private var picked: PhotosPickerItem?
    @State private var showCamera = false
    @State private var shot: UIImage?
    @State private var removing: KhaytAPIClient.OrderPhoto?

    private var token: String? {
        switch access {
        case .ready(let t), .viewOnly(let t): return t
        default: return nil
        }
    }
    private var canAdd: Bool {
        if case .ready = access { return photos.count < KhaytAPIClient.maxPhotosPerOrder }
        return false
    }
    private var canRemove: Bool { if case .ready = access { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("photos.title").uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .tracking(1.05)
                .foregroundStyle(KhaytDesign.note)
            VStack(alignment: .leading, spacing: 10) {
                if access == .needsCloud {
                    Text(L10n.tr("photos.needs_cloud"))
                        .font(.khayt(13.5, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.note)
                } else {
                    if !photos.isEmpty { strip }
                    else if loaded {
                        Text(L10n.tr("photos.none"))
                            .font(.khayt(13.5, relativeTo: .subheadline))
                            .foregroundStyle(KhaytDesign.note)
                    }
                    if canAdd { addRow }
                    else if case .ready = access, photos.count >= KhaytAPIClient.maxPhotosPerOrder {
                        Text(L10n.format("photos.err.full", KhaytAPIClient.maxPhotosPerOrder))
                            .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                    }
                    Text(L10n.tr("photos.note"))
                        .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                }
                if let problem {
                    Text(problem).font(.khayt(12.5, relativeTo: .caption)).foregroundStyle(KhaytDesign.late)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .task(id: token) { await load() }
        .sheet(isPresented: $showCamera) { LabelCameraPicker(image: $shot) }
        .onChange(of: shot) { _, image in
            guard let image else { return }
            shot = nil
            Task { await add(image) }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await add(image)
                } else {
                    problem = KhaytAPIClient.PhotoFailure.notAnImage.errorDescription
                }
            }
        }
        .confirmationDialog(L10n.tr("photos.remove.title"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(L10n.tr("photos.remove"), role: .destructive) {
                if let p = removing { Task { await remove(p) } }
            }
        } message: {
            Text(L10n.tr("photos.remove.message"))
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    AsyncImage(url: api.photoURL(photo)) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { KhaytDesign.ground }
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contextMenu {
                        if canRemove {
                            Button(L10n.tr("photos.remove"), systemImage: "trash", role: .destructive) { removing = photo }
                        }
                    }
                    .accessibilityLabel(L10n.tr("photos.one"))
                }
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 14) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label(L10n.tr("wa.photo.take"), systemImage: "camera") }
            }
            PhotosPicker(selection: $picked, matching: .images) {
                Label(L10n.tr("wa.photo.pick"), systemImage: "photo")
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .disabled(busy)
        .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
        .foregroundStyle(KhaytDesign.brand)
    }

    private func load() async {
        guard let token else { return }
        do {
            photos = try await api.orderPhotos(token: token)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func add(_ image: UIImage) async {
        guard let token else { return }
        busy = true
        defer { busy = false }
        guard let bytes = OrderPhotoPrep.upright(image) else {
            problem = KhaytAPIClient.PhotoFailure.tooLarge.errorDescription
            return
        }
        do {
            photos.append(try await api.addOrderPhoto(token: token, bytes: bytes))
            problem = nil
            CompanionHaptics.success()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    private func remove(_ photo: KhaytAPIClient.OrderPhoto) async {
        guard let token else { return }
        removing = nil
        do {
            try await api.deleteOrderPhoto(token: token, id: photo.id)
            photos.removeAll { $0.id == photo.id }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
