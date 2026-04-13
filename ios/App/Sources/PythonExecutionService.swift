import Foundation

struct PythonExecutionResult: Equatable {
    let output: String
    let exitCode: Int
}

enum PythonExecutionError: LocalizedError, Equatable {
    case emptyCode
    case requestFailed
    case responseFailed
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .emptyCode:
            return "代码为空，无法运行。"
        case .requestFailed:
            return "Python 运行服务不可用，请稍后重试。"
        case .responseFailed:
            return "Python 运行服务响应异常。"
        case .decodeFailed:
            return "Python 运行结果解析失败。"
        }
    }
}

final class PythonExecutionService {
    static let shared = PythonExecutionService()

    private let executeEndpoints: [String]

    private let session: URLSession

    init(
        session: URLSession? = nil,
        executeEndpoints: [String] = [
            "https://emkc.org/api/v2/piston/execute",
            "https://piston.rs/api/v2/execute"
        ]
    ) {
        self.executeEndpoints = executeEndpoints

        if let session {
            self.session = session
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func runPython(code: String) async throws -> PythonExecutionResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PythonExecutionError.emptyCode }

        var lastError: Error?
        for endpoint in executeEndpoints {
            do {
                return try await runPython(code: trimmed, endpoint: endpoint)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? PythonExecutionError.requestFailed
    }

    private func runPython(code: String, endpoint: String) async throws -> PythonExecutionResult {
        guard let url = URL(string: endpoint) else {
            throw PythonExecutionError.requestFailed
        }

        let payload = ExecuteRequest(
            language: "python",
            version: "3.10.0",
            files: [.init(name: "main.py", content: code)],
            stdin: "",
            args: [],
            compileTimeout: 12000,
            runTimeout: 12000
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PythonExecutionError.responseFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw PythonExecutionError.requestFailed
        }

        guard let decoded = try? JSONDecoder().decode(ExecuteResponse.self, from: data) else {
            throw PythonExecutionError.decodeFailed
        }

        let run = decoded.run
        let stdout = run?.stdout ?? ""
        let stderr = run?.stderr ?? ""
        let mergedOutput: String
        if let output = run?.output, !output.isEmpty {
            mergedOutput = output
        } else {
            let combined = [stdout, stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            mergedOutput = combined
        }

        let normalizedOutput: String
        if mergedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedOutput = "执行完成（无输出）"
        } else {
            normalizedOutput = mergedOutput
        }

        return PythonExecutionResult(
            output: normalizedOutput,
            exitCode: run?.code ?? 0
        )
    }
}

private struct ExecuteRequest: Encodable {
    struct ExecuteFile: Encodable {
        let name: String
        let content: String
    }

    let language: String
    let version: String
    let files: [ExecuteFile]
    let stdin: String
    let args: [String]
    let compileTimeout: Int
    let runTimeout: Int

    enum CodingKeys: String, CodingKey {
        case language
        case version
        case files
        case stdin
        case args
        case compileTimeout = "compile_timeout"
        case runTimeout = "run_timeout"
    }
}

private struct ExecuteResponse: Decodable {
    struct RunResult: Decodable {
        let stdout: String?
        let stderr: String?
        let output: String?
        let code: Int?
    }

    let run: RunResult?
}
