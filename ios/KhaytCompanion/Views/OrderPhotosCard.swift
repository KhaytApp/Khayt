import SwiftUI
import PhotosUI
import KhaytCore

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
    /// A tap the shop's internet switch refused (frame B): its words and
    /// "Nothing was sent.", shown under the photos.
    @State private var refusedTap: OutboundBlocked?

    init(access: KhaytAPIClient.PhotoAccess) { self.access = access }

    /// A card already showing photos and a refused tap: how the screenshot
    /// test draws frame B. The app uses the init above.
    init(access: KhaytAPIClient.PhotoAccess, photos: [KhaytAPIClient.OrderPhoto], refusedTap: OutboundBlocked?) {
        self.access = access
        _photos = State(initialValue: photos)
        _loaded = State(initialValue: true)
        _refusedTap = State(initialValue: refusedTap)
    }

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

    /// The shop's "Make no internet calls" switch, as it stands for Khayt
    /// Cloud (P8). Asked, not counted: only a refused tap counts.
    private var switchRefusal: OutboundGate.Verdict? {
        let v = OutboundGate.shared.verdict(.cloud)
        return v.allowed ? nil : v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("photos.title").uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .khaytTracking(1.05)
                .foregroundStyle(KhaytDesign.note)
            VStack(alignment: .leading, spacing: 10) {
                if access == .needsCloud {
                    Text(L10n.tr("photos.needs_cloud"))
                        .font(.khayt(13.5, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.note)
                } else if let refusal = switchRefusal, refusedTap == nil, photos.isEmpty {
                    // Frames A and C (signed off, Nov 22): nothing is asked of
                    // the cloud, and Add is shown but cannot be used.
                    RefusalNote(text: PhoneOutbound.words(purpose: .cloud, reason: refusal.reason),
                                detail: refusal.reason == "settings-unknown" ? nil : L10n.tr("photos.blocked.detail"),
                                starting: refusal.reason == "settings-unknown")
                    if case .ready = access { addRow.disabled(true).opacity(0.45) }
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
                if let refusedTap {
                    // Frame B: the tap was refused before anything was sent.
                    RefusalNote(text: refusedTap.localizedDescription,
                                detail: refusedTap.reason == "settings-unknown" ? nil : L10n.tr("photos.blocked.nothing_sent"),
                                starting: refusedTap.reason == "settings-unknown")
                } else if let problem {
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
        // Switched off: no call at all, and no failure to show (frame A).
        if switchRefusal != nil { loaded = true; return }
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
        guard allowedNow() else { return }
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
        } catch let blocked as OutboundBlocked {
            refusedTap = blocked
            problem = nil
            CompanionHaptics.warning()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    /// Asks the switch before a tap does anything (frame B): a refused tap
    /// shows the words and "Nothing was sent.", and is counted like any
    /// refused call. True when the call may go ahead.
    private func allowedNow() -> Bool {
        do {
            try OutboundGate.shared.require(.cloud)
            refusedTap = nil
            return true
        } catch let blocked as OutboundBlocked {
            refusedTap = blocked
            problem = nil
            CompanionHaptics.warning()
            return false
        } catch {
            return false
        }
    }

    private func remove(_ photo: KhaytAPIClient.OrderPhoto) async {
        guard let token else { return }
        removing = nil
        guard allowedNow() else { return }
        do {
            try await api.deleteOrderPhoto(token: token, id: photo.id)
            photos.removeAll { $0.id == photo.id }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The callout the signed-off frames draw for a refused call: a dot (amber
/// when the switch is on, grey while Khayt is starting), the sentence, and a
/// smaller line under it.
struct RefusalNote: View {
    let text: String
    var detail: String?
    var starting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(starting ? KhaytDesign.note : KhaytDesign.attention)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if !starting {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(KhaytDesign.attention.opacity(0.7), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
