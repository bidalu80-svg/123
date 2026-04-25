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
    static let bundledDependencyNames: Set<String> = [
        "requests", "urllib3", "charset-normalizer", "idna", "certifi",
        "beautifulsoup4", "soupsieve",
        "httpx", "httpcore", "anyio", "sniffio", "h11",
        "python-dateutil", "six", "python-dotenv",
        "pytest", "iniconfig", "packaging", "pluggy", "pygments",
        "click", "jinja2", "markupsafe",
        "rich", "markdown-it-py", "mdurl",
        "attrs", "aiofiles"
    ]

    func runPythonFile(
        atRelativePath path: String,
        projectURL: URL,
        stdin: String? = nil
    ) async throws -> LocalProjectExecutionResult {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw NSError(domain: "LocalProjectExecutionService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Python 入口文件路径为空。"
            ])
        }
        if let dependencyResult = unsupportedDependencyResultIfNeeded(projectURL: projectURL) {
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
        return LocalProjectExecutionResult(output: result.output, exitCode: result.exitCode)
    }

    func runPythonUnitTests(in projectURL: URL) async throws -> LocalProjectExecutionResult {
        if let dependencyResult = unsupportedDependencyResultIfNeeded(projectURL: projectURL) {
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
        return LocalProjectExecutionResult(output: result.output, exitCode: result.exitCode)
    }

    func runPythonCompileAll(in projectURL: URL) async throws -> LocalProjectExecutionResult {
        if let dependencyResult = unsupportedDependencyResultIfNeeded(projectURL: projectURL) {
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
        return LocalProjectExecutionResult(output: result.output, exitCode: result.exitCode)
    }

    private func unsupportedDependencyResultIfNeeded(projectURL: URL) -> LocalProjectExecutionResult? {
        let requirementsURL = projectURL.appendingPathComponent("requirements.txt", isDirectory: false)
        guard let requirementsText = try? String(contentsOf: requirementsURL, encoding: .utf8) else {
            return nil
        }

        let unsupported = Self.unsupportedRequirements(from: requirementsText)
        guard !unsupported.isEmpty else { return nil }

        let joined = unsupported.prefix(12).joined(separator: ", ")
        let suffix = unsupported.count > 12 ? " 等 \(unsupported.count) 项" : ""
        return LocalProjectExecutionResult(
            output: """
            当前内置 Python 不是完整桌面环境，这个项目声明了未内置依赖：
            \(joined)\(suffix)

            当前已内置常用纯 Python 依赖，包括：
            requests, httpx, beautifulsoup4, pytest, click, jinja2, rich, python-dotenv, aiofiles 等。

            像 numpy、pandas、lxml、cryptography、playwright、selenium、aiohttp 这类原生扩展或重型运行时，当前不能在 App 内直接安装运行。
            """,
            exitCode: 1
        )
    }

    static func unsupportedRequirements(from raw: String) -> [String] {
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
            if normalizedPackage.isEmpty {
                continue
            }
            if !Self.bundledDependencyNames.contains(normalizedPackage),
               seen.insert(normalizedPackage).inserted {
                unsupported.append(normalizedPackage)
            }
        }

        return unsupported
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
