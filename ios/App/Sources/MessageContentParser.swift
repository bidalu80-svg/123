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
    private static let bareURLPattern = #"(?<!\]\()https?://[^\s\"<>)\]]+"#
    private static let dataImagePattern = #"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+"#

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
        var collected: [String] = []
        collected.append(contentsOf: findMatches(in: text, pattern: markdownImagePattern))
        collected.append(contentsOf: findMatches(in: text, pattern: dataImagePattern))
        collected.append(contentsOf: findMatches(in: text, pattern: bareURLPattern).filter {
            isLikelyImageURL($0) || isStandaloneURLLine(in: text, url: $0)
        })
        return dedupe(collected)
    }

    private static func parseTextContent(_ raw: String) -> [MessageSegment] {
        guard !raw.isEmpty else { return [] }
        var segments: [MessageSegment] = []
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            guard let fenceStart = raw[cursor...].range(of: "```") else {
                let trailingText = String(raw[cursor...])
                if !trailingText.isEmpty {
                    segments.append(contentsOf: parseInlineImages(in: trailingText))
                }
                break
            }

            if fenceStart.lowerBound > cursor {
                let leadingText = String(raw[cursor..<fenceStart.lowerBound])
                segments.append(contentsOf: parseInlineImages(in: leadingText))
            }

            let codeStart = fenceStart.upperBound
            if let fenceEnd = raw[codeStart...].range(of: "```") {
                let block = String(raw[codeStart..<fenceEnd.lowerBound])
                let parsed = parseCodeBlock(block)
                if !parsed.1.isEmpty {
                    segments.append(.code(language: parsed.0, content: parsed.1))
                }
                cursor = fenceEnd.upperBound
            } else {
                // Streaming unfinished fence: enter code module immediately.
                let block = String(raw[codeStart...])
                let parsed = parseCodeBlock(block)
                if !parsed.1.isEmpty {
                    segments.append(.code(language: parsed.0, content: parsed.1))
                }
                break
            }
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
        let tokenPattern = "\(markdownImagePattern)|(\(bareURLPattern))|(\(dataImagePattern))"
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else {
            return [.text(cleanMarkdownForDisplay(text))]
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return [.text(cleanMarkdownForDisplay(text))] }

        var results: [MessageSegment] = []
        var cursor = text.startIndex

        for match in matches {
            guard let wholeRange = Range(match.range, in: text) else { continue }

            let plain = String(text[cursor..<wholeRange.lowerBound])
            if !plain.isEmpty {
                let normalizedPlain = cleanMarkdownForDisplay(plain)
                if !normalizedPlain.isEmpty {
                    results.append(.text(normalizedPlain))
                }
            }

            let imageURL: String?
            let fallbackText: String?
            if let markdownURLRange = Range(match.range(at: 1), in: text) {
                imageURL = String(text[markdownURLRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                fallbackText = nil
            } else if let bareURLRange = Range(match.range(at: 2), in: text) {
                let candidate = String(text[bareURLRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if isLikelyImageURL(candidate) {
                    imageURL = candidate
                    fallbackText = nil
                } else {
                    imageURL = nil
                    fallbackText = candidate
                }
            } else if let dataRange = Range(match.range(at: 3), in: text) {
                let candidate = String(text[dataRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                imageURL = candidate.hasPrefix("data:image") ? candidate : nil
                fallbackText = nil
            } else {
                imageURL = nil
                fallbackText = nil
            }

            if let imageURL, !imageURL.isEmpty {
                results.append(.image(ChatImageAttachment(dataURL: imageURL, mimeType: "image/*", remoteURL: imageURL)))
            } else if let fallbackText, !fallbackText.isEmpty {
                let normalizedFallback = cleanMarkdownForDisplay(fallbackText)
                if !normalizedFallback.isEmpty {
                    results.append(.text(normalizedFallback))
                }
            }
            cursor = wholeRange.upperBound
        }

        let tail = String(text[cursor...])
        if !tail.isEmpty {
            let normalizedTail = cleanMarkdownForDisplay(tail)
            if !normalizedTail.isEmpty {
                results.append(.text(normalizedTail))
            }
        }
        return results
    }

    private static func findMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            if match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: text) {
                return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let range = Range(match.range, in: text) {
                return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
    }

    private static func isLikelyImageURL(_ rawURL: String) -> Bool {
        let cleaned = rawURL.lowercased()
        if cleaned.hasPrefix("data:image") { return true }
        let imageSuffixes = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif", ".svg"]
        if imageSuffixes.contains(where: { cleaned.contains($0) }) { return true }
        let indicators = ["/images/", "/image/", "/img/", "/v1/images", "image=", "format=png", "format=jpg", "b64_json", "generated-image", "/files/"]
        return indicators.contains(where: { cleaned.contains($0) })
    }

    private static func isStandaloneURLLine(in text: String, url: String) -> Bool {
        guard let range = text.range(of: url) else { return false }
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return line == url
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

    private static func cleanMarkdownForDisplay(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*•]\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*\\d+[\\.)、]\\s+", with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*>\\s?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*([-*_])\\1{2,}\\s*$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text
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
