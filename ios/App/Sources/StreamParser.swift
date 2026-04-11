import Foundation

struct StreamChunk: Equatable {
    let rawLine: String
    let deltaText: String
    let imageURLs: [String]
    let isDone: Bool
}

enum StreamParser {
    static func parse(line: String) -> StreamChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let payload: String
        if trimmed.hasPrefix("data:") {
            payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("event:") || trimmed.hasPrefix(":") {
            // Ignore SSE event/meta/comment lines.
            return nil
        } else {
            // Some providers ignore stream mode and return regular JSON lines directly.
            payload = trimmed
        }

        if payload == "[DONE]" {
            return StreamChunk(rawLine: line, deltaText: "", imageURLs: [], isDone: true)
        }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return StreamChunk(rawLine: line, deltaText: "", imageURLs: [], isDone: false)
        }

        let extracted = extractPayload(from: object)
        return StreamChunk(
            rawLine: line,
            deltaText: extracted.text,
            imageURLs: extracted.imageURLs,
            isDone: false
        )
    }

    static func extractPayload(from object: [String: Any]) -> (text: String, imageURLs: [String]) {
        var textParts: [String] = []
        var imageURLs: [String] = []

        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices {
                appendChoice(choice, textParts: &textParts, imageURLs: &imageURLs)
            }
        }

        // Some providers return image generation payload as data[] even on chat endpoint.
        if let dataArray = object["data"] as? [[String: Any]] {
            appendImageDataArray(dataArray, imageURLs: &imageURLs)
        }

        if let output = object["output"] as? [[String: Any]] {
            for block in output {
                appendFromContentNode(block, textParts: &textParts, imageURLs: &imageURLs)
            }
        }

        if let text = object["text"] as? String, !text.isEmpty {
            textParts.append(text)
        }

        return (
            textParts.joined(),
            dedupe(imageURLs)
        )
    }

    private static func appendChoice(
        _ choice: [String: Any],
        textParts: inout [String],
        imageURLs: inout [String]
    ) {
        if let delta = choice["delta"] as? [String: Any] {
            appendFromContentNode(delta, textParts: &textParts, imageURLs: &imageURLs)
        }
        if let message = choice["message"] as? [String: Any] {
            appendFromContentNode(message, textParts: &textParts, imageURLs: &imageURLs)
        }
        if let text = choice["text"] as? String, !text.isEmpty {
            textParts.append(text)
        }
    }

    private static func appendFromContentNode(
        _ node: [String: Any],
        textParts: inout [String],
        imageURLs: inout [String]
    ) {
        if let direct = node["content"] as? String, !direct.isEmpty {
            textParts.append(direct)
            imageURLs.append(contentsOf: MessageContentParser.extractInlineImageURLs(from: direct))
        }

        if let outputText = node["output_text"] as? String, !outputText.isEmpty {
            textParts.append(outputText)
        }

        if let contentArray = node["content"] as? [[String: Any]] {
            for item in contentArray {
                appendTypedContentItem(item, textParts: &textParts, imageURLs: &imageURLs)
            }
        }

        if let imageArray = node["images"] as? [[String: Any]] {
            appendImageDataArray(imageArray, imageURLs: &imageURLs)
        }

        if let imageURLString = node["image_url"] as? String {
            if !imageURLString.isEmpty {
                imageURLs.append(imageURLString)
            }
        }

        if let imageURLObj = node["image_url"] as? [String: Any] {
            if let url = imageURLObj["url"] as? String, !url.isEmpty {
                imageURLs.append(url)
            }
            if let b64 = imageURLObj["b64_json"] as? String, !b64.isEmpty {
                imageURLs.append("data:image/png;base64,\(b64)")
            }
        }

        if let b64 = node["b64_json"] as? String, !b64.isEmpty {
            imageURLs.append("data:image/png;base64,\(b64)")
        }

        if let dataArray = node["data"] as? [[String: Any]] {
            appendImageDataArray(dataArray, imageURLs: &imageURLs)
        }
    }

    private static func appendTypedContentItem(
        _ item: [String: Any],
        textParts: inout [String],
        imageURLs: inout [String]
    ) {
        let type = (item["type"] as? String)?.lowercased() ?? ""

        if (type == "text" || type == "output_text"), let text = item["text"] as? String, !text.isEmpty {
            textParts.append(text)
            imageURLs.append(contentsOf: MessageContentParser.extractInlineImageURLs(from: text))
        }

        if type == "image_url" || type == "output_image" || type == "image" {
            if let image = item["image_url"] as? [String: Any] {
                if let url = image["url"] as? String, !url.isEmpty {
                    imageURLs.append(url)
                }
                if let b64 = image["b64_json"] as? String, !b64.isEmpty {
                    imageURLs.append("data:image/png;base64,\(b64)")
                }
            }
            if let imageURL = item["image_url"] as? String, !imageURL.isEmpty {
                imageURLs.append(imageURL)
            }
            if let url = item["url"] as? String, !url.isEmpty {
                imageURLs.append(url)
            }
            if let b64 = item["b64_json"] as? String, !b64.isEmpty {
                imageURLs.append("data:image/png;base64,\(b64)")
            }
        }
    }

    private static func appendImageDataArray(_ rows: [[String: Any]], imageURLs: inout [String]) {
        for row in rows {
            if let url = row["url"] as? String, !url.isEmpty {
                imageURLs.append(url)
            }
            if let imageURLObj = row["image_url"] as? [String: Any],
               let url = imageURLObj["url"] as? String,
               !url.isEmpty {
                imageURLs.append(url)
            }
            if let b64 = row["b64_json"] as? String, !b64.isEmpty {
                imageURLs.append("data:image/png;base64,\(b64)")
            }
        }
    }

    private static func dedupe(_ input: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in input {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || seen.contains(trimmed) { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
