import SwiftUI

/// Board or List, for Jobs — one screen, two views of the same jobs.
///
/// The Board used to be a sidebar row of its own, next to Jobs, which put the
/// same book in two places and made "where do I move a job" a question about
/// navigation. It is a choice of view now, in the toolbar of the screen it
/// belongs to. A calendar would join it here if the app had a schedule screen;
/// today the schedule is a sheet over Machines, so there are two.
///
/// Choosing Board from a stage's table leaves the stage: the board shows every
/// stage already, and a board filtered to one column is a table.
struct JobsLayoutPicker: View {
    @Bindable var shop: Shop

    var body: some View {
        // DRAWN HERE, not a system segmented `Picker`. In the toolbar the
        // system control drew its SELECTED segment with no label — "Board
        // [blank] Table" with List chosen (S1 B1 capture, Nov 14) — because
        // its selected text and its selection fill came out the same colour
        // there. Three buttons with their own fill and their own text colour
        // cannot do that, in either shell and in a window that is not key.
        HStack(spacing: 2) {
            ForEach(Shop.JobsLayout.allCases) { choice in
                let chosen = layout.wrappedValue == choice
                Button {
                    layout.wrappedValue = choice
                } label: {
                    Text(shop.words.callIt(choice.titleKey))
                        .font(.callout.weight(chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(chosen ? Color.primary.opacity(0.14) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shop.words.callIt("mac.jobs_layout"))
        .help(shop.words.callIt("mac.jobs_layout"))
    }

    private var layout: Binding<Shop.JobsLayout> {
        Binding(
            // A single stage is never the board (`showingBoard`): it shows
            // as the table unless the List was chosen.
            get: { shop.showingBoard ? .board : shop.jobsLayout == .page ? .page : .list },
            set: { shop.chooseJobsLayout($0) }
        )
    }
}

extension Shop {
    /// Whether the screen in front is Jobs, in either of its views and with
    /// or without a stage chosen.
    var showingJobs: Bool { if case .jobs = shelf { true } else { false } }

    /// The picker's choice, and every other caller's way to ask for a view.
    func chooseJobsLayout(_ layout: JobsLayout) {
        jobsLayout = layout
        if layout == .board { shelf = .jobs(nil) }
    }
}


/// One stage of the pipeline as a table — what the nine sidebar rows were
/// before the redesign folded them away.
struct JobsStageMenu: View {
    @Bindable var shop: Shop

    var body: some View {
        Menu {
            Button(shop.words.callIt("mac.all_jobs")) { shop.shelf = .jobs(nil) }
            Divider()
            ForEach(Stage.allCases) { stage in
                Button("\(shop.words.callIt(stage.key))  \(shop.words.numeral(shop.count(stage)))") {
                    shop.shelf = .jobs(stage)
                }
            }
        } label: {
            Text(currentTitle)
        }
        .fixedSize()
        .help(shop.words.callIt("mac.stage"))
    }

    private var currentTitle: String {
        if case .jobs(let stage?) = shop.shelf { return shop.words.callIt(stage.key) }
        return shop.words.callIt("mac.all_jobs")
    }
}
