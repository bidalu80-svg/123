import Foundation

struct ShellExecutionResult: Equatable {
    let command: String
    let output: String
    let exitCode: Int
    let durationMs: Int?
    let finalWorkingDirectory: String?
}

struct LocalProjectExecutionResult: Equatable {
    let output: String
    let exitCode: Int
}

final class LocalProjectExecutionService {
    static let shared = LocalProjectExecutionService()
    static let fallbackBundledDependencyNames: Set<String> = [
        "requests", "urllib3", "charset-normalizer", "idna", "certifi",
        "beautifulsoup4", "soupsieve",
        "httpx", "httpcore", "anyio", "sniffio", "h11",
        "python-dateutil", "six", "python-dotenv",
        "pytest", "iniconfig", "packaging", "pluggy", "pygments",
        "click", "jinja2", "markupsafe",
        "rich", "markdown-it-py", "mdurl",
        "attrs", "aiofiles"
    ]
    private static let detectedBundledDependencyNames: Set<String> = {
        let discovered = scanBundledDependencyNames()
        return discovered.isEmpty ? fallbackBundledDependencyNames : discovered
    }()

    func runPythonFile(
        atRelativePath path: String,
        projectURL: URL,
        stdin: String? = nil,
        runtimeConfig: ChatConfig? = nil
    ) async throws -> LocalProjectExecutionResult {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw NSError(domain: "LocalProjectExecutionService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Python 入口文件路径为空。"
            ])
        }
        if let dependencyResult = unsupportedDependencyResultIfNeeded(projectURL: projectURL) {
            if shouldUseRemotePythonExecution(config: runtimeConfig) {
                return try await runRemotePythonFile(
                    atRelativePath: trimmedPath,
                    projectURL: projectURL,
                    stdin: stdin,
                    config: runtimeConfig
                )
            }
            return dependencyResult
        }

        let script = pythonProjectBootstrap(projectURL: projectURL) + """
import runpy

target = \(pythonLiteral(trimmedPath))
target_path = os.path.join(workspace, target)
if not os.path.isfile(target_path):
    raise SystemExit("入口文件不存在: " + target)
runpy.run_path(target_path, run_name="__main__")
"""
        let result = try await PythonExecutionService.shared.runPython(
            code: script,
            stdin: stdin,
            waitForEmbeddedRuntimeRecovery: true
        )
        if shouldFallbackToRemotePython(after: result, config: runtimeConfig) {
            return try await runRemotePythonFile(
                atRelativePath: trimmedPath,
                projectURL: projectURL,
                stdin: stdin,
                config: runtimeConfig
            )
        }
        return LocalProjectExecutionResult(output: result.output, exitCode: result.exitCode)
    }

    func runPythonUnitTests(
        in projectURL: URL,
        runtimeConfig: ChatConfig? = nil
    ) async throws -> LocalProjectExecutionResult {
        if let dependencyResult = unsupportedDependencyResultIfNeeded(projectURL: projectURL) {
            if shouldUseRemotePythonExecution(config: runtimeConfig) {
                return try await runRemotePythonUnitTests(in: projectURL, config: runtimeConfig)
            }
            return dependencyResult
        }
        let script = pythonProjectBootstrap(projectURL: projectURL) + """
import unittest

tests_dir = os.path.join(workspace, "tests")
start_dir = "tests" if os.path.isdir(tests_dir) else "."
suite = unittest.defaultTestLoader.discover(start_dir=start_dir, pattern="test*.py")
runner = unittest.TextTestRunner(verbosity=2)
result = runner.run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
"""
        let result = try await PythonExecutionService.shared.runPython(
            code: script,
            waitForEmbeddedRuntimeRecovery: true
        )
        if shouldFallbackToRemotePython(after: result, config: runtimeConfig) {
            return try await runRemotePythonUnitTests(in: projectURL, config: runtimeConfig)
        }
        return LocalProjectExecutionResult(output: result.output, exitCode: result.exitCode)
    }

    func runPythonCompileAll(
        in projectURL: URL,
        skipDependencyCheck: Bool = false,
        runtimeConfig: ChatConfig? = nil
    ) async throws -> LocalProjectExecutionResult {
        if !skipDependencyCheck,
           let dependencyResult = unsupportedDependencyResultIfNeeded(projectURL: projectURL) {
            if shouldUseRemotePythonExecution(config: runtimeConfig) {
                return try await runRemotePythonCompileAll(in: projectURL, config: runtimeConfig)
            }
            return dependencyResult
        }
        let script = pythonProjectBootstrap(projectURL: projectURL) + """
import compileall

ok = compileall.compile_dir(workspace, quiet=1, force=True, maxlevels=10)
print("compileall: ok" if ok else "compileall: failed")
raise SystemExit(0 if ok else 1)
"""
        let result = try await PythonExecutionService.shared.runPython(
            code: script,
            waitForEmbeddedRuntimeRecovery: true
        )
        if !skipDependencyCheck,
           shouldFallbackToRemotePython(after: result, config: runtimeConfig) {
            return try await runRemotePythonCompileAll(in: projectURL, config: runtimeConfig)
        }
        return LocalProjectExecutionResult(output: result.output, exitCode: result.exitCode)
    }

    static func isSyntaxFailure(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("syntaxerror")
            || lowered.contains("indentationerror")
            || lowered.contains("taberror")
            || lowered.contains("invalid syntax")
            || lowered.contains("*** error compiling")
    }

    static func syntaxFailureSummary(from output: String, limit: Int = 900) -> String {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    private func unsupportedDependencyResultIfNeeded(projectURL: URL) -> LocalProjectExecutionResult? {
        let supported = Self.detectedBundledDependencyNames
        var unsupported: [String] = []

        let requirementsURL = projectURL.appendingPathComponent("requirements.txt", isDirectory: false)
        if let requirementsText = try? String(contentsOf: requirementsURL, encoding: .utf8) {
            unsupported.append(contentsOf: Self.unsupportedRequirements(from: requirementsText, supportedDependencies: supported))
        }

        let pyprojectURL = projectURL.appendingPathComponent("pyproject.toml", isDirectory: false)
        if let pyprojectText = try? String(contentsOf: pyprojectURL, encoding: .utf8) {
            unsupported.append(contentsOf: Self.unsupportedPyprojectDependencies(from: pyprojectText, supportedDependencies: supported))
        }

        unsupported = uniqueOrdered(unsupported)
        guard !unsupported.isEmpty else { return nil }

        let joined = unsupported.prefix(12).joined(separator: ", ")
        let suffix = unsupported.count > 12 ? " 等 \(unsupported.count) 项" : ""
        let installedPreview = supported.sorted().prefix(18).joined(separator: ", ")
        return LocalProjectExecutionResult(
            output: """
            当前内置 Python 不是完整桌面环境，这个项目声明了未内置依赖：
            \(joined)\(suffix)

            当前已内置的依赖会随 IPA 一起打包，当前检测到的常用依赖包括：
            \(installedPreview) 等。

            像 numpy、pandas、lxml、cryptography、playwright、selenium、aiohttp 这类原生扩展或重型运行时，当前不能在 App 内直接安装运行。
            """,
            exitCode: 1
        )
    }

    private func shouldUseRemotePythonExecution(config: ChatConfig?) -> Bool {
        guard let config else { return false }
        return config.remotePythonExecutionEnabled
            && !config.remotePythonExecutionURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldFallbackToRemotePython(
        after result: PythonExecutionResult,
        config: ChatConfig?
    ) -> Bool {
        guard shouldUseRemotePythonExecution(config: config) else { return false }
        guard result.exitCode != 0 else { return false }

        let lowered = result.output.lowercased()
        return lowered.contains("完整 cpython")
            || lowered.contains("嵌入 cpython")
            || lowered.contains("未检测到嵌入 cpython")
            || lowered.contains("当前不适合回退到兼容运行器")
            || lowered.contains("兼容运行器")
    }

    private func runRemotePythonFile(
        atRelativePath path: String,
        projectURL: URL,
        stdin: String?,
        config: ChatConfig?
    ) async throws -> LocalProjectExecutionResult {
        guard let config else {
            throw NSError(domain: "LocalProjectExecutionService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "远端 Python 配置缺失。"
            ])
        }
        let remote = try await RemotePythonExecutionService.shared.execute(
            mode: .runFile,
            projectURL: projectURL,
            entryPath: path,
            stdin: stdin,
            config: config
        )
        return LocalProjectExecutionResult(output: remote.output, exitCode: remote.exitCode)
    }

    private func runRemotePythonUnitTests(
        in projectURL: URL,
        config: ChatConfig?
    ) async throws -> LocalProjectExecutionResult {
        guard let config else {
            throw NSError(domain: "LocalProjectExecutionService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "远端 Python 配置缺失。"
            ])
        }
        let remote = try await RemotePythonExecutionService.shared.execute(
            mode: .unitTests,
            projectURL: projectURL,
            config: config
        )
        return LocalProjectExecutionResult(output: remote.output, exitCode: remote.exitCode)
    }

    private func runRemotePythonCompileAll(
        in projectURL: URL,
        config: ChatConfig?
    ) async throws -> LocalProjectExecutionResult {
        guard let config else {
            throw NSError(domain: "LocalProjectExecutionService", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "远端 Python 配置缺失。"
            ])
        }
        let remote = try await RemotePythonExecutionService.shared.execute(
            mode: .compileAll,
            projectURL: projectURL,
            config: config
        )
        return LocalProjectExecutionResult(output: remote.output, exitCode: remote.exitCode)
    }

    static func unsupportedRequirements(
        from raw: String,
        supportedDependencies: Set<String> = detectedBundledDependencyNames
    ) -> [String] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var unsupported: [String] = []
        var seen = Set<String>()

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("-r ")
                || lowered.hasPrefix("--requirement ")
                || lowered.hasPrefix("-e ")
                || lowered.hasPrefix("--editable ")
                || lowered.hasPrefix("git+")
                || lowered.hasPrefix("http://")
                || lowered.hasPrefix("https://")
                || lowered.hasPrefix("file:") {
                if seen.insert(trimmed).inserted {
                    unsupported.append(trimmed)
                }
                continue
            }

            var package = trimmed
            if let commentRange = package.range(of: " #") {
                package = String(package[..<commentRange.lowerBound])
            }
            if let markerRange = package.range(of: ";") {
                package = String(package[..<markerRange.lowerBound])
            }
            if let extrasRange = package.range(of: "[") {
                package = String(package[..<extrasRange.lowerBound])
            }
            if let versionRange = package.range(of: #"[<>=!~ ]"#, options: .regularExpression) {
                package = String(package[..<versionRange.lowerBound])
            }

            let normalizedPackage = package
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let canonicalPackage = canonicalDependencyName(normalizedPackage)
            if canonicalPackage.isEmpty {
                continue
            }
            if !supportedDependencies.contains(canonicalPackage),
               seen.insert(canonicalPackage).inserted {
                unsupported.append(canonicalPackage)
            }
        }

        return unsupported
    }

    static func unsupportedPyprojectDependencies(
        from raw: String,
        supportedDependencies: Set<String> = detectedBundledDependencyNames
    ) -> [String] {
        let requirements = pyprojectDependencyNames(from: raw)
        guard !requirements.isEmpty else { return [] }

        var unsupported: [String] = []
        var seen = Set<String>()
        for dependency in requirements {
            let canonical = canonicalDependencyName(dependency)
            guard !canonical.isEmpty else { continue }
            if !supportedDependencies.contains(canonical),
               seen.insert(canonical).inserted {
                unsupported.append(canonical)
            }
        }
        return unsupported
    }

    static func pyprojectDependencyNames(from raw: String) -> [String] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        enum ArrayMode {
            case projectDependencies
            case dependencyGroup
        }

        var section = ""
        var collectingArray: ArrayMode?
        var collected: [String] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = trimmed
                collectingArray = nil
                continue
            }

            if let arrayMode = collectingArray {
                collected.append(contentsOf: extractQuotedRequirementNames(from: trimmed))
                if trimmed.contains("]") {
                    collectingArray = nil
                }
                if case .dependencyGroup = arrayMode {
                    continue
                }
                continue
            }

            if section == "[project]" {
                if trimmed.hasPrefix("dependencies") {
                    collected.append(contentsOf: extractQuotedRequirementNames(from: trimmed))
                    if trimmed.contains("[") && !trimmed.contains("]") {
                        collectingArray = .projectDependencies
                    }
                }
                continue
            }

            if section == "[dependency-groups]" {
                if trimmed.contains("=") && trimmed.contains("[") {
                    collected.append(contentsOf: extractQuotedRequirementNames(from: trimmed))
                    if !trimmed.contains("]") {
                        collectingArray = .dependencyGroup
                    }
                }
                continue
            }

            if section == "[tool.poetry.dependencies]"
                || section.hasPrefix("[tool.poetry.group.")
                    && section.hasSuffix(".dependencies]") {
                guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
                let name = trimmed[..<equalsIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !name.isEmpty, name != "python" else { continue }
                collected.append(name)
            }
        }

        return uniqueOrdered(collected.map { canonicalDependencyName($0) }.filter { !$0.isEmpty })
    }

    private static func extractQuotedRequirementNames(from raw: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#) else { return [] }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let nsRaw = raw as NSString
        return regex.matches(in: raw, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let value = nsRaw.substring(with: match.range(at: 1))
            return packageName(fromRequirement: value)
        }
    }

    private static func packageName(fromRequirement raw: String) -> String {
        var package = raw
        if let commentRange = package.range(of: " #") {
            package = String(package[..<commentRange.lowerBound])
        }
        if let markerRange = package.range(of: ";") {
            package = String(package[..<markerRange.lowerBound])
        }
        if let extrasRange = package.range(of: "[") {
            package = String(package[..<extrasRange.lowerBound])
        }
        if let versionRange = package.range(of: #"[<>=!~ ]"#, options: .regularExpression) {
            package = String(package[..<versionRange.lowerBound])
        }
        return package.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalDependencyName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func scanBundledDependencyNames() -> Set<String> {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let runtimeRoot = resourceURL.appendingPathComponent("PythonRuntime", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: runtimeRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let libDir = runtimeRoot.appendingPathComponent("lib", isDirectory: true)
        guard let versionDirs = try? FileManager.default.contentsOfDirectory(
            at: libDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var discovered = Set<String>()
        for versionDir in versionDirs where versionDir.lastPathComponent.hasPrefix("python3") {
            for folderName in ["site-packages", "dist-packages"] {
                let packagesDir = versionDir.appendingPathComponent(folderName, isDirectory: true)
                guard FileManager.default.fileExists(atPath: packagesDir.path, isDirectory: &isDir), isDir.boolValue,
                      let entries = try? FileManager.default.contentsOfDirectory(
                        at: packagesDir,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                      ) else {
                    continue
                }

                for entry in entries {
                    let name = entry.lastPathComponent
                    if name == "__pycache__" || name.hasPrefix(".") {
                        continue
                    }

                    if name.hasSuffix(".dist-info") || name.hasSuffix(".egg-info") {
                        let stem = (name as NSString).deletingPathExtension
                        if let range = stem.range(of: #"-\d"#, options: .regularExpression) {
                            let package = String(stem[..<range.lowerBound])
                            let canonical = canonicalDependencyName(package)
                            if !canonical.isEmpty {
                                discovered.insert(canonical)
                            }
                        } else {
                            let canonical = canonicalDependencyName(stem)
                            if !canonical.isEmpty {
                                discovered.insert(canonical)
                            }
                        }
                        continue
                    }

                    if name.hasSuffix(".py") {
                        let canonical = canonicalDependencyName((name as NSString).deletingPathExtension)
                        if !canonical.isEmpty {
                            discovered.insert(canonical)
                        }
                        continue
                    }

                    let canonical = canonicalDependencyName(name)
                    if !canonical.isEmpty {
                        discovered.insert(canonical)
                    }
                }
            }
        }
        return discovered
    }

    private func uniqueOrdered(_ values: [String]) -> [String] {
        Self.uniqueOrdered(values)
    }

    private static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private func pythonProjectBootstrap(projectURL: URL) -> String {
        """
import os
import sys

workspace = \(pythonLiteral(projectURL.path))
if not os.path.isdir(workspace):
    raise SystemExit("工作区不存在: " + workspace)

os.chdir(workspace)
for candidate in [workspace, os.path.join(workspace, "src")]:
    if os.path.isdir(candidate) and candidate not in sys.path:
        sys.path.insert(0, candidate)

"""
    }

    private func pythonLiteral(_ raw: String) -> String {
        var escaped = raw.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
