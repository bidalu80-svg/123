import Foundation

enum RemotePythonExecutionMode: String {
    case runFile = "run_file"
    case unitTests = "unit_tests"
    case compileAll = "compile_all"
}

struct RemotePythonExecutionResult: Equatable {
    let output: String
    let exitCode: Int
}

final class RemotePythonExecutionService {
    static let shared = RemotePythonExecutionService()

    private struct PayloadFile {
        let path: String
        let contentBase64: String
    }

    private let fileManager = FileManager.default
    private let session: URLSession
    private let maxFiles = 180
    private let maxSingleFileBytes = 1_200_000
    private let maxTotalBytes = 7_500_000

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: configuration)
    }

    func execute(
        mode: RemotePythonExecutionMode,
        projectURL: URL,
        entryPath: String? = nil,
        stdin: String? = nil,
        config: ChatConfig
    ) async throws -> RemotePythonExecutionResult {
        let endpoint = config.remotePythonExecutionURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "远端 Python 执行地址无效。"]
            )
        }

        let files = try collectProjectFiles(from: projectURL)
        var payload: [String: Any] = [
            "mode": mode.rawValue,
            "timeout": Int(config.remotePythonExecutionTimeout.rounded()),
            "files": files.map { file in
                [
                    "path": file.path,
                    "content_base64": file.contentBase64
                ]
            }
        ]

        if let entryPath,
           !entryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["entry_path"] = entryPath
        }
        if let stdin {
            payload["stdin"] = stdin
        }

        var request = URLRequest(
            url: url,
            timeoutInterval: max(30, min(config.remotePythonExecutionTimeout, 900))
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let token = config.resolvedRemotePythonExecutionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue(token, forHTTPHeaderField: "api-key")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "远端 Python 响应无效。"]
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "远端 Python 返回 JSON 无效（HTTP \(httpResponse.statusCode)）。"]
            )
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let message = firstNonEmptyString(
                object["detail"],
                object["message"],
                object["error"],
                object["combined_output"]
            ) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "远端 Python 执行失败：\(message)"]
            )
        }

        let exitCode = parseInt(object["exit_code"]) ?? parseInt(object["exitCode"]) ?? 1
        let stdout = firstNonEmptyString(object["stdout"]) ?? ""
        let stderr = firstNonEmptyString(object["stderr"]) ?? ""
        let installLog = firstNonEmptyString(object["install_log"], object["installLog"]) ?? ""
        let combinedOutput = firstNonEmptyString(
            object["combined_output"],
            object["combinedOutput"],
            object["output"]
        ) ?? ([stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n"))

        var segments: [String] = ["[远端 Python 执行]"]
        if !installLog.isEmpty {
            segments.append("安装日志：\n\(installLog)")
        }
        if !combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(combinedOutput)
        } else if !stdout.isEmpty || !stderr.isEmpty {
            segments.append([stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
        } else {
            segments.append("执行完成（无输出）")
        }

        return RemotePythonExecutionResult(
            output: segments.joined(separator: "\n\n"),
            exitCode: exitCode
        )
    }

    private func collectProjectFiles(from projectURL: URL) throws -> [PayloadFile] {
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法遍历项目目录。"]
            )
        }

        let root = projectURL.standardizedFileURL.path
        var totalBytes = 0
        var result: [PayloadFile] = []

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }

            let size = values.fileSize ?? 0
            if size <= 0 || size > maxSingleFileBytes {
                continue
            }

            let data = try Data(contentsOf: fileURL)
            if totalBytes + data.count > maxTotalBytes {
                break
            }

            let absolute = fileURL.standardizedFileURL.path
            let relative = absolute.hasPrefix(root + "/")
                ? String(absolute.dropFirst(root.count + 1))
                : fileURL.lastPathComponent

            result.append(
                PayloadFile(
                    path: relative,
                    contentBase64: data.base64EncodedString()
                )
            )
            totalBytes += data.count

            if result.count >= maxFiles {
                break
            }
        }

        guard !result.isEmpty else {
            throw NSError(
                domain: "RemotePythonExecutionService",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "没有可上传到远端 Python 的项目文件。"]
            )
        }

        return result
    }

    private func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func parseInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let intValue = value as? Int {
            return intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
