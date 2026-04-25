import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IEXATaskLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        IEXATaskLiveActivityWidget()
    }
}

struct IEXATaskLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IEXATaskActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.phaseText)
                    } icon: {
                        Image(systemName: context.state.isFinished ? "checkmark.seal.fill" : "bolt.horizontal.circle.fill")
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.statusText)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(context.state.isInBackground ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(context.state.isInBackground ? "后台继续中" : "前台进行中")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        Text(context.state.modelText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isFinished ? "checkmark.circle.fill" : "hammer.circle.fill")
                    .foregroundStyle(context.state.isFinished ? .green : .blue)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            } minimal: {
                Image(systemName: context.state.isFinished ? "checkmark.circle.fill" : "hammer.circle.fill")
                    .foregroundStyle(context.state.isFinished ? .green : .blue)
            }
        }
    }

    private func lockScreenView(
        context: ActivityViewContext<IEXATaskActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: context.state.isFinished ? "checkmark.seal.fill" : "hammer.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(context.state.isFinished ? .green : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.taskTitle)
                        .font(.system(size: 16, weight: .bold))
                    Text(context.state.phaseText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
            }

            Text(context.state.statusText)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(3)

            HStack(spacing: 8) {
                Capsule(style: .continuous)
                    .fill(context.state.isInBackground ? Color.orange.opacity(0.18) : Color.green.opacity(0.18))
                    .frame(width: 10, height: 10)
                Text(context.state.isInBackground ? "后台继续中" : "前台进行中")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(context.state.modelText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .activityBackgroundTint(Color(.systemBackground))
        .activitySystemActionForegroundColor(.primary)
    }
}
