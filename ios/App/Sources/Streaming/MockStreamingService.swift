import Foundation

final class MockStreamingService: StreamingServiceProviding {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "chatapp.streaming.mock.service", qos: .utility)) {
        self.queue = queue
    }

    @discardableResult
    func startStreaming(
        prompt: String,
        profile: MockStreamProfile,
        onStreamChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) -> StreamCancellable {
        let text = Self.makeMockText(prompt: prompt, profile: profile)
        let chunks = Self.makeChunks(from: text, minChunk: 4, maxChunk: 22)
        let session = MockStreamSession(
            queue: queue,
            chunks: chunks,
            onStreamChunk: onStreamChunk,
            onComplete: onComplete,
            onError: onError
        )
        session.start()
        return session
    }

    private static func makeChunks(from text: String, minChunk: Int, maxChunk: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let minSize = max(1, minChunk)
        let maxSize = max(minSize, maxChunk)

        var result: [String] = []
        var index = text.startIndex
        var rng = SystemRandomNumberGenerator()

        while index < text.endIndex {
            let size = Int.random(in: minSize...maxSize, using: &rng)
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }

        return result
    }

    private static func makeMockText(prompt: String, profile: MockStreamProfile) -> String {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let safePrompt = normalizedPrompt.isEmpty ? "请展示流式渲染效果" : normalizedPrompt

        switch profile {
        case .standard:
            return """
            ## 流式输出演示

            你输入的主题是：**\(safePrompt)**  
            下面这段文字会以流式方式逐步出现，渲染层每 50ms 刷新一次，但每帧最多只追加 50 个字符。

            - UI 不会对每个 chunk 立即刷新
            - 主线程只做 `UITextView.textStorage.append(...)`
            - Markdown 在流结束后才统一解析

            ```swift
            // 流式阶段：只追加纯文本
            textView.textStorage.append(NSAttributedString(string: delta))
            ```

            这样可以明显减少卡顿，并保持稳定的“打字机”观感。
            """

        case .longText:
            var blocks: [String] = []
            blocks.append("## 长文本流式演示（大文本压测）")
            blocks.append("主题：\(safePrompt)")
            blocks.append("这段文本用于验证：几万字情况下，UI 仍保持平滑、可取消、可完成回调。")

            for idx in 1...260 {
                blocks.append(
                    """
                    ### 段落 \(idx)
                    在第 \(idx) 段中，我们持续模拟模型返回结果。渲染器采用“后台缓冲 + 定时拉取 + 主线程增量 append”的策略，避免一次性重绘全文，从而保持滚动与输入手感稳定。
                    """
                )
            }

            blocks.append(
                """

                ```python
                # Markdown 会在流结束后再处理
                # 流式阶段不做语法高亮解析
                print("stream done")
                ```
                """
            )
            return blocks.joined(separator: "\n\n")
        }
    }
}

private final class MockStreamSession: StreamCancellable {
    private enum SessionError: LocalizedError {
        case unexpectedStop

        var errorDescription: String? {
            switch self {
            case .unexpectedStop:
                return "模拟流在未完成时中断。"
            }
        }
    }

    private let queue: DispatchQueue
    private let onStreamChunk: (String) -> Void
    private let onComplete: () -> Void
    private let onError: (Error) -> Void

    private var chunks: [String]
    private var cursor = 0
    private var cancelled = false
    private var finished = false
    private var timer: DispatchSourceTimer?

    init(
        queue: DispatchQueue,
        chunks: [String],
        onStreamChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.queue = queue
        self.chunks = chunks
        self.onStreamChunk = onStreamChunk
        self.onComplete = onComplete
        self.onError = onError
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    func start() {
        queue.async {
            guard !self.finished else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(80), repeating: .milliseconds(16), leeway: .milliseconds(6))
            timer.setEventHandler { [weak self] in
                self?.emitNext()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func cancel() {
        queue.async {
            guard !self.finished else { return }
            self.cancelled = true
            self.finishLocked(notifyCompletion: false)
        }
    }

    private func emitNext() {
        guard !finished else { return }

        if cancelled {
            finishLocked(notifyCompletion: false)
            return
        }

        guard cursor < chunks.count else {
            finishLocked(notifyCompletion: true)
            return
        }

        let piece = chunks[cursor]
        cursor += 1
        onStreamChunk(piece)
    }

    private func finishLocked(notifyCompletion: Bool) {
        guard !finished else { return }
        finished = true
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil

        if notifyCompletion {
            onComplete()
        } else if !cancelled && cursor < chunks.count {
            onError(SessionError.unexpectedStop)
        }
    }
}

