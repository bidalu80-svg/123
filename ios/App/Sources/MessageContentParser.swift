import Foundation
import SwiftUI

enum MessageSegment: Equatable {
    case text(String)
    case code(language: String?, content: String)
    case image(ChatImageAttachment)
}

enum MessageContentParser {
    static func parse(_ message: ChatMessage) -> [MessageSegment] {
        var segments = message.attachments.map { MessageSegment.image($0) }
        segments.append(contentsOf: parseTextContent(message.content))
        return segments
    }

    private static func parseTextContent(_ raw: String) -> [MessageSegment] {
        guard !raw.isEmpty else { return [] }

        var results: [MessageSegment] = []
        var cursor = raw.startIndex

        while let fenceStart = raw[cursor...].range(of: "```") {
            let plainPrefix = String(raw[cursor..<fenceStart.lowerBound])
            if !plainPrefix.isEmpty {
                results.append(contentsOf: parseInlineImages(in: plainPrefix))
            }

            let afterFence = fenceStart.upperBound
            guard let fenceEnd = raw[afterFence...].range(of: "```") else {
                let remain = String(raw[fenceStart.lowerBound...])
                if !remain.isEmpty {
                    results.append(contentsOf: parseInlineImages(in: remain))
                }
                return results
            }

            let block = String(raw[afterFence..<fenceEnd.lowerBound])
            let (language, code) = parseCodeBlock(block)
            results.append(.code(language: language, content: code))
            cursor = fenceEnd.upperBound
        }

        let tail = String(raw[cursor...])
        if !tail.isEmpty {
            results.append(contentsOf: parseInlineImages(in: tail))
        }
        return results
    }

    private static func parseCodeBlock(_ block: String) -> (String?, String) {
        var normalized = block
        if normalized.hasPrefix("\n") {
            normalized.removeFirst()
        }

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (nil, "") }

        let maybeLanguage = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if maybeLanguage.contains(" ") {
            return (nil, normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let body = lines.dropFirst().joined(separator: "\n")
        if body.isEmpty {
            return (nil, normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (maybeLanguage.isEmpty ? nil : maybeLanguage, body)
    }

    private static func parseInlineImages(in text: String) -> [MessageSegment] {
        let pattern = #"!\[[^\]]*\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return [.text(text)] }

        var results: [MessageSegment] = []
        var cursor = text.startIndex

        for match in matches {
            guard
                let wholeRange = Range(match.range, in: text),
                let urlRange = Range(match.range(at: 1), in: text)
            else { continue }

            let plain = String(text[cursor..<wholeRange.lowerBound])
            if !plain.isEmpty {
                results.append(.text(plain))
            }

            let url = String(text[urlRange])
            results.append(.image(ChatImageAttachment(dataURL: url, mimeType: "image/*", remoteURL: url)))
            cursor = wholeRange.upperBound
        }

        let tail = String(text[cursor...])
        if !tail.isEmpty {
            results.append(.text(tail))
        }
        return results
    }
}

enum CodeHighlighter {
    static func highlighted(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = .primary

        let normalizedLanguage = (language ?? "").lowercased()
        let keywordSet: [String]

        switch normalizedLanguage {
        case "swift":
            keywordSet = ["let", "var", "func", "struct", "class", "enum", "if", "else", "guard", "return", "import", "protocol", "extension"]
        case "python", "py":
            keywordSet = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "try", "except", "with", "as"]
        case "javascript", "js", "typescript", "ts":
            keywordSet = ["const", "let", "var", "function", "class", "if", "else", "return", "import", "export", "async", "await"]
        case "json":
            keywordSet = ["true", "false", "null"]
        default:
            keywordSet = ["if", "else", "for", "while", "return", "class", "func", "def", "const", "let", "var", "import"]
        }

        applyColor(.blue, pattern: "\\b(\(keywordSet.joined(separator: "|")))\\b", to: &result)
        applyColor(.orange, pattern: "\"(\\\\.|[^\"])*\"", to: &result)
        applyColor(.green, pattern: "\\b\\d+(\\.\\d+)?\\b", to: &result)
        return result
    }

    private static func applyColor(_ color: Color, pattern: String, to target: inout AttributedString) {
        let plain = String(target.characters)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in regex.matches(in: plain, range: nsRange) {
            guard let range = Range(match.range, in: plain),
                  let attrRange = Range(range, in: target) else { continue }
            target[attrRange].foregroundColor = color
        }
    }
}
