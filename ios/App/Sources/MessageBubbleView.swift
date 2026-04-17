import SwiftUI
import UIKit
import Photos

struct MessageBubbleView: View {
    let message: ChatMessage
    let codeThemeMode: CodeThemeMode
    let apiKey: String
    let apiBaseURL: String
    let showsAssistantActionBar: Bool
    let onRegenerate: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var saveFeedback: String?
    @State private var reaction: AssistantReaction = .none
    @State private var actionFeedback: String?
    @State private var copiedCodeToken: String?
    @State private var runningCodeToken: String?
    @State private var pythonRunTasks: [String: Task<Void, Never>] = [:]
    @State private var codeRunOutputs: [String: String] = [:]
    @State private var codeRunErrors: [String: String] = [:]
    @State private var activeHTMLPreview: HTMLPreviewPayload?
    @State private var activeImagePreview: ImagePreviewPayload?
    @State private var pendingPythonRun: PendingPythonRun?
    @State private var pythonStdinDraft = ""
    @State private var waitingDotPulse = false
    private let chatUIFont = UIFont(name: "PingFangSC-Regular", size: 15.5) ?? UIFont.systemFont(ofSize: 15.5, weight: .regular)

    var body: some View {
        Group {
            if message.role == .user {
                userMessageView
            } else {
                assistantMessageView
            }
        }
        .alert("提示", isPresented: saveFeedbackBinding) {
            Button("确定", role: .cancel) {
                saveFeedback = nil
            }
        } message: {
            Text(saveFeedback ?? "")
        }
        .sheet(item: $activeHTMLPreview) { payload in
            HTMLPreviewSheet(title: payload.title, html: payload.html)
        }
        .sheet(item: $activeImagePreview) { payload in
            ImagePreviewSheet(
                source: payload.source,
                apiKey: apiKey,
                apiBaseURL: apiBaseURL
            )
        }
        .sheet(item: $pendingPythonRun) { payload in
            pythonInputSheet(payload: payload)
        }
        .onDisappear {
            cancelAllPythonRuns()
        }
    }

    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 6) {
            assistantIdentityHeader

            content

            if showsAssistantActionBar {
                assistantActionBar
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantIdentityHeader: some View {
        HStack(spacing: 7) {
            assistantIdentityIcon

            Text("IEXA")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantIdentityIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)

            HStack(spacing: 1) {
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                Image(systemName: "sparkles")
                    .font(.system(size: 5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .offset(y: 2)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var assistantActionBar: some View {
        HStack(spacing: 8) {
            iconActionButton(systemName: "doc.on.doc", accessibilityLabel: "复制") {
                UIPasteboard.general.string = message.copyableText
                feedback(.success, "已复制")
            }

            iconActionButton(
                systemName: reaction == .up ? "hand.thumbsup.fill" : "hand.thumbsup",
                foregroundColor: reaction == .up ? .blue : .secondary,
                accessibilityLabel: "点赞"
            ) {
                reaction = reaction == .up ? .none : .up
                if reaction == .up {
                    feedback(.light, "已点赞")
                } else {
                    feedback(.light, "已取消点赞")
                }
            }

            iconActionButton(
                systemName: reaction == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                foregroundColor: reaction == .down ? .red : .secondary,
                accessibilityLabel: "点踩"
            ) {
                reaction = reaction == .down ? .none : .down
                if reaction == .down {
                    feedback(.light, "已点踩")
                } else {
                    feedback(.light, "已取消点踩")
                }
            }

            if let onRegenerate {
                iconActionButton(systemName: "arrow.clockwise", accessibilityLabel: "重试") {
                    onRegenerate()
                    feedback(.light, "正在重试…")
                }
            }

            Menu {
                Button("复制全部", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.copyableText
                    feedback(.success, "已复制")
                }
                if let onRegenerate {
                    Button("重试", systemImage: "arrow.clockwise") {
                        onRegenerate()
                        feedback(.light, "正在重试…")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MiniIconButtonStyle())
            .foregroundStyle(.secondary)

            if let actionFeedback {
                Text(actionFeedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: reaction)
        .animation(.easeInOut(duration: 0.18), value: actionFeedback)
    }

    private func iconActionButton(
        systemName: String,
        foregroundColor: Color = .secondary,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(MiniIconButtonStyle())
        .foregroundStyle(foregroundColor)
        .accessibilityLabel(accessibilityLabel)
    }

    private func feedback(_ kind: ActionFeedbackKind, _ text: String) {
        switch kind {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        actionFeedback = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard actionFeedback == text else { return }
            actionFeedback = nil
        }
    }

    private var userMessageView: some View {
        HStack {
            Spacer(minLength: 62)
            userMessageContent
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(userBubbleColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.035), lineWidth: 0.8)
                )
                .frame(maxWidth: 312, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var userMessageContent: some View {
        let segments = MessageContentParser.parse(message)
        if segments.isEmpty {
            if message.isStreaming {
                Text("正在发送…")
                    .foregroundStyle(.secondary)
            } else if let fallback = fallbackPlainText {
                Text(fallback)
                    .font(.custom("PingFangSC-Regular", size: 15.5))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("（内容为空）")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    userSegmentView(segment)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.isImageGenerationPlaceholder && message.imageAttachments.isEmpty {
            imageGenerationProgressCard
        } else if message.isStreaming {
            streamingContent
        } else {
            let segments = MessageContentParser.parse(message)

            if segments.isEmpty {
                if let fallback = fallbackPlainText {
                    selectableTextContent(fallback)
                } else {
                    Text("（空响应）")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var streamingContent: some View {
        let displayText = normalizedStreamingText(message.content)
        if message.isImageGenerationPlaceholder && message.imageAttachments.isEmpty {
            imageGenerationProgressCard
        } else {
            let segments = parsedStreamingSegments(for: displayText)

            if segments.isEmpty {
                if !message.imageAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(message.imageAttachments) { attachment in
                            messageImage(attachment)
                        }
                    }
                } else {
                    streamingWaitingDot
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment)
                    }
                }
            }
        }
    }

    private var streamingWaitingDot: some View {
        Circle()
            .fill(Color.black)
            .frame(width: 7, height: 7)
            .scaleEffect(waitingDotPulse ? 1.0 : 0.68)
            .opacity(waitingDotPulse ? 0.95 : 0.3)
            .animation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true), value: waitingDotPulse)
            .onAppear {
                waitingDotPulse = true
            }
            .onDisappear {
                waitingDotPulse = false
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("正在接收流式内容")
    }

    private func normalizedStreamingText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func parsedStreamingSegments(for displayText: String) -> [MessageSegment] {
        let streamingMessage = ChatMessage(
            id: message.id,
            role: message.role,
            content: displayText,
            createdAt: message.createdAt,
            isStreaming: true,
            isImageGenerationPlaceholder: message.isImageGenerationPlaceholder,
            imageAttachments: message.imageAttachments,
            fileAttachments: message.fileAttachments
        )
        return MessageContentParser.parse(streamingMessage)
    }

    private var imageGenerationProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.animation(minimumInterval: 0.12, paused: false)) { timeline in
                ImageGenerationPlaceholderPattern(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: 300, height: 300, alignment: .center)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
            )

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在生成图片…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("生图中")
    }

    private var fallbackPlainText: String? {
        let normalized = message.content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    @ViewBuilder
    private func userSegmentView(_ segment: MessageSegment) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .font(.custom("PingFangSC-Regular", size: 15.5))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let language, let content):
            codeBlock(title: (language ?? "code").uppercased(), content: content, language: language)
        case .file(let name, let language, let content):
            codeBlock(title: "FILE · \(name)", content: content, language: language)
        case .image(let attachment):
            messageImage(attachment)
        case .divider:
            sectionDivider
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment) -> some View {
        switch segment {
        case .text(let text):
            selectableTextContent(text)
        case .code(let language, let content):
            codeBlock(title: (language ?? "code").uppercased(), content: content, language: language)
        case .file(let name, let language, let content):
            codeBlock(title: "FILE · \(name)", content: content, language: language)
        case .image(let attachment):
            messageImage(attachment)
        case .divider:
            sectionDivider
        }
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(Color.secondary.opacity(colorScheme == .dark ? 0.30 : 0.22))
            .padding(.vertical, 10)
    }

    private func selectableTextContent(_ text: String) -> some View {
        SelectableLinkTextView(
            text: text,
            textColor: UIColor.label,
            linkColor: UIColor.secondaryLabel,
            font: chatUIFont,
            renderMarkdown: false
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBlock(title: String, content: String, language: String? = nil) -> some View {
        let copyToken = "\(title)|\(language ?? "")|\(content)"
        let isCopied = copiedCodeToken == copyToken
        let isRunning = runningCodeToken == copyToken
        let canRunPython = supportsPythonRun(language: language, title: title)
            && PythonExecutionService.isRunnableSnippet(content)
        let canRunHTML = supportsHTMLPreview(language: language, title: title, content: content)
        let runOutput = codeRunOutputs[copyToken]
        let runError = codeRunErrors[copyToken]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.92))
                Spacer()
                if canRunPython {
                    Button(isRunning ? "结束运行" : "运行") {
                        if isRunning {
                            stopPythonRun(token: copyToken)
                        } else {
                            requestPythonRun(content, token: copyToken)
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? .red : Color(red: 0.08, green: 0.08, blue: 0.1))
                    .foregroundStyle(.white)
                }
                if canRunHTML {
                    Button("运行网页") {
                        openHTMLPreview(title: title, content: content)
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.06, green: 0.36, blue: 0.86))
                    .foregroundStyle(.white)
                }
                Button(isCopied ? "已复制" : "复制代码") {
                    UIPasteboard.general.string = content
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(.easeInOut(duration: 0.16)) {
                        copiedCodeToken = copyToken
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        guard copiedCodeToken == copyToken else { return }
                        withAnimation(.easeInOut(duration: 0.16)) {
                            copiedCodeToken = nil
                        }
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .tint(isCopied ? .green : nil)
                .animation(.easeInOut(duration: 0.16), value: isCopied)
            }

            SelectableCodeTextView(
                text: content,
                textColor: UIColor.label,
                font: .monospacedSystemFont(ofSize: 15, weight: .regular),
                lineSpacing: 3.5,
                language: language,
                codeThemeMode: codeThemeMode,
                isDarkMode: colorScheme == .dark
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("正在运行 Python…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let runOutput, !runOutput.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("运行输出")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("复制输出") {
                            UIPasteboard.general.string = runOutput
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            feedback(.light, "已复制运行输出")
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                    }

                    Text(runOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.06))
                )
            }

            if let runError, !runError.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("运行失败")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(runError)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(colorScheme == .dark ? 0.18 : 0.08))
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(codeBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(codeCardBorderColor, lineWidth: 1)
        )
    }

    private func supportsPythonRun(language: String?, title: String) -> Bool {
        let normalizedLanguage = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedLanguage == "python" || normalizedLanguage == "py" {
            return true
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedTitle == "python" || normalizedTitle == "py"
    }

    private func requestPythonRun(_ code: String, token: String) {
        if needsInteractiveInput(code) {
            pythonStdinDraft = ""
            pendingPythonRun = PendingPythonRun(token: token, code: code)
            return
        }
        runPythonCode(code, token: token, stdin: nil)
    }

    private func runPythonCode(_ code: String, token: String, stdin: String?) {
        pythonRunTasks[token]?.cancel()
        runningCodeToken = token
        codeRunErrors[token] = nil
        codeRunOutputs[token] = nil

        let task = Task {
            defer {
                Task { @MainActor in
                    pythonRunTasks[token] = nil
                }
            }

            do {
                let result = try await PythonExecutionService.shared.runPython(code: code, stdin: stdin)
                try Task.checkCancellation()
                await MainActor.run {
                    guard runningCodeToken == token else { return }
                    let rendered: String
                    if result.exitCode == 0 {
                        rendered = result.output
                    } else {
                        rendered = "\(result.output)\n\n[退出码 \(result.exitCode)]"
                    }
                    codeRunOutputs[token] = rendered
                    runningCodeToken = nil
                    feedback(.success, "代码运行完成")
                }
            } catch is CancellationError {
                await MainActor.run {
                    if runningCodeToken == token {
                        runningCodeToken = nil
                    }
                    if codeRunErrors[token] == nil {
                        codeRunErrors[token] = "运行已结束。"
                    }
                    feedback(.light, "已结束运行")
                }
            } catch {
                await MainActor.run {
                    guard runningCodeToken == token else { return }
                    codeRunOutputs[token] = nil
                    codeRunErrors[token] = error.localizedDescription
                    runningCodeToken = nil
                    feedback(.light, "代码运行失败")
                }
            }
        }
        pythonRunTasks[token] = task
    }

    private func stopPythonRun(token: String) {
        pythonRunTasks[token]?.cancel()
        pythonRunTasks[token] = nil
        if runningCodeToken == token {
            runningCodeToken = nil
        }
        codeRunErrors[token] = "运行已结束。"
        feedback(.light, "已结束运行")
    }

    private func cancelAllPythonRuns() {
        guard !pythonRunTasks.isEmpty else { return }
        for task in pythonRunTasks.values {
            task.cancel()
        }
        pythonRunTasks.removeAll()
        runningCodeToken = nil
    }

    private func needsInteractiveInput(_ code: String) -> Bool {
        code.range(of: #"(?<![A-Za-z0-9_])input\s*\("#, options: .regularExpression) != nil
    }

    private func pythonInputSheet(payload: PendingPythonRun) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("检测到代码包含 input()。每行对应一次输入，按顺序提供给程序。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $pythonStdinDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Python 输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        pendingPythonRun = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("运行") {
                        let input = pythonStdinDraft.replacingOccurrences(of: "\r\n", with: "\n")
                        let normalizedInput = input.isEmpty ? nil : input
                        pendingPythonRun = nil
                        runPythonCode(payload.code, token: payload.token, stdin: normalizedInput)
                    }
                }
            }
        }
    }

    private func supportsHTMLPreview(language: String?, title: String, content: String) -> Bool {
        let normalizedLanguage = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["html", "htm", "xhtml", "text/html"].contains(normalizedLanguage) {
            return true
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["html", "htm", "xhtml", "text/html"].contains(normalizedTitle) {
            return true
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("<!doctype html")
            || trimmed.hasPrefix("<html")
            || trimmed.contains("<body")
            || trimmed.contains("<head")
    }

    private func openHTMLPreview(title: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feedback(.light, "HTML 代码为空")
            return
        }
        activeHTMLPreview = HTMLPreviewPayload(title: title, html: trimmed)
    }

    @ViewBuilder
    private func messageImage(_ attachment: ChatImageAttachment) -> some View {
        let revealID = attachment.requestURLString.isEmpty
            ? attachment.id.uuidString
            : attachment.requestURLString

        if let data = attachment.decodedImageData, let uiImage = UIImage(data: data) {
            GeneratedImageRevealCard(revealID: revealID) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            }
                .frame(maxWidth: 300, maxHeight: 900, alignment: .leading)
                .onTapGesture {
                    openImagePreview(attachment)
                }
                .contextMenu {
                    imageContextActions(for: attachment)
                }
        } else if let urlString = attachment.renderURLString {
            GeneratedImageRevealCard(revealID: revealID) {
                RemoteImageView(urlString: urlString, apiKey: apiKey, baseURL: apiBaseURL)
            }
                .frame(maxWidth: 300, maxHeight: 900, alignment: .leading)
                .onTapGesture {
                    openImagePreview(attachment)
                }
                .contextMenu {
                    imageContextActions(for: attachment)
                }
        }
    }

    @ViewBuilder
    private func imageContextActions(for attachment: ChatImageAttachment) -> some View {
        if !attachment.requestURLString.isEmpty {
            Button("复制图片链接") {
                UIPasteboard.general.string = attachment.requestURLString
            }
        }
        Button("保存到相册") {
            saveImageAttachment(attachment)
        }
    }

    private var codeBackgroundColor: Color {
        switch codeThemeMode {
        case .vscodeDark:
            return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .githubLight:
            return Color(red: 0.97, green: 0.97, blue: 0.975)
        case .followApp:
            return colorScheme == .dark
                ? Color(red: 0.12, green: 0.12, blue: 0.14)
                : Color(red: 0.97, green: 0.97, blue: 0.975)
        }
    }

    private var codeCardBorderColor: Color {
        switch codeThemeMode {
        case .vscodeDark:
            return Color.white.opacity(0.16)
        case .githubLight:
            return Color.black.opacity(0.08)
        case .followApp:
            return colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
        }
    }

    private var userBubbleColor: Color {
        colorScheme == .dark
            ? Color(red: 0.20, green: 0.20, blue: 0.22)
            : Color(red: 0.93, green: 0.93, blue: 0.94)
    }

    private var saveFeedbackBinding: Binding<Bool> {
        Binding(
            get: { saveFeedback != nil },
            set: { newValue in
                if !newValue {
                    saveFeedback = nil
                }
            }
        )
    }

    private func saveImageAttachment(_ attachment: ChatImageAttachment) {
        if let data = attachment.decodedImageData, let image = UIImage(data: data) {
            writeImageToPhotos(image)
            return
        }

        guard let urlString = attachment.renderURLString,
              let resolved = normalizedRemoteURLString(urlString),
              let url = URL(string: resolved) else {
            saveFeedback = "当前图片无法保存。"
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else {
                    await MainActor.run {
                        saveFeedback = "图片保存失败。"
                    }
                    return
                }
                await MainActor.run {
                    writeImageToPhotos(image)
                }
            } catch {
                await MainActor.run {
                    saveFeedback = "图片保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func writeImageToPhotos(_ image: UIImage) {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            UIImageWriteToSavedPhotosAlbum(image, ImageSaveCoordinator.shared, #selector(ImageSaveCoordinator.handleSaveResult(_:didFinishSavingWithError:contextInfo:)), nil)
            ImageSaveCoordinator.shared.onComplete = { error in
                saveFeedback = error == nil ? "已保存到相册。" : "图片保存失败：\(error?.localizedDescription ?? "未知错误")"
            }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                Task { @MainActor in
                    if status == .authorized || status == .limited {
                        writeImageToPhotos(image)
                    } else {
                        saveFeedback = "没有相册写入权限。"
                    }
                }
            }
        default:
            saveFeedback = "没有相册写入权限。"
        }
    }

    private func normalizedRemoteURLString(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        cleaned = cleaned.replacingOccurrences(of: "\\/", with: "/")
        cleaned = cleaned.replacingOccurrences(of: "&amp;", with: "&")
        if cleaned.hasPrefix("//") {
            cleaned = "https:\(cleaned)"
        }
        if cleaned.hasPrefix("/") {
            let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !base.isEmpty {
                cleaned = "\(base)\(cleaned)"
            }
        }
        if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") {
            return cleaned
        }
        return nil
    }

    private func openImagePreview(_ attachment: ChatImageAttachment) {
        if let data = attachment.decodedImageData, let image = UIImage(data: data) {
            activeImagePreview = ImagePreviewPayload(source: .uiImage(image))
            return
        }

        if let remote = attachment.renderURLString,
           let normalized = normalizedRemoteURLString(remote) {
            activeImagePreview = ImagePreviewPayload(source: .remote(urlString: normalized))
        }
    }
}

private struct ImageGenerationPlaceholderPattern: View {
    let phase: TimeInterval

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            Canvas { context, size in
                let spacing: CGFloat = 18
                let radius: CGFloat = 1.35
                var y: CGFloat = 12

                while y < size.height - 8 {
                    var x: CGFloat = 12
                    while x < size.width - 8 {
                        let wave = sin((x * 0.08) + (y * 0.07) + phase * 2.8)
                        let opacity = 0.18 + ((wave + 1) * 0.5) * 0.32
                        let dotRect = CGRect(
                            x: x - radius,
                            y: y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                        context.fill(
                            Path(ellipseIn: dotRect),
                            with: .color(Color.primary.opacity(opacity))
                        )
                        x += spacing
                    }
                    y += spacing
                }
            }
            .padding(2)

            LinearGradient(
                colors: [
                    .clear,
                    Color.white.opacity(0.22),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.screen)
            .opacity(0.55)
        }
    }
}

private struct GeneratedImageRevealCard<Content: View>: View {
    let revealID: String
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var stageOneProgress: CGFloat = 0
    @State private var stageTwoProgress: CGFloat = 0
    @State private var scanProgress: CGFloat = -0.08
    @State private var revealSequence: Int = 0

    init(revealID: String, @ViewBuilder content: () -> Content) {
        self.revealID = revealID
        self.content = content()
    }

    private var combinedProgress: CGFloat {
        min(1, (stageOneProgress * 0.66) + (stageTwoProgress * 0.34))
    }

    private var contentOpacity: Double {
        Double(min(1, 0.14 + (stageOneProgress * 0.58) + (stageTwoProgress * 0.28)))
    }

    private var contentBlur: CGFloat {
        max(0, (1 - stageOneProgress) * 9 + (1 - stageTwoProgress) * 3)
    }

    private var placeholderOpacity: Double {
        Double(max(0, 1 - ((stageOneProgress * 0.7) + (stageTwoProgress * 0.5))))
    }

    private var scanOpacity: Double {
        Double(max(0, min(1, 0.92 - (stageTwoProgress * 0.56))))
    }

    private var revealFinished: Bool {
        stageTwoProgress >= 0.999
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 0.12, paused: revealFinished)) { timeline in
                ImageGenerationPlaceholderPattern(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
            .opacity(placeholderOpacity)

            content
                .opacity(contentOpacity)
                .blur(radius: contentBlur)
                .scaleEffect(1.028 - (0.028 * combinedProgress))
        }
        .overlay {
            GeometryReader { proxy in
                let height = max(proxy.size.height, 1)
                let offsetY = -64 + (height + 128) * scanProgress

                ZStack {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(colorScheme == .dark ? 0.30 : 0.58),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 56)

                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(colorScheme == .dark ? 0.14 : 0.26),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 126)
                }
                .offset(y: offsetY)
                .opacity(scanOpacity)
                .blendMode(colorScheme == .dark ? .screen : .plusLighter)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
        )
        .onAppear {
            startReveal()
        }
        .onChange(of: revealID) { _, _ in
            startReveal()
        }
    }

    private func startReveal() {
        revealSequence += 1
        let sequence = revealSequence

        stageOneProgress = 0
        stageTwoProgress = 0
        scanProgress = -0.08

        withAnimation(.easeOut(duration: 0.58)) {
            stageOneProgress = 1
            scanProgress = 0.52
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard sequence == revealSequence else { return }
            withAnimation(.easeInOut(duration: 0.88)) {
                stageTwoProgress = 1
                scanProgress = 1.06
            }
        }
    }
}

private struct HTMLPreviewPayload: Identifiable {
    let id = UUID()
    let title: String
    let html: String
}

private struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let source: ImagePreviewSheet.Source
}

private struct PendingPythonRun: Identifiable {
    let id = UUID()
    let token: String
    let code: String
}

private enum AssistantReaction {
    case none
    case up
    case down
}

private enum ActionFeedbackKind {
    case success
    case light
}

private struct MiniIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.0001))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private final class ImageSaveCoordinator: NSObject {
    static let shared = ImageSaveCoordinator()
    var onComplete: ((Error?) -> Void)?

    @objc func handleSaveResult(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        onComplete?(error)
        onComplete = nil
    }
}
