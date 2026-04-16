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
    @State private var pendingPythonRun: PendingPythonRun?
    @State private var pythonStdinDraft = ""

    var body: some View {
        Group {
            if message.role == .user {
                userMessageView
            } else {
                assistantMessageView
            }
        }
        .contextMenu {
            Button("复制全部") {
                UIPasteboard.general.string = message.copyableText
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
        .sheet(item: $pendingPythonRun) { payload in
            pythonInputSheet(payload: payload)
        }
        .onDisappear {
            cancelAllPythonRuns()
        }
    }

    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 0) {
            assistantIdentityHeader
                .padding(.bottom, 6)

            content

            if showsAssistantActionBar {
                assistantActionBar
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantIdentityHeader: some View {
        HStack(spacing: 8) {
            assistantIdentityIcon

            Text("IEXA")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
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
            Spacer(minLength: 68)
            userMessageContent
                .padding(.vertical, 13)
                .padding(.horizontal, 17)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(userBubbleColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.035), lineWidth: 0.8)
                )
                .frame(maxWidth: 290, alignment: .trailing)
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
                    .font(.system(size: 18, weight: .regular))
                    .lineSpacing(5)
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
        if message.isStreaming {
            streamingContent
        } else {
            let segments = MessageContentParser.parse(message)

            if segments.isEmpty {
                if let fallback = fallbackPlainText {
                    SelectableLinkTextView(
                        text: fallback,
                        textColor: UIColor.label,
                        linkColor: UIColor.systemGray,
                        font: .systemFont(ofSize: 18, weight: .regular)
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        let visibleText = message.content.replacingOccurrences(of: "\r\n", with: "\n")
        if !message.imageAttachments.isEmpty || !message.fileAttachments.isEmpty || !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.imageAttachments) { attachment in
                    messageImage(attachment)
                }
                ForEach(message.fileAttachments) { file in
                    codeBlock(title: "FILE · \(file.fileName)", content: file.previewText, language: file.codeLanguageHint)
                }
                if !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    streamingGradientText(visibleText)
                        .font(.system(size: 18, weight: .regular))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let fallback = fallbackPlainText {
            streamingGradientText(fallback)
                .font(.system(size: 18, weight: .regular))
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Circle()
                .fill(Color.black)
                .frame(width: 7, height: 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("正在接收流式内容")
        }
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
                .font(.system(size: 18, weight: .regular))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let language, let content):
            codeBlock(title: (language ?? "code").uppercased(), content: content, language: language)
        case .file(let name, let language, let content):
            codeBlock(title: "FILE · \(name)", content: content, language: language)
        case .image(let attachment):
            messageImage(attachment)
        }
    }

    private func streamingGradientText(_ value: String) -> Text {
        let parts = splitStreamingGradientText(value)
        var rendered = Text(verbatim: parts.head).foregroundColor(.primary)

        if !parts.mid.isEmpty {
            rendered = rendered + Text(verbatim: parts.mid).foregroundColor(Color.primary.opacity(0.72))
        }
        if !parts.tip.isEmpty {
            rendered = rendered + Text(verbatim: parts.tip).foregroundColor(Color.secondary.opacity(0.5))
        }
        return rendered
    }

    private func splitStreamingGradientText(_ value: String) -> (head: String, mid: String, tip: String) {
        let total = value.count
        guard total > 0 else { return ("", "", "") }

        let tipCount = min(3, total)
        let midCount = min(8, max(total - tipCount, 0))
        let headCount = max(total - tipCount - midCount, 0)

        let headEnd = value.index(value.startIndex, offsetBy: headCount)
        let midEnd = value.index(headEnd, offsetBy: midCount)

        return (
            String(value[..<headEnd]),
            String(value[headEnd..<midEnd]),
            String(value[midEnd...])
        )
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment) -> some View {
        switch segment {
        case .text(let text):
            SelectableLinkTextView(
                text: text,
                textColor: UIColor.label,
                linkColor: UIColor.systemGray,
                font: .systemFont(ofSize: 18, weight: .regular)
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let content):
            codeBlock(title: (language ?? "code").uppercased(), content: content, language: language)
        case .file(let name, let language, let content):
            codeBlock(title: "FILE · \(name)", content: content, language: language)
        case .image(let attachment):
            messageImage(attachment)
        }
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

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
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

            ScrollView(.horizontal, showsIndicators: false) {
                if message.isStreaming {
                    Text(content)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Text(CodeHighlighter.highlighted(content, language: language, colorScheme: colorScheme, codeThemeMode: codeThemeMode))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(codeBackgroundColor)
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
        if let data = attachment.decodedImageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300, maxHeight: 900, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contextMenu {
                    if !attachment.requestURLString.isEmpty {
                        Button("复制图片链接") {
                            UIPasteboard.general.string = attachment.requestURLString
                        }
                    }
                    Button("保存到相册") {
                        saveImageAttachment(attachment)
                    }
                }
        } else if let urlString = attachment.renderURLString {
            RemoteImageView(urlString: urlString, apiKey: apiKey, baseURL: apiBaseURL)
                .frame(maxWidth: 300, maxHeight: 900, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contextMenu {
                    if !attachment.requestURLString.isEmpty {
                        Button("复制图片链接") {
                            UIPasteboard.general.string = attachment.requestURLString
                        }
                    }
                    Button("保存到相册") {
                        saveImageAttachment(attachment)
                    }
                }
        }
    }

    private var codeBackgroundColor: Color {
        switch codeThemeMode {
        case .vscodeDark:
            return Color(red: 0.12, green: 0.12, blue: 0.12)
        case .githubLight:
            return Color(red: 0.96, green: 0.97, blue: 0.99)
        case .followApp:
            return colorScheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color(red: 0.96, green: 0.97, blue: 0.99)
        }
    }

    private var userBubbleColor: Color {
        colorScheme == .dark ? Color(red: 0.18, green: 0.18, blue: 0.2) : Color(red: 0.94, green: 0.94, blue: 0.95)
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
}

private struct HTMLPreviewPayload: Identifiable {
    let id = UUID()
    let title: String
    let html: String
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
