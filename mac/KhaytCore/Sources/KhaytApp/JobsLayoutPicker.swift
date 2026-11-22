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
        Picker(shop.words.callIt("mac.jobs_layout"), selection: layout) {
            ForEach(Shop.JobsLayout.allCases) { choice in
                Text(shop.words.callIt(choice.titleKey)).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(shop.words.callIt("mac.jobs_layout"))
    }

    private var layout: Binding<Shop.JobsLayout> {
        Binding(
            get: { shop.showingBoard ? .board : .list },
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
