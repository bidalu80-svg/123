import Foundation

enum FrontendProjectBuilder {
    enum BuildMode {
        case createNewProject
        case overwriteLatestProject
    }

    struct BuildResult {
        let projectDirectoryURL: URL
        let entryFileURL: URL
        let entryHTML: String
        let writtenRelativePaths: [String]
        let createdNewProject: Bool
    }

    enum BuildError: LocalizedError {
        case noFrontendContent
        case invalidProjectDirectory
        case missingEntryFile

        var errorDescription: String? {
            switch self {
            case .noFrontendContent:
                return "没有识别到可落盘的前端代码。请让模型按 [[file:...]] 或代码块输出。"
            case .invalidProjectDirectory:
                return "无法创建本地项目目录。"
            case .missingEntryFile:
                return "未找到可预览入口页（index.html）。"
            }
        }
    }

    private struct ParsedWebFile {
        let path: String
        let content: String
    }

    static func canGenerateProject(from message: ChatMessage) -> Bool {
        if message.fileAttachments.contains(where: {
            $0.binaryBase64 == nil && isLikelyFrontendPath($0.fileName)
        }) {
            return true
        }

        let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        if containsWebTaggedFile(in: text) {
            return true
        }
        if containsLikelyWebFencedBlock(in: text) {
            return true
        }
        return looksLikeHTML(text)
    }

