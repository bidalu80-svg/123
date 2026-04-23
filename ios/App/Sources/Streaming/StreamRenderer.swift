import Foundation

/// Timer-driven renderer scheduler.
/// Pulls batch data from StreamBuffer every 50ms and only renders incremental delta.
final class StreamRenderer {
    struct Configuration {
        var refreshInterval: TimeInterval
        var maxCharactersPerFrame: Int
        var maxCharactersFetchedPerTick: Int

        static let `default` = Configuration(
            refreshInterval: 0.05,            // 20 FPS max
            maxCharactersPerFrame: 50,        // typewriter cap
            maxCharactersFetchedPerTick: 1_200
        )
    }

    private let buffer: StreamBuffer
    private let configuration: Configuration
    private let queue: DispatchQueue
    private let onBackgroundBatch: ((String) -> Void)?
    private let onFrameRender: (String) -> Void
    private let onDrainComplete: () -> Void

    private var timer: DispatchSourceTimer?
    private var running = false
    private var inputCompleted = false
    private var drainNotified = false

    private var stagedChunks: [String] = []
    private var stagedReadIndex = 0
    private var stagedCharacters = 0

    init(
        buffer: StreamBuffer,
        configuration: Configuration = .default,
        queue: DispatchQueue = DispatchQueue(label: "chatapp.streaming.renderer", qos: .userInitiated),
        onBackgroundBatch: ((String) -> Void)? = nil,
        onFrameRender: @escaping (String) -> Void,
        onDrainComplete: @escaping () -> Void
    ) {
        self.buffer = buffer
        self.configuration = configuration
        self.queue = queue
        self.onBackgroundBatch = onBackgroundBatch
        self.onFrameRender = onFrameRender
        self.onDrainComplete = onDrainComplete
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.inputCompleted = false
            self.drainNotified = false
            self.clearStagedLocked()
            self.startTimerLocked()
        }
    }

    func markInputCompleted() {
        queue.async {
            self.inputCompleted = true
            if self.running {
                self.tickLocked()
            }
        }
    }

    func cancel(clearBuffer: Bool = true) {
        queue.async {
            self.stopTimerLocked()
            self.running = false
            self.inputCompleted = true
            self.drainNotified = true
            self.clearStagedLocked()
            if clearBuffer {
                self.buffer.clear()
            }
        }
    }

    private func startTimerLocked() {
        stopTimerLocked()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(0.01, configuration.refreshInterval)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(8)
        )
        timer.setEventHandler { [weak self] in
            self?.tickLocked()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopTimerLocked() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func tickLocked() {
        guard running else { return }

        let fetched = buffer.consume(maxCharacters: configuration.maxCharactersFetchedPerTick)
        if !fetched.isEmpty {
            stageAppendLocked(fetched)
        }

        let delta = stageConsumeLocked(maxCharacters: dynamicFrameCharacterBudgetLocked())
        if !delta.isEmpty {
            onBackgroundBatch?(delta)
            DispatchQueue.main.async {
                self.onFrameRender(delta)
            }
        }

        if inputCompleted && buffer.isEmpty && stagedCharacters == 0 {
            finishDrainLocked()
        }
    }

    private func dynamicFrameCharacterBudgetLocked() -> Int {
        let base = max(1, configuration.maxCharactersPerFrame)
        switch stagedCharacters {
        case 12_000...:
            return min(420, base * 28)
        case 6_000...:
            return min(320, base * 18)
        case 2_500...:
            return min(220, base * 12)
        case 900...:
            return min(150, base * 8)
        case 360...:
            return min(96, base * 4)
        default:
            return base
        }
    }

    private func finishDrainLocked() {
        guard !drainNotified else { return }
        drainNotified = true
        running = false
        stopTimerLocked()
        DispatchQueue.main.async {
            self.onDrainComplete()
        }
    }

    private func stageAppendLocked(_ chunks: [String]) {
        guard !chunks.isEmpty else { return }
        for chunk in chunks where !chunk.isEmpty {
            stagedChunks.append(chunk)
            stagedCharacters += chunk.count
        }
    }

    private func stageConsumeLocked(maxCharacters: Int) -> String {
        guard maxCharacters > 0, stagedReadIndex < stagedChunks.count else { return "" }

        var parts: [String] = []
        var remaining = maxCharacters

        while remaining > 0, stagedReadIndex < stagedChunks.count {
            let head = stagedChunks[stagedReadIndex]
            let count = head.count

            if count <= remaining {
                parts.append(head)
                stagedCharacters -= count
                stagedReadIndex += 1
                remaining -= count
                continue
            }

            let split = head.index(head.startIndex, offsetBy: remaining)
            let prefix = String(head[..<split])
            let suffix = String(head[split...])
            parts.append(prefix)
            stagedChunks[stagedReadIndex] = suffix
            stagedCharacters -= prefix.count
            remaining = 0
        }

        compactStagedLocked()
        return parts.joined()
    }

    private func clearStagedLocked() {
        stagedChunks.removeAll(keepingCapacity: false)
        stagedReadIndex = 0
        stagedCharacters = 0
    }

    private func compactStagedLocked() {
        guard stagedReadIndex > 0 else { return }
        if stagedReadIndex >= 256 || stagedReadIndex * 2 >= stagedChunks.count {
            stagedChunks.removeFirst(stagedReadIndex)
            stagedReadIndex = 0
        }
    }
}

