import SwiftUI
import UIKit

struct LinuxShellScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isCommandFieldFocused: Bool

    @AppStorage("chatapp.linux-shell.cwd") private var persistedWorkingDirectory = ""

    @State private var sessionID: String?
    @State private var terminalOutput = ""
    @State private var commandDraft = ""
    @State private var currentWorkingDirectory = ""
    @State private var isConnecting = false
    @State private var isSending = false
    @State private var connectionError: String?
    @State private var pollTask: Task<Void, Never>?

    private let promptHost = "root@minis"
    private let maxTerminalCharacters = 160_000

    var body: some View {
        VStack(spacing: 0) {
            header

            terminalViewport
        }
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputAccessoryPanel
        }
        .preferredColorScheme(.dark)
        .onAppear {
            startSessionIfNeeded()
        }
        .onDisappear {
            let capturedSessionID = sessionID
            pollTask?.cancel()
            pollTask = nil
            if let capturedSessionID {
                Task {
                    try? await RemoteShellSessionService.shared.stopSession(
                        sessionID: capturedSessionID,
                        endpoint: viewModel.config.shellExecutionURLString,
                        apiKey: viewModel.config.resolvedShellExecutionAPIKey
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            shellHeaderButton(systemName: "xmark") {
                dismiss()
            }

            Spacer(minLength: 0)

            Text("Linux 终端")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            shellHeaderButton(systemName: "paintbrush") {
                terminalOutput = ""
                connectionError = nil
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.black)
    }

    private var terminalViewport: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(displayedTerminalText)
                    .font(.system(size: 18, weight: .regular, design: .monospaced))
                    .foregroundStyle(terminalTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                    .id("linux-shell-output")
            }
            .background(Color.black)
            .contentShape(Rectangle())
            .onTapGesture {
                isCommandFieldFocused = true
            }
            .onChange(of: terminalOutput) { _, _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("linux-shell-output", anchor: .bottom)
                    }
                }
            }
            .onChange(of: commandDraft) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("linux-shell-output", anchor: .bottom)
                }
            }
        }
    }

    private var inputAccessoryPanel: some View {
        VStack(spacing: 10) {
            quickActions

            hiddenInputBridge
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .background(Color.black)
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                quickActionButton(title: "隐藏") {
                    isCommandFieldFocused = false
                }
                quickActionButton(title: "粘贴") {
                    let pasted = UIPasteboard.general.string ?? ""
                    guard !pasted.isEmpty else { return }
                    commandDraft += pasted
                    isCommandFieldFocused = true
                }
                quickActionButton(title: "清屏") {
                    terminalOutput = ""
                    connectionError = nil
                }
                quickActionButton(title: "Esc") { sendRawInput("\u{1B}") }
                quickActionButton(title: "Tab") { sendRawInput("\t") }
                quickActionButton(title: "Ctrl+C") { sendControlSignal("interrupt") }
                quickActionButton(title: "pwd") {
                    runPresetCommand("pwd")
                }
                quickActionButton(title: "ls") {
                    runPresetCommand("ls")
                }
                quickActionButton(title: "git status") {
                    runPresetCommand("git status")
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func quickActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.31, green: 0.93, blue: 0.52))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.18, green: 0.18, blue: 0.19))
                )
        }
        .buttonStyle(.plain)
        .disabled(isConnecting || sessionID == nil)
        .opacity((isConnecting || sessionID == nil) ? 0.45 : 1)
    }

    private var hiddenInputBridge: some View {
        TextField("", text: $commandDraft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.go)
            .focused($isCommandFieldFocused)
            .disabled(!shellReady || isConnecting || isSending)
            .onSubmit {
                submitCurrentCommand()
            }
            .frame(height: 1)
            .opacity(0.01)
    }

    private func shellHeaderButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(MinisTheme.accentBlue)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private var shellReady: Bool {
        !viewModel.config.shellExecutionURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmitCommand: Bool {
        shellReady && !isConnecting && !isSending && !commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayWorkingDirectory: String {
        let candidates = [
            currentWorkingDirectory,
            persistedWorkingDirectory,
            viewModel.config.shellExecutionWorkingDirectory
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "/"
    }

    private var displayedTerminalText: String {
        if let connectionError, !connectionError.isEmpty {
            return connectionError
        }

        var output = terminalOutput

        if output.isEmpty {
            if isConnecting {
                output = "正在连接 \(promptHost)…\n"
            } else {
                output = "\(promptHost):\(displayWorkingDirectory)# "
            }
        }

        if !commandDraft.isEmpty {
            output += commandDraft
        }

        if shellReady && !isConnecting {
            output += "█"
        }

        return output
    }

    private var terminalTextColor: Color {
        if connectionError != nil {
            return Color(red: 1.0, green: 0.42, blue: 0.42)
        }
        return Color(red: 0.34, green: 0.94, blue: 0.56)
    }

    private func startSessionIfNeeded() {
        guard shellReady else {
            connectionError = "当前还没有可用的 Linux 终端。请先配置真实可用的远端终端地址。"
            return
        }
        guard sessionID == nil, !isConnecting else { return }
        startSession()
    }

    private func restartSession() {
        let oldSessionID = sessionID
        sessionID = nil
        terminalOutput = ""
        connectionError = nil
        pollTask?.cancel()
        pollTask = nil

        if let oldSessionID {
            Task {
                try? await RemoteShellSessionService.shared.stopSession(
                    sessionID: oldSessionID,
                    endpoint: viewModel.config.shellExecutionURLString,
                    apiKey: viewModel.config.resolvedShellExecutionAPIKey
                )
            }
        }

        startSession()
    }

    private func startSession() {
        isConnecting = true
        connectionError = nil
        isCommandFieldFocused = true

        Task {
            do {
                let snapshot = try await RemoteShellSessionService.shared.startSession(
                    endpoint: viewModel.config.shellExecutionURLString,
                    apiKey: viewModel.config.resolvedShellExecutionAPIKey,
                    workingDirectory: displayWorkingDirectory
                )
                await MainActor.run {
                    apply(snapshot: snapshot)
                    sessionID = snapshot.sessionID
                    isConnecting = false
                    startPolling(sessionID: snapshot.sessionID)
                }
            } catch {
                await MainActor.run {
                    connectionError = "连接 Linux 终端失败：\(error.localizedDescription)"
                    isConnecting = false
                }
            }
        }
    }

    private func startPolling(sessionID: String) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    let snapshot = try await RemoteShellSessionService.shared.pollSession(
                        sessionID: sessionID,
                        endpoint: viewModel.config.shellExecutionURLString,
                        apiKey: viewModel.config.resolvedShellExecutionAPIKey
                    )
                    await MainActor.run {
                        apply(snapshot: snapshot)
                        if !snapshot.isRunning {
                            self.sessionID = nil
                        }
                    }
                    if !snapshot.isRunning {
                        break
                    }
                } catch {
                    await MainActor.run {
                        if self.connectionError == nil {
                            self.connectionError = "终端会话中断：\(error.localizedDescription)"
                        }
                        self.sessionID = nil
                    }
                    break
                }

                try? await Task.sleep(nanoseconds: 220_000_000)
            }
        }
    }

    private func submitCurrentCommand() {
        guard let sessionID else { return }
        let command = commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        commandDraft = ""
        isSending = true

        Task {
            do {
                let snapshot = try await RemoteShellSessionService.shared.sendInput(
                    sessionID: sessionID,
                    input: command,
                    endpoint: viewModel.config.shellExecutionURLString,
                    apiKey: viewModel.config.resolvedShellExecutionAPIKey
                )
                await MainActor.run {
                    apply(snapshot: snapshot)
                    isSending = false
                    isCommandFieldFocused = true
                }
            } catch {
                await MainActor.run {
                    appendTerminalOutput("\n[error] \(error.localizedDescription)\n")
                    isSending = false
                    isCommandFieldFocused = true
                }
            }
        }
    }

    private func runPresetCommand(_ command: String) {
        commandDraft = command
        submitCurrentCommand()
    }

    private func sendRawInput(_ input: String) {
        guard let sessionID else { return }

        Task {
            do {
                let snapshot = try await RemoteShellSessionService.shared.sendInput(
                    sessionID: sessionID,
                    input: input,
                    endpoint: viewModel.config.shellExecutionURLString,
                    apiKey: viewModel.config.resolvedShellExecutionAPIKey,
                    appendNewline: false
                )
                await MainActor.run {
                    apply(snapshot: snapshot)
                    isCommandFieldFocused = true
                }
            } catch {
                await MainActor.run {
                    appendTerminalOutput("\n[error] \(error.localizedDescription)\n")
                }
            }
        }
    }

    private func sendControlSignal(_ signal: String) {
        guard let sessionID else { return }

        Task {
            do {
                let snapshot = try await RemoteShellSessionService.shared.sendSignal(
                    sessionID: sessionID,
                    signal: signal,
                    endpoint: viewModel.config.shellExecutionURLString,
                    apiKey: viewModel.config.resolvedShellExecutionAPIKey
                )
                await MainActor.run {
                    apply(snapshot: snapshot)
                    isCommandFieldFocused = true
                }
            } catch {
                await MainActor.run {
                    appendTerminalOutput("\n[error] \(error.localizedDescription)\n")
                }
            }
        }
    }

    private func apply(snapshot: RemoteShellSessionSnapshot) {
        let cwd = snapshot.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cwd.isEmpty {
            currentWorkingDirectory = cwd
            persistedWorkingDirectory = cwd
        }

        if !snapshot.output.isEmpty {
            appendTerminalOutput(snapshot.output)
        }

        if !snapshot.isRunning, let exitCode = snapshot.exitCode {
            appendTerminalOutput("\n[session exited] code=\(exitCode)\n")
        }
    }

    private func appendTerminalOutput(_ text: String) {
        guard !text.isEmpty else { return }
        terminalOutput += text
        if terminalOutput.count > maxTerminalCharacters {
            terminalOutput = String(terminalOutput.suffix(maxTerminalCharacters))
        }
    }
}
