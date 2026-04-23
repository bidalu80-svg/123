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
        let shouldAutoOpenPreview: Bool
        let hadNaturalPreviewEntry: Bool
    }

    struct ChatProgressSnapshot {
        let detectedFileCount: Int
        let hasEntryHTML: Bool
    }

    enum BuildError: LocalizedError {
        case noFrontendContent
        case invalidProjectDirectory
        case missingEntryFile

        var errorDescription: String? {
            switch self {
            case .noFrontendContent:
                return "没有识别到可落盘的项目代码。请让模型按 [[file:...]] 或代码块输出。"
            case .invalidProjectDirectory:
                return "无法创建本地项目目录。"
            case .missingEntryFile:
                return "未找到可预览入口页（index.html / index.php）。"
            }
        }
    }

    private struct ParsedWebFile {
        let path: String
        let content: String
    }

    private static let knownLanguageDescriptors: Set<String> = [
        "html", "htm", "xhtml", "text/html",
        "css", "scss", "sass", "less",
        "php", "phtml",
        "javascript", "js", "typescript", "ts", "json", "vue", "jsx", "tsx",
        "xml", "yaml", "yml", "toml", "ini", "properties",
        "markdown", "md", "text", "plaintext", "plain", "code", "txt",
        "python", "py", "python3", "swift", "bash", "sh", "zsh", "shell", "powershell", "ps1",
        "go", "rust", "rs", "java", "kotlin", "kt", "kts",
        "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hxx",
        "csharp", "cs", "fsharp", "fs", "ruby", "rb", "lua", "r", "scala",
        "objective-c", "objc", "objectivec", "m", "objective-c++", "objc++", "mm",
        "dart", "sql", "dockerfile", "makefile", "cmake", "gradle", "groovy"
    ]
    private static let commonProjectExtensions: Set<String> = [
        "html", "htm", "xhtml", "css", "scss", "sass", "less",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte",
        "php", "phtml",
        "py", "swift", "go", "rs", "java", "kt", "kts",
        "c", "h", "cc", "cpp", "cxx", "hpp", "hxx",
        "cs", "fs", "rb", "lua", "r", "scala", "dart",
        "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "env",
        "md", "txt", "sql", "sh", "zsh", "bash", "ps1",
        "dockerfile", "gradle", "properties", "lock"
    ]
    private static let wellKnownProjectFileNames: Set<String> = [
        "dockerfile", "makefile", "cmakelists.txt", "readme", "readme.md", "license", "license.md",
        "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
        "tsconfig.json", "jsconfig.json", "vite.config.ts", "vite.config.js", "webpack.config.js", "webpack.config.ts",
        "next.config.js", "next.config.mjs", "nuxt.config.ts",
        "composer.json", "composer.lock",
        "requirements.txt", "pyproject.toml", "poetry.lock", "pipfile", "pipfile.lock", "setup.py",
        "go.mod", "go.sum", "cargo.toml", "cargo.lock",
        "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradle.properties",
        "gemfile", "gemfile.lock", "rakefile",
        "mix.exs", "mix.lock", "pubspec.yaml", "pubspec.lock",
        "docker-compose.yml", "docker-compose.yaml",
        ".gitignore", ".gitattributes", ".editorconfig", ".env", ".env.example"
    ]
    private static let latestEntryPointerFileName = ".iexa-latest-entry"
    private static let canGenerateCacheLimit = 64
    private static let progressSnapshotCacheLimit = 36
    private static let parsedFilesCacheLimit = 6
    private enum ProgressSnapshotCacheValue {
        case some(ChatProgressSnapshot)
        case none
    }
    private static var canGenerateCache: [UUID: Bool] = [:]
    private static var canGenerateCacheOrder: [UUID] = []
    private static var progressSnapshotCache: [UUID: ProgressSnapshotCacheValue] = [:]
    private static var progressSnapshotCacheOrder: [UUID] = []
    private static var parsedFilesCache: [UUID: [ParsedWebFile]] = [:]
    private static var parsedFilesCacheOrder: [UUID] = []

    static func canGenerateProject(from message: ChatMessage) -> Bool {
        if !message.isStreaming, let cached = canGenerateCache[message.id] {
            return cached
        }

        let canGenerate: Bool
        if message.fileAttachments.contains(where: {
            $0.binaryBase64 == nil
                && sanitizeRelativePath($0.fileName) != nil
                && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            canGenerate = true
        } else {
            let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
            canGenerate = containsTaggedFile(in: text)
                || containsLikelyProjectFencedBlock(in: text)
                || looksLikeHTML(text)
                || looksLikePHP(text)
        }

        if !message.isStreaming {
            storeCanGenerateCache(canGenerate, for: message.id)
        }
        return canGenerate
    }

    static func chatProgressSnapshot(from message: ChatMessage) -> ChatProgressSnapshot? {
        if !message.isStreaming, let cached = progressSnapshotCache[message.id] {
            switch cached {
            case .some(let snapshot):
                return snapshot
            case .none:
                return nil
            }
        }

        let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        let parsed = extractProjectFiles(from: message)
        let normalizedPaths = parsed.map { $0.path.lowercased() }
        let uniquePaths = Array(Set(normalizedPaths))

        let hasHTMLPath = uniquePaths.contains(where: { isHTMLPath($0) })
        let hasPHPPath = uniquePaths.contains(where: { isPHPPath($0) })
        let hasHTMLLikeFile = parsed.contains(where: { looksLikeHTML($0.content) })
        let hasPHPLikeFile = parsed.contains(where: { looksLikePHP($0.content) })
        let hasTaggedFile = containsTaggedFile(in: text)
        let hasFencedProjectBlock = containsLikelyProjectFencedBlock(in: text)
        let hasHTMLText = looksLikeHTML(text)
        let hasPHPText = looksLikePHP(text)
        let hasProjectAttachment = message.fileAttachments.contains(where: {
            $0.binaryBase64 == nil
                && sanitizeRelativePath($0.fileName) != nil
                && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })

        let shouldRenderProgress = !uniquePaths.isEmpty
            || hasTaggedFile
            || hasFencedProjectBlock
            || hasHTMLText
            || hasPHPText
            || hasProjectAttachment
        let snapshot: ChatProgressSnapshot? = shouldRenderProgress ? ChatProgressSnapshot(
            detectedFileCount: uniquePaths.count,
            hasEntryHTML: hasHTMLPath
                || hasPHPPath
                || hasHTMLLikeFile
                || hasPHPLikeFile
                || hasHTMLText
                || hasPHPText
        ) : nil

        if !message.isStreaming {
            storeProgressSnapshotCache(snapshot, for: message.id)
        }
        return snapshot
    }

    static func projectsRootURL() -> URL? {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsURL.appendingPathComponent("FrontendProjects", isDirectory: true)
    }

    static func latestProjectURL() -> URL? {
        projectsRootURL()?.appendingPathComponent("latest", isDirectory: true)
    }

    static func latestEntryFileURL() -> URL? {
        guard let latest = latestProjectURL() else { return nil }

        if let pointed = pointedLatestEntryFileURL(in: latest) {
            return pointed
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: latest,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var entryCandidates: [(url: URL, size: Int)] = []
        for case let fileURL as URL in enumerator {
            guard isPreviewEntryPath(fileURL.lastPathComponent) else { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            entryCandidates.append((fileURL, size))
        }

        guard !entryCandidates.isEmpty else { return nil }

        if let rootIndexHTML = entryCandidates.first(where: {
            $0.url.lastPathComponent.lowercased() == "index.html"
                && $0.url.deletingLastPathComponent().standardizedFileURL == latest.standardizedFileURL
        }) {
            return rootIndexHTML.url
        }

        if let rootIndexPHP = entryCandidates.first(where: {
            $0.url.lastPathComponent.lowercased() == "index.php"
                && $0.url.deletingLastPathComponent().standardizedFileURL == latest.standardizedFileURL
        }) {
            return rootIndexPHP.url
        }

        if let nestedIndexHTML = entryCandidates.first(where: { $0.url.lastPathComponent.lowercased() == "index.html" }) {
            return nestedIndexHTML.url
        }

        if let nestedIndexPHP = entryCandidates.first(where: { $0.url.lastPathComponent.lowercased() == "index.php" }) {
            return nestedIndexPHP.url
        }

        if let richest = entryCandidates.max(by: { lhs, rhs in
            if lhs.size == rhs.size {
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
            return lhs.size < rhs.size
        }) {
            return richest.url
        }

        return entryCandidates.first?.url
    }

    private static func pointedLatestEntryFileURL(in latest: URL) -> URL? {
        let pointerURL = latest.appendingPathComponent(latestEntryPointerFileName, isDirectory: false)
        guard let raw = try? String(contentsOf: pointerURL, encoding: .utf8) else { return nil }
        let trimmed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let relativePath = sanitizeRelativePath(trimmed), isPreviewEntryPath(relativePath) else {
            return nil
        }

        let candidate = latest.appendingPathComponent(relativePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    static func projectsRootPathDisplay() -> String {
        projectsRootURL()?.path ?? "不可用"
    }

    static func latestProjectPathDisplay() -> String {
        latestProjectURL()?.path ?? "不可用"
    }

    static func clearLatestProject() throws {
        let fileManager = FileManager.default
        guard let latest = latestProjectURL() else {
            throw BuildError.invalidProjectDirectory
        }

        if fileManager.fileExists(atPath: latest.path) {
            try fileManager.removeItem(at: latest)
        }
        try fileManager.createDirectory(at: latest, withIntermediateDirectories: true)
    }

    static func buildProject(
        from message: ChatMessage,
        mode: BuildMode,
        useParseCache: Bool = true
    ) throws -> BuildResult {
        var parsedFiles = useParseCache
            ? extractProjectFiles(from: message)
            : extractProjectFilesWithoutCache(from: message)
        if parsedFiles.isEmpty {
            if let fallbackHTML = fallbackHTML(in: message.content) {
                parsedFiles = [ParsedWebFile(path: "index.html", content: fallbackHTML)]
            } else if let fallbackPHP = fallbackPHP(in: message.content) {
                parsedFiles = [ParsedWebFile(path: "index.php", content: fallbackPHP)]
            }
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

        promoteHTMLLikeFilePathsIfNeeded(merged: &merged, orderedPaths: &orderedPaths)

        let hadNaturalPreviewEntry = orderedPaths.contains(where: { isPreviewEntryPath($0) })
        let stylePaths = orderedPaths.filter { isStylePath($0) }
        let scriptPaths = orderedPaths.filter { isScriptPath($0) }

        if !hadNaturalPreviewEntry {
            let synthesized = synthesizedIndexHTML(
                stylePaths: stylePaths,
                scriptPaths: scriptPaths,
                projectPaths: orderedPaths
            )
            if merged["index.html"] == nil {
                orderedPaths.insert("index.html", at: 0)
            }
            merged["index.html"] = synthesized
        }

        guard let entryRelativePath = preferredEntryPath(from: orderedPaths) else {
            throw BuildError.missingEntryFile
        }

        if isHTMLPath(entryRelativePath) {
            let currentEntryHTML = merged[entryRelativePath] ?? ""
            merged[entryRelativePath] = normalizedEntryHTMLIfNeeded(
                currentEntryHTML,
                stylePaths: stylePaths,
                scriptPaths: scriptPaths
            )
        }

        if isHTMLPath(entryRelativePath) {
            let currentEntryHTML = merged[entryRelativePath] ?? ""
            resolveReferencedAssetAliases(
                entryRelativePath: entryRelativePath,
                entryHTML: currentEntryHTML,
                merged: &merged,
                orderedPaths: &orderedPaths
            )
            autoWireEntryAssetReferencesIfNeeded(
                entryRelativePath: entryRelativePath,
                merged: &merged,
                orderedPaths: orderedPaths
            )
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

        guard let finalizedEntryHTML = merged[entryRelativePath] else {
            throw BuildError.missingEntryFile
        }

        persistLatestEntryPointerIfNeeded(
            mode: mode,
            projectDirectoryURL: projectDirectoryURL,
            entryRelativePath: entryRelativePath
        )

        return BuildResult(
            projectDirectoryURL: projectDirectoryURL,
            entryFileURL: projectDirectoryURL.appendingPathComponent(entryRelativePath, isDirectory: false),
            entryHTML: finalizedEntryHTML,
            writtenRelativePaths: orderedPaths,
            createdNewProject: mode == .createNewProject,
            shouldAutoOpenPreview: hadNaturalPreviewEntry || !stylePaths.isEmpty || !scriptPaths.isEmpty,
            hadNaturalPreviewEntry: hadNaturalPreviewEntry
        )
    }

    private static func persistLatestEntryPointerIfNeeded(
        mode: BuildMode,
        projectDirectoryURL: URL,
        entryRelativePath: String
    ) {
        guard mode == .overwriteLatestProject else { return }
        guard let normalized = sanitizeRelativePath(entryRelativePath), isPreviewEntryPath(normalized) else { return }

        let pointerURL = projectDirectoryURL.appendingPathComponent(latestEntryPointerFileName, isDirectory: false)
        try? "\(normalized)\n".write(to: pointerURL, atomically: true, encoding: .utf8)
    }

    private static func extractProjectFiles(from message: ChatMessage) -> [ParsedWebFile] {
        if !message.isStreaming, let cached = parsedFilesCache[message.id] {
            return cached
        }

        let merged = extractProjectFilesWithoutCache(from: message)
        if !message.isStreaming {
            storeParsedFilesCache(merged, for: message.id)
        }
        return merged
    }

    private static func extractProjectFilesWithoutCache(from message: ChatMessage) -> [ParsedWebFile] {
        var files: [ParsedWebFile] = []

        for attachment in message.fileAttachments {
            guard attachment.binaryBase64 == nil else { continue }
            guard let path = sanitizeRelativePath(attachment.fileName) else { continue }
            let content = normalizeFileContent(
                unwrapSingleFencedTaggedFileContent(attachment.textContent)
            )
            guard !content.isEmpty else { continue }
            files.append(ParsedWebFile(path: path, content: content))
        }

        let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        files.append(contentsOf: parseTaggedFiles(in: text))
        files.append(contentsOf: parseFencedCodeBlocks(in: text))
        return mergeParsedFiles(files)
    }

    private static func storeCanGenerateCache(_ value: Bool, for messageID: UUID) {
        canGenerateCache[messageID] = value
        canGenerateCacheOrder.removeAll(where: { $0 == messageID })
        canGenerateCacheOrder.append(messageID)
        while canGenerateCacheOrder.count > canGenerateCacheLimit {
            let removed = canGenerateCacheOrder.removeFirst()
            canGenerateCache.removeValue(forKey: removed)
        }
    }

    private static func storeProgressSnapshotCache(_ value: ChatProgressSnapshot?, for messageID: UUID) {
        progressSnapshotCache[messageID] = value.map { .some($0) } ?? .none
        progressSnapshotCacheOrder.removeAll(where: { $0 == messageID })
        progressSnapshotCacheOrder.append(messageID)
        while progressSnapshotCacheOrder.count > progressSnapshotCacheLimit {
            let removed = progressSnapshotCacheOrder.removeFirst()
            progressSnapshotCache.removeValue(forKey: removed)
        }
    }

    private static func storeParsedFilesCache(_ value: [ParsedWebFile], for messageID: UUID) {
        parsedFilesCache[messageID] = value
        parsedFilesCacheOrder.removeAll(where: { $0 == messageID })
        parsedFilesCacheOrder.append(messageID)
        while parsedFilesCacheOrder.count > parsedFilesCacheLimit {
            let removed = parsedFilesCacheOrder.removeFirst()
            parsedFilesCache.removeValue(forKey: removed)
        }
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
            let rawContent = String(text[contentRange])
            let content = normalizeFileContent(unwrapSingleFencedTaggedFileContent(rawContent))
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
            guard !containsTaggedFileMarker(codeContent) else { continue }

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

        let trimmedDescriptor = descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pathLike = pathLikeDescriptorPath(trimmedDescriptor),
           let normalized = sanitizeRelativePath(pathLike) {
            return normalized
        }

        if let mapped = mappedPathFromLanguage(trimmedDescriptor) {
            return mapped
        }

        if shouldTryPrefixHints(for: trimmedDescriptor) {
            if let hinted = sanitizeRelativePath(extractPathHintFromPrefix(prefixText)) {
                return hinted
            }
            if let bareHint = sanitizeRelativePath(extractBarePathFromPrefix(prefixText)) {
                return bareHint
            }
        }

        if trimmedDescriptor.isEmpty, looksLikeHTML(codeContent) {
            return "index.html"
        }
        if trimmedDescriptor.isEmpty, looksLikePHP(codeContent) {
            return "index.php"
        }

        return nil
    }

    private static func shouldTryPrefixHints(for _: String) -> Bool {
        return true
    }

    private static func containsTaggedFile(in text: String) -> Bool {
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
            if sanitizeRelativePath(rawPath) != nil {
                return true
            }
        }
        return false
    }

    private static func containsLikelyProjectFencedBlock(in text: String) -> Bool {
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

            let descriptor = String(text[descriptorRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixStart = max(0, match.range.location - 260)
            let prefixLength = max(0, match.range.location - prefixStart)
            let prefix = nsText.substring(with: NSRange(location: prefixStart, length: prefixLength))

            if resolvePathForFencedBlock(
                descriptor: descriptor,
                codeContent: content,
                prefixText: prefix
            ) != nil {
                return true
            }

            if looksLikeHTML(content) {
                return true
            }
            if looksLikePHP(content) {
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

    private static func extractBarePathFromPrefix(_ prefix: String) -> String {
        let lines = prefix
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .reversed()

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            line = line.replacingOccurrences(
                of: #"^[#>*\-\+\d\.\)\(\s`]+|[`]+$"#,
                with: "",
                options: .regularExpression
            )
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if isLikelyBarePathHint(line) {
                return line
            }
        }

        return ""
    }

    private static func isLikelyBarePathHint(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }

        if line.contains("<")
            || line.contains(">")
            || line.contains("=")
            || line.contains("\"")
            || line.contains("'")
            || line.contains("`") {
            return false
        }

        let normalized = line.replacingOccurrences(of: "\\", with: "/")
        let lowered = normalized.lowercased()
        if wellKnownProjectFileNames.contains(lowered) {
            return true
        }

        guard normalized.range(of: #"^[A-Za-z0-9_./\\@+\-]+$"#, options: .regularExpression) != nil else {
            return false
        }

        let fileName = (normalized as NSString).lastPathComponent.lowercased()
        if wellKnownProjectFileNames.contains(fileName) {
            return true
        }

        if fileName.hasPrefix("."),
           fileName.count > 1,
           fileName.dropFirst().contains(where: { $0.isLetter }) {
            return true
        }

        if let ext = fileName.split(separator: ".").last, ext.count <= 12 {
            let extLower = ext.lowercased()
            if commonProjectExtensions.contains(extLower) {
                return true
            }
        }

        return false
    }

    private static func pathLikeDescriptorPath(_ descriptor: String) -> String? {
        let trimmed = descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let loweredTrimmed = trimmed.lowercased()
        if !trimmed.contains(" ") {
            if knownLanguageDescriptors.contains(loweredTrimmed) {
                return nil
            }
            if isLikelyProjectPath(trimmed) {
                return trimmed
            }
        }

        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        let firstTokenIsLanguage = knownLanguageDescriptors.contains(tokens[0].lowercased())
        let candidateTokens = firstTokenIsLanguage ? Array(tokens.dropFirst()) : tokens

        for token in candidateTokens {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"(),:"))
            guard !candidate.isEmpty else { continue }
            if isLikelyProjectPath(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func mappedPathFromLanguage(_ language: String) -> String? {
        switch normalizeLanguageDescriptor(language) {
        case "html", "htm", "xhtml", "text/html":
            return "index.html"
        case "php", "phtml", "text/php", "application/php":
            return "index.php"
        case "css", "scss", "sass", "less":
            return "styles.css"
        case "javascript", "js":
            return "script.js"
        case "typescript", "ts":
            return "app.js"
        case "jsx":
            return "src/App.jsx"
        case "tsx":
            return "src/App.tsx"
        case "vue":
            return "App.vue"
        case "python", "py", "python3":
            return "main.py"
        case "swift":
            return "main.swift"
        case "go":
            return "main.go"
        case "rust", "rs":
            return "src/main.rs"
        case "java":
            return "Main.java"
        case "kotlin", "kt":
            return "Main.kt"
        case "kts":
            return "build.gradle.kts"
        case "c":
            return "main.c"
        case "cpp", "c++", "cc", "cxx":
            return "main.cpp"
        case "csharp", "cs":
            return "Program.cs"
        case "ruby", "rb":
            return "main.rb"
        case "lua":
            return "main.lua"
        case "r":
            return "main.R"
        case "scala":
            return "Main.scala"
        case "dart":
            return "lib/main.dart"
        case "json":
            return "data.json"
        case "yaml", "yml":
            return "config.yaml"
        case "toml":
            return "config.toml"
        case "xml":
            return "config.xml"
        case "ini", "properties":
            return "config.ini"
        case "markdown", "md":
            return "README.md"
        case "sql":
            return "schema.sql"
        case "dockerfile":
            return "Dockerfile"
        case "makefile":
            return "Makefile"
        default:
            return nil
        }
    }

    private static func normalizeLanguageDescriptor(_ descriptor: String) -> String {
        let trimmed = descriptor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if knownLanguageDescriptors.contains(trimmed) {
            return trimmed
        }

        let token = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()[]{}")) ?? trimmed

        if knownLanguageDescriptors.contains(token) {
            return token
        }
        return token
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
            let existingHasMarker = containsTaggedFileMarker(existing)
            let candidateHasMarker = containsTaggedFileMarker(normalizedContent)

            if existingHasMarker != candidateHasMarker {
                if !candidateHasMarker {
                    merged[normalizedPath] = normalizedContent
                }
                continue
            }

            if normalizedContent.count >= existing.count {
                merged[normalizedPath] = normalizedContent
            }
        }

        return order.compactMap { path in
            guard let content = merged[path] else { return nil }
            return ParsedWebFile(path: path, content: content)
        }
    }

    private static func resolveReferencedAssetAliases(
        entryRelativePath: String,
        entryHTML: String,
        merged: inout [String: String],
        orderedPaths: inout [String]
    ) {
        let references = referencedLocalAssetPaths(in: entryHTML, entryRelativePath: entryRelativePath)
        guard !references.isEmpty else { return }

        for referencedPath in references {
            guard merged[referencedPath] == nil else { continue }
            guard let sourcePath = pickAliasSourcePath(for: referencedPath, existingPaths: orderedPaths),
                  let sourceContent = merged[sourcePath] else {
                continue
            }
            merged[referencedPath] = sourceContent
            orderedPaths.append(referencedPath)
        }
    }

    private static func autoWireEntryAssetReferencesIfNeeded(
        entryRelativePath: String,
        merged: inout [String: String],
        orderedPaths: [String]
    ) {
        guard var entryHTML = merged[entryRelativePath] else { return }
        let referencedPaths = referencedLocalAssetPaths(in: entryHTML, entryRelativePath: entryRelativePath)
        let hasLinkedStylesheet = referencedPaths.contains(where: { isBrowserStylePath($0) })
        let hasLinkedScript = referencedPaths.contains(where: { isBrowserScriptPath($0) })

        if !hasLinkedStylesheet {
            let styleCandidates = orderedPaths.filter { path in
                path != entryRelativePath && isBrowserStylePath(path)
            }
            if let stylePath = pickPreferredAutoLinkedAssetPath(
                entryRelativePath: entryRelativePath,
                candidatePaths: styleCandidates,
                preferredBasenames: ["styles.css", "style.css", "main.css", "app.css"]
            ) {
                let href = relativeReferencePath(from: entryRelativePath, to: stylePath)
                entryHTML = injectStylesheetReference(href: href, into: entryHTML)
            }
        }

        if !hasLinkedScript {
            let scriptCandidates = orderedPaths.filter { path in
                path != entryRelativePath && isBrowserScriptPath(path)
            }
            if let scriptPath = pickPreferredAutoLinkedAssetPath(
                entryRelativePath: entryRelativePath,
                candidatePaths: scriptCandidates,
                preferredBasenames: ["script.js", "app.js", "main.js", "index.js"]
            ) {
                let src = relativeReferencePath(from: entryRelativePath, to: scriptPath)
                entryHTML = injectScriptReference(src: src, into: entryHTML)
            }
        }

        merged[entryRelativePath] = entryHTML
    }

    private static func normalizedEntryHTMLIfNeeded(
        _ rawEntryHTML: String,
        stylePaths: [String],
        scriptPaths: [String]
    ) -> String {
        let normalized = rawEntryHTML.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return synthesizedIndexHTML(
                stylePaths: stylePaths,
                scriptPaths: scriptPaths,
                projectPaths: []
            )
        }

        let lowered = trimmed.lowercased()
        let hasDocumentStructure = lowered.contains("<!doctype html")
            || lowered.contains("<html")
            || lowered.contains("<body")

        guard !hasDocumentStructure else {
            return normalized
        }

        // Model may output a fragment (or plain text) as index.html; wrap it to avoid blank preview.
        let styleLines = stylePaths.map { "    <link rel=\"stylesheet\" href=\"\($0)\">" }
        let scriptLines = scriptPaths.map { "    <script src=\"\($0)\"></script>" }
        let styleBlock = styleLines.isEmpty ? "" : (styleLines.joined(separator: "\n") + "\n")
        let scriptBlock = scriptLines.isEmpty ? "" : ("\n" + scriptLines.joined(separator: "\n"))
        let bodyContent: String
        if trimmed.contains("<") && trimmed.contains(">") {
            bodyContent = trimmed
        } else {
            bodyContent = "<main><pre>\(htmlEscaped(trimmed))</pre></main>"
        }

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>IEXA Project</title>
        \(styleBlock)</head>
        <body>
        \(bodyContent)\(scriptBlock)
        </body>
        </html>
        """
    }

    private static func referencedLocalAssetPaths(
        in html: String,
        entryRelativePath: String
    ) -> [String] {
        let pattern = #"(?i)(?:href|src)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)
        guard !matches.isEmpty else { return [] }

        var result: [String] = []
        var seen = Set<String>()
        for match in matches {
            guard let refRange = Range(match.range(at: 1), in: html) else { continue }
            let rawReference = String(html[refRange])
            guard let normalized = normalizeLocalReferencePath(rawReference, entryRelativePath: entryRelativePath) else {
                continue
            }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    private static func pickPreferredAutoLinkedAssetPath(
        entryRelativePath: String,
        candidatePaths: [String],
        preferredBasenames: [String]
    ) -> String? {
        guard !candidatePaths.isEmpty else { return nil }

        let entryDirectory = (entryRelativePath as NSString).deletingLastPathComponent.lowercased()
        for preferredBase in preferredBasenames {
            if let sameDirectory = candidatePaths.first(where: { path in
                let base = (path as NSString).lastPathComponent.lowercased()
                let directory = (path as NSString).deletingLastPathComponent.lowercased()
                return base == preferredBase && directory == entryDirectory
            }) {
                return sameDirectory
            }
        }

        if let sameDirectoryAny = candidatePaths.first(where: {
            ($0 as NSString).deletingLastPathComponent.lowercased() == entryDirectory
        }) {
            return sameDirectoryAny
        }

        for preferredBase in preferredBasenames {
            if let preferredAny = candidatePaths.first(where: {
                ($0 as NSString).lastPathComponent.lowercased() == preferredBase
            }) {
                return preferredAny
            }
        }

        return candidatePaths.first
    }

    private static func relativeReferencePath(from entryRelativePath: String, to targetRelativePath: String) -> String {
        let baseDirectory = (entryRelativePath as NSString)
            .deletingLastPathComponent
            .replacingOccurrences(of: "\\", with: "/")
        let baseComponents = baseDirectory
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let targetComponents = targetRelativePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !targetComponents.isEmpty else { return targetRelativePath }

        var commonCount = 0
        let limit = min(baseComponents.count, targetComponents.count)
        while commonCount < limit && baseComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }

        var parts = Array(repeating: "..", count: max(0, baseComponents.count - commonCount))
        parts.append(contentsOf: targetComponents.dropFirst(commonCount))

        if parts.isEmpty {
            return targetComponents.last ?? targetRelativePath
        }
        return parts.joined(separator: "/")
    }

    private static func injectStylesheetReference(href: String, into html: String) -> String {
        let normalizedHref = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHref.isEmpty else { return html }
        let loweredHTML = html.lowercased()
        let loweredHref = normalizedHref.lowercased()
        if loweredHTML.contains("href=\"\(loweredHref)\"") || loweredHTML.contains("href='\(loweredHref)'") {
            return html
        }

        let tagLine = "    <link rel=\"stylesheet\" href=\"\(normalizedHref)\">"
        if let headCloseRange = firstRegexRange(of: #"(?i)</head\s*>"#, in: html) {
            return html.replacingCharacters(in: headCloseRange.lowerBound..<headCloseRange.lowerBound, with: "\(tagLine)\n")
        }
        if let bodyOpenRange = firstRegexRange(of: #"(?i)<body[^>]*>"#, in: html) {
            return html.replacingCharacters(in: bodyOpenRange.upperBound..<bodyOpenRange.upperBound, with: "\n\(tagLine)")
        }
        return "\(tagLine)\n\(html)"
    }

    private static func injectScriptReference(src: String, into html: String) -> String {
        let normalizedSrc = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSrc.isEmpty else { return html }
        let loweredHTML = html.lowercased()
        let loweredSrc = normalizedSrc.lowercased()
        if loweredHTML.contains("src=\"\(loweredSrc)\"") || loweredHTML.contains("src='\(loweredSrc)'") {
            return html
        }

        let tagLine = "    <script src=\"\(normalizedSrc)\"></script>"
        if let bodyCloseRange = firstRegexRange(of: #"(?i)</body\s*>"#, in: html) {
            return html.replacingCharacters(in: bodyCloseRange.lowerBound..<bodyCloseRange.lowerBound, with: "\(tagLine)\n")
        }
        if let htmlCloseRange = firstRegexRange(of: #"(?i)</html\s*>"#, in: html) {
            return html.replacingCharacters(in: htmlCloseRange.lowerBound..<htmlCloseRange.lowerBound, with: "\(tagLine)\n")
        }
        return "\(html)\n\(tagLine)"
    }

    private static func firstRegexRange(of pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }
        return Range(match.range, in: text)
    }

    private static func normalizeLocalReferencePath(
        _ rawReference: String,
        entryRelativePath: String
    ) -> String? {
        var reference = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }

        if let hashIndex = reference.firstIndex(of: "#") {
            reference = String(reference[..<hashIndex])
        }
        if let queryIndex = reference.firstIndex(of: "?") {
            reference = String(reference[..<queryIndex])
        }
        reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }

        let lowered = reference.lowercased()
        if lowered.hasPrefix("http://")
            || lowered.hasPrefix("https://")
            || lowered.hasPrefix("//")
            || lowered.hasPrefix("data:")
            || lowered.hasPrefix("javascript:")
            || lowered.hasPrefix("mailto:")
            || lowered.hasPrefix("tel:") {
            return nil
        }

        let entryDirectory = (entryRelativePath as NSString).deletingLastPathComponent
        let combinedPath: String
        if reference.hasPrefix("/") {
            combinedPath = String(reference.drop(while: { $0 == "/" }))
        } else if entryDirectory.isEmpty {
            combinedPath = reference
        } else {
            combinedPath = "\(entryDirectory)/\(reference)"
        }

        return sanitizeRelativePath(combinedPath)
    }

    private static func pickAliasSourcePath(
        for referencedPath: String,
        existingPaths: [String]
    ) -> String? {
        if isStylePath(referencedPath) {
            return bestAliasPath(
                requestedPath: referencedPath,
                candidatePaths: existingPaths.filter { isStylePath($0) },
                preferredBasenames: ["styles.css", "style.css", "main.css", "app.css"]
            )
        }
        if isScriptPath(referencedPath) {
            return bestAliasPath(
                requestedPath: referencedPath,
                candidatePaths: existingPaths.filter { isScriptPath($0) },
                preferredBasenames: ["script.js", "app.js", "main.js", "index.js"]
            )
        }
        return nil
    }

    private static func bestAliasPath(
        requestedPath: String,
        candidatePaths: [String],
        preferredBasenames: [String]
    ) -> String? {
        guard !candidatePaths.isEmpty else { return nil }

        let requestedBase = (requestedPath as NSString).lastPathComponent.lowercased()
        let requestedDir = (requestedPath as NSString).deletingLastPathComponent.lowercased()

        if let sameNameSameDir = candidatePaths.first(where: { path in
            let base = (path as NSString).lastPathComponent.lowercased()
            let dir = (path as NSString).deletingLastPathComponent.lowercased()
            return base == requestedBase && (requestedDir.isEmpty || requestedDir == dir)
        }) {
            return sameNameSameDir
        }

        if let sameNameAny = candidatePaths.first(where: {
            ($0 as NSString).lastPathComponent.lowercased() == requestedBase
        }) {
            return sameNameAny
        }

        for preferredBase in preferredBasenames {
            if let preferredSameDir = candidatePaths.first(where: { path in
                let base = (path as NSString).lastPathComponent.lowercased()
                let dir = (path as NSString).deletingLastPathComponent.lowercased()
                return base == preferredBase && (requestedDir.isEmpty || requestedDir == dir)
            }) {
                return preferredSameDir
            }
            if let preferredAny = candidatePaths.first(where: {
                ($0 as NSString).lastPathComponent.lowercased() == preferredBase
            }) {
                return preferredAny
            }
        }

        if !requestedDir.isEmpty,
           let sameDirAny = candidatePaths.first(where: {
               ($0 as NSString).deletingLastPathComponent.lowercased() == requestedDir
           }) {
            return sameDirAny
        }

        return candidatePaths.first
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

    private static func fallbackPHP(in text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let fenced = firstFencedPHP(in: trimmed) {
            return normalizeFileContent(fenced)
        }

        if looksLikePHP(trimmed) {
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

    private static func firstFencedPHP(in text: String) -> String? {
        let pattern = #"(?is)```(?:php|phtml|text/php|application/php)\s*\n(.*?)```"#
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

    private static func looksLikePHP(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("<?php")
            || lowered.contains("<?= ")
            || lowered.contains("<?=")
    }

    private static func isLikelyProjectPath(_ rawPath: String) -> Bool {
        let path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        guard !path.isEmpty else { return false }

        if wellKnownProjectFileNames.contains(path) {
            return true
        }

        let fileName = (path as NSString).lastPathComponent
        if wellKnownProjectFileNames.contains(fileName) {
            return true
        }

        if fileName.hasPrefix("."),
           fileName.count > 1,
           fileName.dropFirst().contains(where: { $0.isLetter }) {
            return true
        }

        if let ext = fileName.split(separator: ".").last,
           commonProjectExtensions.contains(String(ext)) {
            return true
        }

        if let ext = fileName.split(separator: ".").last,
           ext.count <= 12,
           ext.contains(where: { $0.isLetter }) {
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

        let preserveLeadingDot = trimmed.hasPrefix(".")
        let allowedExtraScalars = CharacterSet(charactersIn: "._- @+")
        var buffer = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || allowedExtraScalars.contains(scalar) {
                buffer.unicodeScalars.append(scalar)
            } else {
                buffer.append("-")
            }
        }
        var normalized = buffer
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if preserveLeadingDot {
            normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !normalized.isEmpty else { return nil }
            return ".\(normalized)"
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeFileContent(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return removeLeakedTaggedFileMarkers(from: normalized)
    }

    private static func containsTaggedFileMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("[[file:") || lowered.contains("[[endfile]]")
    }

    private static func removeLeakedTaggedFileMarkers(from raw: String) -> String {
        var text = raw

        text = text.replacingOccurrences(
            of: #"(?is)\s*\[\[endfile\]\]\s*\[\[file:[^\]]+\]\]\s*"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?im)^\s*\[\[(?:endfile|file:[^\]]+)\]\]\s*$"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrapSingleFencedTaggedFileContent(_ raw: String) -> String {
        let normalized = normalizeFileContent(raw)
        guard normalized.hasPrefix("```"), normalized.hasSuffix("```") else {
            return normalized
        }

        var inner = String(normalized.dropFirst(3))
        guard inner.count >= 3 else { return normalized }
        inner.removeLast(3)

        let normalizedInner = normalizeFileContent(inner)
        guard let newlineIndex = normalizedInner.firstIndex(of: "\n") else {
            return normalizedInner
        }

        let descriptor = normalizedInner[..<newlineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyStart = normalizedInner.index(after: newlineIndex)
        let body = normalizeFileContent(String(normalizedInner[bodyStart...]))
        let content = (!descriptor.isEmpty && !descriptor.contains(" ") && !body.isEmpty)
            ? body
            : normalizedInner
        return content.isEmpty ? normalized : content
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
            if fileManager.fileExists(atPath: latest.path) {
                try fileManager.removeItem(at: latest)
            }
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
        if let html = paths.first(where: { isHTMLPath($0) }) {
            return html
        }
        if let exactPHP = paths.first(where: { $0.lowercased().hasSuffix("index.php") }) {
            return exactPHP
        }
        return paths.first(where: { isPHPPath($0) })
    }

    private static func promoteHTMLLikeFilePathsIfNeeded(
        merged: inout [String: String],
        orderedPaths: inout [String]
    ) {
        guard !orderedPaths.contains(where: { isHTMLPath($0) }) else { return }
        guard let candidatePath = orderedPaths.first(where: { path in
            guard let content = merged[path] else { return false }
            return looksLikeHTML(content)
        }) else {
            return
        }
        guard let content = merged[candidatePath] else { return }

        let promotedPath = promotedHTMLPath(from: candidatePath)
        guard promotedPath != candidatePath else { return }

        if merged[promotedPath] == nil {
            merged[promotedPath] = content
        }
        merged.removeValue(forKey: candidatePath)

        if let index = orderedPaths.firstIndex(of: candidatePath) {
            orderedPaths[index] = promotedPath
        } else {
            orderedPaths.append(promotedPath)
        }
    }

    private static func promotedHTMLPath(from rawPath: String) -> String {
        if isHTMLPath(rawPath) { return rawPath }

        let path = rawPath as NSString
        let directory = path.deletingLastPathComponent
        let fileName = path.lastPathComponent

        let promotedName: String
        if fileName.isEmpty {
            promotedName = "index.html"
        } else if fileName.contains(".") {
            let stem = (fileName as NSString).deletingPathExtension
            promotedName = stem.isEmpty ? "index.html" : "\(stem).html"
        } else {
            promotedName = fileName.lowercased() == "index" ? "index.html" : "\(fileName).html"
        }

        if directory.isEmpty {
            return promotedName
        }
        return "\(directory)/\(promotedName)"
    }

    private static func isHTMLPath(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".htm")
    }

    private static func isPHPPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".php") || lowered.hasSuffix(".phtml")
    }

    private static func isPreviewEntryPath(_ path: String) -> Bool {
        isHTMLPath(path) || isPHPPath(path)
    }

    private static func isStylePath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".css")
            || lowered.hasSuffix(".scss")
            || lowered.hasSuffix(".sass")
            || lowered.hasSuffix(".less")
    }

    private static func isBrowserStylePath(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".css")
    }

    private static func isScriptPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".js")
            || lowered.hasSuffix(".mjs")
            || lowered.hasSuffix(".cjs")
            || lowered.hasSuffix(".ts")
    }

    private static func isBrowserScriptPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".js")
            || lowered.hasSuffix(".mjs")
            || lowered.hasSuffix(".cjs")
    }

    private static func synthesizedIndexHTML(
        stylePaths: [String],
        scriptPaths: [String],
        projectPaths: [String]
    ) -> String {
        let styleLinks = stylePaths.map { "    <link rel=\"stylesheet\" href=\"\($0)\">" }
        let scripts = scriptPaths.map { "    <script src=\"\($0)\"></script>" }
        let styleBlock = styleLinks.isEmpty ? "" : (styleLinks.joined(separator: "\n") + "\n")
        let scriptBlock = scripts.isEmpty ? "" : ("\n" + scripts.joined(separator: "\n"))
        let renderedList = projectPaths
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(48)
            .map { "            <li><code>\(htmlEscaped($0))</code></li>" }
            .joined(separator: "\n")
        let fileListBlock = renderedList.isEmpty ? "" : """
                <section class=\"files\">
                    <h2>已写入文件</h2>
                    <ul>
        \(renderedList)
                    </ul>
                </section>
        """
        let nonWebNotice = (stylePaths.isEmpty && scriptPaths.isEmpty) ? """
                <p class=\"notice\">当前项目以源码文件为主（非网页入口），请在 latest 目录查看完整代码结构。</p>
        """ : ""

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>IEXA Project</title>
            <style>
                :root {
                    color-scheme: light dark;
                }
                body {
                    margin: 0;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                    line-height: 1.55;
                    background: radial-gradient(circle at top, rgba(43, 104, 255, 0.14), transparent 58%);
                    padding: 24px;
                }
                .card {
                    max-width: 860px;
                    margin: 0 auto;
                    border: 1px solid rgba(128, 128, 128, 0.26);
                    border-radius: 16px;
                    background: rgba(255, 255, 255, 0.78);
                    backdrop-filter: blur(8px);
                    padding: 18px 18px 8px 18px;
                }
                h1 {
                    margin: 0 0 8px 0;
                    font-size: 20px;
                }
                .desc {
                    margin: 0 0 10px 0;
                    color: rgba(80, 80, 80, 0.92);
                }
                .notice {
                    margin: 10px 0 4px 0;
                    font-size: 14px;
                    color: rgba(100, 84, 0, 0.98);
                    background: rgba(255, 214, 10, 0.14);
                    border: 1px solid rgba(255, 214, 10, 0.35);
                    border-radius: 10px;
                    padding: 8px 10px;
                }
                .files h2 {
                    margin: 14px 0 8px 0;
                    font-size: 14px;
                    opacity: 0.86;
                    letter-spacing: 0.02em;
                }
                ul {
                    margin: 0;
                    padding-left: 20px;
                }
                li {
                    margin: 4px 0;
                }
                code {
                    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
                }
            </style>
        \(styleBlock)</head>
        <body>
            <main class="card">
                <h1>IEXA 已生成本地项目</h1>
                <p class="desc">可在应用设置中的 latest 目录查看和管理全部文件。</p>
        \(nonWebNotice)
        \(fileListBlock)
                <div id="app"></div>
            </main>\(scriptBlock)
        </body>
        </html>
        """
    }

    private static func htmlEscaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
