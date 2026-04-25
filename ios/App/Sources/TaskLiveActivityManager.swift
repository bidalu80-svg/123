import ActivityKit
import Foundation

struct TaskLiveActivitySnapshot: Equatable {
    let isRunning: Bool
    let phaseText: String
    let statusText: String
    let modelText: String
    let isInBackground: Bool
}

@MainActor
final class TaskLiveActivityManager {
    static let shared = TaskLiveActivityManager()

    private var currentActivity: Activity<IEXATaskActivityAttributes>?
    private var lastState: IEXATaskActivityAttributes.ContentState?

    func sync(snapshot: TaskLiveActivitySnapshot) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if !snapshot.isRunning {
            await endActivity(using: snapshot)
            return
        }

        let state = makeContentState(from: snapshot)
        if let currentActivity {
            guard lastState != state else { return }
            await currentActivity.update(
                ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(120)
                )
            )
            lastState = state
            return
        }

        if let existing = Activity<IEXATaskActivityAttributes>.activities.first {
            currentActivity = existing
            if lastState != state {
                await existing.update(
                    ActivityContent(
                        state: state,
                        staleDate: Date().addingTimeInterval(120)
                    )
                )
            }
            lastState = state
            return
        }

        do {
            let attributes = IEXATaskActivityAttributes(
                taskTitle: "IEXA 任务",
                startedAt: Date()
            )
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(120)
                ),
                pushType: nil
            )
            currentActivity = activity
            lastState = state
        } catch {
            currentActivity = nil
            lastState = nil
        }
    }

    private func endActivity(using snapshot: TaskLiveActivitySnapshot) async {
        guard let currentActivity ?? Activity<IEXATaskActivityAttributes>.activities.first else {
            currentActivity = nil
            lastState = nil
            return
        }

        let finalState = IEXATaskActivityAttributes.ContentState(
            statusText: clippedText(snapshot.statusText, limit: 72),
            phaseText: clippedText(snapshot.phaseText, limit: 28),
            modelText: clippedText(snapshot.modelText, limit: 28),
            isInBackground: false,
            isFinished: true
        )

        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .default
        )
        currentActivity = nil
        lastState = nil
    }

    private func makeContentState(from snapshot: TaskLiveActivitySnapshot) -> IEXATaskActivityAttributes.ContentState {
        IEXATaskActivityAttributes.ContentState(
            statusText: clippedText(snapshot.statusText, limit: 72),
            phaseText: clippedText(snapshot.phaseText, limit: 28),
            modelText: clippedText(snapshot.modelText, limit: 28),
            isInBackground: snapshot.isInBackground,
            isFinished: false
        )
    }

    private func clippedText(_ raw: String, limit: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
