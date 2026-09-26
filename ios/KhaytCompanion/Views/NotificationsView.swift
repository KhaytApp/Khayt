import SwiftUI

/// The design's Notifications screen: what the phone has been told about the
/// shop, newest first. An unread line sits on the card colour with a blue dot;
/// a late or low-stock one carries its rail. Tapping one about a job opens the
/// job; a customer's order request opens Intake.
struct NotificationsView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @ObservedObject private var feed = ShopFeed.shared
    @State private var openOrder: QueueOrder?
    @State private var showIntake = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if feed.items.isEmpty {
                    VStack(spacing: 5) {
                        Text(L10n.tr("feed.empty"))
                            .font(.khayt(15, .semibold, relativeTo: .headline))
                            .foregroundStyle(KhaytDesign.ink)
                        Text(L10n.tr("feed.empty.sub"))
                            .font(.khayt(13, relativeTo: .footnote))
                            .foregroundStyle(KhaytDesign.note)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                }
                ForEach(feed.items) { item in
                    Button { Task { await open(item) } } label: { FeedRow(item: item) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .refreshable { await feed.backfill(api: api) }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .navigationTitle(L10n.tr("feed.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await feed.backfill(api: api) }
        // Read once they have been seen: the dots stay while the screen is
        // open, so the person can see which ones were new.
        .onDisappear { feed.markAllRead() }
        .navigationDestination(item: $openOrder) { order in
            OrderDetailPage(order: order, facts: nil) {}
        }
        .sheet(isPresented: $showIntake) { IntakeView() }
    }

    private func open(_ item: FeedItem) async {
        if item.kind == "intake" { showIntake = true; return }
        guard let id = item.orderId else { return }
        if let order = (try? await api.fetchQueue())?.first(where: { $0.id == id }) {
            openOrder = order
        } else if let done = (try? await api.fetchRecentOrders(limit: 200))?.first(where: { $0.id == id }) {
            openOrder = QueueOrder(entry: done)
        }
    }
}

private struct FeedRow: View {
    let item: FeedItem

    private var tone: Color {
        switch item.tone {
        case .late: return KhaytDesign.late
        case .attention: return KhaytDesign.attention
        case .done: return KhaytDesign.done
        case .none: return KhaytDesign.note
        }
    }

    private var when: String {
        Calendar.current.isDateInToday(item.at)
            ? item.at.formatted(date: .omitted, time: .shortened)
            : item.at.formatted(.relative(presentation: .named))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(when)
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
            }
            Spacer(minLength: 0)
            if item.unread {
                Circle().fill(KhaytDesign.brand).frame(width: 8, height: 8).padding(.top, 5)
                    .accessibilityLabel(L10n.tr("feed.unread"))
            }
        }
        .padding(.vertical, 13).padding(.leading, 17).padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.unread ? KhaytDesign.surface : .clear)
        .overlay(alignment: .leading) {
            if item.tone == .late || item.tone == .attention { Rectangle().fill(tone).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
