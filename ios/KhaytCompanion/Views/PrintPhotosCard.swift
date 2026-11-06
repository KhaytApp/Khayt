import SwiftUI

/// The job's photos of the finished print, as the Mac and the desktop keep
/// them (`JobPrintPhotos`): the shop's own, and the printer's snapshot at the
/// end of a print. Read-only here — the full-size files stay on the computer.
struct PrintPhotosCard: View {
    let photos: [JobPrintPhoto]

    @State private var showing: JobPrintPhoto?

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
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.tr("printphotos.one"))
                            }
                        }
                    }
                }
                Text(L10n.tr("printphotos.note"))
                    .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .sheet(item: $showing) { photo in
            VStack(spacing: 14) {
                if let image = UIImage(data: photo.thumb) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(L10n.tr("printphotos.one"))
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
}
