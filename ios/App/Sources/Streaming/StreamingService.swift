import Foundation

protocol StreamCancellable: AnyObject {
    func cancel()
}

enum MockStreamProfile: Int, CaseIterable {
    case standard
    case longText

    var title: String {
        switch self {
        case .standard:
            return "标准流"
        case .longText:
            return "大文本"
        }
    }
}

/// Decoupled stream network contract.
/// Any future provider/model can implement this protocol.
protocol StreamingServiceProviding {
    @discardableResult
    func startStreaming(
        prompt: String,
        profile: MockStreamProfile,
        onStreamChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) -> StreamCancellable
}

