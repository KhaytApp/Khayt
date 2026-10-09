import ActivityKit
import SwiftUI
import WidgetKit

/// How a print looks as a Live Activity. Every presentation is drawn —
/// Apple requires all of them: Lock Screen, and the Dynamic Island's
/// expanded, compact and minimal forms.
struct PrintActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            LockScreenPrint(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.machineName, systemImage: "printer.fill")
                        .font(.caption.bold()).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PrintRemaining(state: context.state).font(.caption.bold().monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let job = context.state.job { Text(job).font(.caption).lineLimit(1) }
                        PrintBar(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "printer.fill")
            } compactTrailing: {
                PrintRemaining(state: context.state).font(.caption2.monospacedDigit()).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.state.phase == .printing ? "printer.fill" : "checkmark.circle.fill")
            }
        }
    }
}

private struct LockScreenPrint: View {
    let attributes: PrintActivityAttributes
    let state: PrintActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributes.machineName, systemImage: "printer.fill").font(.headline).lineLimit(1)
                Spacer()
                PrintRemaining(state: state).font(.headline.monospacedDigit())
            }
            if let job = state.job { Text(job).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            PrintBar(state: state)
        }
    }
}

/// Time left while printing, from the end date — so it counts down by itself.
/// Otherwise the outcome, in words.
private struct PrintRemaining: View {
    let state: PrintActivityAttributes.ContentState
    var body: some View {
        switch state.phase {
        case .printing:
            if let end = state.endsAt, end > Date() {
                Text(timerInterval: Date()...end, countsDown: true)
            } else {
                Text("\(state.progress)%")
            }
        case .paused: Text("Paused")
        case .finished: Text("Done")
        case .failed: Text("Failed")
        case .cancelled: Text("Cancelled")
        }
    }
}

private struct PrintBar: View {
    let state: PrintActivityAttributes.ContentState
    var body: some View {
        if state.phase == .printing, let start = state.startedAt, let end = state.endsAt, end > start {
            ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
        } else {
            ProgressView(value: Double(min(100, max(0, state.progress))), total: 100)
        }
    }
}
