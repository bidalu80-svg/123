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
    struct Palette {
        let plain: Color
        let keyword: Color
        let string: Color
        let number: Color
        let comment: Color
        let function: Color
        let type: Color
    }

    static func highlighted(_ code: String, language: String?, colorScheme: ColorScheme, codeThemeMode: CodeThemeMode) -> AttributedString {
        var result = AttributedString(code)
        let resolvedDarkMode: Bool = {
            switch codeThemeMode {
            case .vscodeDark:
                return true
            case .githubLight:
                return false
            case .followApp:
                return colorScheme == .dark
            }
        }()

        let palette: Palette = resolvedDarkMode
            ? Palette(
                plain: Color(red: 0.83, green: 0.84, blue: 0.86),
                keyword: Color(red: 0.77, green: 0.53, blue: 0.75),
                string: Color(red: 0.81, green: 0.57, blue: 0.47),
                number: Color(red: 0.71, green: 0.81, blue: 0.66),
                comment: Color(red: 0.42, green: 0.60, blue: 0.33),
                function: Color(red: 0.86, green: 0.86, blue: 0.48),
                type: Color(red: 0.31, green: 0.79, blue: 0.69)
            )
            : Palette(
                plain: Color(red: 0.14, green: 0.16, blue: 0.18),
                keyword: Color(red: 0.69, green: 0.00, blue: 0.86),
                string: Color(red: 0.64, green: 0.08, blue: 0.08),
                number: Color(red: 0.04, green: 0.53, blue: 0.34),
                comment: Color(red: 0.42, green: 0.45, blue: 0.49),
                function: Color(red: 0.47, green: 0.37, blue: 0.15),
                type: Color(red: 0.15, green: 0.50, blue: 0.60)
            )

        result.foregroundColor = palette.plain

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

        applyColor(palette.comment, pattern: "(?m)#.*$|//.*$", to: &result)
        applyColor(palette.comment, pattern: "(?s)/\\*.*?\\*/", to: &result)
        applyColor(palette.string, pattern: "\"(\\\\.|[^\"])*\"|'(\\\\.|[^'])*'", to: &result)
        applyColor(palette.number, pattern: "\\b\\d+(\\.\\d+)?\\b", to: &result)
        applyColor(palette.keyword, pattern: "\\b(\(keywordSet.joined(separator: "|")))\\b", to: &result)
        applyColor(palette.type, pattern: "\\b([A-Z][A-Za-z0-9_]*)\\b", to: &result)
        applyColor(palette.function, pattern: "\\b([a-zA-Z_][A-Za-z0-9_]*)\\s*(?=\\()", to: &result)
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
