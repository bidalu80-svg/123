import Foundation
import SwiftUI

enum MessageSegment: Equatable {
    case text(String)
    case code(language: String?, content: String)
    case image(ChatImageAttachment)
    case file(name: String, language: String?, content: String)
}

enum MessageContentParser {
    private static let markdownImagePattern = #"!\[[^\]]*\]\(([^)]+)\)"#
    private static let bareURLPattern = #"https?://[^\s\"<>)\]]+"#
    private static let codeFencePattern = #"(?s)```(.*?)```"#

    static func parse(_ message: ChatMessage) -> [MessageSegment] {
        var segments: [MessageSegment] = []

        for image in message.imageAttachments {
            segments.append(.image(image))
        }

        for file in message.fileAttachments {
            segments.append(.file(name: file.fileName, language: file.codeLanguageHint, content: file.previewText))
        }

        segments.append(contentsOf: parseTextContent(message.content))
        return mergeAdjacentTextSegments(segments)
    }

    static func extractInlineImageURLs(from text: String) -> [String] {
        var results: [String] = []
        let markdownMatches = findMatches(in: text, pattern: markdownImagePattern)
        results.append(contentsOf: markdownMatches.map(\.value))

        let bareMatches = findMatches(in: text, pattern: bareURLPattern)
            .map(\.value)
            .filter { isLikelyImageURL($0) }
        results.append(contentsOf: bareMatches)

        return dedupe(results)
    }

    private static func parseTextContent(_ raw: String) -> [MessageSegment] {
        guard !raw.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: codeFencePattern) else {
            return parseInlineImages(in: raw)
        }

        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, range: range)
        guard !matches.isEmpty else { return parseInlineImages(in: raw) }

        var segments: [MessageSegment] = []
        var cursor = raw.startIndex

        for match in matches {
            guard let wholeRange = Range(match.range, in: raw) else { continue }

            let leadingText = String(raw[cursor..<wholeRange.lowerBound])
            if !leadingText.isEmpty {
                segments.append(contentsOf: parseInlineImages(in: leadingText))
            }

            if let codeRange = Range(match.range(at: 1), in: raw) {
                let parsed = parseCodeBlock(String(raw[codeRange]))
                if !parsed.1.isEmpty {
                    segments.append(.code(language: parsed.0, content: parsed.1))
                }
            }

            cursor = wholeRange.upperBound
        }

        let trailingText = String(raw[cursor...])
        if !trailingText.isEmpty {
            segments.append(contentsOf: parseInlineImages(in: trailingText))
        }
        return segments
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
        let tokenPattern = "\(markdownImagePattern)|(\(bareURLPattern))"
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else {
            return [.text(text)]
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return [.text(text)] }

        var results: [MessageSegment] = []
        var cursor = text.startIndex

        for match in matches {
            guard let wholeRange = Range(match.range, in: text) else { continue }

            let plain = String(text[cursor..<wholeRange.lowerBound])
            if !plain.isEmpty {
                results.append(.text(plain))
            }

            let url: String?
            if let markdownURLRange = Range(match.range(at: 1), in: text) {
                url = String(text[markdownURLRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let bareURLRange = Range(match.range(at: 2), in: text) {
                let candidate = String(text[bareURLRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                url = isLikelyImageURL(candidate) ? candidate : nil
            } else {
                url = nil
            }

            if let url, !url.isEmpty {
                results.append(.image(ChatImageAttachment(dataURL: url, mimeType: "image/*", remoteURL: url)))
            }
            cursor = wholeRange.upperBound
        }

        let tail = String(text[cursor...])
        if !tail.isEmpty {
            results.append(.text(tail))
        }
        return results
    }

    private static func findMatches(in text: String, pattern: String) -> [(range: NSRange, value: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            if match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) {
                return (match.range, String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let range = Range(match.range, in: text) {
                return (match.range, String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
    }

    private static func isLikelyImageURL(_ rawURL: String) -> Bool {
        let cleaned = rawURL.lowercased()
        if cleaned.contains("data:image") { return true }

        let imageSuffixes = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif", ".svg"]
        if imageSuffixes.contains(where: { cleaned.contains($0) }) { return true }

        let indicators = ["/images/", "/image/", "/img/", "/v1/images", "image=", "format=png", "format=jpg", "b64_json", "generated-image", "/files/"]
        return indicators.contains(where: { cleaned.contains($0) })
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            if value.isEmpty || seen.contains(value) { continue }
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private static func mergeAdjacentTextSegments(_ segments: [MessageSegment]) -> [MessageSegment] {
        var merged: [MessageSegment] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                if case .text(let previous)? = merged.last {
                    merged.removeLast()
                    merged.append(.text(previous + text))
                } else {
                    merged.append(.text(text))
                }
            default:
                merged.append(segment)
            }
        }
        return merged
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
