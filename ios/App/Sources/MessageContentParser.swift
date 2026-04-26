import Foundation
import SwiftUI

enum MessageSegment: Equatable {
    case text(String)
    case code(language: String?, content: String)
    case table(headers: [String], rows: [[String]])
    case image(ChatImageAttachment)
    case video(ChatVideoAttachment)
    case file(name: String, language: String?, content: String)
    case divider
}

enum MessageContentParser {
    private struct StreamingParseSnapshot {
        let parsedAt: Date
        let contentLength: Int
        let imageCount: Int
        let videoCount: Int
        let fileCount: Int
        let segments: [MessageSegment]
    }

    private static let markdownImagePattern = #"!\[[^\]]*\]\(([^)]+)\)"#
    private static let bareURLPattern = #"(?<!\]\()https?://[^\s\"<>)\]]+"#
    private static let dataImagePattern = #"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=]+"#
    private static let streamingParseDebounce: TimeInterval = 0.045
    private static let mediumStreamingParseDebounce: TimeInterval = 0.12
    private static let longStreamingParseDebounce: TimeInterval = 0.22
    private static let ultraStreamingParseDebounce: TimeInterval = 0.32
    private static let mediumStreamingContentThreshold = 7_000
    private static let longStreamingContentThreshold = 16_000
    private static let ultraStreamingContentThreshold = 32_000
    private static let nonStreamingCacheContentThreshold = 8_000
    private static let maxCachedSegmentsPerEntry = 140
    private static let maxCacheEntries = 72
    private static let maxStreamingSnapshots = 4
    private static let streamingSnapshotTTL: TimeInterval = 2.5
    private static let languageTagAliases: [String: String] = [
        "go": "go",
        "golang": "go",
        "python": "python",
        "py": "python",
        "javascript": "javascript",
        "js": "javascript",
        "node": "javascript",
        "nodejs": "javascript",
        "typescript": "typescript",
        "ts": "typescript",
        "java": "java",
        "kotlin": "kotlin",
        "swift": "swift",
        "rust": "rust",
        "rs": "rust",
        "c": "c",
        "cpp": "cpp",
        "c++": "cpp",
        "cxx": "cpp",
        "c#": "csharp",
        "cs": "csharp",
        "php": "php",
        "ruby": "ruby",
        "sql": "sql",
        "bash": "bash",
        "shell": "bash",
        "sh": "bash",
        "json": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "xml": "xml",
        "html": "html",
        "css": "css",
        "markdown": "markdown",
        "md": "markdown"
    ]
    private static let weakLanguageLabels: Set<String> = [
        "text", "txt", "plain", "plaintext", "markdown", "md"
    ]
    private static let strongLanguageLabels: Set<String> = [
        "go", "python", "javascript", "typescript", "java", "kotlin", "swift",
        "rust", "c", "cpp", "csharp", "php", "ruby", "sql", "bash",
        "shell", "json", "yaml", "xml", "html", "css"
    ]
    private static var parseCache: [String: [MessageSegment]] = [:]
    private static var parseCacheOrder: [String] = []
    private static var streamingSnapshots: [UUID: StreamingParseSnapshot] = [:]

    private enum StructuredTokenKind {
        case fencedCode
        case taggedFile
    }

    private struct StructuredToken {
        let kind: StructuredTokenKind
        let range: Range<String.Index>
    }

    private struct ParsedTaggedFileSegment {
        let name: String
        let language: String?
        let content: String
        let nextCursor: String.Index
    }

    static func parse(_ message: ChatMessage) -> [MessageSegment] {
        let now = Date()
        pruneStreamingSnapshots(now: now)
        trimParseCacheForStreamingPressureIfNeeded(message: message)

        let effectiveStreamingDebounce: TimeInterval = {
            guard message.isStreaming else { return streamingParseDebounce }
            if message.content.count >= ultraStreamingContentThreshold {
                return ultraStreamingParseDebounce
            }
            if message.content.count >= longStreamingContentThreshold {
                return longStreamingParseDebounce
            }
            if message.content.count >= mediumStreamingContentThreshold {
                return mediumStreamingParseDebounce
            }
            return streamingParseDebounce
        }()

        if message.isStreaming,
           let snapshot = streamingSnapshots[message.id],
           now.timeIntervalSince(snapshot.parsedAt) < effectiveStreamingDebounce,
           message.content.count >= snapshot.contentLength,
           message.imageAttachments.count == snapshot.imageCount,
           message.videoAttachments.count == snapshot.videoCount,
           message.fileAttachments.count == snapshot.fileCount {
            return snapshot.segments
        }

        let signature: String? = {
            guard !message.isStreaming else { return nil }
            guard message.content.count <= nonStreamingCacheContentThreshold else { return nil }
            return cacheSignature(for: message)
        }()
        if let signature, let cached = parseCache[signature] {
            return cached
        }

        var segments: [MessageSegment] = []

        for image in message.imageAttachments {
            segments.append(.image(image))
        }

        for video in message.videoAttachments {
            segments.append(.video(video))
        }

        for file in message.fileAttachments {
            segments.append(.file(name: file.fileName, language: file.codeLanguageHint, content: file.previewText))
        }

        segments.append(contentsOf: parseTextContent(message.content, allowUnclosedFencedCode: message.isStreaming))
        let merged = mergeAdjacentTextSegments(segments)
        let stitched = mergeTrailingCodeLikeTextSegments(merged)
        let sectioned = sectionizeAssistantLongTextSegments(
            stitched,
            role: message.role,
            isStreaming: message.isStreaming
        )

        if message.isStreaming {
            streamingSnapshots[message.id] = StreamingParseSnapshot(
                parsedAt: now,
                contentLength: message.content.count,
                imageCount: message.imageAttachments.count,
                videoCount: message.videoAttachments.count,
                fileCount: message.fileAttachments.count,
                segments: sectioned
            )
        } else if let signature {
            storeParseCache(segments: sectioned, signature: signature)
            streamingSnapshots.removeValue(forKey: message.id)
        } else {
            streamingSnapshots.removeValue(forKey: message.id)
        }
        return sectioned
    }

