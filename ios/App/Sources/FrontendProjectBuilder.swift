import Foundation

enum FrontendProjectBuilder {
    enum BuildMode {
        case createNewProject
        case overwriteLatestProject
    }

    enum WorkspaceOperation: Equatable {
        case clearLatest
        case createDirectory(path: String)
        case createEmptyFile(path: String)
        case delete(path: String)

        var path: String? {
            switch self {
            case .clearLatest:
                return nil
            case .createDirectory(let path), .createEmptyFile(let path), .delete(let path):
                return path
            }
        }
    }

    struct BuildResult {
        let projectDirectoryURL: URL
        let entryFileURL: URL
        let entryHTML: String
        let previewEntryFileURL: URL?
        let previewEntryHTML: String?
        let writtenRelativePaths: [String]
        let writtenFiles: [String: String]
        let validationPlan: ValidationPlan?
        let suggestedValidationCommand: String?
        let createdNewProject: Bool
        let shouldAutoOpenPreview: Bool
        let hadNaturalPreviewEntry: Bool
        let workspaceOperations: [WorkspaceOperation]
    }

    struct WorkspaceMutationResult: Equatable {
        let operations: [WorkspaceOperation]
        let affectedPaths: [String]
    }

    struct ValidationPlan: Equatable {
        let installCommand: String?
        let runCommand: String

