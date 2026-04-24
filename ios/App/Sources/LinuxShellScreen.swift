import SwiftUI
import UIKit

private struct LinuxShellTranscriptEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case prompt
        case output
        case error
        case meta
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

struct LinuxShellScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isCommandFieldFocused: Bool

    @AppStorage("chatapp.linux-shell.cwd") private var persistedWorkingDirectory = ""

    @State private var transcript: [LinuxShellTranscriptEntry] = []
    @State private var commandDraft = ""
    @State private var isRunning = false
    @State private var bootstrapCompleted = false
    @State private var activeTask: Task<Void, Never>?
    @State private var currentWorkingDirectory = ""

    private let promptHost = "root@minis"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    transcriptScrollView(proxy: proxy)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomPanel
            }
            .preferredColorScheme(.dark)
            .onAppear {
                prepareShellIfNeeded()
            }
            .onDisappear {
                activeTask?.cancel()
                activeTask = nil
            }
            .onChange(of: transcript.count) { _, _ in
                scrollToBottom(with: proxy)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            shellCircleButton(systemName: "xmark") {
                dismiss()
            }

            Spacer(minLength: 0)

            Text("Linux 终端")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            shellCircleButton(systemName: "paintbrush") {
                clearTranscript()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.black)
    }

    private func transcriptScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if transcript.isEmpty {
                    Text(currentPromptLine)
                        .font(.system(size: 18, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                } else {
                    ForEach(transcript) { entry in
                        transcriptEntryView(entry)
                    }
                }

                if isRunning {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Color(red: 0.27, green: 0.88, blue: 0.47))
                            .scaleEffect(0.82)
                        Text("命令执行中…")
                            .font(.system(size: 15.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.76))
                    }
                    .padding(.horizontal, 14)
                }

                Color.clear
                    .frame(height: 1)
                    .id("linux-shell-bottom")
            }
            .padding(.top, 6)
            .padding(.bottom, 18)
        }
        .background(Color.black)
        .onAppear {
            scrollToBottom(with: proxy, animated: false)
        }
    }

    @ViewBuilder
    private func transcriptEntryView(_ entry: LinuxShellTranscriptEntry) -> some View {
        switch entry.kind {
        case .prompt:
            Text(entry.text)
                .font(.system(size: 18, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.94))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        case .output:
            Text(entry.text)
                .font(.system(size: 17, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(red: 0.34, green: 0.94, blue: 0.56))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .textSelection(.enabled)
        case .error:
            Text(entry.text)
                .font(.system(size: 17, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .textSelection(.enabled)
        case .meta:
            Text(entry.text)
                .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.54))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            quickActionsRow

            VStack(alignment: .leading, spacing: 10) {
                Text(currentPromptLine)
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)

                HStack(spacing: 12) {
                    TextField(
                        "输入命令，例如 npm install、git status、python main.py",
                        text: $commandDraft
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.go)
                    .focused($isCommandFieldFocused)
                    .disabled(!shellReady || isRunning)
                    .onSubmit {
                        submitCurrentCommand()
                    }
                    .font(.system(size: 17, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white)

                    Button {
                        submitCurrentCommand()
                    } label: {
                        Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 38, height: 38)
                            .background(
                                Circle()
                                    .fill(shellReady && !commandDraftTrimmed.isEmpty && !isRunning
                                        ? Color(red: 0.32, green: 0.93, blue: 0.52)
                                        : Color.white.opacity(0.18))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!shellReady || commandDraftTrimmed.isEmpty || isRunning)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color.black)
        }
        .background(Color.black)
    }

    private var quickActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                quickActionButton(title: "隐藏") {
                    isCommandFieldFocused = false
                }
                quickActionButton(title: "粘贴") {
                    let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else { return }
                    if commandDraftTrimmed.isEmpty {
                        commandDraft = text
                    } else {
                        commandDraft += text
                    }
                    isCommandFieldFocused = true
                }
                quickActionButton(title: "清屏") {
                    clearTranscript()
                }
                quickActionButton(title: "pwd") {
                    runPresetCommand("pwd")
                }
                quickActionButton(title: "ls") {
                    runPresetCommand("ls")
                }
                quickActionButton(title: "cd ..") {
                    runPresetCommand("cd ..")
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
                .foregroundStyle(Color(red: 0.32, green: 0.93, blue: 0.52))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.18, green: 0.18, blue: 0.19))
                )
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .opacity(isRunning ? 0.45 : 1)
    }

    private func shellCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(MinisTheme.accentBlue)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private var shellReady: Bool {
        viewModel.config.shellExecutionEnabled
            && !viewModel.config.shellExecutionURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commandDraftTrimmed: String {
        commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveWorkingDirectory: String {
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
        return "."
    }

    private var currentPromptLine: String {
        "\(promptHost):\(displayPromptPath(effectiveWorkingDirectory))#"
    }

    private func displayPromptPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "/"
        }
        return trimmed
    }

    private func prepareShellIfNeeded() {
        guard !bootstrapCompleted else { return }
        bootstrapCompleted = true
        isCommandFieldFocused = true

        guard shellReady else {
            transcript = [
                LinuxShellTranscriptEntry(
                    kind: .error,
                    text: "当前还没有可用的 Linux Shell。请先在设置里启用远端 Linux Shell，并配置真实可用的接口地址。"
                )
            ]
            return
        }

        activeTask?.cancel()
        activeTask = Task {
            do {
                let result = try await RemoteShellExecutionService.shared.run(
                    command: "pwd",
                    endpoint: viewModel.config.shellExecutionURLString,
                    apiKey: viewModel.config.apiKey,
                    workingDirectory: effectiveWorkingDirectory,
                    timeout: min(max(viewModel.config.shellExecutionTimeout, 5), 60)
                )
                await MainActor.run {
                    let resolved = result.finalWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let resolved, !resolved.isEmpty {
                        currentWorkingDirectory = resolved
                        persistedWorkingDirectory = resolved
                    }
                }
            } catch {
                await MainActor.run {
                    transcript = [
                        LinuxShellTranscriptEntry(
                            kind: .error,
                            text: "连接 Linux Shell 失败：\(error.localizedDescription)"
                        )
                    ]
                }
            }
        }
    }

    private func clearTranscript() {
        transcript.removeAll()
    }

    private func runPresetCommand(_ command: String) {
        guard !isRunning else { return }
        commandDraft = command
        submitCurrentCommand()
    }

    private func submitCurrentCommand() {
        let command = commandDraftTrimmed
        guard !command.isEmpty else { return }
        commandDraft = ""

        if command == "clear" || command == "cls" {
            clearTranscript()
            return
        }

        if command == "exit" || command == "quit" {
            dismiss()
            return
        }

        runCommand(command)
    }

    private func runCommand(_ command: String) {
        guard shellReady else { return }

        let displayedCommand = "\(currentPromptLine) \(command)"
        transcript.append(.init(kind: .prompt, text: displayedCommand))
        isRunning = true

        activeTask?.cancel()
        activeTask = Task {
            do {
                let result = try await RemoteShellExecutionService.shared.run(
                    command: command,
                    endpoint: viewModel.config.shellExecutionURLString,
                    apiKey: viewModel.config.apiKey,
                    workingDirectory: effectiveWorkingDirectory,
                    timeout: viewModel.config.shellExecutionTimeout
                )

                await MainActor.run {
                    if let finalWorkingDirectory = result.finalWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !finalWorkingDirectory.isEmpty {
                        currentWorkingDirectory = finalWorkingDirectory
                        persistedWorkingDirectory = finalWorkingDirectory
                    }

                    let normalizedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalizedOutput.isEmpty {
                        transcript.append(
                            .init(
                                kind: result.exitCode == 0 ? .output : .error,
                                text: normalizedOutput
                            )
                        )
                    }

                    let meta = result.durationMs.map { "退出码 \(result.exitCode) · \($0)ms" } ?? "退出码 \(result.exitCode)"
                    transcript.append(.init(kind: .meta, text: meta))
                    isRunning = false
                    isCommandFieldFocused = true
                }
            } catch is CancellationError {
                await MainActor.run {
                    transcript.append(.init(kind: .meta, text: "命令已结束"))
                    isRunning = false
                    isCommandFieldFocused = true
                }
            } catch {
                await MainActor.run {
                    transcript.append(
                        .init(
                            kind: .error,
                            text: "执行失败：\(error.localizedDescription)"
                        )
                    )
                    isRunning = false
                    isCommandFieldFocused = true
                }
            }
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            withAnimation(animated ? .easeOut(duration: 0.18) : nil) {
                proxy.scrollTo("linux-shell-bottom", anchor: .bottom)
            }
        }
    }
}