    private static func trimParseCacheForStreamingPressureIfNeeded(message: ChatMessage) {
        guard message.isStreaming, message.content.count >= mediumStreamingContentThreshold else { return }
        let targetCacheCount = max(24, maxCacheEntries / 3)
        while parseCacheOrder.count > targetCacheCount {
            let key = parseCacheOrder.removeFirst()
            parseCache.removeValue(forKey: key)
        }
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

    private static func parseTextContent(_ raw: String, allowUnclosedFencedCode: Bool) -> [MessageSegment] {
        guard !raw.isEmpty else { return [] }
        var segments: [MessageSegment] = []
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            guard let token = nextStructuredToken(in: raw, from: cursor) else {
                let trailingText = String(raw[cursor...])
                if !trailingText.isEmpty {
                    segments.append(contentsOf: parseTablesAndInlineImages(in: trailingText))
                }
                break
            }

            if token.range.lowerBound > cursor {
                let leadingText = String(raw[cursor..<token.range.lowerBound])
                segments.append(contentsOf: parseTablesAndInlineImages(in: leadingText))
            }

            switch token.kind {
            case .fencedCode:
                let codeStart = token.range.upperBound
                if let fenceEnd = raw[codeStart...].range(of: "```") {
                    let block = String(raw[codeStart..<fenceEnd.lowerBound])
                    appendParsedCodeFenceSegments(
                        parseCodeBlock(block),
                        allowMixedNarrationSplit: true,
                        to: &segments
                    )
                    cursor = fenceEnd.upperBound
                } else {
                    // Streaming unfinished fence: enter code module immediately.
                    let block = String(raw[codeStart...])
                    let parsed = parseCodeBlock(block)
                    if allowUnclosedFencedCode {
                        appendParsedCodeFenceSegments(
                            parsed,
                            allowMixedNarrationSplit: true,
                            to: &segments
                        )
                    } else if !parsed.1.isEmpty {
                        let inferredLanguage = inferCodeLanguage(language: parsed.0, content: parsed.1)
                        let split = splitLikelyCodePrefix(
                            from: parsed.1,
                            languageHint: inferredLanguage ?? parsed.0
                        )
                        if !split.code.isEmpty,
                           isLikelyStructuredCodeContent(languageHint: inferredLanguage ?? parsed.0, content: split.code) {
                            segments.append(.code(language: inferredLanguage, content: split.code))
                        }
                        if !split.remainder.isEmpty {
                            segments.append(contentsOf: parseTablesAndInlineImages(in: split.remainder))
                        }
                    }
                    cursor = raw.endIndex
                }
            case .taggedFile:
                guard let parsed = parseTaggedFileSegment(in: raw, from: token.range.lowerBound) else {
                    let trailingText = String(raw[token.range.lowerBound...])
                    if !trailingText.isEmpty {
                        segments.append(contentsOf: parseTablesAndInlineImages(in: trailingText))
                    }
                    cursor = raw.endIndex
                    continue
                }
                segments.append(.file(name: parsed.name, language: parsed.language, content: parsed.content))
                cursor = parsed.nextCursor
            }
        }
        return segments
    }

    private static func nextStructuredToken(in raw: String, from start: String.Index) -> StructuredToken? {
        let fenceStart = raw[start...].range(of: "```")
        let taggedFileStart = raw[start...].range(of: "[[file:", options: [.caseInsensitive])

        switch (fenceStart, taggedFileStart) {
        case let (.some(fence), .some(tagged)):
            if tagged.lowerBound <= fence.lowerBound {
                return StructuredToken(kind: .taggedFile, range: tagged)
            }
            return StructuredToken(kind: .fencedCode, range: fence)
        case let (.some(fence), .none):
            return StructuredToken(kind: .fencedCode, range: fence)
        case let (.none, .some(tagged)):
            return StructuredToken(kind: .taggedFile, range: tagged)
        case (.none, .none):
            return nil
        }
    }

    private static func parseTaggedFileSegment(
        in raw: String,
        from start: String.Index
    ) -> ParsedTaggedFileSegment? {
        let tagOpener = "[[file:"
        guard raw[start...].range(of: tagOpener, options: [.anchored, .caseInsensitive]) != nil else {
            return nil
        }

        let headerStart = raw.index(start, offsetBy: tagOpener.count)
        guard let headerEnd = raw[headerStart...].range(of: "]]") else {
            return nil
        }

        let name = normalizeTaggedFileName(String(raw[headerStart..<headerEnd.lowerBound]))
        guard !name.isEmpty else { return nil }

        var contentStart = headerEnd.upperBound
        if raw[contentStart...].hasPrefix("\r\n") {
            contentStart = raw.index(contentStart, offsetBy: 2)
        } else if contentStart < raw.endIndex, raw[contentStart] == "\n" {
            contentStart = raw.index(after: contentStart)
        }

        let endTagRange = raw[contentStart...].range(of: "[[endfile]]", options: [.caseInsensitive])
        let contentEnd = endTagRange?.lowerBound ?? raw.endIndex
        let rawContent = String(raw[contentStart..<contentEnd])
        let normalizedRawContent = rawContent
            .replacingOccurrences(of: "\r\n", with: "\n")
        let preparedRawContent = trimCodeBoundaryBlankLines(normalizedRawContent)
        let content = unwrapSingleFencedTaggedFileContent(preparedRawContent)

        if content.isEmpty && endTagRange == nil {
            return nil
        }

        let language = inferTaggedFileLanguage(fileName: name, content: content)
        return ParsedTaggedFileSegment(
            name: name,
            language: language,
            content: content,
            nextCursor: endTagRange?.upperBound ?? raw.endIndex
        )
    }

