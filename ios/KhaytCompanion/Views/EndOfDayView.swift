import SwiftUI
import KhaytCore

/// Closing time: what was finished and earned today, what is still on the
/// floor, and what was due today and is not done — the Mac's End of Day
/// Report (`EndOfDay`), on the phone. Waste and hours logged are the Mac's
/// figures while the phone does not keep those logs, and say so.
struct EndOfDayView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var day: DayReport?
    @State private var currency: String?

    var body: some View {
        ScrollView {
            if let day {
                content(day)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .navigationTitle(L10n.tr("eod.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("common.done")) { dismiss() } }
        }
        .task {
            currency = await api.shopCurrency()
            day = await api.fetchEndOfDay()
        }
        .refreshable { day = await api.fetchEndOfDay() }
    }

    private func number(_ n: Double, decimals: Int = 0) -> String {
        n.formatted(.number.precision(.fractionLength(decimals)).locale(L10n.locale))
    }

    private func content(_ d: DayReport) -> some View {
        let r = d.report
        let tiles: [(String, String, Color)] = [
            (L10n.tr("eod.finished"), number(Double(r.finished.count)), KhaytDesign.done),
            (L10n.tr("eod.revenue"), Money.text(r.revenue, currency), KhaytDesign.done),
            (L10n.tr("eod.open"), number(Double(r.inProgress)), KhaytDesign.ink),
            (L10n.tr("eod.overdue"), number(Double(r.overdue)), r.overdue > 0 ? KhaytDesign.late : KhaytDesign.ink),
            (L10n.tr("eod.waste"), d.holdsWaste ? L10n.format("eod.grams", number(r.wasteGrams)) : "—", KhaytDesign.ink),
            (L10n.tr("eod.hours"), d.holdsTime ? number(r.hoursLogged, decimals: 1) : "—", KhaytDesign.ink),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(tiles, id: \.0) { label, value, tint in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value)
                            .font(.khayt(22, .semibold, relativeTo: .title2).monospacedDigit())
                            .foregroundStyle(value == "—" ? KhaytDesign.note : tint)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(label.uppercased())
                            .font(.khayt(9.5, .bold, relativeTo: .caption2)).khaytTracking(1)
                            .foregroundStyle(KhaytDesign.note)
                        if value == "—" {
                            Text(L10n.tr("pulse.on_the_mac"))
                                .font(.khayt(11, relativeTo: .caption2))
                                .foregroundStyle(KhaytDesign.attention)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
                    .accessibilityElement(children: .combine)
                }
            }
            list(L10n.tr("eod.finished_list"), r.finished, empty: L10n.tr("eod.nothing"), money: true)
            if !r.dueNotDone.isEmpty {
                list(L10n.tr("eod.due_list"), r.dueNotDone, empty: "", money: false)
            }
        }
        .padding(16)
    }

    private func list(_ title: String, _ jobs: [EndOfDay.Job], empty: String, money: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.khayt(10, .bold, relativeTo: .caption2)).khaytTracking(1)
                .foregroundStyle(KhaytDesign.note)
                .padding(.bottom, 8)
            if jobs.isEmpty {
                Text(empty).font(.khayt(13.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            }
            ForEach(jobs) { job in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).font(.khayt(14.5, .medium, relativeTo: .body)).foregroundStyle(KhaytDesign.ink)
                        Text(job.reference).font(.khayt(11.5, relativeTo: .caption2)).foregroundStyle(KhaytDesign.note)
                    }
                    Spacer()
                    if money {
                        Text(Money.text(job.revenue, currency))
                            .font(.khayt(14, .medium, relativeTo: .body).monospacedDigit())
                            .foregroundStyle(KhaytDesign.ink)
                    }
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
            }
        }
    }
}
