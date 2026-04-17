import Foundation
import SwiftUI

enum MessageSegment: Equatable {
    case text(String)
    case code(language: String?, content: String)
    case image(ChatImageAttachment)
    case file(name: String, language: String?, content: String)
    case divider
}

enum MessageContentParser {
    private struct StreamingParseSnapshot {
        let parsedAt: Date
        let contentLength: Int
        let imageCount: Int
        let fileCount: Int
        let segments: [MessageSegment]
    }

    private static let markdownImagePattern = #"!\[[^\]]*\]\(([^)]+)\)"#
    private static let bareURLPattern = #"(?<!\]\()https?://[^\s\"<>)\]]+"#
    private static let dataImagePattern = #"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+"#
    private static let streamingParseDebounce: TimeInterval = 0.2
    private static let maxCacheEntries = 360
    private static var parseCache: [String: [MessageSegment]] = [:]
    private static var parseCacheOrder: [String] = []
    private static var streamingSnapshots: [UUID: StreamingParseSnapshot] = [:]

    static func parse(_ message: ChatMessage) -> [MessageSegment] {
        if message.isStreaming,
           let snapshot = streamingSnapshots[message.id],
           Date().timeIntervalSince(snapshot.parsedAt) < streamingParseDebounce,
           message.content.count >= snapshot.contentLength,
           message.imageAttachments.count == snapshot.imageCount,
           message.fileAttachments.count == snapshot.fileCount {
            return snapshot.segments
        }

        let signature = cacheSignature(for: message)
        if let cached = parseCache[signature] {
            if message.isStreaming {
                streamingSnapshots[message.id] = StreamingParseSnapshot(
                    parsedAt: Date(),
                    contentLength: message.content.count,
                    imageCount: message.imageAttachments.count,
                    fileCount: message.fileAttachments.count,
                    segments: cached
                )
            }
            return cached
        }

        var segments: [MessageSegment] = []

        for image in message.imageAttachments {
            segments.append(.image(image))
        }

        for file in message.fileAttachments {
            segments.append(.file(name: file.fileName, language: file.codeLanguageHint, content: file.previewText))
        }

        segments.append(contentsOf: parseTextContent(message.content))
        let merged = mergeAdjacentTextSegments(segments)
        storeParseCache(segments: merged, signature: signature)

        if message.isStreaming {
            streamingSnapshots[message.id] = StreamingParseSnapshot(
                parsedAt: Date(),
                contentLength: message.content.count,
                imageCount: message.imageAttachments.count,
                fileCount: message.fileAttachments.count,
                segments: merged
            )
        } else {
            streamingSnapshots.removeValue(forKey: message.id)
        }
        return merged
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
        let dividerTokens = splitMarkdownDividers(in: text)
        if dividerTokens.contains(where: {
            if case .divider = $0 { return true }
            return false
        }) {
            var mergedSegments: [MessageSegment] = []
            for token in dividerTokens {
                switch token {
                case .text(let chunk):
                    mergedSegments.append(contentsOf: parseInlineImagesInSingleChunk(chunk))
                case .divider:
                    mergedSegments.append(.divider)
                }
            }
            return mergedSegments
        }
        return parseInlineImagesInSingleChunk(text)
    }

    private static func parseInlineImagesInSingleChunk(_ text: String) -> [MessageSegment] {
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

    private enum DividerToken {
        case text(String)
        case divider
    }

    private static func splitMarkdownDividers(in text: String) -> [DividerToken] {
        guard let regex = try? NSRegularExpression(pattern: "(?m)^\\s*([-*_])\\1{2,}\\s*$") else {
            return [.text(text)]
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else {
            return [.text(text)]
        }

        var tokens: [DividerToken] = []
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if range.lowerBound > cursor {
                tokens.append(.text(String(text[cursor..<range.lowerBound])))
            }
            tokens.append(.divider)
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            tokens.append(.text(String(text[cursor...])))
        }

        return tokens
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
        let imageSuffixes = [
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp",
            ".heic", ".heif", ".svg", ".avif", ".apng", ".tif", ".tiff", ".ico", ".jxl"
        ]
        if imageSuffixes.contains(where: { cleaned.contains($0) }) { return true }
        let indicators = [
            "/images/", "/image/", "/img/", "/v1/images", "image=", "mime=image/",
            "format=png", "format=jpg", "format=jpeg", "format=webp", "format=avif",
            "b64_json", "generated-image", "/files/"
        ]
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
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = expandGitHubRepositoryLinks(in: text)
        return text
    }

    private static func autoBulletizePlainLineGroups(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.count >= 3 else { return raw }

        var result: [String] = []
        var buffer: [String] = []

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let meaningful = buffer.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if meaningful.count >= 3,
               meaningful.allSatisfy({ line in
                   let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                   if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") { return false }
                   if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return false }
                   if trimmed.count > 28 { return false }
                   return true
               }) {
                for line in buffer {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        result.append(line)
                    } else {
                        result.append("• \(trimmed)")
                    }
                }
            } else {
                result.append(contentsOf: buffer)
            }
            buffer = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                flushBuffer()
                result.append(line)
            } else {
                buffer.append(line)
            }
        }
        flushBuffer()

        return result.joined(separator: "\n")
    }

    private static func expandGitHubRepositoryLinks(in raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!github\.com/)\(([A-Za-z0-9-]{1,39}/[A-Za-z0-9_.-]{1,100})\)"#) else {
            return raw
        }

        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, range: nsRange)
        guard !matches.isEmpty else { return raw }

        var result = raw
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let repoRange = Range(match.range(at: 1), in: result) else { continue }
            let repo = String(result[repoRange])
            let replacement = "(\(repo) · https://github.com/\(repo))"
            result.replaceSubrange(fullRange, with: replacement)
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

    private static func cacheSignature(for message: ChatMessage) -> String {
        let prefix = String(message.content.prefix(120))
        let suffix = String(message.content.suffix(120))
        let prefixHash = prefix.hashValue
        let suffixHash = suffix.hashValue
        return [
            message.id.uuidString,
            message.role.rawValue,
            String(message.content.count),
            String(prefixHash),
            String(suffixHash),
            String(message.imageAttachments.count),
            String(message.fileAttachments.count),
            message.isStreaming ? "1" : "0"
        ].joined(separator: "|")
    }

    private static func storeParseCache(segments: [MessageSegment], signature: String) {
        parseCache[signature] = segments
        if !parseCacheOrder.contains(signature) {
            parseCacheOrder.append(signature)
        }

        while parseCacheOrder.count > maxCacheEntries {
            let oldest = parseCacheOrder.removeFirst()
            parseCache.removeValue(forKey: oldest)
        }

        if !streamingSnapshots.isEmpty && streamingSnapshots.count > 80 {
            let sortedKeys = streamingSnapshots.keys.sorted { lhs, rhs in
                let left = streamingSnapshots[lhs]?.parsedAt ?? .distantPast
                let right = streamingSnapshots[rhs]?.parsedAt ?? .distantPast
                return left < right
            }
            let removeCount = max(0, streamingSnapshots.count - 80)
            if removeCount > 0 {
                for key in sortedKeys.prefix(removeCount) {
                    streamingSnapshots.removeValue(forKey: key)
                }
            }
        }
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
