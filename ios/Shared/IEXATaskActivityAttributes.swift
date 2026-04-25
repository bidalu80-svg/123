import ActivityKit
import Foundation

struct IEXATaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
        var phaseText: String
        var modelText: String
        var isInBackground: Bool
        var isFinished: Bool
    }

    var taskTitle: String
    var startedAt: Date
}
