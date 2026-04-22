import SwiftUI

struct RemoteTerminalScreen: View {
    @AppStorage("terminal.runner.baseURL") private var baseURL = "http://8.218.177.114/terminal"
    @AppStorage("terminal.runner.token") private var token = ""
    @AppStorage("terminal.runner.cwd") private var cwd = ""
    @AppStorage("terminal.runner.timeoutSeconds") private var timeoutSeconds = 45
    @AppStorage("terminal.runner.maxOutputBytes") private var maxOutputBytes = 120_000

    @State private var command = "python3 --version"
    @State private var stdoutText = ""
    @State private var stderrText = ""
    @State private var statusText = "未运行"
    @State private var activeJobID: String?
    @State private var isRunning = false
    @State private var healthText = "未检查"
    @State private var lastDurationMs: Int?
    @State private var lastExitCode: Int?
    @State private var runTask: Task<Void, Never>?

    private let service = RemoteTerminalService()

    var body: some View {
        List {
            Section("服务器配置") {
                TextField("终端服务地址", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                SecureField("终端 Token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("工作目录（可空）", text: $cwd)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Stepper("超时：\(timeoutSeconds)s", value: $timeoutSeconds, in: 5...180, step: 5)
                Stepper("输出上限：\(maxOutputBytes / 1024)KB", value: $maxOutputBytes, in: 32_768...300_000, step: 8_192)
            }

            Section("命令") {
                TextEditor(text: $command)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 90)
                HStack(spacing: 10) {
                    Button(isRunning ? "运行中…" : "运行命令") {
                        startRun()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("停止") {
                        stopRun()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isRunning)

                    Button("健康检查") {
                        pingHealth()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
                }

                HStack(spacing: 10) {
                    Button("清空输出") {
                        stdoutText = ""
                        stderrText = ""
                        lastDurationMs = nil
                        lastExitCode = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
                }
            }

            Section("状态") {
                statusRow("运行状态", statusText)
                statusRow("服务状态", healthText)
                statusRow("当前任务", activeJobID ?? "-")
                statusRow("退出码", lastExitCode.map(String.init) ?? "-")
                statusRow("耗时", lastDurationMs.map { "\($0) ms" } ?? "-")
            }

            Section("标准输出 stdout") {
                terminalOutputBlock(stdoutText)
            }

            Section("错误输出 stderr") {
                terminalOutputBlock(stderrText)
            }
        }
        .navigationTitle("远程终端")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CornerClockBadge()
            }
        }
        .onDisappear {
            runTask?.cancel()
        }
    }

    @ViewBuilder
    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func terminalOutputBlock(_ text: String) -> some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("暂无输出")
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 160, maxHeight: 280)
        }
    }

    private func startRun() {
        guard !isRunning else { return }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }

        isRunning = true
        statusText = "创建任务中…"
        activeJobID = nil
        lastDurationMs = nil
        lastExitCode = nil

        runTask?.cancel()
        let base = baseURL
        let authToken = token
        let workingDir = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeout = timeoutSeconds
        let outputLimit = maxOutputBytes

        runTask = Task {
            do {
                let jobID = try await service.startJob(
                    baseURL: base,
                    token: authToken,
                    command: trimmedCommand,
                    cwd: workingDir.isEmpty ? nil : workingDir,
                    timeoutSeconds: timeout,
                    maxOutputBytes: outputLimit
                )
                await MainActor.run {
                    activeJobID = jobID
                    statusText = "运行中"
                }
                try await pollJob(baseURL: base, token: authToken, jobID: jobID)
            } catch {
                await MainActor.run {
                    statusText = "运行失败：\(error.localizedDescription)"
                    isRunning = false
                    activeJobID = nil
                }
            }
        }
    }

    private func pollJob(baseURL: String, token: String, jobID: String) async throws {
        while !Task.isCancelled {
            let snapshot = try await service.fetchJob(baseURL: baseURL, token: token, jobID: jobID)
            await MainActor.run {
                stdoutText = snapshot.stdout
                stderrText = snapshot.stderr
                lastDurationMs = snapshot.durationMs
                lastExitCode = snapshot.exitCode
                statusText = statusLabel(for: snapshot)
            }

            if snapshot.status != "queued" && snapshot.status != "running" {
                await MainActor.run {
                    isRunning = false
                    activeJobID = nil
                }
                return
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    private func statusLabel(for snapshot: RemoteTerminalJobSnapshot) -> String {
        var parts: [String] = []
        parts.append(snapshot.status)
        if snapshot.timedOut {
            parts.append("超时")
        }
        if snapshot.truncatedStdout || snapshot.truncatedStderr {
            parts.append("输出已截断")
        }
        if let error = snapshot.error, !error.isEmpty {
            parts.append("错误: \(error)")
        }
        return parts.joined(separator: " · ")
    }

    private func stopRun() {
        guard let jobID = activeJobID else {
            runTask?.cancel()
            isRunning = false
            statusText = "已停止"
            return
        }

        let base = baseURL
        let authToken = token
        Task {
            try? await service.cancelJob(baseURL: base, token: authToken, jobID: jobID)
            await MainActor.run {
                runTask?.cancel()
                runTask = nil
                statusText = "已请求停止"
                isRunning = false
                activeJobID = nil
            }
        }
    }

    private func pingHealth() {
        let base = baseURL
        let authToken = token
        Task {
            do {
                let health = try await service.health(baseURL: base, token: authToken)
                await MainActor.run {
                    let running = health.runningJobs ?? 0
                    let known = health.knownJobs ?? 0
                    healthText = "up (running \(running), jobs \(known))"
                }
            } catch {
                await MainActor.run {
                    healthText = "检查失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

