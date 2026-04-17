import Foundation

/// Segmented archive store for long streaming text.
/// - Stores data in 5k-char style segments.
/// - Applies a total archive cap to avoid memory growth.
/// - Can return recent text for UI while keeping old history bounded.
final class StreamSegmentStore {
    struct Snapshot: Equatable {
        let segmentCount: Int
        let totalArchivedCharacters: Int
        let droppedCharacters: Int
    }

    private let queue = DispatchQueue(label: "chatapp.streaming.segment-store", qos: .utility)
    private let segmentCharacterLimit: Int
    private let maxArchivedCharacters: Int

    private var segments: [String] = []
    private var totalArchivedCharacters = 0
    private var droppedCharacters = 0

    init(segmentCharacterLimit: Int = 5_000, maxArchivedCharacters: Int = 120_000) {
        self.segmentCharacterLimit = max(512, segmentCharacterLimit)
        self.maxArchivedCharacters = max(self.segmentCharacterLimit, maxArchivedCharacters)
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        queue.sync {
            appendLocked(text)
            trimOverflowLocked()
        }
    }

    func clear() {
        queue.sync {
            segments.removeAll(keepingCapacity: false)
            totalArchivedCharacters = 0
            droppedCharacters = 0
        }
    }

    func allText(includeDropNotice: Bool = true) -> String {
        queue.sync {
            let merged = segments.joined()
            guard includeDropNotice, droppedCharacters > 0 else { return merged }
            return "[...已省略 \(droppedCharacters) 个字符以控制内存...]\n" + merged
        }
    }

    func recentText(maxCharacters: Int, includeDropNotice: Bool = true) -> String {
        guard maxCharacters > 0 else { return "" }

        return queue.sync {
            guard !segments.isEmpty else { return "" }

            var remaining = maxCharacters
            var reversedPieces: [String] = []

            for segment in segments.reversed() {
                guard remaining > 0 else { break }
                let count = segment.count

                if count <= remaining {
                    reversedPieces.append(segment)
                    remaining -= count
                    continue
                }

                let start = segment.index(segment.endIndex, offsetBy: -remaining)
                reversedPieces.append(String(segment[start...]))
                remaining = 0
            }

            let recent = reversedPieces.reversed().joined()
            guard includeDropNotice, droppedCharacters > 0 else { return recent }
            return "[...前文已省略 \(droppedCharacters) 字符...]\n" + recent
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                segmentCount: segments.count,
                totalArchivedCharacters: totalArchivedCharacters,
                droppedCharacters: droppedCharacters
            )
        }
    }

    private func appendLocked(_ text: String) {
        var cursor = text.startIndex

        while cursor < text.endIndex {
            if segments.isEmpty || segments[segments.count - 1].count >= segmentCharacterLimit {
                segments.append("")
            }

            let lastIndex = segments.count - 1
            let available = segmentCharacterLimit - segments[lastIndex].count
            guard available > 0 else { continue }

            let remainingCount = text.distance(from: cursor, to: text.endIndex)
            let take = min(available, remainingCount)
            let next = text.index(cursor, offsetBy: take)
            let part = String(text[cursor..<next])
            segments[lastIndex].append(part)
            totalArchivedCharacters += part.count
            cursor = next
        }
    }

    private func trimOverflowLocked() {
        guard totalArchivedCharacters > maxArchivedCharacters else { return }

        while totalArchivedCharacters > maxArchivedCharacters, !segments.isEmpty {
            let overflow = totalArchivedCharacters - maxArchivedCharacters
            let first = segments[0]
            let firstCount = first.count

            if overflow >= firstCount {
                segments.removeFirst()
                totalArchivedCharacters -= firstCount
                droppedCharacters += firstCount
                continue
            }

            let start = first.index(first.startIndex, offsetBy: overflow)
            let suffix = String(first[start...])
            segments[0] = suffix
            totalArchivedCharacters -= overflow
            droppedCharacters += overflow
        }
    }
}

