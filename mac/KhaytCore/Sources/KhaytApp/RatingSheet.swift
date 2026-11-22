import SwiftUI
import KhaytCore

/// Writing down what a customer said about a finished job.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// A rating could reach this book one way only: a customer opening the portal
/// on their phone and submitting it. A shop that rings a customer and hears
/// "yes, five out of five" had nowhere to put it — while the Reports screen
/// draws a ratings line that, on a Mac-only shop, could never fill.
struct RatingSheet: View {
    @Bindable var shop: Shop
    let job: Order

    @State private var rating = 0
    @State private var comment = ""
    @State private var loaded = false

    /// The scale comes from the rule that READS it, so a rating this sheet can
    /// offer is one the chart will draw.
    private var stars: [Int] { Array(Int(RatingTrend.minRating)...Int(RatingTrend.maxRating)) }

    var body: some View {
        // `SheetFrame`, like every other sheet: a sheet cannot be moved, so one
        // taller than the screen hides its own buttons. The comment box has a
        // ceiling of its own, but the frame is what makes that true on a
        // laptop as well as on this desk.
        SheetFrame(width: 440) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("ord.record_survey")).font(.headline)
                Text(job.client.isEmpty ? job.project : "\(job.project) · \(job.client)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("survey.star_rating")).font(.callout)
                HStack(spacing: 8) {
                    ForEach(stars, id: \.self) { n in
                        Button {
                            // Tapping the star you are on clears it, which is
                            // the only way back to "nothing recorded" once a
                            // number has been put in by mistake.
                            rating = (rating == n) ? 0 : n
                        } label: {
                            Image(systemName: n <= rating ? "star.fill" : "star")
                                .font(.title2)
                                // `Khayt.marked`, whose own note says it is for
                                // exactly this: a FILLED GLYPH, never text, held
                                // to the graphical contrast threshold. A raw
                                // `Color.orange` says nothing about what it
                                // means and does not move with the appearance.
                                .foregroundStyle(n <= rating ? Khayt.marked : Khayt.note)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(n)")
                    }
                    Spacer()
                    if rating > 0 {
                        Text("\(rating)/\(Int(RatingTrend.maxRating))")
                            .font(.callout).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("survey.comment_optional")).font(.callout)
                TextEditor(text: $comment)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }

            if let problem = shop.moveProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.ratingFor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    Task {
                        await shop.recordRating(job.id, rating: rating, comment: comment)
                        if shop.moveProblem == nil { shop.ratingFor = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
                // Nothing to save until a star is chosen. The other app counts
                // the lit buttons instead, so opening and saving without
                // touching one writes a rating of NOUGHT — a survey that reads
                // as recorded and counts for nothing, because `ratingOf`
                // refuses anything below one.
                .disabled(rating < Int(RatingTrend.minRating))
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            let held = shop.ratingOn(job.id)
            rating = held.rating
            comment = held.comment
        }
    }
}
