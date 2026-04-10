import Foundation

enum ChatSessionStore {
    private static let messagesKey = "chatapp.chat.messages"

    static func load(from defaults: UserDefaults = .standard) -> [ChatMessage] {
        guard let data = defaults.data(forKey: messagesKey),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        return messages
    }

    static func save(_ messages: [ChatMessage], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        defaults.set(data, forKey: messagesKey)
    }

    static func reset(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: messagesKey)
    }
}
