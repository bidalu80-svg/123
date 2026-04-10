import Foundation

struct StreamChunk: Equatable {
    let rawLine: String
    let delta: String?
    let isDone: Bool
}

enum StreamParser {
    static func parse(line: String) -> StreamChunk? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)

        if payload == "[DONE]" {
            return StreamChunk(rawLine: line, delta: nil, isDone: true)
        }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else {
            return StreamChunk(rawLine: line, delta: nil, isDone: false)
        }

        return StreamChunk(
            rawLine: line,
            delta: delta["content"] as? String,
            isDone: false
        )
    }
}