    private static func normalizeTaggedFileName(_ rawName: String) -> String {
        rawName
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`'\"")))
            .replacingOccurrences(of: "\\", with: "/")
    }

    private static func inferTaggedFileLanguage(fileName: String, content: String) -> String? {
        let attachment = ChatFileAttachment(
            fileName: fileName,
            mimeType: "text/plain",
            textContent: content
        )
        return attachment.codeLanguageHint ?? inferCodeLanguage(language: nil, content: content)
    }

    private static func unwrapSingleFencedTaggedFileContent(_ raw: String) -> String {
        let normalized = trimCodeBoundaryBlankLines(raw)
        guard normalized.hasPrefix("```"), normalized.hasSuffix("```") else {
            return normalized
        }

        var inner = String(normalized.dropFirst(3))
        guard inner.count >= 3 else { return normalized }
        inner.removeLast(3)
        let parsed = parseCodeBlock(inner)
        let content = trimCodeBoundaryBlankLines(parsed.1)
        return content.isEmpty ? normalized : content
    }

    private struct ParsedMarkdownTable {
        let headers: [String]
        let rows: [[String]]
        let consumedLineCount: Int
    }

    private static func parseTablesAndInlineImages(in text: String) -> [MessageSegment] {
        guard !text.isEmpty else { return [] }

        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else {
            return parseInlineImagesAndImplicitCode(in: text)
        }

        var segments: [MessageSegment] = []
        var textBuffer: [String] = []
        var index = 0

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else { return }
            let chunk = textBuffer.joined(separator: "\n")
            segments.append(contentsOf: parseInlineImagesAndImplicitCode(in: chunk))
            textBuffer.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            if let parsedTable = parseMarkdownTable(lines: lines, start: index) {
                flushTextBuffer()
                let headers = parsedTable.headers.map(cleanTableCell)
                let rows = parsedTable.rows.map { row in row.map(cleanTableCell) }
                segments.append(.table(headers: headers, rows: rows))
                index += parsedTable.consumedLineCount
                continue
            }

            textBuffer.append(lines[index])
            index += 1
        }

        flushTextBuffer()
        return segments
    }

    private static func appendParsedCodeFenceSegments(
        _ parsed: (String?, String),
        allowMixedNarrationSplit: Bool,
        to segments: inout [MessageSegment]
    ) {
        let (language, content) = parsed
        guard !content.isEmpty else { return }

        if let table = parseDelimitedTableFromCode(language: language, content: content) {
            segments.append(.table(headers: table.headers, rows: table.rows))
            return
        }

        let inferredLanguage = inferCodeLanguage(language: language, content: content)
        let languageHint = inferredLanguage ?? language

        if allowMixedNarrationSplit,
           let mixedSplit = splitMixedCodeAndNarration(from: content, languageHint: languageHint) {
            segments.append(.code(language: inferredLanguage, content: mixedSplit.code))
            segments.append(contentsOf: parseTablesAndInlineImages(in: mixedSplit.remainder))
            return
        }

        if isLikelyStructuredCodeContent(languageHint: languageHint, content: content) {
            segments.append(.code(language: inferredLanguage, content: content))
        } else {
            segments.append(contentsOf: parseTablesAndInlineImages(in: content))
        }
    }

    private static func parseInlineImagesAndImplicitCode(in text: String) -> [MessageSegment] {
        let promoted = parseLanguageMarkerCodeBlocks(in: text)
        var output: [MessageSegment] = []
        output.reserveCapacity(promoted.count)

        for segment in promoted {
            switch segment {
            case .text(let raw):
                output.append(contentsOf: parseInlineImages(in: raw))
            default:
                output.append(segment)
            }
        }
        return output
    }

    private static func parseLanguageMarkerCodeBlocks(in text: String) -> [MessageSegment] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.count >= 2 else { return [.text(text)] }

        var segments: [MessageSegment] = []
        var textBuffer: [String] = []
        var index = 0

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else { return }
            let joined = textBuffer.joined(separator: "\n")
            if !joined.isEmpty {
                segments.append(.text(joined))
            }
            textBuffer.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            if let parsed = parseLanguageMarkerCodeRun(lines: lines, start: index) {
                flushTextBuffer()
                segments.append(.code(language: parsed.language, content: parsed.content))
                index = parsed.nextIndex
                continue
            }

            textBuffer.append(lines[index])
            index += 1
        }

        flushTextBuffer()
        return segments
    }

    private static func parseLanguageMarkerCodeRun(
        lines: [String],
        start: Int
    ) -> (language: String?, content: String, nextIndex: Int)? {
        guard start < lines.count else { return nil }
        let markerLine = lines[start].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markerLine.isEmpty else { return nil }

        let normalizedMarker = markerLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
            .lowercased()
        guard let language = languageTagAliases[normalizedMarker] else { return nil }

        var cursor = start + 1
        var collected: [String] = []
        var strongCodeLineCount = 0
        var weakCodeLineCount = 0
        var nonEmptyCount = 0

        while cursor < lines.count {
            let rawLine = lines[cursor]
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                if collected.isEmpty {
                    cursor += 1
                    continue
                }

                if let nextIndex = nextNonEmptyLineIndex(in: lines, from: cursor + 1) {
                    let nextRaw = lines[nextIndex]
                    let nextTrimmed = nextRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isLikelyCodeLine(nextTrimmed)
                        || isLikelyCodeContinuationLine(nextTrimmed)
                        || isLikelyIndentedCodeContinuationLine(rawLine: nextRaw, trimmed: nextTrimmed) {
                        collected.append(rawLine)
                        cursor += 1
                        continue
                    }
                }

                break
            }

            if trimmed == "```" || trimmed == "``" {
                cursor += 1
                break
            }

