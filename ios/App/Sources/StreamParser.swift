import Foundation

struct StreamChunk: Equatable {
    let rawLine: String
    let deltaText: String
    let imageURLs: [String]
    let isDone: Bool
}

enum StreamParser {
    static func parse(line: String) -> StreamChunk? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)

        if payload == "[DONE]" {
            return StreamChunk(rawLine: line, deltaText: "", imageURLs: [], isDone: true)
        }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            return StreamChunk(rawLine: line, deltaText: "", imageURLs: [], isDone: false)
        }

        let delta = first["delta"] as? [String: Any] ?? [:]
        let parsed = parseDelta(delta)
        return StreamChunk(rawLine: line, deltaText: parsed.text, imageURLs: parsed.imageURLs, isDone: false)
    }

    private static func parseDelta(_ delta: [String: Any]) -> (text: String, imageURLs: [String]) {
        var textParts: [String] = []
        var imageURLs: [String] = []

        if let contentText = delta["content"] as? String, !contentText.isEmpty {
            textParts.append(contentText)
        }

        if let contentArray = delta["content"] as? [[String: Any]] {
            for item in contentArray {
                let type = (item["type"] as? String)?.lowercased() ?? ""
                if (type == "text" || type == "output_text"), let text = item["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
                if (type == "image_url" || type == "output_image"),
                   let image = item["image_url"] as? [String: Any],
                   let url = image["url"] as? String,
                   !url.isEmpty {
                    imageURLs.append(url)
                }
            }
        }

        if let output = delta["output_text"] as? String, !output.isEmpty {
            textParts.append(output)
        }

        return (textParts.joined(), imageURLs)
    }
}
