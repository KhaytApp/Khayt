import ActivityKit
import SwiftUI
import WidgetKit

/// How a print looks as a Live Activity. Every presentation is drawn —
/// Apple requires all of them: Lock Screen, and the Dynamic Island's
/// expanded, compact and minimal forms. The views themselves are in
/// `PrintActivityViews.swift`, where the app's tests can render them.
struct PrintActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            PrintActivityLockScreen(attributes: context.attributes, state: context.state)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .activityBackgroundTint(PrintActivityLook.surface.opacity(0.92))
                .activitySystemActionForegroundColor(PrintActivityLook.ink)
        } dynamicIsland: { context in
            let state = context.state
            let tone = PrintActivityLook.tone(state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "printer.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(PrintActivityLook.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(context.attributes.machineName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PrintPhasePill(phase: state.phase).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            PrintHeadline(state: state)
                                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 4)
                            PrintEnds(state: state)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            PrintBar(state: state)
                            if PrintActivityText.showsPercent(state.phase) {
                                Text(verbatim: PrintActivityText.percent(state.progress))
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(tone)
                                    .fixedSize()
                            }
                        }
                        if let job = state.job {
                            Text(PrintActivityText.jobTitle(job))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: PrintActivityLook.symbol(state.phase))
                    .foregroundStyle(tone)
            } compactTrailing: {
                CompactRemaining(state: state)
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tone)
            } minimal: {
                if let range = PrintActivityText.barRange(state) {
                    ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: {
                        Image(systemName: "printer.fill").font(.system(size: 9))
                    }
                    .progressViewStyle(.circular)
                    .tint(tone)
                } else {
                    Image(systemName: PrintActivityLook.symbol(state.phase)).foregroundStyle(tone)
                }
            }
            .keylineTint(tone)
        }
    }
}

/// The compact island's figure: the time left, kept narrow, or the percent.
private struct CompactRemaining: View {
    let state: PrintActivityAttributes.ContentState
    var body: some View {
        if state.phase == .printing, let end = state.endsAt, end > Date() {
            PrintTimeLeft(end: end)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 56)
        } else {
            Text(verbatim: PrintActivityText.percent(state.progress))
        }
    }
}