            let strongCode = isStrongCodeLine(trimmed)
            let weakCode = isLikelyCodeLine(trimmed) || isLikelyInlineCommentedCodeLine(trimmed)
            if strongCode
                || weakCode
                || isLikelyCodeContinuationLine(trimmed)
                || isLikelyIndentedCodeContinuationLine(rawLine: rawLine, trimmed: trimmed) {
                collected.append(rawLine)
                nonEmptyCount += 1
                if strongCode {
                    strongCodeLineCount += 1
                } else if weakCode {
                    weakCodeLineCount += 1
                }
                cursor += 1
                continue
            }

            break
        }

        guard !collected.isEmpty else { return nil }
        let hasStrongLanguageHint = strongLanguageLabels.contains(language.lowercased())
        guard strongCodeLineCount >= 1 || (hasStrongLanguageHint && weakCodeLineCount >= 2) else { return nil }
        if nonEmptyCount > 1, strongCodeLineCount == 0, weakCodeLineCount < 3 {
            return nil
        }

        let content = trimCodeBoundaryBlankLines(
            collected.joined(separator: "\n")
        )
        guard !content.isEmpty else { return nil }
        guard isLikelyStructuredCodeContent(languageHint: language, content: content) else { return nil }

        return (language: language, content: content, nextIndex: cursor)
    }

    private static func nextNonEmptyLineIndex(in lines: [String], from start: Int) -> Int? {
        guard start < lines.count else { return nil }
        for idx in start..<lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return idx
            }
        }
        return nil
    }

    private static func isLikelyCodeContinuationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let continuationTokens: Set<String> = ["{", "}", "(", ")", "[", "]", ">", "<", ":", "::", ","]
        if continuationTokens.contains(trimmed) { return true }
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") { return true }
        return false
    }

    private static func isLikelyIndentedCodeContinuationLine(rawLine: String, trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let leadingIndent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        guard leadingIndent >= 2 else { return false }

        if trimmed.hasSuffix(",") || trimmed.hasSuffix(":") {
            return true
        }

        if trimmed.contains(": ") {
            return true
        }

        if trimmed.hasPrefix(".") || trimmed.hasPrefix(")") || trimmed.hasPrefix("]") || trimmed.hasPrefix("}") {
            return true
        }

        if trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*:"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func isLikelyCodeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isLikelyNaturalLanguageBullet(trimmed) { return false }
        if looksLikeNaturalLanguageSentence(trimmed) { return false }
        if trimmed.range(of: #"[。！？；，]$"#, options: .regularExpression) != nil {
            return false
        }

        if trimmed.range(
            of: #"^(package|import|func|type|var|const|class|interface|struct|enum|def|return|if|for|while|switch|case|let|public|private|protected|from|select|insert|update|delete)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        if trimmed.range(of: #"^[A-Za-z0-9_./-]+\.(go|py|js|ts|tsx|jsx|java|kt|swift|rs|c|cc|cpp|h|hpp|sql|sh|yaml|yml|json|xml|html|css)$"#, options: .regularExpression) != nil {
            return true
        }

        if trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*:\s*"#, options: .regularExpression) != nil {
            return true
        }

        let codeTokens = ["{", "}", "=>", "->", ":=", "::", "()", "[]", "==", "!=", "<=", ">=", "&&", "||", ";"]
        if codeTokens.contains(where: { trimmed.contains($0) }) {
            return true
        }

        if trimmed.range(
            of: #"^[A-Za-z_][A-Za-z0-9_\.]*\s*\([^)]*\)\s*(?:\{|;|:)?$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if trimmed.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]+\])?\s*=\s*.+$"#,
            options: .regularExpression
        ) != nil, !trimmed.contains("==") {
            return true
        }

        if trimmed.hasSuffix(","),
           trimmed.contains("\"") || trimmed.contains("'") || trimmed.contains(":") || trimmed.hasPrefix(".") {
            return true
        }

        if trimmed.range(of: #"^</?[A-Za-z][A-Za-z0-9:-]*(\s+[^>]*)?>$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func isStrongCodeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if looksLikeNaturalLanguageSentence(trimmed) { return false }

        if let stripped = stripInlineCommentForCodeDetection(from: trimmed),
           stripped != trimmed {
            if isStrongCodeLine(stripped) {
                return true
            }

            if stripped.range(
                of: #"^[A-Za-z_][A-Za-z0-9_\.]*\s*\([^)]*\)$"#,
                options: .regularExpression
            ) != nil {
                return true
            }
        }

        if trimmed.range(
            of: #"^(func|def|class|interface|struct|enum|import|from|package|public|private|protected|return|if|for|while|switch|case|try|catch|finally)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        if trimmed.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*\s*=\s*[^=]"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if trimmed.contains("{") || trimmed.contains("}") || trimmed.contains("=>") || trimmed.contains(":=") {
            return true
        }

        if trimmed.contains("(") && trimmed.contains(")") && trimmed.hasSuffix(":") {
            return true
        }

        if trimmed.hasSuffix(";") {
            return true
        }

        if trimmed.range(
            of: #"^[A-Za-z_][A-Za-z0-9_\.]*\s*\([^)]*\)$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if trimmed.range(of: #"^</?[A-Za-z][A-Za-z0-9:-]*(\s+[^>]*)?>$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func parseMarkdownTable(lines: [String], start: Int) -> ParsedMarkdownTable? {
        guard start + 1 < lines.count else { return nil }

        let headerLine = lines[start]
        let separatorLine = lines[start + 1]

        guard headerLine.contains("|"), separatorLine.contains("|") else { return nil }

        let headers = splitTableCells(headerLine)
        guard headers.count >= 2 else { return nil }

        let separatorCells = splitTableCells(separatorLine)
        guard isTableSeparatorRow(separatorCells, columnCount: headers.count) else { return nil }

        var rows: [[String]] = []
        var cursor = start + 2

        while cursor < lines.count {
            let rowLine = lines[cursor]
            let trimmed = rowLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            guard rowLine.contains("|") else { break }

            let cells = splitTableCells(rowLine)
            guard cells.count == headers.count else { break }
            rows.append(cells)
            cursor += 1
        }

        guard !rows.isEmpty else { return nil }
        return ParsedMarkdownTable(headers: headers, rows: rows, consumedLineCount: cursor - start)
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("|") {
            normalized.removeFirst()
        }
        if normalized.hasSuffix("|") {
            normalized.removeLast()
        }

        return normalized
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func isTableSeparatorRow(_ cells: [String], columnCount: Int) -> Bool {
        guard cells.count == columnCount else { return false }
        return cells.allSatisfy { rawCell in
            let compact = rawCell.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 3 else { return false }
            return compact.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private static func cleanTableCell(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        return cleanMarkdownForDisplay(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseCodeBlock(_ block: String) -> (String?, String) {
        var normalized = block
        if normalized.hasPrefix("\n") {
            normalized.removeFirst()
        }

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (nil, "") }

        let maybeLanguage = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredLanguage = maybeLanguage.lowercased()
        let isRecognizedLanguageTag = languageTagAliases[loweredLanguage] != nil
            || weakLanguageLabels.contains(loweredLanguage)
            || strongLanguageLabels.contains(loweredLanguage)
        if maybeLanguage.contains(" ") || !isRecognizedLanguageTag {
            return (nil, sanitizeCodeContent(normalized))
        }

        let body = lines.dropFirst().joined(separator: "\n")
        if body.isEmpty {
            return (nil, sanitizeCodeContent(normalized))
        }
        return (maybeLanguage.isEmpty ? nil : maybeLanguage, sanitizeCodeContent(body))
    }

    private static func parseDelimitedTableFromCode(
        language: String?,
        content: String
    ) -> (headers: [String], rows: [[String]])? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalizedLanguage = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let forceDelimited = ["csv", "tsv", "excel", "xlsx"].contains(normalizedLanguage)

        let delimiter: Character?
        if normalizedLanguage == "tsv" || trimmed.contains("\t") {
            delimiter = "\t"
        } else if forceDelimited || isLikelyDelimitedData(trimmed, delimiter: ",") {
            delimiter = ","
        } else if isLikelyDelimitedData(trimmed, delimiter: ";") {
            delimiter = ";"
        } else {
            delimiter = nil
        }

        guard let delimiter else { return nil }

        let lines = trimmed
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        let header = splitDelimitedCells(lines[0], delimiter: delimiter)
        guard header.count >= 2 else { return nil }

        var rows: [[String]] = []
        for line in lines.dropFirst() {
            let cells = splitDelimitedCells(line, delimiter: delimiter)
            guard !cells.isEmpty else { continue }
            if cells.count == header.count {
                rows.append(cells)
            } else if cells.count > header.count {
                rows.append(Array(cells.prefix(header.count)))
            } else {
                rows.append(cells + Array(repeating: "", count: header.count - cells.count))
            }
        }

        guard !rows.isEmpty else { return nil }
        let cleanedHeader = header.map(cleanTableCell)
        let cleanedRows = rows.map { row in row.map(cleanTableCell) }
        return (headers: cleanedHeader, rows: cleanedRows)
    }

    private static func splitDelimitedCells(_ line: String, delimiter: Character) -> [String] {
        line
            .split(separator: delimiter, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func isLikelyDelimitedData(_ text: String, delimiter: Character) -> Bool {
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }

        let suspiciousCodeTokens = ["{", "}", "=>", "func ", "class ", "def ", "return ", "import "]
        if lines.contains(where: { line in suspiciousCodeTokens.contains(where: { line.contains($0) }) }) {
            return false
        }

        let counts = lines.map { line in
            line.reduce(into: 0) { count, character in
                if character == delimiter { count += 1 }
            }
        }
        let positive = counts.filter { $0 > 0 }
        guard positive.count >= 2 else { return false }

        let maxCount = positive.max() ?? 0
        let minCount = positive.min() ?? 0
        guard maxCount >= 1, maxCount - minCount <= 1 else { return false }
        return true
    }

    private static func splitLikelyCodePrefix(
        from raw: String,
        languageHint: String?
    ) -> (code: String, remainder: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard !lines.isEmpty else { return ("", "") }

        var codeLines: [String] = []
        var cursor = 0
        var seenStrongCodeLine = false
        var weakCodeLineCount = 0
        var naturalLanguageLineCount = 0

        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                if codeLines.isEmpty {
                    cursor += 1
                    continue
                }

                if let next = nextNonEmptyLineIndex(in: lines, from: cursor + 1) {
                    let nextLine = lines[next]
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isLikelyCodeLine(nextTrimmed)
                        || isLikelyInlineCommentedCodeLine(nextTrimmed)
                        || isStrongCodeLine(nextTrimmed)
                        || isLikelyCodeContinuationLine(nextTrimmed)
                        || isLikelyIndentedCodeContinuationLine(rawLine: nextLine, trimmed: nextTrimmed) {
                        codeLines.append(line)
                        cursor += 1
                        continue
                    }
                }
                break
            }

            if let inlineNarration = splitInlineNarrativeSuffix(from: line) {
                let inlineCode = inlineNarration.code.trimmingCharacters(in: .whitespacesAndNewlines)
                if isStrongCodeLine(inlineCode) {
                    seenStrongCodeLine = true
                    codeLines.append(inlineNarration.code)
                    let tailLines = [inlineNarration.narration] + Array(lines.dropFirst(cursor + 1))
                    let code = codeLines
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let remainder = tailLines
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (code, remainder)
                }
                if isLikelyCodeLine(inlineCode) || isLikelyInlineCommentedCodeLine(inlineCode) {
                    weakCodeLineCount += 1
                    codeLines.append(inlineNarration.code)
                    let tailLines = [inlineNarration.narration] + Array(lines.dropFirst(cursor + 1))
                    let code = codeLines
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let remainder = tailLines
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (code, remainder)
                }
            }

            if isStrongCodeLine(trimmed) {
                seenStrongCodeLine = true
                codeLines.append(line)
                cursor += 1
                continue
            }

            if codeLines.isEmpty && isLikelyCodeLeadInLine(trimmed) {
                cursor += 1
                continue
            }

            if isLikelyCodeLine(trimmed)
                || isLikelyInlineCommentedCodeLine(trimmed)
                || isLikelyCodeContinuationLine(trimmed)
                || isLikelyIndentedCodeContinuationLine(rawLine: line, trimmed: trimmed) {
                if isLikelyCodeLine(trimmed) {
                    weakCodeLineCount += 1
                } else if isLikelyInlineCommentedCodeLine(trimmed) {
                    weakCodeLineCount += 1
                }
                codeLines.append(line)
                cursor += 1
                continue
            }

            if looksLikeNaturalLanguageSentence(trimmed) || isLikelyNaturalLanguageBullet(trimmed) {
                naturalLanguageLineCount += 1
            }
            break
        }

        let normalizedHint = languageHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasStrongHint = {
            guard let normalizedHint else { return false }
            return strongLanguageLabels.contains(normalizedHint)
        }()
        let allowedByHint = hasStrongHint
            && weakCodeLineCount >= 2
            && naturalLanguageLineCount == 0

        if !seenStrongCodeLine && !allowedByHint {
            return ("", normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let code = trimCodeBoundaryBlankLines(codeLines.joined(separator: "\n"))
        let remainder = lines.dropFirst(cursor)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (code, remainder)
    }

    private static func splitMixedCodeAndNarration(
        from raw: String,
        languageHint: String?
    ) -> (code: String, remainder: String)? {
        let split = splitLikelyCodePrefix(from: raw, languageHint: languageHint)
        let code = trimCodeBoundaryBlankLines(split.code)
        let remainder = split.remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !remainder.isEmpty else { return nil }
        guard isLikelyStructuredCodeContent(languageHint: languageHint, content: code) else { return nil }
        guard !isLikelyStructuredCodeContent(languageHint: languageHint, content: remainder) else { return nil }

        let remainderLines = remainder
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !remainderLines.isEmpty else { return nil }
        guard !remainderLines.allSatisfy({ isLikelyCodeCommentLine($0) }) else { return nil }

        let codeLikeLineCount = remainderLines.reduce(into: 0) { count, line in
            if isStrongCodeLine(line) || isLikelyCodeLine(line) || isLikelyInlineCommentedCodeLine(line) {
                count += 1
            }
        }
        guard codeLikeLineCount == 0 else { return nil }

        let naturalLineCount = remainderLines.reduce(into: 0) { count, line in
            if looksLikeNaturalLanguageSentence(line) || isLikelyNaturalLanguageBullet(line) {
                count += 1
            }
        }
        let allowsSingleNarrativeHeading =
            naturalLineCount >= 1
            && remainderLines.count == 1
            && isLikelyNarrativeHeadingLine(remainderLines[0])
        guard naturalLineCount >= 2 || allowsSingleNarrativeHeading else { return nil }
        return (code, remainder)
    }

    private static func splitInlineNarrativeSuffix(from rawLine: String) -> (code: String, narration: String)? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("#"), !trimmed.contains("//"), !trimmed.contains("/*") else { return nil }

        let punctuationSet = CharacterSet(charactersIn: "。！？")
        for index in trimmed.indices {
            let scalarSet = trimmed[index].unicodeScalars
            guard scalarSet.allSatisfy({ punctuationSet.contains($0) }) else { continue }

            let codePart = String(trimmed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let narrationStart = trimmed.index(after: index)
            let narration = String(trimmed[narrationStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !codePart.isEmpty, !narration.isEmpty else { continue }
            guard hasBalancedInlineQuotes(codePart) else { continue }
            guard looksLikeNaturalLanguageSentence(narration) || isLikelyNaturalLanguageBullet(narration) else { continue }

            if isStrongCodeLine(codePart)
                || isLikelyCodeLine(codePart)
                || isLikelyInlineCommentedCodeLine(codePart) {
                return (codePart, narration)
            }
        }

        return nil
    }

    private static func hasBalancedInlineQuotes(_ text: String) -> Bool {
        let doubleQuoteCount = text.filter { $0 == "\"" }.count
        let singleQuoteCount = text.filter { $0 == "'" }.count
        return doubleQuoteCount.isMultiple(of: 2) && singleQuoteCount.isMultiple(of: 2)
    }

    private static func isLikelyCodeCommentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let commentPrefixes = ["#", "//", "/*", "*", "--", "<!--", "///"]
        return commentPrefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func isLikelyInlineCommentedCodeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let stripped = stripInlineCommentForCodeDetection(from: trimmed) else { return false }
        guard stripped != trimmed else { return false }

        if isStrongCodeLine(stripped) || isLikelyCodeLine(stripped) {
            return true
        }

        if stripped.range(
            of: #"^[A-Za-z_][A-Za-z0-9_\.]*\s*\([^)]*\)$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    private static func stripInlineCommentForCodeDetection(from line: String) -> String? {
        let markers = [" #", "\t#", " //", "\t//", " -- "]
        for marker in markers {
            if let range = line.range(of: marker) {
                let candidate = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func isLikelyCodeLeadInLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let markers = [
            "下面是代码", "以下是代码", "代码如下", "示例代码", "完整代码",
            "here is the code", "code below", "example code", "source code"
        ]
        if markers.contains(where: { lowered.contains($0) }) {
            return true
        }

        if trimmed.hasSuffix(":") || trimmed.hasSuffix("：") {
            return true
        }
        return false
    }

    private static func isLikelyNarrativeHeadingLine(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_`"))
            )
        guard !normalized.isEmpty else { return false }

        let lowered = normalized.lowercased()
        let markers = ["例子", "例如", "示例", "样例", "输出", "说明", "结果", "demo", "example", "usage"]
        if markers.contains(lowered) {
            return true
        }

        if markers.contains(where: { lowered == "\($0):" || lowered == "\($0)：" }) {
            return true
        }

        return normalized.count <= 24 && (normalized.hasSuffix(":") || normalized.hasSuffix("："))
    }

    private static func sanitizeCodeContent(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let filtered = normalized
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return true }
                if trimmed.range(of: #"^`{2,}$"#, options: .regularExpression) != nil {
                    return false
                }
                return true
            }
            .joined(separator: "\n")
        return trimCodeBoundaryBlankLines(filtered)
    }

    private static func inferCodeLanguage(language: String?, content: String) -> String? {
        let normalized = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalized, !normalized.isEmpty {
            if weakLanguageLabels.contains(normalized) {
                return nil
            }
            return normalized
        }

        let sample = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }

        if parseDelimitedTableFromCode(language: nil, content: sample) != nil {
            return sample.contains("\t") ? "tsv" : "csv"
        }

        let lowered = sample.lowercased()
        if lowered.hasPrefix("{") || lowered.hasPrefix("["),
           lowered.contains("\":") {
            return "json"
        }
        if lowered.contains("def ") || lowered.contains("print(") || lowered.contains("import pandas") {
            return "python"
        }
        if lowered.contains("function ") || lowered.contains("const ") || lowered.contains("let ") || lowered.contains("=>") {
            return "javascript"
        }
        if lowered.contains("<html") || lowered.contains("<body") || lowered.contains("<!doctype html") {
            return "html"
        }
        if lowered.contains("select ") || lowered.contains(" from ") || lowered.contains(" where ") {
            return "sql"
        }
        if lowered.contains("public class ") || lowered.contains("system.out.println") {
            return "java"
        }
        if lowered.contains("import swift") || lowered.contains("let ") && lowered.contains("func ") {
            return "swift"
        }
        return nil
    }

    private static func isLikelyStructuredCodeContent(languageHint: String?, content: String) -> Bool {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let language = languageHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let language, weakLanguageLabels.contains(language), !strongLanguageLabels.contains(language) {
            return false
        }

        let lines = normalized.components(separatedBy: "\n")
        var strongCount = 0
        var weakCount = 0
        var nonEmptyCount = 0
        var naturalLanguageCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            nonEmptyCount += 1
            if isStrongCodeLine(trimmed) {
                strongCount += 1
            } else if isLikelyCodeLine(trimmed) {
                weakCount += 1
            } else if looksLikeNaturalLanguageSentence(trimmed) || isLikelyNaturalLanguageBullet(trimmed) {
                naturalLanguageCount += 1
            }
        }

        if naturalLanguageCount >= max(2, nonEmptyCount / 2) {
            return false
        }

        if nonEmptyCount == 1 {
            return strongCount >= 1
        }

        if strongCount >= 2 {
            return true
        }

        if strongCount >= 1 && weakCount >= 1 {
            return true
        }

        if let language, strongLanguageLabels.contains(language), weakCount >= 2, naturalLanguageCount == 0 {
            return true
        }

        return false
    }

    private static func isLikelyNaturalLanguageBullet(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let bulletPrefixes = ["•", "●", "○", "◦", "- ", "* ", "· ", "▪", "▫"]
        if bulletPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }

        if trimmed.range(of: #"^\d+[\.)、]\s*"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func looksLikeNaturalLanguageSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isLikelyNaturalLanguageBullet(trimmed) { return true }
        if trimmed.count < 8 { return false }
        if trimmed.contains("：") || trimmed.contains("。") || trimmed.contains("，") {
            return true
        }
        let letterCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let symbolCount = trimmed.filter { "{}[]();=<>:+-*/\\_".contains($0) }.count
        let containsCJK = trimmed.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
        if containsCJK && trimmed.count >= 4 && symbolCount <= 1 {
            return true
        }
        if letterCount >= 12 && symbolCount <= 1 {
            return true
        }
        return false
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
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.replacingOccurrences(of: "``", with: "")
        text = text.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*•]\\s+", with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*\\d+[\\.)、]\\s+", with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*>\\s?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\(([^)\s]+)\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<!`)`([^`\\n]+)`(?!`)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\*)\*([^\*\n]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!_)_([^_\n]+)_(?!_)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"~~([^~\n]+)~~"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!>~|])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = expandGitHubRepositoryLinks(in: text)
        text = autoBulletizePlainLineGroups(text)
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

    private static func mergeTrailingCodeLikeTextSegments(_ segments: [MessageSegment]) -> [MessageSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [MessageSegment] = []
        merged.reserveCapacity(segments.count)

        for segment in segments {
            switch segment {
            case .text(let text):
                guard let last = merged.last else {
                    merged.append(segment)
                    continue
                }

                switch last {
                case .code(let language, let content):
                    let split = splitLikelyCodePrefix(from: text, languageHint: language)
                    if !split.code.isEmpty,
                       isLikelyStructuredCodeContent(languageHint: language, content: split.code) {
                        merged.removeLast()
                        let combined = trimCodeBoundaryBlankLines(content) + "\n" + trimCodeBoundaryBlankLines(split.code)
                        merged.append(.code(language: language, content: trimCodeBoundaryBlankLines(combined)))
                        if !split.remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            merged.append(.text(split.remainder))
                        }
                        continue
                    }
                    merged.append(segment)

                case .file(let name, let language, let content):
                    let split = splitLikelyCodePrefix(from: text, languageHint: language)
                    if !split.code.isEmpty,
                       isLikelyStructuredCodeContent(languageHint: language, content: split.code) {
                        merged.removeLast()
                        let combined = trimCodeBoundaryBlankLines(content) + "\n" + trimCodeBoundaryBlankLines(split.code)
                        merged.append(.file(name: name, language: language, content: trimCodeBoundaryBlankLines(combined)))
                        if !split.remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            merged.append(.text(split.remainder))
                        }
                        continue
                    }
                    merged.append(segment)

                default:
                    merged.append(segment)
                }

            default:
                merged.append(segment)
            }
        }

        return merged
    }

    private static func sectionizeAssistantLongTextSegments(
        _ segments: [MessageSegment],
        role: ChatMessage.Role,
        isStreaming: Bool
    ) -> [MessageSegment] {
        guard role == .assistant else { return segments }

        var output: [MessageSegment] = []
        for segment in segments {
            guard case .text(let rawText) = segment else {
                output.append(segment)
                continue
            }

            let blocks = splitIntoSectionBlocks(rawText)
            guard blocks.count > 1 else {
                output.append(segment)
                continue
            }

            for (index, block) in blocks.enumerated() {
                if index > 0 {
                    output.append(.divider)
                }
                output.append(.text(block))
            }
        }
        return output
    }

    private static func splitIntoSectionBlocks(_ rawText: String) -> [String] {
        let normalized = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep medium replies readable, but avoid over-fragmenting very long replies into too many views.
        guard trimmed.count >= 560 else { return [rawText] }

        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard paragraphs.count >= 3 else { return [rawText] }

        var chunks: [String] = []
        var buffer: [String] = []
        var bufferLength = 0

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            chunks.append(buffer.joined(separator: "\n\n"))
            buffer.removeAll(keepingCapacity: true)
            bufferLength = 0
        }

        for paragraph in paragraphs {
            let candidateLength = bufferLength + paragraph.count + (buffer.isEmpty ? 0 : 2)
            let shouldBreakForHeading = !buffer.isEmpty && isSectionHeading(paragraph)
            let shouldBreakForLength = candidateLength >= 980

            if shouldBreakForHeading || shouldBreakForLength {
                flushBuffer()
            }

            buffer.append(paragraph)
            bufferLength += paragraph.count + (buffer.count > 1 ? 2 : 0)

            if bufferLength >= 760 {
                flushBuffer()
            }
        }

        flushBuffer()

        guard chunks.count >= 2 else { return [rawText] }
        return chunks
    }

    private static func isSectionHeading(_ paragraph: String) -> Bool {
        let firstLine = paragraph
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return false }

        if firstLine.hasPrefix("#") { return true }
        if firstLine.hasSuffix("：") || firstLine.hasSuffix(":") { return true }
        if firstLine.count <= 24 && !firstLine.contains("。") && !firstLine.contains("，") {
            return true
        }
        return false
    }

    private static func trimCodeBoundaryBlankLines(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }

        var start = 0
        var end = lines.count - 1

        while start <= end && lines[start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            start += 1
        }
        while end >= start && lines[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }

        guard start <= end else { return "" }
        let trimmedLines = Array(lines[start...end])
        let nonEmptyLines = trimmedLines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let leadingCounts = nonEmptyLines.map { line in
            line.prefix { $0 == " " || $0 == "\t" }.count
        }
        let sharedIndent = leadingCounts.min() ?? 0
        guard sharedIndent > 0 else {
            return trimmedLines.joined(separator: "\n")
        }

        let dedented = trimmedLines.map { line -> String in
            let leading = line.prefix { $0 == " " || $0 == "\t" }.count
            guard leading >= sharedIndent else { return line }
            return String(line.dropFirst(sharedIndent))
        }
        return dedented.joined(separator: "\n")
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
            String(message.videoAttachments.count),
            String(message.fileAttachments.count),
            message.isStreaming ? "1" : "0"
        ].joined(separator: "|")
    }

    static func clearCaches() {
        parseCache.removeAll(keepingCapacity: false)
        parseCacheOrder.removeAll(keepingCapacity: false)
        streamingSnapshots.removeAll(keepingCapacity: false)
    }

    private static func storeParseCache(segments: [MessageSegment], signature: String) {
        guard segments.count <= maxCachedSegmentsPerEntry else { return }
        parseCache[signature] = segments
        if !parseCacheOrder.contains(signature) {
            parseCacheOrder.append(signature)
        }

        while parseCacheOrder.count > maxCacheEntries {
            let oldest = parseCacheOrder.removeFirst()
            parseCache.removeValue(forKey: oldest)
        }
    }

    private static func pruneStreamingSnapshots(now: Date) {
        guard !streamingSnapshots.isEmpty else { return }

        streamingSnapshots = streamingSnapshots.filter { _, snapshot in
            now.timeIntervalSince(snapshot.parsedAt) <= streamingSnapshotTTL
        }

        if streamingSnapshots.count <= maxStreamingSnapshots {
            return
        }

        let sortedKeys = streamingSnapshots.keys.sorted { lhs, rhs in
            let left = streamingSnapshots[lhs]?.parsedAt ?? .distantPast
            let right = streamingSnapshots[rhs]?.parsedAt ?? .distantPast
            return left < right
        }
        let removeCount = max(0, streamingSnapshots.count - maxStreamingSnapshots)
        if removeCount > 0 {
            for key in sortedKeys.prefix(removeCount) {
                streamingSnapshots.removeValue(forKey: key)
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
