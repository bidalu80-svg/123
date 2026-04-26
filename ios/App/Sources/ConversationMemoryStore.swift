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
    private enum MemoryCategory: String, CaseIterable {
        case responseStyle
        case languagePreference
        case codingLanguage
        case platform
        case location
        case identity
        case workflow
    }

    private struct LegacyMemoryEntry: Codable, Equatable {
        var text: String
        var updatedAt: Date
    }

    private static let asciiWordRegex = try? NSRegularExpression(
        pattern: #"[a-z0-9.+#_-]{2,}"#,
        options: [.caseInsensitive]
    )
    private static let cjkRunRegex = try? NSRegularExpression(
        pattern: #"[\p{Han}]{2,}"#
    )

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
        buildRelevantSystemContext(for: "")
    }

    func buildRelevantSystemContext(for userQuery: String, maxItems: Int? = nil) -> String? {
        loadIfNeeded()
        let stableEntries = entries.filter { isLongTermPreferenceCandidate($0.text) }
        guard !stableEntries.isEmpty else { return nil }

        let sortedEntries = stableEntries.sorted { $0.updatedAt > $1.updatedAt }
        let clampedLimit = min(maxItems ?? maxContextItems, maxContextItems)
        let effectiveLimit = max(1, clampedLimit)
        let normalizedQuery = normalize(userQuery)

        let selected: [ConversationMemoryItem]
        if normalizedQuery.isEmpty {
            selected = Array(sortedEntries.prefix(effectiveLimit))
        } else {
            let queryCategories = categorizeText(normalizedQuery)
            let queryKeywords = keywordSet(for: normalizedQuery)

            var chosen: [ConversationMemoryItem] = []
            var chosenIDs = Set<UUID>()

            let globallyHelpful = sortedEntries.filter { isGloballyHelpfulPreference($0.text) }
            for item in globallyHelpful.prefix(min(2, effectiveLimit)) {
                chosen.append(item)
                chosenIDs.insert(item.id)
            }

            let rankedMatches = sortedEntries
                .map { item in
                    (
                        item: item,
                        score: relevanceScore(
                            for: item.text,
                            query: normalizedQuery,
                            queryKeywords: queryKeywords,
                            queryCategories: queryCategories
                        )
                    )
                }
                .filter { $0.score > 0 }
                .sorted {
                    if $0.score == $1.score {
                        return $0.item.updatedAt > $1.item.updatedAt
                    }
                    return $0.score > $1.score
                }

            for match in rankedMatches where chosen.count < effectiveLimit {
                guard !chosenIDs.contains(match.item.id) else { continue }
                chosen.append(match.item)
                chosenIDs.insert(match.item.id)
            }

            if chosen.isEmpty {
                selected = Array(sortedEntries.prefix(min(2, effectiveLimit)))
            } else {
                selected = chosen
            }
        }

        guard !selected.isEmpty else { return nil }
        return renderSystemContext(from: selected)
    }

    private func renderSystemContext(from items: [ConversationMemoryItem]) -> String? {
        guard !items.isEmpty else { return nil }
        var lines: [String] = []
        lines.append("以下是用户跨会话偏好记忆（只用于长期偏好与稳定个人信息，不代表上一个任务的上下文）：")
        for item in items {
            lines.append("• \(item.text)")
        }
        lines.append("若用户当前消息与记忆冲突，优先遵循当前消息；不要把这些记忆当成当前项目状态或上一轮任务指令。")
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
            entries = deduplicatedEntries(decoded)
                .filter { isLongTermPreferenceCandidate($0.text) }
                .sorted { $0.updatedAt > $1.updatedAt }
            persist()
            return
        }

        // Backward compatibility for historical storage format without stable IDs.
        if let legacy = try? JSONDecoder().decode([LegacyMemoryEntry].self, from: data) {
            entries = deduplicatedEntries(legacy.map { ConversationMemoryItem(text: $0.text, updatedAt: $0.updatedAt) })
                .filter { isLongTermPreferenceCandidate($0.text) }
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
            "我希望", "我想", "我的偏好", "以后默认", "默认用", "尽量用", "请一直", "以后都用",
            "my name", "i am", "i'm", "i live", "i like", "i prefer", "remember", "default to", "always use"
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

    private func isLongTermPreferenceCandidate(_ raw: String) -> Bool {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return false }

        let stableMarkers = [
            "请记住", "记住我", "我的偏好", "我喜欢", "我不喜欢", "我希望",
            "以后默认", "默认用", "尽量用", "请一直", "以后都用",
            "我叫", "我是", "我住", "我在",
            "remember", "my name", "i am", "i'm", "i live", "i like", "i prefer", "default to", "always use"
        ]
        guard stableMarkers.contains(where: { normalized.contains($0) }) else { return false }

        let taskMarkers = [
            "写一个", "做一个", "生成一个", "创建一个", "删掉", "删除", "清空", "重置",
            "继续改", "接着改", "修一下", "看下报错", "这个项目", "上一个项目",
            "write a", "build a", "create a", "delete", "clear", "reset", "fix this", "previous project"
        ]
        return !taskMarkers.contains(where: { normalized.contains($0) })
    }

    private func isGloballyHelpfulPreference(_ raw: String) -> Bool {
        let categories = categorizeText(raw)
        return categories.contains(.responseStyle)
            || categories.contains(.languagePreference)
            || categories.contains(.workflow)
    }

    private func categorizeText(_ raw: String) -> Set<MemoryCategory> {
        let text = normalize(raw)
        guard !text.isEmpty else { return [] }

        var result = Set<MemoryCategory>()

        if containsAny(in: text, markers: [
            "简洁", "详细", "短句", "长一点", "分步骤", "一步一步", "先给结论",
            "代码块", "表格", "少解释", "多解释", "bullet", "markdown"
        ]) {
            result.insert(.responseStyle)
        }

        if containsAny(in: text, markers: [
            "中文", "英文", "english", "chinese", "简体", "繁体"
        ]) {
            result.insert(.languagePreference)
        }

        if containsAny(in: text, markers: [
            "swift", "swiftui", "uikit", "python", "javascript", "typescript",
            "go", "rust", "java", "kotlin", "php", "ruby", "sql", "bash"
        ]) {
            result.insert(.codingLanguage)
        }

        if containsAny(in: text, markers: [
            "ios", "android", "xcode", "ipa", "info.plist", "entitlement",
            "前端", "网站", "网页", "后端", "接口", "api"
        ]) {
            result.insert(.platform)
        }

        if containsAny(in: text, markers: [
            "我住", "我在", "住在", "located", "live in", "上海", "北京", "深圳",
            "广州", "杭州", "成都", "东京", "singapore", "new york", "london"
        ]) {
            result.insert(.location)
        }

        if containsAny(in: text, markers: [
            "我叫", "我的名字", "名字是", "my name", "i am", "i'm", "我是"
        ]) {
            result.insert(.identity)
        }

        if containsAny(in: text, markers: [
            "默认", "以后都用", "请一直", "尽量用", "prefer", "default to", "always use"
        ]) {
            result.insert(.workflow)
        }

        return result
    }

    private func relevanceScore(
        for memory: String,
        query: String,
        queryKeywords: Set<String>,
        queryCategories: Set<MemoryCategory>
    ) -> Int {
        let normalizedMemory = normalize(memory)
        guard !normalizedMemory.isEmpty else { return 0 }

        var score = 0
        let memoryCategories = categorizeText(normalizedMemory)
        score += queryCategories.intersection(memoryCategories).count * 5

        let memoryKeywords = keywordSet(for: normalizedMemory)
        let overlapCount = queryKeywords.intersection(memoryKeywords).count
        score += min(overlapCount, 5) * 2

        if query.contains(normalizedMemory) || normalizedMemory.contains(query) {
            score += 8
        }

        if isGloballyHelpfulPreference(memory),
           containsAny(in: query, markers: [
               "回答", "回复", "语气", "风格", "默认", "以后", "中文", "英文", "简洁", "详细",
               "answer", "reply", "style", "default"
           ]) {
            score += 4
        }

        return score
    }

    private func keywordSet(for raw: String) -> Set<String> {
        let text = normalize(raw)
        guard !text.isEmpty else { return [] }

        var result = Set<String>()
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if let regex = Self.asciiWordRegex {
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match else { return }
                let token = nsText.substring(with: match.range)
                if token.count >= 2 {
                    result.insert(token)
                }
            }
        }

        if let regex = Self.cjkRunRegex {
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match else { return }
                let run = nsText.substring(with: match.range)
                appendChineseKeywords(from: run, into: &result)
            }
        }

        let stopTokens: Set<String> = [
            "请记", "记住", "住我", "我是", "我的", "以后", "默认", "请一", "一直", "都用",
            "i am", "i'm", "remember", "default"
        ]
        result.subtract(stopTokens)
        return result
    }

    private func appendChineseKeywords(from run: String, into result: inout Set<String>) {
        let characters = Array(run)
        guard characters.count >= 2 else { return }

        let maxWindow = min(characters.count, 4)
        for window in 2...maxWindow {
            guard characters.count >= window else { continue }
            for start in 0...(characters.count - window) {
                let token = String(characters[start..<(start + window)])
                result.insert(token)
            }
        }

        if characters.count <= 8 {
            result.insert(run)
        }
    }

    private func containsAny(in text: String, markers: [String]) -> Bool {
        markers.contains(where: { text.contains($0) })
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