    static func buildProject(from message: ChatMessage, mode: BuildMode) throws -> BuildResult {
        var parsedFiles = extractWebFiles(from: message)
        if parsedFiles.isEmpty, let fallbackHTML = fallbackHTML(in: message.content) {
            parsedFiles = [ParsedWebFile(path: "index.html", content: fallbackHTML)]
        }

        guard !parsedFiles.isEmpty else {
            throw BuildError.noFrontendContent
        }

        var merged: [String: String] = [:]
        var orderedPaths: [String] = []
        for item in parsedFiles {
            let normalizedPath = item.path.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedContent = normalizeFileContent(item.content)
            guard !normalizedPath.isEmpty, !normalizedContent.isEmpty else { continue }
            if merged[normalizedPath] == nil {
                orderedPaths.append(normalizedPath)
            }
            merged[normalizedPath] = normalizedContent
        }

        guard !merged.isEmpty else {
            throw BuildError.noFrontendContent
        }

        if !orderedPaths.contains(where: { isHTMLPath($0) }) {
            let stylePaths = orderedPaths.filter { isStylePath($0) }
            let scriptPaths = orderedPaths.filter { isScriptPath($0) }
            let synthesized = synthesizedIndexHTML(stylePaths: stylePaths, scriptPaths: scriptPaths)
            if merged["index.html"] == nil {
                orderedPaths.insert("index.html", at: 0)
            }
            merged["index.html"] = synthesized
        }

        let projectDirectoryURL = try prepareProjectDirectory(mode: mode)
        let fileManager = FileManager.default

        for relativePath in orderedPaths {
            guard let content = merged[relativePath] else { continue }
            let fileURL = projectDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            let parentURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        guard let entryRelativePath = preferredEntryPath(from: orderedPaths),
              let entryHTML = merged[entryRelativePath] else {
            throw BuildError.missingEntryFile
        }

        return BuildResult(
            projectDirectoryURL: projectDirectoryURL,
            entryFileURL: projectDirectoryURL.appendingPathComponent(entryRelativePath, isDirectory: false),
            entryHTML: entryHTML,
            writtenRelativePaths: orderedPaths,
            createdNewProject: mode == .createNewProject
        )
    }

    private static func extractWebFiles(from message: ChatMessage) -> [ParsedWebFile] {
        var files: [ParsedWebFile] = []

        for attachment in message.fileAttachments {
            guard attachment.binaryBase64 == nil else { continue }
            guard let path = sanitizeRelativePath(attachment.fileName) else { continue }
            let content = normalizeFileContent(attachment.textContent)
            guard !content.isEmpty else { continue }
            files.append(ParsedWebFile(path: path, content: content))
        }

        let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        files.append(contentsOf: parseTaggedFiles(in: text))
        files.append(contentsOf: parseFencedCodeBlocks(in: text))

        return mergeParsedFiles(files)
    }

    private static func parseTaggedFiles(in text: String) -> [ParsedWebFile] {
        let pattern = #"\[\[file:(.+?)\]\]([\s\S]*?)\[\[endfile\]\]"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return [] }

        return matches.compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: text),
                  let contentRange = Range(match.range(at: 2), in: text) else {
                return nil
            }
            let rawPath = String(text[pathRange])
            guard let normalizedPath = sanitizeRelativePath(rawPath) else { return nil }
            let content = normalizeFileContent(String(text[contentRange]))
            guard !content.isEmpty else { return nil }
            return ParsedWebFile(path: normalizedPath, content: content)
        }
    }

    private static func parseFencedCodeBlocks(in text: String) -> [ParsedWebFile] {
        let pattern = #"(?s)```([^\n`]*)\n(.*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsText = text as NSString
        let nsRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return [] }

        var result: [ParsedWebFile] = []
        for match in matches {
            guard let descriptorRange = Range(match.range(at: 1), in: text),
                  let contentRange = Range(match.range(at: 2), in: text) else {
                continue
            }

            let descriptor = String(text[descriptorRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let codeContent = normalizeFileContent(String(text[contentRange]))
            guard !codeContent.isEmpty else { continue }

            let prefixStart = max(0, match.range.location - 260)
            let prefixLength = max(0, match.range.location - prefixStart)
            let prefix = nsText.substring(with: NSRange(location: prefixStart, length: prefixLength))

            guard let path = resolvePathForFencedBlock(
                descriptor: descriptor,
                codeContent: codeContent,
                prefixText: prefix
            ) else {
                continue
            }
            result.append(ParsedWebFile(path: path, content: codeContent))
        }
        return result
    }

    private static func resolvePathForFencedBlock(
        descriptor: String,
        codeContent: String,
        prefixText: String
    ) -> String? {
        if let explicit = sanitizeRelativePath(extractPathHint(from: descriptor)) {
            return explicit
        }

        let loweredDescriptor = descriptor.lowercased()
        if let hinted = sanitizeRelativePath(extractPathHintFromPrefix(prefixText)) {
            return hinted
        }

        if let pathLike = pathLikeDescriptorPath(loweredDescriptor),
           let normalized = sanitizeRelativePath(pathLike) {
            return normalized
        }

        if let mapped = mappedPathFromLanguage(loweredDescriptor) {
            return mapped
        }

        if loweredDescriptor.isEmpty, looksLikeHTML(codeContent) {
            return "index.html"
        }

        return nil
    }

    private static func containsWebTaggedFile(in text: String) -> Bool {
        let pattern = #"\[\[file:(.+?)\]\]"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return false
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let rawPath = String(text[range])
            guard let normalized = sanitizeRelativePath(rawPath) else { continue }
            if isLikelyFrontendPath(normalized) {
                return true
            }
        }
        return false
    }

    private static func containsLikelyWebFencedBlock(in text: String) -> Bool {
        let pattern = #"(?s)```([^\n`]*)\n(.*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let nsText = text as NSString
        let nsRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return false }

        for match in matches {
            guard let descriptorRange = Range(match.range(at: 1), in: text),
                  let contentRange = Range(match.range(at: 2), in: text) else {
                continue
            }

            let descriptor = String(text[descriptorRange]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let content = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            if mappedPathFromLanguage(descriptor) != nil {
                return true
            }

            if let pathLike = pathLikeDescriptorPath(descriptor), isLikelyFrontendPath(pathLike) {
                return true
            }

            if looksLikeHTML(content) {
                return true
            }
        }

        return false
    }

    private static func extractPathHint(from text: String) -> String {
        let pattern = #"(?i)(?:file(?:name)?|path)\s*[:=]\s*([`"'A-Za-z0-9_./\\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return ""
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func extractPathHintFromPrefix(_ prefix: String) -> String {
        let pattern = #"(?im)(?:文件名|文件路径|路径|filename|file|path)\s*[:：]\s*([`"'A-Za-z0-9_./\\-]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let nsText = prefix as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: prefix, range: range),
              match.numberOfRanges > 1 else {
            return ""
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func pathLikeDescriptorPath(_ descriptor: String) -> String? {
        let trimmed = descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(" ") {
            return nil
        }

        let knownLanguages: Set<String> = [
            "html", "htm", "xhtml", "css", "scss", "sass", "less",
            "javascript", "js", "typescript", "ts", "json", "vue", "jsx", "tsx",
            "xml", "yaml", "yml", "markdown", "md", "python", "py", "swift", "bash"
        ]
        if knownLanguages.contains(trimmed) {
            return nil
        }

        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains(".") {
            return trimmed
        }
        return nil
    }

    private static func mappedPathFromLanguage(_ language: String) -> String? {
        switch language {
        case "html", "htm", "xhtml", "text/html":
            return "index.html"
        case "css", "scss", "sass", "less":
            return "style.css"
        case "javascript", "js", "typescript", "ts", "jsx", "tsx", "vue":
            return "app.js"
        default:
            return nil
        }
    }

    private static func mergeParsedFiles(_ files: [ParsedWebFile]) -> [ParsedWebFile] {
        var order: [String] = []
        var merged: [String: String] = [:]

        for item in files {
            let normalizedPath = item.path.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedContent = normalizeFileContent(item.content)
            guard !normalizedPath.isEmpty, !normalizedContent.isEmpty else { continue }

            if merged[normalizedPath] == nil {
                order.append(normalizedPath)
                merged[normalizedPath] = normalizedContent
                continue
            }

            let existing = merged[normalizedPath] ?? ""
            if normalizedContent.count >= existing.count {
                merged[normalizedPath] = normalizedContent
            }
        }

        return order.compactMap { path in
            guard let content = merged[path] else { return nil }
            return ParsedWebFile(path: path, content: content)
        }
    }

    private static func fallbackHTML(in text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let fencedHTML = firstFencedHTML(in: trimmed) {
            return normalizeFileContent(fencedHTML)
        }

        if looksLikeHTML(trimmed) {
            return normalizeFileContent(trimmed)
        }
        return nil
    }

    private static func firstFencedHTML(in text: String) -> String? {
        let pattern = #"(?is)```(?:html|htm|xhtml|text/html)?\s*\n(.*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("<!doctype html")
            || lowered.contains("<html")
            || lowered.contains("<head")
            || lowered.contains("<body")
            || lowered.contains("</html>")
    }

    private static func isLikelyFrontendPath(_ rawPath: String) -> Bool {
        let path = rawPath.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }

        if path.hasSuffix("index.html") || path.hasSuffix("index.htm") {
            return true
        }

        let webSuffixes = [
            ".html", ".htm", ".css", ".scss", ".sass", ".less",
            ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".vue"
        ]
        if webSuffixes.contains(where: { path.hasSuffix($0) }) {
            return true
        }

        if path.hasSuffix("package.json")
            || path.hasSuffix("vite.config.js")
            || path.hasSuffix("vite.config.ts") {
            return true
        }

        return false
    }

    private static func sanitizeRelativePath(_ rawPath: String) -> String? {
        var value = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
            .replacingOccurrences(of: "\\", with: "/")

        while value.hasPrefix("./") {
            value.removeFirst(2)
        }
        while value.hasPrefix("/") {
            value.removeFirst()
        }

        guard !value.isEmpty else { return nil }
        let components = value
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !components.isEmpty else { return nil }
        guard !components.contains("..") else { return nil }

        let sanitized = components.compactMap { sanitizePathComponent($0) }
        guard !sanitized.isEmpty else { return nil }
        return sanitized.joined(separator: "/")
    }

    private static func sanitizePathComponent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }

        let allowedExtraScalars = CharacterSet(charactersIn: "._- ")
        var buffer = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || allowedExtraScalars.contains(scalar) {
                buffer.unicodeScalars.append(scalar)
            } else {
                buffer.append("-")
            }
        }
        let normalized = buffer
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeFileContent(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func prepareProjectDirectory(mode: BuildMode) throws -> URL {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw BuildError.invalidProjectDirectory
        }

        let root = documentsURL.appendingPathComponent("FrontendProjects", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        switch mode {
        case .overwriteLatestProject:
            let latest = root.appendingPathComponent("latest", isDirectory: true)
            try fileManager.createDirectory(at: latest, withIntermediateDirectories: true)
            return latest
        case .createNewProject:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())

            for index in 0..<20 {
                let suffix = index == 0 ? "" : "-\(index)"
                let candidate = root.appendingPathComponent("site-\(stamp)\(suffix)", isDirectory: true)
                if !fileManager.fileExists(atPath: candidate.path) {
                    try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
                    return candidate
                }
            }
            throw BuildError.invalidProjectDirectory
        }
    }

    private static func preferredEntryPath(from paths: [String]) -> String? {
        if let exact = paths.first(where: { $0.lowercased().hasSuffix("index.html") }) {
            return exact
        }
        return paths.first(where: { isHTMLPath($0) })
    }

    private static func isHTMLPath(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".htm")
    }

    private static func isStylePath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".css")
            || lowered.hasSuffix(".scss")
            || lowered.hasSuffix(".sass")
            || lowered.hasSuffix(".less")
    }

    private static func isScriptPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".js")
            || lowered.hasSuffix(".mjs")
            || lowered.hasSuffix(".cjs")
            || lowered.hasSuffix(".ts")
    }

    private static func synthesizedIndexHTML(stylePaths: [String], scriptPaths: [String]) -> String {
        let styleLinks = stylePaths.map { "    <link rel=\"stylesheet\" href=\"\($0)\">" }
        let scripts = scriptPaths.map { "    <script src=\"\($0)\"></script>" }
        let styleBlock = styleLinks.isEmpty ? "" : (styleLinks.joined(separator: "\n") + "\n")
        let scriptBlock = scripts.isEmpty ? "" : ("\n" + scripts.joined(separator: "\n"))

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>IEXA Frontend</title>
        \(styleBlock)</head>
        <body>
            <div id="app"></div>\(scriptBlock)
        </body>
        </html>
        """
    }
}
