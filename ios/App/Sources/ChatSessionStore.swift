import Foundation

struct ChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var previewText: String {
        if let first = messages.first(where: { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return first.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }
}

enum ChatSessionStore {
    private static let messagesKey = "chatapp.chat.messages"
    private static let sessionsKey = "chatapp.chat.sessions"
    private static let currentSessionIDKey = "chatapp.chat.current_session_id"

    static func loadSessions(from defaults: UserDefaults = .standard) -> [ChatSession] {
        if let data = defaults.data(forKey: sessionsKey),
           let sessions = try? JSONDecoder().decode([ChatSession].self, from: data) {
            return sessions.sorted { $0.updatedAt > $1.updatedAt }
        }

        // Backward compatibility with previous single-session format.
        let legacyMessages = loadLegacyMessages(from: defaults)
        if legacyMessages.isEmpty {
            return []
        }

        let legacySession = ChatSession(
            title: "历史会话",
            createdAt: Date(),
            updatedAt: Date(),
            messages: legacyMessages
        )
        saveSessions([legacySession], currentSessionID: legacySession.id, to: defaults)
        defaults.removeObject(forKey: messagesKey)
        return [legacySession]
    }

    static func loadCurrentSessionID(from defaults: UserDefaults = .standard) -> UUID? {
        guard let raw = defaults.string(forKey: currentSessionIDKey) else { return nil }
        return UUID(uuidString: raw)
    }

    static func saveSessions(_ sessions: [ChatSession], currentSessionID: UUID?, to defaults: UserDefaults = .standard) {
        let normalized = sessions.sorted { $0.updatedAt > $1.updatedAt }
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: sessionsKey)
        }

        if let currentSessionID {
            defaults.set(currentSessionID.uuidString, forKey: currentSessionIDKey)
        } else {
            defaults.removeObject(forKey: currentSessionIDKey)
        }
    }

    static func saveLegacyMessages(_ messages: [ChatMessage], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        defaults.set(data, forKey: messagesKey)
    }

    static func reset(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: sessionsKey)
        defaults.removeObject(forKey: currentSessionIDKey)
        defaults.removeObject(forKey: messagesKey)
    }

    private static func loadLegacyMessages(from defaults: UserDefaults) -> [ChatMessage] {
        guard let data = defaults.data(forKey: messagesKey),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        return messages
    }
}
