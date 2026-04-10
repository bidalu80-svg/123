import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable, CaseIterable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    var content: String
    let createdAt: Date
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }

    var apiPayload: [String: String] {
        [
            "role": role.rawValue,
            "content": content
        ]
    }
}
