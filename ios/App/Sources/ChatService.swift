import Foundation

struct ChatRequestBuilder {
    static func makeRequest(config: ChatConfig, history: [ChatMessage], message: ChatMessage) throws -> URLRequest {
        let normalizedURL = ChatConfigStore.normalizedURL(config.apiURL)
        guard let url = URL(string: normalizedURL), !normalizedURL.isEmpty else {
            throw ChatServiceError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedAPIKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": config.model,
            "messages": history.map(\.apiPayload) + [message.apiPayload],
            "stream": config.streamEnabled
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }
}

enum ChatServiceError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noData
    case streamFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "API 地址无效，请检查配置。"
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case .httpError(let statusCode):
            return "请求失败，HTTP 状态码：\(statusCode)。"
        case .noData:
            return "服务器没有返回可用数据。"
        case .streamFailed:
            return "流式响应解析失败。"
        }
    }
}

final class ChatService {
    func sendMessage(
        config: ChatConfig,
        history: [ChatMessage],
        message: ChatMessage,
        onEvent: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: message)

        if config.streamEnabled {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ChatServiceError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw ChatServiceError.httpError(httpResponse.statusCode)
            }

            var fullReply = ""
            for try await line in bytes.lines {
                guard let chunk = StreamParser.parse(line: line) else { continue }
                if chunk.isDone { break }
                if let delta = chunk.delta, !delta.isEmpty {
                    fullReply += delta
                    onEvent(delta)
                }
            }

            if fullReply.isEmpty {
                throw ChatServiceError.noData
            }

            return fullReply
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ChatServiceError.httpError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let messageObject = first["message"] as? [String: Any],
              let content = extractContent(from: messageObject),
              !content.isEmpty else {
            throw ChatServiceError.noData
        }

        onEvent(content)
        return content
    }

    func testConnection(config: ChatConfig) async -> String {
        do {
            let ping = ChatMessage(role: .user, content: "ping")
            let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: ping)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return "接口联通成功，状态码：\(httpResponse.statusCode)"
            }
            return "接口已响应，但返回类型异常。"
        } catch {
            return "接口测试失败：\(error.localizedDescription)"
        }
    }

    private func extractContent(from messageObject: [String: Any]) -> String? {
        if let content = messageObject["content"] as? String {
            return content
        }

        if let contentItems = messageObject["content"] as? [[String: Any]] {
            let textParts = contentItems.compactMap { item -> String? in
                guard let type = item["type"] as? String, type == "text" else { return nil }
                return item["text"] as? String
            }
            if !textParts.isEmpty {
                return textParts.joined()
            }
        }

        return nil
    }
}
