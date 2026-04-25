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
