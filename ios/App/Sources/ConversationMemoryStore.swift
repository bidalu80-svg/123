import Foundation

struct ConversationMemoryItem: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var updatedAt: Date

    init(id: UUID = UUID(), text: String, updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

actor ConversationMemoryStore {
    private struct LegacyMemoryEntry: Codable, Equatable {
        var text: String
        var updatedAt: Date
    }

    private let defaults: UserDefaults
    private let storeKey: String
    private let maxEntries: Int
    private let maxEntryLength: Int
    private let maxContextItems: Int

    private var loaded = false
    private var entries: [ConversationMemoryItem] = []

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
                entries.append(ConversationMemoryItem(text: candidate, updatedAt: Date()))
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

    func listEntries() -> [ConversationMemoryItem] {
        loadIfNeeded()
        return entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func removeEntry(id: UUID) {
        loadIfNeeded()
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before {
            persist()
        }
    }

    func removeEntries(ids: [UUID]) {
        loadIfNeeded()
        let deleting = Set(ids)
        guard !deleting.isEmpty else { return }
        let before = entries.count
        entries.removeAll { deleting.contains($0.id) }
        if entries.count != before {
            persist()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = defaults.data(forKey: storeKey) else {
            entries = []
            return
        }

        if let decoded = try? JSONDecoder().decode([ConversationMemoryItem].self, from: data) {
            entries = deduplicatedEntries(decoded).sorted { $0.updatedAt > $1.updatedAt }
            return
        }

        // Backward compatibility for historical storage format without stable IDs.
        if let legacy = try? JSONDecoder().decode([LegacyMemoryEntry].self, from: data) {
            entries = deduplicatedEntries(legacy.map { ConversationMemoryItem(text: $0.text, updatedAt: $0.updatedAt) })
                .sorted { $0.updatedAt > $1.updatedAt }
            persist()
            return
        }

        entries = []
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

    private func deduplicatedEntries(_ values: [ConversationMemoryItem]) -> [ConversationMemoryItem] {
        var deduped: [String: ConversationMemoryItem] = [:]
        for item in values {
            let key = normalize(item.text)
            guard !key.isEmpty else { continue }
            if let old = deduped[key] {
                deduped[key] = old.updatedAt >= item.updatedAt ? old : item
            } else {
                deduped[key] = item
            }
        }
        return Array(deduped.values)
    }
}
