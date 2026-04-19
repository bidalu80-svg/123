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

        appendResponsesEventPayload(object, textParts: &textParts, imageURLs: &imageURLs)

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

    private static func appendResponsesEventPayload(
        _ object: [String: Any],
        textParts: inout [String],
        imageURLs: inout [String]
    ) {
        guard let rawType = object["type"] as? String else { return }
        let type = rawType.lowercased()

        // Responses streaming: text arrives as delta events.
        if type == "response.output_text.delta",
           let delta = object["delta"] as? String,
           !delta.isEmpty {
            textParts.append(delta)
            return
        }

        // Done event usually repeats fully-assembled text; skip to avoid duplication.
        if type == "response.output_text.done" {
            return
        }

        if type == "response.content_part.added" || type == "response.content_part.done" {
            if let part = object["part"] as? [String: Any] {
                var discardTextParts: [String] = []
                appendResponsesContentPart(part, textParts: &discardTextParts, imageURLs: &imageURLs)
            }
            return
        }

        if type == "response.output_item.added" || type == "response.output_item.done" {
            if let item = object["item"] as? [String: Any] {
                var discardTextParts: [String] = []
                appendResponsesOutputItem(item, textParts: &discardTextParts, imageURLs: &imageURLs)
            }
            return
        }

        // `response.completed` often carries the full assembled text again.
        // Keep only media URLs here; text stream should come from delta events.
        if type == "response.completed",
           let response = object["response"] as? [String: Any],
           let output = response["output"] as? [[String: Any]] {
            var discardTextParts: [String] = []
            for item in output {
                appendResponsesOutputItem(item, textParts: &discardTextParts, imageURLs: &imageURLs)
            }
        }
    }

    private static func appendResponsesOutputItem(
        _ item: [String: Any],
        textParts: inout [String],
        imageURLs: inout [String]
    ) {
        if let content = item["content"] as? [[String: Any]] {
            for part in content {
                appendResponsesContentPart(part, textParts: &textParts, imageURLs: &imageURLs)
            }
            return
        }

        appendFromContentNode(item, textParts: &textParts, imageURLs: &imageURLs)
    }

    private static func appendResponsesContentPart(
        _ part: [String: Any],
        textParts: inout [String],
        imageURLs: inout [String]
    ) {
        appendTypedContentItem(part, textParts: &textParts, imageURLs: &imageURLs)

        if let outputText = part["output_text"] as? String, !outputText.isEmpty {
            textParts.append(outputText)
        }
    }

    static func extractCitationURLs(line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let payload: String
        if trimmed.hasPrefix("data:") {
            payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("event:") || trimmed.hasPrefix(":") {
            return []
        } else {
            payload = trimmed
        }

        if payload == "[DONE]" { return [] }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return extractCitationURLs(from: object)
    }

    static func extractCitationURLs(from object: [String: Any]) -> [String] {
        var urls: [String] = []

        appendCitationURLs(from: object["citations"], into: &urls)
        appendCitationURLs(from: object["annotations"], into: &urls)
        appendCitationURLs(from: object["search_results"], into: &urls)
        appendCitationURLs(from: object["sources"], into: &urls)

        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices {
                appendCitationURLs(from: choice["citations"], into: &urls)
                appendCitationURLs(from: choice["annotations"], into: &urls)
                appendCitationURLs(from: choice["search_results"], into: &urls)
                appendCitationURLs(from: choice["sources"], into: &urls)

                if let delta = choice["delta"] as? [String: Any] {
                    appendCitationURLs(from: delta["citations"], into: &urls)
                    appendCitationURLs(from: delta["annotations"], into: &urls)
                    appendCitationURLs(from: delta["search_results"], into: &urls)
                    appendCitationURLs(from: delta["sources"], into: &urls)

                    if let content = delta["content"] as? [[String: Any]] {
                        for item in content {
                            appendCitationURLs(from: item["citations"], into: &urls)
                            appendCitationURLs(from: item["annotations"], into: &urls)
                            appendCitationURLs(from: item["search_results"], into: &urls)
                            appendCitationURLs(from: item["sources"], into: &urls)
                        }
                    }
                }

                if let message = choice["message"] as? [String: Any] {
                    appendCitationURLs(from: message["citations"], into: &urls)
                    appendCitationURLs(from: message["annotations"], into: &urls)
                    appendCitationURLs(from: message["search_results"], into: &urls)
                    appendCitationURLs(from: message["sources"], into: &urls)

                    if let content = message["content"] as? [[String: Any]] {
                        for item in content {
                            appendCitationURLs(from: item["citations"], into: &urls)
                            appendCitationURLs(from: item["annotations"], into: &urls)
                            appendCitationURLs(from: item["search_results"], into: &urls)
                            appendCitationURLs(from: item["sources"], into: &urls)
                        }
                    }
                }
            }
        }

        if let output = object["output"] as? [[String: Any]] {
            for block in output {
                appendCitationURLs(from: block["citations"], into: &urls)
                appendCitationURLs(from: block["annotations"], into: &urls)
                appendCitationURLs(from: block["search_results"], into: &urls)
                appendCitationURLs(from: block["sources"], into: &urls)

                if let content = block["content"] as? [[String: Any]] {
                    for item in content {
                        appendCitationURLs(from: item["citations"], into: &urls)
                        appendCitationURLs(from: item["annotations"], into: &urls)
                        appendCitationURLs(from: item["search_results"], into: &urls)
                        appendCitationURLs(from: item["sources"], into: &urls)
                    }
                }
            }
        }

        return dedupe(urls)
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
            if let imageURLObj = row["image_url"] as? [String: Any],
               let b64 = imageURLObj["b64_json"] as? String,
               !b64.isEmpty {
                imageURLs.append("data:image/png;base64,\(b64)")
            }
            if let b64 = row["b64_json"] as? String, !b64.isEmpty {
                imageURLs.append("data:image/png;base64,\(b64)")
            }
        }
    }

    private static func appendCitationURLs(from node: Any?, into urls: inout [String]) {
        guard let node else { return }

        if let text = node as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isWebURL(trimmed) {
                urls.append(trimmed)
            }
            return
        }

        if let array = node as? [Any] {
            for item in array {
                appendCitationURLs(from: item, into: &urls)
            }
            return
        }

        if let dict = node as? [String: Any] {
            if let url = dict["url"] as? String {
                appendCitationURLs(from: url, into: &urls)
            }
            if let href = dict["href"] as? String {
                appendCitationURLs(from: href, into: &urls)
            }
            if let source = dict["source"] as? String {
                appendCitationURLs(from: source, into: &urls)
            }
            if let webpage = dict["webpage_url"] as? String {
                appendCitationURLs(from: webpage, into: &urls)
            }
            if let canonical = dict["canonical_url"] as? String {
                appendCitationURLs(from: canonical, into: &urls)
            }

            appendCitationURLs(from: dict["citations"], into: &urls)
            appendCitationURLs(from: dict["citation"], into: &urls)
            appendCitationURLs(from: dict["annotations"], into: &urls)
            appendCitationURLs(from: dict["annotation"], into: &urls)
            appendCitationURLs(from: dict["sources"], into: &urls)
            appendCitationURLs(from: dict["source_links"], into: &urls)
            appendCitationURLs(from: dict["search_results"], into: &urls)

            // Responses API events often wrap data under `response`, `item`, `part`, etc.
            // Recursively scanning all values keeps URL extraction resilient to shape changes.
            for value in dict.values {
                appendCitationURLs(from: value, into: &urls)
            }
        }
    }

    private static func isWebURL(_ value: String) -> Bool {
        value.hasPrefix("https://") || value.hasPrefix("http://")
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
