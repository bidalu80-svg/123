import Foundation

actor ConversationMemoryStore {
    private struct MemoryEntry: Codable, Equatable {
        var text: String
        var updatedAt: Date
    }

    private let defaults: UserDefaults
    private let storeKey: String
    private let maxEntries: Int
    private let maxEntryLength: Int
    private let maxContextItems: Int

    private var loaded = false
    private var entries: [MemoryEntry] = []

    init(
        defaults: UserDefaults = .standard,
        storeKey: String = "chatapp.chat.memory.entries",
        maxEntries: Int = 80,
        maxEntryLength: Int = 180,
        maxContextItems: Int = 14
    ) {
        self.defaults = defaults
        self.storeKey = storeKey
        self.maxEntries = maxEntries
        self.maxEntryLength = maxEntryLength
        self.maxContextItems = maxContextItems
    }

    func remember(_ message: ChatMessage) {
        guard message.role == .user else { return }
        loadIfNeeded()

        let candidates = extractCandidates(from: message)
        guard !candidates.isEmpty else { return }

        var changed = false
        for candidate in candidates {
            let normalized = normalize(candidate)
            guard !normalized.isEmpty else { continue }

            if let index = entries.firstIndex(where: { normalize($0.text) == normalized }) {
                entries[index].updatedAt = Date()
                changed = true
            } else {
                entries.append(MemoryEntry(text: candidate, updatedAt: Date()))
                changed = true
            }
        }

        guard changed else { return }
        entries.sort { $0.updatedAt > $1.updatedAt }
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    func buildSystemContext() -> String? {
        loadIfNeeded()
        guard !entries.isEmpty else { return nil }

        let top = Array(entries.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxContextItems))
        guard !top.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("以下是用户跨会话记忆（来自历史聊天，可能会过时）：")
        for item in top {
            lines.append("• \(item.text)")
        }
        lines.append("若用户当前消息与记忆冲突，优先遵循当前消息。")
        return lines.joined(separator: "\n")
    }

    func reset() {
        entries = []
        loaded = true
        defaults.removeObject(forKey: storeKey)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = defaults.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([MemoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storeKey)
    }

    private func extractCandidates(from message: ChatMessage) -> [String] {
        var result: [String] = []
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty {
            let memoryLines = extractMemoryFocusedLines(from: text)
            if !memoryLines.isEmpty {
                result.append(contentsOf: memoryLines)
            } else if let fallback = clipForMemory(text) {
                result.append(fallback)
            }
        }

        if let file = message.fileAttachments.first {
            let fileHint = "用户上传了文件：\(file.fileName)"
            if let clipped = clipForMemory(fileHint) {
                result.append(clipped)
            }
        }

        return deduplicate(result)
    }

    private func extractMemoryFocusedLines(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        let separators = CharacterSet(charactersIn: "\n。！？!?；;")
        let chunks = normalized
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let markers = [
            "请记住", "记住我", "我叫", "我是", "我的", "我住", "我在", "我喜欢", "我不喜欢",
            "我希望", "我想", "我的偏好", "my name", "i am", "i'm", "i live", "i like", "i prefer", "remember"
        ]

        var focused: [String] = []
        for chunk in chunks {
            let lowered = chunk.lowercased()
            guard markers.contains(where: { lowered.contains($0) }) else { continue }
            if let clipped = clipForMemory(chunk) {
                focused.append(clipped)
            }
        }
        return focused
    }

    private func clipForMemory(_ raw: String) -> String? {
        let compact = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compact.count >= 4 else { return nil }
        if compact.count <= maxEntryLength {
            return compact
        }
        return String(compact.prefix(maxEntryLength))
    }

    private func normalize(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func deduplicate(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let key = normalize(value)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            result.append(value)
        }
        return result
    }
}
