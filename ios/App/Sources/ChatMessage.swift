import Foundation

struct ChatImageAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    var dataURL: String
    var mimeType: String
    var remoteURL: String?

    init(
        id: UUID = UUID(),
        dataURL: String,
        mimeType: String,
        remoteURL: String? = nil
    ) {
        self.id = id
        self.dataURL = dataURL
        self.mimeType = mimeType
        self.remoteURL = remoteURL
    }

    static func fromImageData(_ data: Data, mimeType: String) -> ChatImageAttachment {
        let encoded = data.base64EncodedString()
        return ChatImageAttachment(
            dataURL: "data:\(mimeType);base64,\(encoded)",
            mimeType: mimeType
        )
    }

    var decodedImageData: Data? {
        guard dataURL.hasPrefix("data:") else { return nil }
        let components = dataURL.split(separator: ",", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        return Data(base64Encoded: components[1])
    }

    var renderURLString: String? {
        if let remoteURL, !remoteURL.isEmpty {
            return remoteURL
        }
        if dataURL.hasPrefix("http://") || dataURL.hasPrefix("https://") {
            return dataURL
        }
        return nil
    }

    var requestURLString: String {
        if let remoteURL, !remoteURL.isEmpty {
            return remoteURL
        }
        return dataURL
    }
}

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
    var attachments: [ChatImageAttachment]

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        attachments: [ChatImageAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        attachments = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .attachments) ?? []
    }

    var apiPayload: [String: Any] {
        [
            "role": role.rawValue,
            "content": apiContent
        ]
    }

    var copyableText: String {
        var parts: [String] = []
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }

        let urls = attachments.map(\.requestURLString).filter { !$0.isEmpty }
        if !urls.isEmpty {
            parts.append(urls.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    private var apiContent: Any {
        if attachments.isEmpty {
            return content
        }

        var segments: [[String: Any]] = []
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append([
                "type": "text",
                "text": trimmed
            ])
        }

        for attachment in attachments {
            segments.append([
                "type": "image_url",
                "image_url": [
                    "url": attachment.requestURLString
                ]
            ])
        }
        return segments
    }
}
