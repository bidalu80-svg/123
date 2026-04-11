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

struct ChatFileAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    var fileName: String
    var mimeType: String
    var textContent: String

    init(
        id: UUID = UUID(),
        fileName: String,
        mimeType: String,
        textContent: String
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.textContent = textContent
    }

    var codeLanguageHint: String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return "swift"
        case "py":
            return "python"
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "java":
            return "java"
        case "kt":
            return "kotlin"
        case "json":
            return "json"
        case "xml":
            return "xml"
        case "md":
            return "markdown"
        case "html":
            return "html"
        case "css":
            return "css"
        case "sh":
            return "bash"
        case "yaml", "yml":
            return "yaml"
        default:
            return nil
        }
    }

    var previewText: String {
        textContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var promptBlock: String {
        let safeName = fileName.isEmpty ? "untitled.txt" : fileName
        let language = codeLanguageHint ?? "text"
        return """
        [FILE: \(safeName)]
        ```\(language)
        \(previewText)
        ```
        """
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
    var imageAttachments: [ChatImageAttachment]
    var fileAttachments: [ChatFileAttachment]

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        imageAttachments: [ChatImageAttachment] = [],
        fileAttachments: [ChatFileAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.imageAttachments = imageAttachments
        self.fileAttachments = fileAttachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false

        if let images = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .imageAttachments) {
            imageAttachments = images
        } else if let legacy = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .attachments) {
            imageAttachments = legacy
        } else {
            imageAttachments = []
        }

        fileAttachments = try container.decodeIfPresent([ChatFileAttachment].self, forKey: .fileAttachments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(imageAttachments, forKey: .imageAttachments)
        try container.encode(fileAttachments, forKey: .fileAttachments)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case createdAt
        case isStreaming
        case imageAttachments
        case fileAttachments
        case attachments
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

        let imageURLs = imageAttachments.map(\.requestURLString).filter { !$0.isEmpty }
        if !imageURLs.isEmpty {
            parts.append(imageURLs.joined(separator: "\n"))
        }

        if !fileAttachments.isEmpty {
            let fileBlocks = fileAttachments.map { $0.promptBlock }
            parts.append(fileBlocks.joined(separator: "\n\n"))
        }

        return parts.joined(separator: "\n")
    }

    private var apiContent: Any {
        if imageAttachments.isEmpty && fileAttachments.isEmpty {
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

        for file in fileAttachments {
            segments.append([
                "type": "text",
                "text": file.promptBlock
            ])
        }

        for attachment in imageAttachments {
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