        var fullCommand: String {
            if let installCommand, !installCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(installCommand) && \(runCommand)"
            }
            return runCommand
        }
    }

    struct ChatProgressSnapshot {
        let detectedFileCount: Int
        let hasEntryHTML: Bool
    }

    enum BuildError: LocalizedError {
        case noFrontendContent
        case noWorkspaceOperations
        case invalidProjectDirectory
        case missingEntryFile

        var errorDescription: String? {
            switch self {
            case .noFrontendContent:
                return "没有识别到可落盘的项目代码。请让模型按 [[file:...]] 或代码块输出。"
            case .noWorkspaceOperations:
                return "没有识别到可执行的工作区操作。请使用 [[mkdir:...]] / [[touch:...]] / [[delete:...]] / [[clear:latest]]。"
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

    private struct ExistingProjectSnapshot {
        let files: [ParsedWebFile]
        let preferredEntryPath: String?
    }

    private struct LatestValidationSnapshot: Codable {
        let command: String
        let exitCode: Int
        let output: String
        let updatedAt: Date
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
    private static let latestPreviewDisabledFileName = ".iexa-no-preview"
    private static let latestValidationSnapshotFileName = ".iexa-latest-validation.json"
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
        if hasExplicitWorkspaceOperationPayload(from: message) {
            canGenerate = true
        } else if message.fileAttachments.contains(where: {
            $0.binaryBase64 == nil
                && sanitizeRelativePath($0.fileName) != nil
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

    static func hasExplicitProjectPayload(from message: ChatMessage) -> Bool {
        if hasExplicitWorkspaceOperationPayload(from: message) {
            return true
        }
        return hasExplicitProjectFilePayload(from: message)
    }

    static func hasExplicitProjectFilePayload(from message: ChatMessage) -> Bool {
        if message.fileAttachments.contains(where: {
            $0.binaryBase64 == nil
                && sanitizeRelativePath($0.fileName) != nil
        }) {
            return true
        }

        let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        return containsTaggedFile(in: text)
    }

    static func hasExplicitWorkspaceOperationPayload(from message: ChatMessage) -> Bool {
        !extractWorkspaceOperations(from: message).isEmpty
    }

    static func explicitWorkspaceOperations(from message: ChatMessage) -> [WorkspaceOperation] {
        extractWorkspaceOperations(from: message)
    }

    static func explicitPayloadProgressSnapshot(from message: ChatMessage) -> ChatProgressSnapshot? {
        if message.isStreaming {
            return explicitStreamingChatProgressSnapshot(from: message)
        }

        let workspaceOperations = extractWorkspaceOperations(from: message)
        if !workspaceOperations.isEmpty {
            return ChatProgressSnapshot(
                detectedFileCount: workspaceOperations.count,
                hasEntryHTML: false
            )
        }

        let parsed = extractExplicitProjectFiles(from: message)
        let normalizedPaths = parsed.map { $0.path.lowercased() }
        let uniquePaths = Array(Set(normalizedPaths))
        guard !uniquePaths.isEmpty else { return nil }

        let hasHTMLPath = uniquePaths.contains(where: { isHTMLPath($0) })
        let hasPHPPath = uniquePaths.contains(where: { isPHPPath($0) })

        return ChatProgressSnapshot(
            detectedFileCount: uniquePaths.count,
            hasEntryHTML: hasHTMLPath || hasPHPPath
        )
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

        if message.isStreaming {
            return fastStreamingChatProgressSnapshot(from: message)
        }

        let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        let parsed = extractProjectFiles(from: message)
        let normalizedPaths = parsed.map { $0.path.lowercased() }
        let uniquePaths = Array(Set(normalizedPaths))

        let hasHTMLPath = uniquePaths.contains(where: { isHTMLPath($0) })
        let hasPHPPath = uniquePaths.contains(where: { isPHPPath($0) })
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
        let hasInlinePreviewText = uniquePaths.isEmpty
            && !hasProjectAttachment
            && !hasTaggedFile
            && (hasHTMLText || hasPHPText)
        let snapshot: ChatProgressSnapshot? = shouldRenderProgress ? ChatProgressSnapshot(
            detectedFileCount: uniquePaths.count,
            hasEntryHTML: hasHTMLPath
                || hasPHPPath
                || hasInlinePreviewText
        ) : nil

        if !message.isStreaming {
            storeProgressSnapshotCache(snapshot, for: message.id)
        }
        return snapshot
    }

    private static func fastStreamingChatProgressSnapshot(from message: ChatMessage) -> ChatProgressSnapshot? {
        let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        let taggedFileCount = max(0, text.components(separatedBy: "[[file:").count - 1)
        let pathHintCount = countProjectPathHints(in: text)
        let attachmentCount = message.fileAttachments.count
        let detectedFileCount = max(taggedFileCount, pathHintCount, attachmentCount)

        let hasTaggedFile = taggedFileCount > 0
        let hasFencedProjectBlock = containsLikelyProjectFencedBlock(in: text)
        let hasHTMLText = looksLikeHTML(text)
        let hasPHPText = looksLikePHP(text)
        let taggedPaths = explicitTaggedPaths(in: text)
        let attachmentPaths = message.fileAttachments.compactMap { attachment -> String? in
            guard attachment.binaryBase64 == nil else { return nil }
            return sanitizeRelativePath(attachment.fileName)?.lowercased()
        }
        let hasPreviewPath = (taggedPaths + attachmentPaths).contains(where: { isHTMLPath($0) || isPHPPath($0) })
        let hasProjectAttachment = message.fileAttachments.contains(where: {
            $0.binaryBase64 == nil
                && sanitizeRelativePath($0.fileName) != nil
                && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })

        let shouldRenderProgress = detectedFileCount > 0
            || hasTaggedFile
            || hasFencedProjectBlock
            || hasHTMLText
            || hasPHPText
            || hasProjectAttachment

        guard shouldRenderProgress else { return nil }

        let hasEntryHTML = hasPreviewPath
            || (!hasTaggedFile && !hasProjectAttachment && (hasHTMLText || hasPHPText))

        return ChatProgressSnapshot(
            detectedFileCount: max(detectedFileCount, 1),
            hasEntryHTML: hasEntryHTML
        )
    }

    private static func explicitStreamingChatProgressSnapshot(from message: ChatMessage) -> ChatProgressSnapshot? {
        let text = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        let taggedPaths = explicitTaggedPaths(in: text)
        let attachmentPaths = message.fileAttachments.compactMap { attachment -> String? in
            guard attachment.binaryBase64 == nil else { return nil }
            guard !attachment.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return sanitizeRelativePath(attachment.fileName)?.lowercased()
        }
        let uniquePaths = Array(Set(taggedPaths + attachmentPaths))
        guard !uniquePaths.isEmpty else { return nil }

        let hasEntryHTML = uniquePaths.contains(where: { isHTMLPath($0) || isPHPPath($0) })
        return ChatProgressSnapshot(
            detectedFileCount: uniquePaths.count,
            hasEntryHTML: hasEntryHTML
        )
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

    static func normalizeWorkspaceRelativePath(_ rawPath: String) -> String? {
        sanitizeRelativePath(rawPath)
    }

    static func latestEntryFileURL() -> URL? {
        guard let latest = latestProjectURL() else { return nil }
        let disabledMarkerURL = latest.appendingPathComponent(latestPreviewDisabledFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: disabledMarkerURL.path) {
            return nil
        }

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

    static func latestProjectConversationContext() -> String? {
        guard let latest = latestProjectURL() else { return nil }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: latest.path) else { return nil }

        let relativePaths: [String] = {
            guard let enumerator = fileManager.enumerator(
                at: latest,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            var collected: [String] = []
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else {
                    continue
                }
                let absolute = fileURL.standardizedFileURL.path
                let root = latest.standardizedFileURL.path
                let relative = absolute.hasPrefix(root + "/")
                    ? String(absolute.dropFirst(root.count + 1))
                    : fileURL.lastPathComponent
                collected.append(relative)
            }
            return collected.sorted()
        }()

        let entryFileURL = latestEntryFileURL()
        let primaryPath = preferredPrimaryProjectPath(
            from: relativePaths,
            files: Dictionary(uniqueKeysWithValues: relativePaths.map { ($0, "") }),
            preferredPreviewPath: entryFileURL.map {
                let absolute = $0.standardizedFileURL.path
                let root = latest.standardizedFileURL.path
                return absolute.hasPrefix(root + "/")
                    ? String(absolute.dropFirst(root.count + 1))
                    : $0.lastPathComponent
            }
        ) ?? "无"

        var parts: [String] = []
        parts.append("当前 latest 工作区已有项目。")
        parts.append("主文件：\(primaryPath)")
        if let entryFileURL {
            parts.append("预览入口：\(entryFileURL.lastPathComponent)")
        }
        if !relativePaths.isEmpty {
            let filesText = relativePaths.prefix(20).map { "- \($0)" }.joined(separator: "\n")
            parts.append("文件列表：\n\(filesText)")
        }
        let snippets = latestProjectKeyFileSnippets(
            in: latest,
            entryFileURL: entryFileURL,
            relativePaths: relativePaths,
            preferredPrimaryPath: primaryPath
        )
        if !snippets.isEmpty {
            parts.append("关键文件片段：\n\(snippets.joined(separator: "\n\n"))")
        }
        if let validation = loadLatestValidationSnapshot() {
            parts.append("""
            最近一次自动验证：
            - 命令：\(validation.command)
            - 退出码：\(validation.exitCode)
            - 输出摘要：
            \(validation.output)
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func latestProjectKeyFileSnippets(
        in latest: URL,
        entryFileURL: URL?,
        relativePaths: [String],
        preferredPrimaryPath: String
    ) -> [String] {
        var targets: [String] = []

        if let normalized = sanitizeRelativePath(preferredPrimaryPath) {
            targets.append(normalized)
        }

        if let entryFileURL {
            let root = latest.standardizedFileURL.path
            let absolute = entryFileURL.standardizedFileURL.path
            if absolute.hasPrefix(root + "/") {
                targets.append(String(absolute.dropFirst(root.count + 1)))
            } else {
                targets.append(entryFileURL.lastPathComponent)
            }
        }

        let preferredNames = [
            "package.json",
            "requirements.txt",
            "pyproject.toml",
            "cargo.toml",
            "go.mod",
            "package.swift",
            "pom.xml",
            "build.gradle",
            "build.gradle.kts",
            "readme.md"
        ]
        for name in preferredNames {
            if let matched = relativePaths.first(where: { $0.lowercased() == name }) {
                targets.append(matched)
            }
        }

        var snippets: [String] = []
        var seen = Set<String>()
        for relativePath in targets {
            let normalized = relativePath.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            let fileURL = latest.appendingPathComponent(relativePath, isDirectory: false)
            guard let snippet = contextSnippet(for: fileURL, relativePath: relativePath) else { continue }
            snippets.append(snippet)
            if snippets.count >= 3 {
                break
            }
        }

        return snippets
    }

    private static func contextSnippet(for fileURL: URL, relativePath: String) -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lines = trimmed.components(separatedBy: "\n")
        let previewLines = Array(lines.prefix(28)).joined(separator: "\n")
        let preview = String(previewLines.prefix(1_200))
        return """
        --- \(relativePath) ---
        \(preview)
        """
    }

    static func saveLatestValidationResult(command: String, result: ShellExecutionResult) {
        guard let latest = latestProjectURL() else { return }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }

        let trimmedOutput = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = LatestValidationSnapshot(
            command: trimmedCommand,
            exitCode: result.exitCode,
            output: String(trimmedOutput.prefix(2400)),
            updatedAt: Date()
        )

        let fileURL = latest.appendingPathComponent(latestValidationSnapshotFileName, isDirectory: false)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func clearLatestValidationResult() {
        guard let latest = latestProjectURL() else { return }
        let fileURL = latest.appendingPathComponent(latestValidationSnapshotFileName, isDirectory: false)
        try? FileManager.default.removeItem(at: fileURL)
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

    static func applyLatestWorkspaceMutations(from message: ChatMessage) throws -> WorkspaceMutationResult {
        let operations = extractWorkspaceOperations(from: message)
        guard !operations.isEmpty else {
            throw BuildError.noWorkspaceOperations
        }

        return try applyLatestWorkspaceMutations(operations)
    }

    static func applyLatestWorkspaceMutations(_ operations: [WorkspaceOperation]) throws -> WorkspaceMutationResult {
        guard !operations.isEmpty else {
            throw BuildError.noWorkspaceOperations
        }

        let fileManager = FileManager.default
        guard let latest = latestProjectURL() else {
            throw BuildError.invalidProjectDirectory
        }
        if !fileManager.fileExists(atPath: latest.path) {
            try fileManager.createDirectory(at: latest, withIntermediateDirectories: true)
        }

        var affectedPaths: [String] = []
        clearLatestValidationResult()

        for operation in operations {
            switch operation {
            case .clearLatest:
                let children = try fileManager.contentsOfDirectory(
                    at: latest,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                for child in children {
                    try fileManager.removeItem(at: child)
                }
                affectedPaths.append("latest")

            case .createDirectory(let path):
                let targetURL = latest.appendingPathComponent(path, isDirectory: true)
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
                affectedPaths.append(path)

            case .createEmptyFile(let path):
                let targetURL = latest.appendingPathComponent(path, isDirectory: false)
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: targetURL, options: .atomic)
                affectedPaths.append(path)

            case .delete(let path):
                let targetURL = latest.appendingPathComponent(path, isDirectory: false)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                    pruneEmptyParentDirectories(startingFrom: targetURL.deletingLastPathComponent(), root: latest)
                    affectedPaths.append(path)
                }
            }
        }

        return WorkspaceMutationResult(
            operations: operations,
            affectedPaths: affectedPaths
        )
    }

    static func inferredWorkspaceOperations(fromUserPrompt raw: String) -> [WorkspaceOperation] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()
        guard !lowered.isEmpty else { return [] }

        if lowered.contains("删除所有项目")
            || lowered.contains("清空latest")
            || lowered.contains("清空 latest")
            || lowered.contains("清空工作区")
            || lowered.contains("清空当前项目")
            || lowered.contains("清空这个项目")
            || lowered.contains("清理工作区")
            || lowered.contains("清理 latest")
            || lowered.contains("clear latest")
            || lowered.contains("clear workspace")
            || lowered.contains("reset latest")
            || lowered.contains("wipe workspace")
            || lowered.contains("删除这个项目")
            || lowered.contains("删除这个脚本项目")
            || lowered.contains("删除这个python项目")
            || lowered.contains("删除这个 python 项目")
            || lowered.contains("删除当前项目")
            || lowered.contains("删除当前工作区")
            || lowered.contains("删除这个网站项目")
            || lowered.contains("删除网站项目")
            || lowered.contains("删掉当前项目")
            || lowered.contains("删掉这个脚本项目")
            || lowered.contains("移除这个脚本项目")
            || lowered.contains("移除当前项目")
            || lowered.contains("delete this project")
            || lowered.contains("delete current project") {
            return [.clearLatest]
        }

        if lowered.range(
            of: #"(删除|删掉|移除|清空).{0,8}(脚本|python|py|应用|项目).{0,4}项目"#,
            options: .regularExpression
        ) != nil {
            return [.clearLatest]
        }

        if looksLikeWholeProjectDeletion(normalized) {
            return [.clearLatest]
        }

        if let path = inferredDirectoryPath(in: normalized) {
            return [.createDirectory(path: path)]
        }

        if let path = inferredPath(
            in: normalized,
            prefixes: ["创建空文件夹", "创建文件夹", "新建文件夹", "创建目录", "新建目录", "mkdir "]
        ) {
            return [.createDirectory(path: path)]
        }

        if let path = inferredEmptyFilePath(in: normalized) {
            return [.createEmptyFile(path: path)]
        }

        if let path = inferredPath(
            in: normalized,
            prefixes: ["创建空文件", "新建空文件", "创建文件", "新建文件", "touch "]
        ) {
            return [.createEmptyFile(path: path)]
        }

        if looksLikeFolderContentsDeletion(lowered) {
            return []
        }

        if let path = inferredDeletePath(in: normalized) {
            return [.delete(path: path)]
        }

        if let path = inferredPath(
            in: normalized,
            prefixes: [
                "删除文件夹", "删除目录", "删除文件", "删除 ",
                "删掉文件夹", "删掉目录", "删掉文件", "删掉 ",
                "移除文件夹", "移除目录", "移除文件", "移除 ",
                "去掉文件夹", "去掉目录", "去掉文件", "去掉 ",
                "remove folder ", "remove directory ", "remove file ", "remove ",
                "delete folder ", "delete directory ", "delete file ", "delete ",
                "rm "
            ]
        ) {
            return [.delete(path: path)]
        }

        return []
    }

    private static func inferredDirectoryPath(in text: String) -> String? {
        let patterns = [
            #"(?i)(?:生成|创建|新建)\s*(?:一个|个)?\s*[\"'`“”‘’]?([A-Za-z0-9._/\-]+)[\"'`“”‘’]?\s*(?:文件夹|目录)"#,
            #"(?i)(?:create|make|generate)\s+(?:a\s+)?[\"'`]?([A-Za-z0-9._/\-]+)[\"'`]?\s+(?:folder|directory)"#
        ]
        for pattern in patterns {
            if let path = firstRegexCapture(in: text, pattern: pattern),
               let normalized = sanitizeRelativePath(path) {
                return normalized
            }
        }
        return nil
    }

    private static func inferredEmptyFilePath(in text: String) -> String? {
        let patterns = [
            #"(?i)(?:生成|创建|新建)\s*(?:一个|个)?\s*[\"'`“”‘’]?([A-Za-z0-9._/\-]+)[\"'`“”‘’]?\s*文件(?!夹)"#,
            #"(?i)(?:create|make|generate)\s+(?:an?\s+)?(?:empty\s+)?[\"'`]?([A-Za-z0-9._/\-]+)[\"'`]?\s+file"#
        ]
        for pattern in patterns {
            if let path = firstRegexCapture(in: text, pattern: pattern),
               let normalized = sanitizeRelativePath(path) {
                return normalized
            }
        }
        return nil
    }

    private static func inferredDeletePath(in text: String) -> String? {
        let patterns = [
            #"(?i)(?:删除|删掉|移除|去掉|清理)\s*(?:latest\s*(?:里|中|下|里面|中的|里的)?的?\s*)?(?:当前\s*)?(?:这个\s*)?(?:文件夹|目录|文件|路径)?\s*[`"'“”‘’]?([A-Za-z0-9._/\-]+)[`"'“”‘’]?\s*(?:文件夹|目录|文件|路径)?"#,
            #"(?i)[`"'“”‘’]?([A-Za-z0-9._/\-]+)[`"'“”‘’]?\s*(?:这个|此)?(?:文件夹|目录|文件|路径)?\s*(?:删除|删掉|移除|去掉)"#,
            #"(?i)(?:delete|remove|rm)\s+(?:the\s+)?(?:file|folder|directory|path)?\s*[`"']?([A-Za-z0-9._/\-]+)[`"']?"#,
            #"(?i)[`"']?([A-Za-z0-9._/\-]+)[`"']?\s+(?:file|folder|directory|path)?\s*(?:delete|remove)"#
        ]
        for pattern in patterns {
            if let path = firstRegexCapture(in: text, pattern: pattern),
               let normalized = sanitizeRelativePath(path) {
                return normalized
            }
        }
        return nil
    }

    private static func looksLikeFolderContentsDeletion(_ lowered: String) -> Bool {
        let markers = [
            "文件夹里的文件", "文件夹中的文件", "文件夹内的文件",
            "目录里的文件", "目录中的文件", "目录内的文件",
            "folder contents", "files in folder", "files inside folder",
            "directory contents", "files in directory", "files inside directory"
        ]
        if markers.contains(where: { lowered.contains($0) }) {
            return true
        }
        return lowered.range(
            of: #"(文件夹|目录).{0,4}(里|中|内).{0,4}(文件|内容|东西)"#,
            options: .regularExpression
        ) != nil
    }

    private static func looksLikeWholeProjectDeletion(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard lowered.contains("项目") else { return false }
        let destructiveVerbs = ["删除", "删掉", "移除", "清空", "重置", "clear", "reset", "delete", "remove", "wipe"]
        guard destructiveVerbs.contains(where: { lowered.contains($0) }) else { return false }

        if lowered.contains("项目里的文件")
            || lowered.contains("项目中的文件")
            || lowered.contains("项目内的文件")
            || lowered.contains("project file")
            || lowered.contains("files in project") {
            return false
        }

        return lowered.range(
            of: #"(删除|删掉|移除|清空|重置).{0,16}(这个|当前|整个|整个的)?[^\n]{0,16}项目"#,
            options: .regularExpression
        ) != nil
            || lowered.range(
                of: #"(delete|remove|clear|reset|wipe).{0,18}(this|current|whole)?\s*(?:[a-z0-9._/\-]+\s+)?project"#,
                options: .regularExpression
            ) != nil
    }

    static func buildProject(
        from message: ChatMessage,
        mode: BuildMode,
        useParseCache: Bool = true,
        mergeExistingProject: Bool = false
    ) throws -> BuildResult {
        let existingProject = (mode == .overwriteLatestProject && mergeExistingProject)
            ? existingLatestProjectSnapshot()
            : nil
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
        if let existingProject {
            for item in existingProject.files {
                let normalizedPath = item.path.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedContent = normalizeFileContent(item.content)
                guard !normalizedPath.isEmpty, !normalizedContent.isEmpty else { continue }
                if merged[normalizedPath] == nil {
                    orderedPaths.append(normalizedPath)
                }
                merged[normalizedPath] = normalizedContent
            }
        }

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

        synthesizePythonRequirementsIfNeeded(merged: &merged, orderedPaths: &orderedPaths)
        promoteHTMLLikeFilePathsIfNeeded(merged: &merged, orderedPaths: &orderedPaths)

        let hadNaturalPreviewEntry = orderedPaths.contains(where: { isPreviewEntryPath($0) })
        let stylePaths = orderedPaths.filter { isStylePath($0) }
        let scriptPaths = orderedPaths.filter { isScriptPath($0) }

        let previewEntryRelativePath: String? = {
            if let existingEntryPath = existingProject?.preferredEntryPath,
               merged[existingEntryPath] != nil {
                if !orderedPaths.contains(existingEntryPath) {
                    orderedPaths.insert(existingEntryPath, at: 0)
                }
                return existingEntryPath
            }
            return preferredPreviewEntryPath(from: orderedPaths)
        }()

        guard let primaryEntryRelativePath = preferredPrimaryProjectPath(
            from: orderedPaths,
            files: merged,
            preferredPreviewPath: previewEntryRelativePath
        ) else {
            throw BuildError.noFrontendContent
        }

        if let previewEntryRelativePath, isHTMLPath(previewEntryRelativePath) {
            let currentEntryHTML = merged[previewEntryRelativePath] ?? ""
            merged[previewEntryRelativePath] = normalizedEntryHTMLIfNeeded(
                currentEntryHTML,
                stylePaths: stylePaths,
                scriptPaths: scriptPaths
            )
        }

        if let previewEntryRelativePath, isHTMLPath(previewEntryRelativePath) {
            let currentEntryHTML = merged[previewEntryRelativePath] ?? ""
            resolveReferencedAssetAliases(
                entryRelativePath: previewEntryRelativePath,
                entryHTML: currentEntryHTML,
                merged: &merged,
                orderedPaths: &orderedPaths
            )
            autoWireEntryAssetReferencesIfNeeded(
                entryRelativePath: previewEntryRelativePath,
                merged: &merged,
                orderedPaths: orderedPaths
            )
        }

        if mode == .overwriteLatestProject && !mergeExistingProject {
            try clearLatestProject()
        }

        let projectDirectoryURL = try prepareProjectDirectory(mode: mode)
        let fileManager = FileManager.default
        let validationPlan = suggestedValidationPlan(
            orderedPaths: orderedPaths,
            files: merged
        )
        let suggestedValidationCommand = validationPlan?.fullCommand

        if mode == .overwriteLatestProject {
            clearLatestValidationResult()
        }

        for relativePath in orderedPaths {
            guard let content = merged[relativePath] else { continue }
            let fileURL = projectDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            let parentURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let shouldAutoOpenPreview = shouldAutoOpenPreview(
            previewEntryRelativePath: previewEntryRelativePath,
            primaryEntryRelativePath: primaryEntryRelativePath,
            orderedPaths: orderedPaths,
            files: merged
        )

        persistLatestPreviewPreference(
            mode: mode,
            projectDirectoryURL: projectDirectoryURL,
            entryRelativePath: shouldAutoOpenPreview ? previewEntryRelativePath : nil
        )

        let previewEntryFileURL = shouldAutoOpenPreview ? previewEntryRelativePath.map {
            projectDirectoryURL.appendingPathComponent($0, isDirectory: false)
        } : nil
        let previewEntryHTML = shouldAutoOpenPreview ? previewEntryRelativePath.flatMap { merged[$0] } : nil

        return BuildResult(
            projectDirectoryURL: projectDirectoryURL,
            entryFileURL: projectDirectoryURL.appendingPathComponent(primaryEntryRelativePath, isDirectory: false),
            entryHTML: previewEntryHTML ?? "",
            previewEntryFileURL: previewEntryFileURL,
            previewEntryHTML: previewEntryHTML,
            writtenRelativePaths: orderedPaths,
            writtenFiles: merged,
            validationPlan: validationPlan,
            suggestedValidationCommand: suggestedValidationCommand,
            createdNewProject: mode == .createNewProject,
            shouldAutoOpenPreview: shouldAutoOpenPreview,
            hadNaturalPreviewEntry: hadNaturalPreviewEntry,
            workspaceOperations: []
        )
    }

    private static func persistLatestPreviewPreference(
        mode: BuildMode,
        projectDirectoryURL: URL,
        entryRelativePath: String?
    ) {
        guard mode == .overwriteLatestProject else { return }
        let pointerURL = projectDirectoryURL.appendingPathComponent(latestEntryPointerFileName, isDirectory: false)
        let disabledMarkerURL = projectDirectoryURL.appendingPathComponent(latestPreviewDisabledFileName, isDirectory: false)

        guard let entryRelativePath,
              let normalized = sanitizeRelativePath(entryRelativePath),
              isPreviewEntryPath(normalized) else {
            try? FileManager.default.removeItem(at: pointerURL)
            try? "1\n".write(to: disabledMarkerURL, atomically: true, encoding: .utf8)
            return
        }

        try? FileManager.default.removeItem(at: disabledMarkerURL)
        try? "\(normalized)\n".write(to: pointerURL, atomically: true, encoding: .utf8)
    }

    private static func loadLatestValidationSnapshot() -> LatestValidationSnapshot? {
        guard let latest = latestProjectURL() else { return nil }
        let fileURL = latest.appendingPathComponent(latestValidationSnapshotFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LatestValidationSnapshot.self, from: data)
    }

    private static func existingLatestProjectSnapshot() -> ExistingProjectSnapshot? {
        guard let latest = latestProjectURL() else { return nil }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: latest.path) else { return nil }

        guard let enumerator = fileManager.enumerator(
            at: latest,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var files: [ParsedWebFile] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let absolute = fileURL.standardizedFileURL.path
            let root = latest.standardizedFileURL.path
            let relative = absolute.hasPrefix(root + "/")
                ? String(absolute.dropFirst(root.count + 1))
                : fileURL.lastPathComponent
            guard let normalized = sanitizeRelativePath(relative) else { continue }
            let normalizedContent = normalizeFileContent(content)
            guard !normalizedContent.isEmpty else { continue }
            files.append(ParsedWebFile(path: normalized, content: normalizedContent))
        }

        let preferredEntryPath: String? = {
            guard let entryURL = latestEntryFileURL() else { return nil }
            let absolute = entryURL.standardizedFileURL.path
            let root = latest.standardizedFileURL.path
            let relative = absolute.hasPrefix(root + "/")
                ? String(absolute.dropFirst(root.count + 1))
                : entryURL.lastPathComponent
            return sanitizeRelativePath(relative)
        }()

        if files.isEmpty, preferredEntryPath == nil {
            return nil
        }
        return ExistingProjectSnapshot(files: files, preferredEntryPath: preferredEntryPath)
    }

    private static func suggestedValidationPlan(
        orderedPaths: [String],
        files: [String: String]
    ) -> ValidationPlan? {
        let loweredPaths = orderedPaths.map { $0.lowercased() }
        let loweredSet = Set(loweredPaths)
        let normalizedFiles = Dictionary(uniqueKeysWithValues: files.map { key, value in
            (key.lowercased(), value)
        })

        if let packagePath = loweredPaths.first(where: { $0.hasSuffix("package.json") }),
           let package = normalizedFiles[packagePath]?.lowercased() {
            if package.contains("\"build\"") {
                return ValidationPlan(installCommand: "npm install", runCommand: "npm run build")
            }
            if package.contains("\"test\""), !package.contains("no test specified") {
                return ValidationPlan(installCommand: "npm install", runCommand: "npm test")
            }
            if package.contains("\"start\"") {
                return ValidationPlan(installCommand: "npm install", runCommand: "npm run start")
            }
            return ValidationPlan(installCommand: "npm install", runCommand: "node -e \"console.log('npm dependencies installed')\"")
        }

        if loweredSet.contains("cargo.toml") {
            let hasRustTests = loweredPaths.contains(where: { $0.contains("/tests/") || $0.hasSuffix("_test.rs") })
            return ValidationPlan(installCommand: nil, runCommand: hasRustTests ? "cargo test" : "cargo run")
        }

        if loweredSet.contains("go.mod") {
            let hasGoTests = loweredPaths.contains(where: { $0.hasSuffix("_test.go") })
            return ValidationPlan(installCommand: nil, runCommand: hasGoTests ? "go test ./..." : "go run .")
        }

        if loweredSet.contains("package.swift") {
            let hasSwiftTests = loweredPaths.contains(where: { $0.contains("/tests/") || $0.hasSuffix("tests.swift") })
            return ValidationPlan(installCommand: nil, runCommand: hasSwiftTests ? "swift test" : "swift run")
        }

        if loweredSet.contains("cmakelists.txt") {
            return ValidationPlan(
                installCommand: nil,
                runCommand: "cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure"
            )
        }

        if loweredSet.contains("pom.xml") {
            return ValidationPlan(installCommand: nil, runCommand: "mvn test")
        }

        if loweredSet.contains("build.gradle") || loweredSet.contains("build.gradle.kts") {
            return ValidationPlan(installCommand: nil, runCommand: "./gradlew test || gradle test")
        }

        if loweredSet.contains("composer.json") {
            return ValidationPlan(installCommand: "composer install", runCommand: "composer validate")
        }

        if loweredPaths.contains(where: { $0.hasSuffix(".py") }) {
            let hasPytest = loweredPaths.contains(where: {
                $0.contains("/tests/")
                    || $0.contains("/test/")
                    || $0.hasPrefix("tests.py")
                    || $0.hasSuffix("/tests.py")
                    || $0.hasPrefix("tests/")
                    || $0.hasPrefix("test")
                    || $0.contains("/test_")
                    || $0.hasSuffix("_test.py")
                    || $0.hasSuffix("test.py")
            })
            let installCommandBase: String? = {
                if loweredSet.contains("requirements.txt") {
                    return "python3 -m pip install -r requirements.txt"
                }
                if loweredSet.contains("pyproject.toml") || loweredSet.contains("setup.py") {
                    return "python3 -m pip install -e ."
                }
                return nil
            }()
            if hasPytest {
                let installCommand: String? = {
                    if let installCommandBase {
                        return "\(installCommandBase) && python3 -m pip install pytest"
                    }
                    return "python3 -m pip install pytest"
                }()
                return ValidationPlan(
                    installCommand: installCommand,
                    runCommand: "python3 -m pytest || python3 -m unittest discover -v"
                )
            }
            let installCommand = installCommandBase
            if let main = preferredPythonRunnablePath(from: loweredPaths) {
                return ValidationPlan(installCommand: installCommand, runCommand: "python3 \(main)")
            }
            return ValidationPlan(installCommand: installCommand, runCommand: "python3 -m compileall .")
        }

        return nil
    }

    private static func preferredPythonRunnablePath(from loweredPaths: [String]) -> String? {
        let preferred = [
            "main.py",
            "app.py",
            "cli.py",
            "run.py",
            "src/main.py"
        ]
        for item in preferred {
            if let matched = loweredPaths.first(where: { $0 == item || $0.hasSuffix("/" + item) }) {
                return matched
            }
        }
        return loweredPaths.first(where: {
            $0.hasSuffix(".py")
                && !$0.contains("/tests/")
                && !$0.hasPrefix("tests/")
                && !$0.hasPrefix("test_")
                && !$0.hasSuffix("_test.py")
        })
    }

    private static func looksLikeNetworkPythonProject(files: [String: String]) -> Bool {
        for (path, content) in files {
            guard path.lowercased().hasSuffix(".py") else { continue }
            let lowered = content.lowercased()
            if lowered.contains("import requests")
                || lowered.contains("from requests import")
                || lowered.contains("import aiohttp")
                || lowered.contains("import httpx")
                || lowered.contains("beautifulsoup")
                || lowered.contains("https://")
                || lowered.contains("http://") {
                return true
            }
        }
        return false
    }

    private static func synthesizePythonRequirementsIfNeeded(
        merged: inout [String: String],
        orderedPaths: inout [String]
    ) {
        let loweredPaths = orderedPaths.map { $0.lowercased() }
        let hasPythonFiles = loweredPaths.contains(where: { $0.hasSuffix(".py") })
        guard hasPythonFiles else { return }

        let hasDependencyManifest = loweredPaths.contains("requirements.txt")
            || loweredPaths.contains("pyproject.toml")
            || loweredPaths.contains("setup.py")
            || loweredPaths.contains("pipfile")
            || loweredPaths.contains("poetry.lock")
        guard !hasDependencyManifest else { return }

        let inferred = inferredPythonDependencies(from: merged)
        guard !inferred.isEmpty else { return }

        let requirementsPath = "requirements.txt"
        let content = inferred.joined(separator: "\n")
        merged[requirementsPath] = content
        if !orderedPaths.contains(requirementsPath) {
            orderedPaths.append(requirementsPath)
        }
    }

    private static func inferredPythonDependencies(from files: [String: String]) -> [String] {
        let packageMap: [String: String] = [
            "requests": "requests",
            "bs4": "beautifulsoup4",
            "beautifulsoup4": "beautifulsoup4",
            "lxml": "lxml",
            "yaml": "pyyaml",
            "pandas": "pandas",
            "numpy": "numpy",
            "aiohttp": "aiohttp",
            "httpx": "httpx",
            "selenium": "selenium",
            "playwright": "playwright",
            "PIL": "pillow",
            "cv2": "opencv-python",
            "sklearn": "scikit-learn",
            "dotenv": "python-dotenv",
            "dateutil": "python-dateutil",
            "Crypto": "pycryptodome"
        ]
        let stdlibImports: Set<String> = [
            "abc", "argparse", "asyncio", "base64", "collections", "concurrent", "contextlib",
            "copy", "csv", "datetime", "decimal", "functools", "hashlib", "heapq", "html",
            "http", "importlib", "inspect", "io", "itertools", "json", "logging", "math",
            "multiprocessing", "os", "pathlib", "queue", "random", "re", "shutil", "signal",
            "socket", "sqlite3", "statistics", "string", "subprocess", "sys", "tempfile",
            "threading", "time", "traceback", "typing", "unittest", "urllib", "uuid",
            "xml", "zipfile"
        ]

        var packages = Set<String>()
        for (path, content) in files {
            guard path.lowercased().hasSuffix(".py") else { continue }
            let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            let lines = normalized.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }

                if let match = firstRegexCapture(in: trimmed, pattern: #"^import\s+([A-Za-z_][A-Za-z0-9_\.]*)"#) {
                    let root = match.components(separatedBy: ".").first ?? match
                    if let package = mappedPythonDependency(rootImport: root, packageMap: packageMap, stdlibImports: stdlibImports) {
                        packages.insert(package)
                    }
                }
                if let match = firstRegexCapture(in: trimmed, pattern: #"^from\s+([A-Za-z_][A-Za-z0-9_\.]*)\s+import\s+"#) {
                    let root = match.components(separatedBy: ".").first ?? match
                    if let package = mappedPythonDependency(rootImport: root, packageMap: packageMap, stdlibImports: stdlibImports) {
                        packages.insert(package)
                    }
                }
            }
        }

        return packages.sorted()
    }

    private static func mappedPythonDependency(
        rootImport: String,
        packageMap: [String: String],
        stdlibImports: Set<String>
    ) -> String? {
        guard !stdlibImports.contains(rootImport) else { return nil }
        if let mapped = packageMap[rootImport] {
            return mapped
        }
        let lowered = rootImport.lowercased()
        guard !stdlibImports.contains(lowered) else { return nil }
        return packageMap[lowered] ?? lowered
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
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

    private static func countProjectPathHints(in text: String) -> Int {
        let pattern = #"(?im)^(?:src|app|public|assets|components|pages|views|styles|scripts|lib|utils|server|client|api|cmd|internal|pkg)?/?(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:html|css|scss|sass|js|mjs|cjs|ts|tsx|jsx|vue|svelte|json|php|py|swift|go|rs|java|kt|sql|md|txt)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: nsRange)
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

    private static func extractWorkspaceOperations(from message: ChatMessage) -> [WorkspaceOperation] {
        parseWorkspaceOperations(in: message.content.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    private static func parseWorkspaceOperations(in text: String) -> [WorkspaceOperation] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\[(mkdir|touch|delete|clear):([^\]]*)\]\]"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsText = text as NSString
        let nsRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return [] }

        var operations: [WorkspaceOperation] = []
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let verb = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = nsText.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            switch verb {
            case "clear":
                let normalized = rawValue.lowercased()
                if normalized.isEmpty || normalized == "latest" {
                    operations.append(.clearLatest)
                }
            case "mkdir":
                if let path = sanitizeRelativePath(rawValue) {
                    operations.append(.createDirectory(path: path))
                }
            case "touch":
                if let path = sanitizeRelativePath(rawValue) {
                    operations.append(.createEmptyFile(path: path))
                }
            case "delete":
                if let path = sanitizeRelativePath(rawValue) {
                    operations.append(.delete(path: path))
                }
            default:
                continue
            }
        }
        return operations
    }

    private static func extractExplicitProjectFiles(from message: ChatMessage) -> [ParsedWebFile] {
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

    private static func explicitTaggedPaths(in text: String) -> [String] {
        let pattern = #"\[\[file:(.+?)\]\]"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var paths: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let rawPath = String(text[range])
            guard let normalized = sanitizeRelativePath(rawPath)?.lowercased() else { continue }
            paths.append(normalized)
        }
        return Array(Set(paths))
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

    private static func inferredPath(in text: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            guard let range = text.range(
                of: prefix,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let suffix = text[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suffix.isEmpty else { continue }

            if let quoted = firstRegexCapture(
                in: String(suffix),
                pattern: #"[`"'“”‘’]([^`"'“”‘’]+)[`"'“”‘’]"#
            ), let normalized = sanitizeRelativePath(quoted) {
                return normalized
            }

            let tokens = suffix
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            if let first = tokens.first, let normalized = sanitizeRelativePath(first) {
                return normalized
            }
        }
        return nil
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
        let prepared = trimCodeBoundaryBlankLines(normalized)
        return removeLeakedTaggedFileMarkers(from: prepared)
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
        return trimCodeBoundaryBlankLines(text)
    }

    private static func pruneEmptyParentDirectories(startingFrom folderURL: URL, root: URL) {
        let fileManager = FileManager.default
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var current = folderURL.standardizedFileURL.resolvingSymlinksInPath()

        while current.path != rootPath {
            guard current.path.hasPrefix(rootPath + "/") else { break }
            guard let items = try? fileManager.contentsOfDirectory(atPath: current.path),
                  items.isEmpty else {
                break
            }
            try? fileManager.removeItem(at: current)
            let next = current.deletingLastPathComponent()
            if next.path == current.path {
                break
            }
            current = next
        }
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

        let sharedIndent = nonEmptyLines
            .map { $0.prefix { ch in ch == " " || ch == "\t" }.count }
            .min() ?? 0
        guard sharedIndent > 0 else {
            return trimmedLines.joined(separator: "\n")
        }

        return trimmedLines.map { line in
            let leading = line.prefix { ch in ch == " " || ch == "\t" }.count
            guard leading >= sharedIndent else { return line }
            return String(line.dropFirst(sharedIndent))
        }
        .joined(separator: "\n")
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

    private static func preferredPreviewEntryPath(from paths: [String]) -> String? {
        if let exact = paths.first(where: {
            $0.lowercased().hasSuffix("index.html") && isLikelyWebPreviewPath($0)
        }) {
            return exact
        }
        if let html = paths.first(where: { isHTMLPath($0) && isLikelyWebPreviewPath($0) }) {
            return html
        }
        if let exactPHP = paths.first(where: {
            $0.lowercased().hasSuffix("index.php") && isLikelyWebPreviewPath($0)
        }) {
            return exactPHP
        }
        return paths.first(where: { isPHPPath($0) && isLikelyWebPreviewPath($0) })
    }

    private static func shouldAutoOpenPreview(
        previewEntryRelativePath: String?,
        primaryEntryRelativePath: String,
        orderedPaths: [String],
        files: [String: String]
    ) -> Bool {
        guard let previewEntryRelativePath else { return false }
        guard isLikelyWebPreviewPath(previewEntryRelativePath) else { return false }
        if previewEntryRelativePath == primaryEntryRelativePath {
            return true
        }
        return isLikelyWebPrimaryPath(primaryEntryRelativePath)
            || orderedPaths.contains(where: { isLikelyWebPrimaryPath($0) })
            || orderedPaths.contains(where: { $0.lowercased().hasSuffix("package.json") })
            || previewHTMLLooksRenderable(files[previewEntryRelativePath] ?? "")
    }

    private static func isLikelyWebPrimaryPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        if isHTMLPath(lowered) || isPHPPath(lowered) {
            return true
        }
        let ext = (lowered as NSString).pathExtension
        let webLikeExtensions: Set<String> = [
            "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte",
            "css", "scss", "sass", "less"
        ]
        return webLikeExtensions.contains(ext)
    }

    private static func isLikelyWebPreviewPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let blockedPrefixes = [
            "tests/", "test/", "fixtures/", "samples/", "sample/", "docs/", "doc/"
        ]
        if blockedPrefixes.contains(where: { lowered.hasPrefix($0) || lowered.contains("/" + $0) }) {
            return false
        }
        return true
    }

    private static func previewHTMLLooksRenderable(_ html: String) -> Bool {
        let lowered = html.lowercased()
        return lowered.contains("<body")
            || lowered.contains("<script")
            || lowered.contains("<style")
            || lowered.contains("<div")
    }

    private static func preferredPrimaryProjectPath(
        from paths: [String],
        files: [String: String],
        preferredPreviewPath: String?
    ) -> String? {
        let exactPreferred = [
            "main.py", "app.py", "manage.py", "cli.py",
            "main.go",
            "src/main.rs", "main.rs",
            "main.swift", "package.swift", "package.swift",
            "main.java", "main.kt", "main.kts",
            "go.mod", "cargo.toml", "pyproject.toml", "requirements.txt",
            "pom.xml", "build.gradle", "build.gradle.kts",
            "composer.json"
        ]
        for preferred in exactPreferred {
            if let match = paths.first(where: { $0.lowercased() == preferred }) {
                return match
            }
        }

        let runnableSuffixes = [
            "main.py", "app.py", "cli.py",
            "main.go", "main.rs", "main.swift",
            "main.java", "main.kt", "main.kts",
            "index.js", "main.js", "index.ts", "main.ts",
            "program.cs"
        ]
        for suffix in runnableSuffixes {
            if let match = paths.first(where: { $0.lowercased().hasSuffix(suffix) }) {
                return match
            }
        }

        if let preferredPreviewPath, paths.contains(preferredPreviewPath) {
            return preferredPreviewPath
        }

        if let packageJSON = paths.first(where: { $0.lowercased().hasSuffix("package.json") }) {
            return packageJSON
        }

        if let bestScript = paths.first(where: { path in
            let lowered = path.lowercased()
            if isPreviewEntryPath(lowered) { return false }
            let ext = (lowered as NSString).pathExtension
            let scriptLike = ["py", "go", "rs", "swift", "java", "kt", "kts", "js", "mjs", "cjs", "ts", "tsx", "jsx", "php", "rb", "lua", "cs"]
            guard scriptLike.contains(ext) else { return false }
            return !(files[path]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) {
            return bestScript
        }

        return paths.first
    }

    private static func promoteHTMLLikeFilePathsIfNeeded(
        merged: inout [String: String],
        orderedPaths: inout [String]
    ) {
        guard !orderedPaths.contains(where: { isHTMLPath($0) }) else { return }
        guard let candidatePath = orderedPaths.first(where: { path in
            guard let content = merged[path] else { return false }
            guard isHTMLPromotionCandidatePath(path) else { return false }
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

    private static func isHTMLPromotionCandidatePath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        if isHTMLPath(lowered) || isPHPPath(lowered) {
            return true
        }

        let ext = (lowered as NSString).pathExtension
        if ext.isEmpty {
            return true
        }

        let genericTextExtensions: Set<String> = [
            "txt", "text", "code", "log", "tmp"
        ]
        return genericTextExtensions.contains(ext)
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
