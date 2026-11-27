import SwiftUI

/// "Coffee dallah · time-lapse / Time-lapse on the printer / Recorded by the
/// printer for this print / 34 MB / Keep as proof" (signed frame 7b), or,
/// over the Mac's limit, "Too large to keep here" with Open on the printer.
struct JobTimelapseCard: View {
    let orderId: String
    let jobName: String

    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var health: ConnectionHealth
    @Environment(\.openURL) private var openURL
    @State private var lapse = JobTimelapse.nothing
    @State private var keeping = false
    @State private var note: String?

    var body: some View {
        Group {
            if lapse.shows { card }
        }
        .task(id: health.macInReach) { await load() }
    }

    private func load() async {
        guard JobTimelapse.asks(macInReach: health.macInReach, sampleShop: settings.isSampleShop) else { lapse = .nothing; return }
        lapse = await api.jobTimelapse(orderId: orderId)
        await watchTheCopy()
    }

    /// While the Mac says it is copying, ask again every few seconds until it
    /// has finished (or ten minutes pass): the card ends on "kept" by itself,
    /// whether the copy was started here, on another phone, or outlasted this
    /// phone's wait. Ends when the page goes away.
    private func watchTheCopy() async {
        var rounds = 0
        while lapse.copying, rounds < JobTimelapse.watchRounds, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(JobTimelapse.watchEvery))
            if Task.isCancelled { return }
            lapse = await api.jobTimelapse(orderId: orderId)
            rounds += 1
        }
        if !lapse.copying, lapse.state == .kept { note = nil }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.format("lapse.title", jobName))
                .font(.khayt(17, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.ink)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lapse.title)
                        .font(.khayt(14.5, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.ink)
                    Text(lapse.sub)
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let size = JobTimelapse.megabytes(lapse.bytes) {
                    Text(size)
                        .font(.khayt(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(lapse.state == .link ? KhaytDesign.attention : KhaytDesign.note)
                }
            }
            HStack(spacing: 10) {
                if lapse.state == .available, JobTimelapse.mayKeep(role: settings.effectiveRole) {
                    Button(L10n.tr("lapse.keep")) {
                        guard !keeping else { return }
                        Task { await keep() }
                    }
                    .buttonStyle(.borderedProminent).tint(KhaytDesign.brand)
                    .disabled(keeping || lapse.copying)
                }
                if lapse.state == .link, let url = lapse.url {
                    Button(L10n.tr("lapse.open")) { openURL(url) }
                        .buttonStyle(.bordered)
                }
                if keeping { ProgressView() }
            }
            .font(.khayt(13, .semibold, relativeTo: .footnote))
            if let note {
                Text(note)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.tr("lapse.foot"))
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    private func keep() async {
        keeping = true
        note = L10n.tr("lapse.keeping")
        defer { keeping = false }
        switch await api.keepTimelapse(orderId: orderId) {
        case .done(let now):
            lapse = now
            note = nil
            // A keep that ended as a link carries no address: read it.
            if now.state == .link { await load() }
        case .refused(let reason):
            note = JobTimelapse.words(reason)
            await load()
        case .noAnswer:
            // A copy can outlast the phone's wait: say the Mac is at it, and
            // watch until the Mac says it is done.
            note = L10n.tr("lapse.why.no_answer")
            await load()
        }
    }
}
