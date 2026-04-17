import Foundation

/// Thread-safe stream chunk buffer.
/// Stores incoming chunks as array items (not direct `+=` accumulation),
/// then allows batched consume from renderer side.
final class StreamBuffer {
    struct Snapshot: Equatable {
        let chunkCount: Int
        let pendingCharacters: Int
        let droppedCharacters: Int
    }

    private let queue = DispatchQueue(label: "chatapp.streaming.buffer", qos: .userInitiated)
    private let maxBufferedCharacters: Int

    private var chunks: [String] = []
    private var readIndex = 0
    private var pendingCharacters = 0
    private var droppedCharacters = 0

    init(maxBufferedCharacters: Int = 120_000) {
        self.maxBufferedCharacters = max(2_000, maxBufferedCharacters)
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        queue.sync {
            chunks.append(chunk)
            pendingCharacters += chunk.count
            trimOverflowLocked()
        }
    }

    /// Consume all currently buffered chunks.
    func consume() -> [String] {
        consume(maxCharacters: Int.max)
    }

    /// Consume at most `maxCharacters` from buffered chunks.
    /// Returns chunk pieces preserving original order.
    func consume(maxCharacters: Int) -> [String] {
        guard maxCharacters > 0 else { return [] }

        return queue.sync {
            guard readIndex < chunks.count else { return [] }

            var output: [String] = []
            var remaining = maxCharacters

            while remaining > 0, readIndex < chunks.count {
                let head = chunks[readIndex]
                let headCount = head.count

                if headCount <= remaining {
                    output.append(head)
                    pendingCharacters -= headCount
                    readIndex += 1
                    remaining -= headCount
                    continue
                }

                let splitIndex = head.index(head.startIndex, offsetBy: remaining)
                let prefix = String(head[..<splitIndex])
                let suffix = String(head[splitIndex...])
                output.append(prefix)
                chunks[readIndex] = suffix
                pendingCharacters -= prefix.count
                remaining = 0
            }

            compactIfNeededLocked()
            return output
        }
    }

    func clear() {
        queue.sync {
            chunks.removeAll(keepingCapacity: false)
            readIndex = 0
            pendingCharacters = 0
        }
    }

    var isEmpty: Bool {
        queue.sync { pendingCharacters == 0 }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                chunkCount: max(0, chunks.count - readIndex),
                pendingCharacters: pendingCharacters,
                droppedCharacters: droppedCharacters
            )
        }
    }

    private func trimOverflowLocked() {
        guard pendingCharacters > maxBufferedCharacters else { return }

        while pendingCharacters > maxBufferedCharacters, readIndex < chunks.count {
            let dropped = chunks[readIndex]
            pendingCharacters -= dropped.count
            droppedCharacters += dropped.count
            readIndex += 1
        }

        compactIfNeededLocked()
    }

    private func compactIfNeededLocked() {
        guard readIndex > 0 else { return }
        if readIndex >= 256 || readIndex * 2 >= chunks.count {
            chunks.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

