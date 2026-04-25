import SwiftUI
import UIKit
import Photos
import AVKit
import QuickLook

struct MessageBubbleView: View {
    let message: ChatMessage
    let sourceMessage: ChatMessage?
    let precedingUserMessage: ChatMessage?
    let codeThemeMode: CodeThemeMode
    let apiKey: String
    let apiBaseURL: String
    let showsAssistantActionBar: Bool
    let onRegenerate: (() -> Void)?
    let onDelete: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var speechPlayback = SpeechPlaybackService.shared
    @State private var saveFeedback: String?
    @State private var reaction: AssistantReaction = .none
    @State private var actionFeedback: String?
    @State private var copiedCodeToken: String?
    @State private var runningCodeToken: String?
    @State private var pythonRunTasks: [String: Task<Void, Never>] = [:]
    @State private var codeRunOutputs: [String: String] = [:]
    @State private var codeRunErrors: [String: String] = [:]
    @State private var isBuildingFrontendProject = false
    @State private var activeHTMLPreview: HTMLPreviewPayload?
    @State private var activeImagePreview: ImagePreviewPayload?
    @State private var activeVideoPreview: VideoPreviewPayload?
    @State private var activeCodeViewer: CodeViewerPayload?
    @State private var pendingPythonRun: PendingPythonRun?
    @State private var frontendProgressPulse = false
    @State private var isGeneratingPPT = false
    @State private var generatedPPTPayload: GeneratedPPTPayload?
    @State private var isGeneratingWord = false
    @State private var generatedWordPayload: GeneratedWordPayload?
    @State private var isGeneratingExcel = false
    @State private var generatedExcelPayload: GeneratedExcelPayload?
    @State private var hasAutoTriggeredExcelGeneration = false
    @State private var activePPTPreview: PPTPreviewPayload?
    @State private var activeShareSheet: ShareSheetPayload?
    @State private var pptGenerationTask: Task<Void, Never>?
    @State private var wordGenerationTask: Task<Void, Never>?
    @State private var excelGenerationTask: Task<Void, Never>?
    @State private var frontendBuildRequestID: Int = 0
    private let chatUIFont = MinisTheme.assistantStrongUIFont

    init(
        message: ChatMessage,
        sourceMessage: ChatMessage? = nil,
        precedingUserMessage: ChatMessage? = nil,
        codeThemeMode: CodeThemeMode,
        apiKey: String,
        apiBaseURL: String,
        showsAssistantActionBar: Bool,
        onRegenerate: (() -> Void)?,
        onDelete: (() -> Void)? = nil
    ) {
        self.message = message
        self.sourceMessage = sourceMessage
        self.precedingUserMessage = precedingUserMessage
        self.codeThemeMode = codeThemeMode
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.showsAssistantActionBar = showsAssistantActionBar
        self.onRegenerate = onRegenerate
        self.onDelete = onDelete
    }

    private var actionMessage: ChatMessage {
        sourceMessage ?? message
    }

    private var triggeringUserPromptText: String {
        precedingUserMessage?.copyableText.lowercased() ?? ""
    }

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
            HTMLPreviewSheet(
                title: payload.title,
                html: payload.html,
                baseURL: payload.baseURL,
                entryFileURL: payload.entryFileURL
            )
        }
        .sheet(item: $activeImagePreview) { payload in
            ImagePreviewSheet(
                source: payload.source,
                apiKey: apiKey,
                apiBaseURL: apiBaseURL
            )
        }
        .sheet(item: $activeVideoPreview) { payload in
            VideoPreviewSheet(urlString: payload.urlString)
        }
        .sheet(item: $activeCodeViewer) { payload in
            CodeViewerSheet(
                payload: payload,
                codeThemeMode: codeThemeMode,
                onRunTerminalCommand: nil
            )
        }
        .sheet(item: $pendingPythonRun) { payload in
            pythonInputSheet(payload: payload)
        }
        .sheet(item: $activePPTPreview) { payload in
            OfficePreviewSheet(payload: payload)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $activeShareSheet) { payload in
            ShareSheet(activityItems: [payload.fileURL])
        }
        .task(id: actionMessage.id) {
            generatedExcelPayload = nil
            hasAutoTriggeredExcelGeneration = false
            if shouldAutoGenerateExcelCard {
                hasAutoTriggeredExcelGeneration = true
                generateExcelFile()
            }
        }
        .onDisappear {
            frontendBuildRequestID &+= 1
            isBuildingFrontendProject = false
            cancelAllPythonRuns()
            pptGenerationTask?.cancel()
            pptGenerationTask = nil
            wordGenerationTask?.cancel()
            wordGenerationTask = nil
            excelGenerationTask?.cancel()
            excelGenerationTask = nil
        }
    }

    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 9) {
            assistantIdentityHeader

            content

            if showsAssistantActionBar && frontendProgressPayload == nil {
                assistantActionBar
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantIdentityHeader: some View {
        HStack(spacing: 7) {
            assistantIdentityIcon

            Text("IEXA")
                .font(.system(size: 16.5, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantIdentityIcon: some View {
        IEXASparkleMark()
    }

    private var assistantActionBar: some View {
        HStack(spacing: 8) {
            iconActionButton(systemName: "doc.on.doc", accessibilityLabel: "复制") {
                UIPasteboard.general.string = actionMessage.copyableText
                feedback(.success, "已复制")
            }

            if canPlayAssistantReply {
                iconActionButton(
                    systemName: isPlayingAssistantReply ? "stop.fill" : "speaker.wave.2",
                    foregroundColor: isPlayingAssistantReply ? Color(red: 0.09, green: 0.43, blue: 0.88) : .secondary,
                    accessibilityLabel: isPlayingAssistantReply ? "停止朗读" : "朗读回复"
                ) {
                    toggleAssistantSpeechPlayback()
                }
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

            if let onDelete {
                iconActionButton(
                    systemName: "trash",
                    foregroundColor: .secondary,
                    accessibilityLabel: "删除这条回复"
                ) {
                    onDelete()
                    feedback(.light, "删除中…")
                }
            }

            if canGenerateFrontendProject {
                Menu {
                    Button("生成到新项目", systemImage: "folder.badge.plus") {
                        generateFrontendProject(mode: .createNewProject)
                    }
                    Button("覆盖更新 latest", systemImage: "arrow.triangle.2.circlepath") {
                        generateFrontendProject(mode: .overwriteLatestProject)
                    }
                } label: {
                    Image(systemName: "hammer")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MiniIconButtonStyle())
                .foregroundStyle(.secondary)
                .disabled(isBuildingFrontendProject)
            }

            if canGeneratePPT {
                iconActionButton(systemName: "doc.richtext", accessibilityLabel: "生成PPT") {
                    generatePPTFile()
                }
                .disabled(isGeneratingPPT)
            }

            Menu {
                Button("复制全部", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = actionMessage.copyableText
                    feedback(.success, "已复制")
                }
                if canPlayAssistantReply {
                    Button(
                        isPlayingAssistantReply ? "停止朗读" : "朗读回复",
                        systemImage: isPlayingAssistantReply ? "stop.fill" : "speaker.wave.2"
                    ) {
                        toggleAssistantSpeechPlayback()
                    }
                }
                if let onRegenerate {
                    Button("重试", systemImage: "arrow.clockwise") {
                        onRegenerate()
                        feedback(.light, "正在重试…")
                    }
                }
                if let onDelete {
                    Divider()
                    Button(role: .destructive) {
                        onDelete()
                        feedback(.light, "删除中…")
                    } label: {
                        Label("删除这条回复", systemImage: "trash")
                    }
                }
                if canGenerateFrontendProject {
                    Divider()
                    Button("生成到新项目", systemImage: "folder.badge.plus") {
                        generateFrontendProject(mode: .createNewProject)
                    }
                    Button("覆盖更新 latest", systemImage: "arrow.triangle.2.circlepath") {
                        generateFrontendProject(mode: .overwriteLatestProject)
                    }
                }
                if canGeneratePPT {
                    Divider()
                    Button("生成 PPT", systemImage: "doc.richtext") {
                        generatePPTFile()
                    }
                    if let generatedPPTPayload {
                        Button("查看 PPT", systemImage: "doc.text.magnifyingglass") {
                            previewPPTFile(generatedPPTPayload)
                        }
                        Button("分享 PPT", systemImage: "square.and.arrow.up") {
                            sharePPTFile(generatedPPTPayload)
                        }
                    }
                }
                if canGenerateWord {
                    Divider()
                    Button("生成 Word", systemImage: "doc.text") {
                        generateWordFile()
                    }
                    if let generatedWordPayload {
                        Button("查看 Word", systemImage: "doc.text.magnifyingglass") {
                            previewWordFile(generatedWordPayload)
                        }
                        Button("分享 Word", systemImage: "square.and.arrow.up") {
                            shareWordFile(generatedWordPayload)
                        }
                    }
                }
                if canGenerateExcel {
                    Divider()
                    Button("生成 Excel", systemImage: "tablecells") {
                        generateExcelFile()
                    }
                    if let generatedExcelPayload {
                        Button("查看 Excel", systemImage: "doc.text.magnifyingglass") {
                            previewExcelFile(generatedExcelPayload)
                        }
                        Button("分享 Excel", systemImage: "square.and.arrow.up") {
                            shareExcelFile(generatedExcelPayload)
                        }
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
            .disabled(isBuildingFrontendProject || isGeneratingPPT || isGeneratingWord || isGeneratingExcel)

            if let actionFeedback {
                Text(actionFeedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if isBuildingFrontendProject {
                Text("生成中…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if isGeneratingPPT {
                Text("PPT 生成中…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if isGeneratingWord {
                Text("Word 生成中…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if isGeneratingExcel {
                Text("Excel 生成中…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(MinisTheme.softPill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(MinisTheme.subtleStroke, lineWidth: 0.8)
        )
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
                .padding(.horizontal, 17)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(userBubbleColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.03), lineWidth: 0.8)
                )
                .frame(maxWidth: 306, alignment: .trailing)
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
                    .font(.system(size: 17, weight: .regular))
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
        if let payload = frontendProgressPayload {
            frontendProgressTimeline(payload)
        } else if message.isImageGenerationPlaceholder && message.imageAttachments.isEmpty {
            imageGenerationProgressCard
        } else if message.isVideoGenerationPlaceholder && message.videoAttachments.isEmpty {
            videoGenerationProgressContainer(streamingTextAnimated: false)
        } else if message.isStreaming {
            streamingContent
        } else {
            let segments = MessageContentParser.parse(message)

            if segments.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if let fallback = fallbackPlainText {
                        selectableTextContent(fallback)
                    } else {
                        Text("（空响应）")
                            .foregroundStyle(.secondary)
                    }
                    if shouldShowPPTCard {
                        pptGenerationCard
                    }
                    if shouldShowWordCard {
                        wordGenerationCard
                    }
                    if shouldShowExcelCard {
                        excelGenerationCard
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment, streamingTextAnimated: false)
                    }
                    if shouldShowPPTCard {
                        pptGenerationCard
                    }
                    if shouldShowWordCard {
                        wordGenerationCard
                    }
                    if shouldShowExcelCard {
                        excelGenerationCard
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var streamingContent: some View {
        if let payload = frontendProgressPayload {
            frontendProgressTimeline(payload)
        } else {
            let streamingSlice = streamingDisplaySlice(from: message.content)
            let displayText = streamingSlice.text
            if message.isImageGenerationPlaceholder && message.imageAttachments.isEmpty {
                imageGenerationProgressCard
            } else if message.isVideoGenerationPlaceholder && message.videoAttachments.isEmpty {
                videoGenerationProgressContainer(streamingTextAnimated: false)
            } else {
                let hasStreamingMedia = !message.imageAttachments.isEmpty || !message.videoAttachments.isEmpty
                let hasStreamingText = !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if !hasStreamingText && !hasStreamingMedia {
                    streamingWaitingDot
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if streamingSlice.isTruncated {
                            Text("长文本生成中，已仅渲染最新片段以保持流畅；完成后自动展示全文。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if hasStreamingText {
                            let segments = parsedStreamingSegments(for: displayText)
                            if segments.isEmpty {
                                assistantTextSegmentView(displayText, streamingTextAnimated: true)
                            } else {
                                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                    segmentView(segment, streamingTextAnimated: true)
                                }
                            }
                        }
                        ForEach(message.imageAttachments) { attachment in
                            messageImage(attachment)
                        }
                        ForEach(message.videoAttachments) { attachment in
                            messageVideo(attachment)
                        }
                    }
                }
            }
        }
    }

    private var streamingWaitingDot: some View {
        HStack(spacing: 4) {
            SweepShimmerText(
                "正在思考",
                font: .system(size: 17, weight: .semibold),
                baseColor: .secondary
            )

            ThinkingDotsWaveView(dotSize: 6, spacing: 4)
                .frame(width: 28, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("正在思考")
    }

    private var frontendProgressPayload: FrontendProgressPayload? {
        FrontendProgressPayload.parse(from: message.content)
    }

    private func frontendProgressTimeline(_ payload: FrontendProgressPayload) -> some View {
        let steps = frontendProgressSteps(for: payload)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: payload.isStreaming ? "hammer.fill" : "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(payload.isStreaming ? Color.cyan : Color.green)
                Text(payload.isStreaming ? "正在生成项目文件" : "项目文件已生成完成")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("文件 \(max(payload.fileCount, 1))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(MinisTheme.softPill)
                    )
            }

            ProgressView(value: frontendProgressValue(steps))
                .progressViewStyle(.linear)
                .tint(payload.isStreaming ? Color.cyan : Color.green)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { step in
                    frontendProgressStepRow(step: step, isStreaming: payload.isStreaming)
                }
            }

            if !payload.isStreaming {
                Button {
                    openLatestProjectPreviewFromProgress()
                } label: {
                    Label("预览入口页", systemImage: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(red: 0.08, green: 0.45, blue: 0.90))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            frontendProgressPulse = true
        }
        .onDisappear {
            frontendProgressPulse = false
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func frontendProgressStepRow(step: FrontendProgressStep, isStreaming: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                switch step.state {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                case .running:
                    if isStreaming {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    } else {
                        Image(systemName: "clock.badge.checkmark")
                    }
                case .pending:
                    Image(systemName: "circle.dashed")
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(step.iconColor)
            .scaleEffect(step.state == .running && isStreaming && frontendProgressPulse ? 1.05 : 1.0)
            .rotationEffect(.degrees(rotationDegrees(for: step, isStreaming: isStreaming)))
            .animation(
                shouldRotate(step: step, isStreaming: isStreaming)
                    ? .linear(duration: rotationDuration(for: step)).repeatForever(autoreverses: false)
                    : .easeOut(duration: 0.12),
                value: frontendProgressPulse
            )

            Text(step.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(step.trailing)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(step.trailingColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.62 : 0.86))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 0.8)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func frontendProgressSteps(for payload: FrontendProgressPayload) -> [FrontendProgressStep] {
        if payload.isStreaming {
            let stage: Int
            if payload.fileCount <= 0 {
                stage = 1
            } else if payload.fileCount <= 1 {
                stage = 2
            } else {
                stage = 3
            }
            return [
                FrontendProgressStep(
                    title: "解析文件结构",
                    state: stage >= 2 ? .completed : .running
                ),
                FrontendProgressStep(
                    title: "生成项目代码",
                    state: stage >= 3 ? .completed : (stage == 2 ? .running : .pending)
                ),
                FrontendProgressStep(
                    title: "写入 latest 项目目录",
                    state: stage == 3 ? .running : .pending
                ),
                FrontendProgressStep(
                    title: payload.hasEntry ? "准备入口预览" : "整理项目索引",
                    state: .pending
                )
            ]
        }

        return [
            FrontendProgressStep(title: "解析文件结构", state: .completed),
            FrontendProgressStep(title: "生成项目代码", state: .completed),
            FrontendProgressStep(title: "写入 latest 项目目录", state: .completed),
            FrontendProgressStep(
                title: payload.hasEntry ? "准备入口预览" : "整理项目索引",
                state: .completed
            )
        ]
    }

    private func frontendProgressValue(_ steps: [FrontendProgressStep]) -> Double {
        guard !steps.isEmpty else { return 0 }
        let completed = steps.filter { $0.state == .completed }.count
        let running = steps.contains { $0.state == .running } ? 0.5 : 0
        return min(1, (Double(completed) + running) / Double(steps.count))
    }

    private func shouldRotate(step: FrontendProgressStep, isStreaming: Bool) -> Bool {
        guard isStreaming else { return false }
        switch step.state {
        case .completed:
            return false
        case .running, .pending:
            return true
        }
    }

    private func rotationDuration(for step: FrontendProgressStep) -> Double {
        switch step.state {
        case .running:
            return 0.75
        case .pending:
            return 1.6
        case .completed:
            return 0.0
        }
    }

    private func rotationDegrees(for step: FrontendProgressStep, isStreaming: Bool) -> Double {
        guard shouldRotate(step: step, isStreaming: isStreaming) else { return 0 }
        return frontendProgressPulse ? 360 : 0
    }

    private func normalizedStreamingText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func streamingDisplaySlice(from raw: String) -> (text: String, isTruncated: Bool) {
        let normalized = normalizedStreamingText(raw)
        let isCodeLikePayload = normalized.contains("```") || normalized.contains("[[file:")
        let hardLimit = isCodeLikePayload ? 10_000 : 16_000
        let tailLimit = isCodeLikePayload ? 4_800 : 9_000
        guard normalized.count > hardLimit else {
            return (normalized, false)
        }

        let start = normalized.index(normalized.endIndex, offsetBy: -tailLimit)
        var tail = String(normalized[start...])
        if let firstBreak = tail.firstIndex(of: "\n"), firstBreak != tail.startIndex {
            tail = String(tail[firstBreak...])
        }
        return (tail, true)
    }

    private func parsedStreamingSegments(for displayText: String) -> [MessageSegment] {
        let streamingMessage = ChatMessage(
            id: message.id,
            role: message.role,
            content: displayText,
            createdAt: message.createdAt,
            isStreaming: true,
            isImageGenerationPlaceholder: message.isImageGenerationPlaceholder,
            isVideoGenerationPlaceholder: message.isVideoGenerationPlaceholder,
            imageAttachments: message.imageAttachments,
            videoAttachments: message.videoAttachments,
            fileAttachments: message.fileAttachments
        )
        return MessageContentParser.parse(streamingMessage)
    }

    private func shouldRenderStreamingTextDirectly(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        if !message.imageAttachments.isEmpty || !message.videoAttachments.isEmpty || !message.fileAttachments.isEmpty {
            return false
        }

        // Keep strict parsing for structural blocks.
        if text.contains("```") || text.contains("[[file:") { return false }
        if text.contains("|---") || text.contains("\n|") { return false }
        if text.contains("![](") || text.contains("data:image/") { return false }

        // For long streaming text, skip markdown parsing to reduce per-frame layout work.
        if text.count >= 2_400 { return true }

        if text.contains("**") || text.contains("__") || text.contains("`") { return false }
        if text.hasPrefix("#") || text.contains("\n#") { return false }
        if text.hasPrefix("- ") || text.contains("\n- ") { return false }
        if text.hasPrefix("* ") || text.contains("\n* ") { return false }
        if text.hasPrefix("> ") || text.contains("\n> ") { return false }
        return true
    }

    private var imageGenerationProgressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.animation(minimumInterval: 0.12, paused: false)) { timeline in
                ImageGenerationPlaceholderPattern(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: 300, height: 300, alignment: .center)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("生图中")
    }

    private var videoGenerationProgressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.animation(minimumInterval: 0.12, paused: false)) { timeline in
                ImageGenerationPlaceholderPattern(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: 300, height: 180, alignment: .center)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                    Text("视频生成中…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("生视频中")
    }

    private func videoGenerationProgressContainer(streamingTextAnimated: Bool) -> some View {
        let status = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            videoGenerationProgressCard
            if !status.isEmpty {
                selectableTextContent(status, streamingTextAnimated: streamingTextAnimated)
            }
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
                .font(.system(size: 17, weight: .semibold))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let language, let content):
            codeBlock(
                title: (language ?? "code").uppercased(),
                content: content,
                language: language,
                followsTailDuringStreaming: false
            )
        case .file(let name, let language, let content):
            fileSegmentView(
                name: name,
                language: language,
                content: content,
                followsTailDuringStreaming: false
            )
        case .table(let headers, let rows):
            markdownTableCard(headers: headers, rows: rows)
        case .image(let attachment):
            messageImage(attachment)
        case .video(let attachment):
            messageVideo(attachment)
        case .divider:
            sectionDivider
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageSegment, streamingTextAnimated: Bool) -> some View {
        switch segment {
        case .text(let text):
            assistantTextSegmentView(text, streamingTextAnimated: streamingTextAnimated)
        case .code(let language, let content):
            codeBlock(
                title: (language ?? "code").uppercased(),
                content: content,
                language: language,
                followsTailDuringStreaming: streamingTextAnimated
            )
        case .file(let name, let language, let content):
            fileSegmentView(
                name: name,
                language: language,
                content: content,
                followsTailDuringStreaming: streamingTextAnimated
            )
        case .table(let headers, let rows):
            markdownTableCard(headers: headers, rows: rows)
        case .image(let attachment):
            messageImage(attachment)
        case .video(let attachment):
            messageVideo(attachment)
        case .divider:
            sectionDivider
        }
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(Color.secondary.opacity(colorScheme == .dark ? 0.30 : 0.22))
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private func fileSegmentView(
        name: String,
        language: String?,
        content: String,
        followsTailDuringStreaming: Bool
    ) -> some View {
        let spreadsheetSheets = ExcelGenerationService.extractSheets(
            fromRawText: content,
            preferredName: (name as NSString).deletingPathExtension
        )

        if isSpreadsheetPreviewFile(name: name), let firstSheet = spreadsheetSheets.first {
            spreadsheetPreviewCard(fileName: name, sheet: firstSheet)
        } else {
            codeBlock(
                title: "FILE · \(name)",
                content: content,
                language: language,
                followsTailDuringStreaming: followsTailDuringStreaming
            )
        }
    }

    private func isSpreadsheetPreviewFile(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "xlsx" || ext == "xls" || ext == "csv" || ext == "tsv"
    }

    private func spreadsheetPreviewCard(fileName: String, sheet: ExcelGenerationService.Sheet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("表格")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    let lines = ([sheet.headers] + sheet.rows)
                        .map { $0.joined(separator: "\t") }
                        .joined(separator: "\n")
                    UIPasteboard.general.string = lines
                    feedback(.success, "已复制表格")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(fileName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            markdownTableCard(headers: sheet.headers, rows: sheet.rows)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MinisTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MinisTheme.subtleStroke, lineWidth: 1)
        )
    }

    private func markdownTableCard(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? headers.count)
        let normalizedHeaders = normalizeTableCells(headers, targetCount: columnCount)
        let normalizedRows = rows.map { normalizeTableCells($0, targetCount: columnCount) }

        return VStack(spacing: 0) {
            markdownTableRow(normalizedHeaders, isHeader: true, index: 0)

            ForEach(Array(normalizedRows.enumerated()), id: \.offset) { index, row in
                Divider()
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08))
                markdownTableRow(row, isHeader: false, index: index)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MinisTheme.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MinisTheme.subtleStroke, lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func markdownTableRow(_ cells: [String], isHeader: Bool, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell.isEmpty ? " " : cell)
                    .font(.system(size: isHeader ? 15.5 : 15, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineSpacing(2.6)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isHeader ? 11 : 10)
        .background(tableRowBackground(isHeader: isHeader, rowIndex: index))
    }

    private func tableRowBackground(isHeader: Bool, rowIndex: Int) -> Color {
        if isHeader {
            return colorScheme == .dark
                ? Color.white.opacity(0.06)
                : Color.black.opacity(0.04)
        }

        if rowIndex % 2 == 0 {
            return colorScheme == .dark
                ? Color.white.opacity(0.03)
                : Color.black.opacity(0.015)
        }
        return .clear
    }

    private func normalizeTableCells(_ cells: [String], targetCount: Int) -> [String] {
        guard targetCount > 0 else { return [] }
        if cells.count == targetCount { return cells }
        if cells.count > targetCount { return Array(cells.prefix(targetCount)) }
        return cells + Array(repeating: "", count: targetCount - cells.count)
    }

    private enum AssistantStepStatus {
        case neutral
        case running
        case success
        case error
    }

    private enum AssistantStepKind {
        case command
        case file
        case memory
        case generic
    }

    private enum AssistantTextBlock: Equatable {
        case plain(String)
        case step(
            title: String,
            duration: String?,
            status: AssistantStepStatus,
            kind: AssistantStepKind
        )
    }

    @ViewBuilder
    private func assistantTextSegmentView(_ text: String, streamingTextAnimated: Bool) -> some View {
        let blocks = assistantTextBlocks(from: text, streamingTextAnimated: streamingTextAnimated)
        if blocks.count == 1, case .plain(let only)? = blocks.first {
            selectableTextContent(only, streamingTextAnimated: streamingTextAnimated)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .plain(let plain):
                        selectableTextContent(plain, streamingTextAnimated: streamingTextAnimated)
                    case .step(let title, let duration, let status, let kind):
                        assistantStepChip(title: title, duration: duration, status: status, kind: kind)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func assistantTextBlocks(from text: String, streamingTextAnimated: Bool) -> [AssistantTextBlock] {
        guard message.role == .assistant else {
            return [.plain(text)]
        }
        // Avoid expensive per-line step parsing for very long responses.
        if text.count > 9_000 {
            return [.plain(text)]
        }

        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return [.plain(text)] }

        var output: [AssistantTextBlock] = []
        var plainBuffer: [String] = []

        func flushPlainBuffer() {
            guard !plainBuffer.isEmpty else { return }
            let plain = plainBuffer.joined(separator: "\n")
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(.plain(plain))
            }
            plainBuffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parseAssistantStepLine(trimmed) {
                flushPlainBuffer()
                output.append(
                    .step(
                        title: parsed.title,
                        duration: parsed.duration,
                        status: parsed.status,
                        kind: parsed.kind
                    )
                )
            } else {
                plainBuffer.append(line)
            }
        }

        flushPlainBuffer()
        return output.isEmpty ? [.plain(text)] : output
    }

    private func parseAssistantStepLine(
        _ line: String
    ) -> (title: String, duration: String?, status: AssistantStepStatus, kind: AssistantStepKind)? {
        guard !line.isEmpty else { return nil }

        let duration: String? = {
            guard let range = line.range(
                of: #"\s\(?([0-9]+(?:\.[0-9]+)?(?:ms|s|m))\)?$"#,
                options: .regularExpression
            ) else {
                return nil
            }
            let value = line[range]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            return value.isEmpty ? nil : value
        }()

        var title = line
        if let duration {
            title = line.replacingOccurrences(of: duration, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let normalizedTitle = title
            .replacingOccurrences(of: #"^[✅✔☑️🟢🔴🟡❌⚠️•·\-\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return nil }

        let lowered = normalizedTitle.lowercased()
        let prefixMarkers = [
            "已运行", "运行", "执行", "已执行",
            "构建", "编译", "测试", "检查", "安装",
            "写入", "读取", "查看", "编辑", "修改",
            "创建", "生成", "回忆", "记录",
            "正在", "处理中", "引导对话", "已处理", "已编辑"
        ]
        let keywordMarkers = [
            "shell", "terminal", "cmake", "g++", "clang", "ctest", "cargo", "npm", "pnpm", "pip", "gradle", "maven",
            "脚本", "依赖", "result", "命令", "源码", "文件", "memory", "readme", "main",
            "编译", "构建", "测试", "运行", "写入", "读取", "查看", "编辑", "修改", "回忆", "记录", "改为"
        ]
        let hasPrefixMarker = prefixMarkers.contains(where: { lowered.hasPrefix($0) })
        let hasKeywordMarker = keywordMarkers.contains(where: { lowered.contains($0) })
        let hasStepBulletPrefix = line.range(
            of: #"^(?:[-*•·]|[0-9]+[.)、])\s+"#,
            options: .regularExpression
        ) != nil
        let hasExplicitStepEmoji = line.contains("✅")
            || line.contains("✔")
            || line.contains("❌")
            || line.contains("⚠️")
        let hasCommandPrefix = normalizedTitle.hasPrefix("$ ") || normalizedTitle.hasPrefix("> ")
        let looksLikeToolIdentifier = normalizedTitle.range(
            of: #"^(memory_(get|save|write)|browser|shell|terminal|read|write|exec|edit|command)$"#,
            options: .regularExpression
        ) != nil
        let looksLikeStep = duration != nil
            || hasPrefixMarker
            || hasExplicitStepEmoji
            || hasCommandPrefix
            || looksLikeToolIdentifier
            || (hasStepBulletPrefix && hasKeywordMarker && normalizedTitle.count <= 80)
        guard looksLikeStep else { return nil }
        if isLikelyConversationalAssistantLine(normalizedTitle),
           duration == nil,
           !hasPrefixMarker,
           !hasExplicitStepEmoji,
           !hasCommandPrefix {
            return nil
        }

        let status: AssistantStepStatus = {
            if normalizedTitle.contains("失败")
                || normalizedTitle.contains("错误")
                || lowered.contains("error")
                || lowered.contains("failed")
                || lowered.contains("exit code")
                || line.contains("❌") {
                return .error
            }
            if normalizedTitle.contains("正在")
                || normalizedTitle.contains("处理中")
                || lowered.contains("running")
                || lowered.contains("in progress")
                || lowered.contains("reconnecting")
                || normalizedTitle.contains("重试")
                || normalizedTitle.contains("等待") {
                return .running
            }
            if normalizedTitle.contains("完成")
                || normalizedTitle.contains("成功")
                || line.contains("✅")
                || line.contains("✔")
                || lowered.hasPrefix("已")
                || lowered.contains("done") {
                return .success
            }
            return .neutral
        }()

        let kind: AssistantStepKind = {
            if lowered.contains("回忆") || lowered.contains("memory") {
                return .memory
            }

            if lowered.contains("运行")
                || lowered.contains("执行")
                || lowered.contains("构建")
                || lowered.contains("编译")
                || lowered.contains("测试")
                || lowered.contains("安装")
                || lowered.contains("命令")
                || lowered.contains("shell")
                || lowered.contains("terminal")
                || lowered.contains("cmake")
                || lowered.contains("g++")
                || lowered.contains("clang")
                || lowered.contains("cargo")
                || lowered.contains("ctest")
                || lowered.contains("npm")
                || lowered.contains("pip")
                || lowered.contains("gradle")
                || lowered.contains("maven") {
                return .command
            }

            if lowered.contains("写入")
                || lowered.contains("读取")
                || lowered.contains("查看")
                || lowered.contains("编辑")
                || lowered.contains("修改")
                || lowered.contains("文件")
                || lowered.contains("源码")
                || lowered.contains("配置")
                || lowered.contains("文档") {
                return .file
            }

            return .generic
        }()

        return (normalizedTitle, duration, status, kind)
    }

    private func isLikelyConversationalAssistantLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }

        let lowered = trimmed.lowercased()
        let hasConversationalPunctuation =
            trimmed.contains("。")
            || trimmed.contains("？")
            || trimmed.contains("?")
            || trimmed.contains("！")
            || trimmed.contains("!")
            || trimmed.contains("，")
        guard hasConversationalPunctuation else { return false }

        let executionMarkers = [
            "运行", "执行", "构建", "编译", "测试", "安装",
            "写入", "读取", "查看", "编辑", "修改",
            "命令", "shell", "terminal", "cmake", "cargo", "npm", "pip", "gradle", "maven",
            "src/", "dist/", "readme", "file", "[[file:"
        ]
        if executionMarkers.contains(where: { lowered.contains($0) }) {
            return false
        }

        if trimmed.range(
            of: #"([A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        return true
    }

    private func assistantStepChip(
        title: String,
        duration: String?,
        status: AssistantStepStatus,
        kind: AssistantStepKind
    ) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(stepIconBadgeFill(kind: kind, status: status))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: stepIconName(for: title, kind: kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(stepIconColor(kind: kind, status: status))
                )
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let duration, !duration.isEmpty {
                Text(duration)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MinisTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(stepBorderColor(status), lineWidth: 0.9)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: Color.black.opacity(0.035), radius: 10, x: 0, y: 4)
    }

    private func stepIconName(for title: String, kind: AssistantStepKind) -> String {
        let lowered = title.lowercased()
        switch kind {
        case .memory:
            return "brain.head.profile"
        case .command:
            return "terminal"
        case .file:
            if lowered.contains("查看") || lowered.contains("读取") {
                return "doc.text.magnifyingglass"
            }
            if lowered.contains("编辑") || lowered.contains("修改") {
                return "square.and.pencil"
            }
            return "doc.fill"
        case .generic:
            break
        }

        if lowered.contains("安装") || lowered.contains("apk") || lowered.contains("pip") {
            return "terminal.fill"
        }
        if lowered.contains("运行") || lowered.contains("执行") {
            return "play.fill"
        }
        if lowered.contains("查看") || lowered.contains("检查") {
            return "doc.text.magnifyingglass"
        }
        if lowered.contains("写入") || lowered.contains("保存") {
            return "square.and.arrow.down.fill"
        }
        return "doc.fill"
    }

    private func stepIconColor(kind: AssistantStepKind, status: AssistantStepStatus) -> Color {
        if status == .error {
            return Color.red
        }
        if status == .running {
            return MinisTheme.accentOrange
        }
        switch kind {
        case .command:
            return MinisTheme.accentBlue
        case .file, .memory, .generic:
            return MinisTheme.accentGreen
        }
    }

    private func stepIconBadgeFill(kind: AssistantStepKind, status: AssistantStepStatus) -> Color {
        let base: Color
        switch kind {
        case .command:
            base = MinisTheme.accentBlue
        case .file, .memory, .generic:
            base = MinisTheme.accentGreen
        }
        if status == .error {
            return Color.red.opacity(0.12)
        }
        if status == .running {
            return MinisTheme.accentOrange.opacity(0.16)
        }
        return base.opacity(0.12)
    }

    private func stepBorderColor(_ status: AssistantStepStatus) -> Color {
        switch status {
        case .neutral:
            return MinisTheme.subtleStroke
        case .running:
            return MinisTheme.accentOrange.opacity(0.42)
        case .success:
            return MinisTheme.accentGreen.opacity(0.34)
        case .error:
            return Color.red.opacity(0.42)
        }
    }

    private func selectableTextContent(_ text: String, streamingTextAnimated: Bool = false) -> some View {
        let displayText = text
        return SelectableLinkTextView(
            text: displayText,
            textColor: UIColor.label,
            linkColor: MinisTheme.accentBlueUIColor,
            font: chatUIFont,
            renderMarkdown: false,
            streamingAnimated: message.isStreaming || streamingTextAnimated,
            onFileLinkTap: { path in
                openCodeViewerForLinkedPath(path)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func decoratedAssistantListText(_ text: String) -> String {
        guard message.role == .assistant, !text.isEmpty else { return text }

        let normalizedReadableText = readableAssistantNarration(text)

        let lines = normalizedReadableText.components(separatedBy: "\n")
        guard !lines.isEmpty else { return text }

        var output: [String] = []
        output.reserveCapacity(lines.count)

        for (_, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(line)
                continue
            }

            let leading = String(line.prefix { $0 == " " || $0 == "\t" })
            let trimmedStart = String(line.dropFirst(leading.count))
            if isLikelyFileTreeLine(trimmedStart) {
                output.append(line)
                continue
            }

            if let markerRange = trimmedStart.range(
                of: #"^\d+\s*[)\.、:：]\s+"#,
                options: .regularExpression
            ) {
                let marker = String(trimmedStart[markerRange])
                let number = Int(marker.prefix { $0.isNumber }) ?? 0
                let remainder = trimmedStart[markerRange.upperBound...]
                output.append("\(leading)\(max(1, number)). \(remainder)")
                continue
            }

            if let markerRange = trimmedStart.range(
                of: #"^[•●▪︎◦\-*]\s+"#,
                options: .regularExpression
            ) {
                let remainder = trimmedStart[markerRange.upperBound...]
                output.append("\(leading)• \(remainder)")
                continue
            }

            output.append(line)
        }

        return output.joined(separator: "\n")
    }

    private func readableAssistantNarration(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count >= 120 else { return text }
        guard !normalized.contains("\n\n") else { return text }
        guard !normalized.contains("```"), !normalized.contains("[[file:") else { return text }

        if normalized.range(of: #"(?m)^\s*(?:[-*•]|\d+\.)\s+"#, options: .regularExpression) != nil {
            return text
        }

        let sentences = splitAssistantSentences(normalized)
        guard sentences.count >= 3 else { return text }

        let processMarkers = [
            "我先", "先看", "先确认", "然后", "接着", "再", "接下来",
            "我会", "我再", "我直接", "我现在", "确认一下", "创建", "写入", "搭一个"
        ]
        let processSentenceCount = sentences.reduce(into: 0) { count, sentence in
            if processMarkers.contains(where: { sentence.contains($0) }) {
                count += 1
            }
        }

        if processSentenceCount >= 2 {
            return sentences.enumerated().map { index, sentence in
                "\(index + 1). \(sentence)"
            }
            .joined(separator: "\n")
        }

        var paragraphs: [String] = []
        var buffer: [String] = []
        var bufferLength = 0

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            paragraphs.append(buffer.joined())
            buffer.removeAll(keepingCapacity: true)
            bufferLength = 0
        }

        for sentence in sentences {
            let candidateLength = bufferLength + sentence.count
            if !buffer.isEmpty && candidateLength > 44 {
                flushBuffer()
            }
            buffer.append(sentence)
            bufferLength += sentence.count
        }
        flushBuffer()

        if paragraphs.count >= 2 {
            return paragraphs.joined(separator: "\n\n")
        }

        return text
    }

    private func splitAssistantSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if "。！？；!?;".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            sentences.append(trailing)
        }

        return sentences
    }

    private func isLikelyFileTreeLine(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        if line.contains("├") || line.contains("└") || line.contains("│") {
            return true
        }
        if line.contains("[[file:") || line.contains("[[endfile]]") {
            return true
        }
        if line.range(of: #"^[A-Za-z0-9._/\-]+\s*/$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func codeBlock(
        title: String,
        content: String,
        language: String? = nil,
        followsTailDuringStreaming: Bool = false
    ) -> some View {
        let actionContent = resolvedCodeActionContent(
            title: title,
            language: language,
            displayContent: content
        )
        let shouldAutoFollowTail = followsTailDuringStreaming && message.isStreaming
        // Highlight during streaming for immediate readability.
        // For very long code, degrade gracefully to plain text to avoid heavy per-tick regex cost.
        let disableSyntaxHighlighting = followsTailDuringStreaming && message.isStreaming && content.count > 12_000
        let codeViewportHeight: CGFloat = 286
        let codeViewportInnerMaxHeight = codeViewportHeight - 20
        let shouldShowScrollHint = estimatedCodeLineCount(content) >= 14 || content.count >= 520
        let copyToken = "\(title)|\(language ?? "")|\(actionContent)"
        let isCopied = copiedCodeToken == copyToken
        let isRunning = runningCodeToken == copyToken
        let canRunPython = supportsPythonRun(language: language, title: title)
            && PythonExecutionService.isRunnableSnippet(actionContent)
        let canRunHTML = supportsHTMLPreview(language: language, title: title, content: actionContent)
        let runOutput = codeRunOutputs[copyToken]
        let runError = codeRunErrors[copyToken]
        let isStandaloneSnippet = !title.hasPrefix("FILE ·")
        let badgeTitle = codeBlockBadgeTitle(title: title, language: language)
        let topChromeHeight: CGFloat = isStandaloneSnippet ? 30 : 0
        let codeViewportContentHeight = codeViewportInnerMaxHeight - topChromeHeight

        return VStack(alignment: .leading, spacing: 10) {
            if !isStandaloneSnippet {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.68))
                    Spacer()
                    if canRunPython {
                        Button {
                            if isRunning {
                                stopPythonRun(token: copyToken)
                            } else {
                                requestPythonRun(actionContent, token: copyToken)
                            }
                        } label: {
                            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(MiniIconButtonStyle())
                        .accessibilityLabel(isRunning ? "停止 Python 运行" : "运行 Python")
                    }
                    if canRunHTML {
                        Button {
                            openHTMLPreview(title: title, content: actionContent)
                        } label: {
                            Image(systemName: "globe")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(MiniIconButtonStyle())
                        .accessibilityLabel("打开网页预览")
                    }
                    Button {
                        openCodeViewer(
                            title: title,
                            language: language,
                            displayContent: content
                        )
                    } label: {
                        Image(systemName: "doc.text")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(MiniIconButtonStyle())
                    .disabled(actionContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    copyCodeButton(copyToken: copyToken, actionContent: actionContent, isCopied: isCopied)
                }
                .padding(.horizontal, 2)
            }

            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(codeViewportBackgroundColor)

                SelectableCodeTextView(
                    text: content,
                    textColor: codePrimaryTextColor,
                    font: MinisTheme.codeUIFont,
                    lineSpacing: 3.5,
                    language: language,
                    codeThemeMode: codeThemeMode,
                    isDarkMode: colorScheme == .dark,
                    isScrollEnabled: true,
                    maximumHeight: codeViewportContentHeight,
                    autoFollowTail: shouldAutoFollowTail,
                    disableSyntaxHighlighting: disableSyntaxHighlighting
                )
                .frame(maxWidth: .infinity, maxHeight: codeViewportContentHeight, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.top, 10 + topChromeHeight)
                .padding(.bottom, 10)

                if isStandaloneSnippet {
                    HStack(alignment: .center, spacing: 8) {
                        Text(badgeTitle)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.39, green: 0.93, blue: 0.62))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.08))
                            )

                        Spacer(minLength: 0)

                        if canRunPython {
                            Button {
                                if isRunning {
                                    stopPythonRun(token: copyToken)
                                } else {
                                    requestPythonRun(actionContent, token: copyToken)
                                }
                            } label: {
                                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.92))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(MiniIconButtonStyle())
                        } else if canRunHTML {
                            Button {
                                openHTMLPreview(title: title, content: actionContent)
                            } label: {
                                Image(systemName: "globe")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.92))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(MiniIconButtonStyle())
                        }

                        copyCodeButton(copyToken: copyToken, actionContent: actionContent, isCopied: isCopied)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if shouldShowScrollHint {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text("上下拖动")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(MinisTheme.elevatedBackground.opacity(colorScheme == .dark ? 0.92 : 0.96))
                    )
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10), lineWidth: 0.8)
            )
            .frame(maxWidth: .infinity, maxHeight: codeViewportHeight, alignment: .topLeading)

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("正在运行 Python…")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.72))
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
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
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
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.22, green: 0.06, blue: 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.28), lineWidth: 0.8)
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(codeBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(codeCardBorderColor, lineWidth: 1)
        )
    }

    private func copyCodeButton(
        copyToken: String,
        actionContent: String,
        isCopied: Bool
    ) -> some View {
        Button {
            UIPasteboard.general.string = actionContent
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
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isCopied ? MinisTheme.accentGreen : Color.white.opacity(0.92))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(MiniIconButtonStyle())
        .animation(.easeInOut(duration: 0.16), value: isCopied)
    }

    private func codeBlockBadgeTitle(title: String, language: String?) -> String {
        if let language {
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.lowercased()
            }
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func openCodeViewer(
        title: String,
        language: String?,
        displayContent: String
    ) {
        let selectedContent = resolvedCodeActionContent(
            title: title,
            language: language,
            displayContent: displayContent
        )
        let entries = buildCodeViewerEntries(
            fallbackTitle: title,
            fallbackLanguage: language,
            fallbackContent: selectedContent
        )
        guard !entries.isEmpty else {
            feedback(.light, "当前代码为空")
            return
        }

        let initialIndex = codeViewerInitialIndex(
            entries: entries,
            title: title,
            language: language,
            selectedContent: selectedContent
        )
        activeCodeViewer = CodeViewerPayload(
            title: "代码查看",
            entries: entries,
            initialIndex: initialIndex,
            preferredTerminalCommand: nil
        )
    }

    private func openCodeViewerForLinkedPath(_ rawPath: String) {
        let normalizedPath = rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return }

        let entries = buildCodeViewerEntries(
            fallbackTitle: "代码",
            fallbackLanguage: nil,
            fallbackContent: ""
        )
        guard !entries.isEmpty else {
            feedback(.light, "当前没有可查看的项目代码")
            return
        }

        let loweredTarget = normalizedPath.lowercased()
        let index = entries.firstIndex(where: { entry in
            let loweredName = entry.name
                .replacingOccurrences(of: "\\", with: "/")
                .lowercased()
            return loweredName == loweredTarget
                || loweredName.hasSuffix("/\(loweredTarget)")
                || loweredTarget.hasSuffix("/\(loweredName)")
        }) ?? 0

        activeCodeViewer = CodeViewerPayload(
            title: "项目代码",
            entries: entries,
            initialIndex: index,
            preferredTerminalCommand: nil
        )

        if index == 0,
           entries.first?.name.caseInsensitiveCompare(normalizedPath) != .orderedSame {
            feedback(.light, "未找到 \(normalizedPath)，已打开项目代码列表")
        }
    }

    private func buildCodeViewerEntries(
        fallbackTitle: String,
        fallbackLanguage: String?,
        fallbackContent: String
    ) -> [CodeViewerEntry] {
        var entries: [CodeViewerEntry] = []
        var snippetIndex = 1

        for segment in actionMessageStructuredSegments() {
            switch segment {
            case .file(let name, let language, let content):
                let normalized = normalizedCodeViewerContent(content)
                guard !normalized.isEmpty else { continue }
                entries.append(
                    CodeViewerEntry(
                        name: name,
                        language: language,
                        content: normalized
                    )
                )
            case .code(let language, let content):
                let normalized = normalizedCodeViewerContent(content)
                guard !normalized.isEmpty else { continue }
                entries.append(
                    CodeViewerEntry(
                        name: inferredSnippetFileName(language: language, index: snippetIndex),
                        language: language,
                        content: normalized
                    )
                )
                snippetIndex += 1
            default:
                continue
            }
        }

        let deduped = deduplicatedCodeViewerEntries(entries)
        if !deduped.isEmpty {
            return deduped
        }

        let normalizedFallback = normalizedCodeViewerContent(fallbackContent)
        guard !normalizedFallback.isEmpty else { return [] }
        return [
            CodeViewerEntry(
                name: codeViewerEntryName(
                    fallbackTitle: fallbackTitle,
                    fallbackLanguage: fallbackLanguage
                ),
                language: fallbackLanguage,
                content: normalizedFallback
            )
        ]
    }

    private func deduplicatedCodeViewerEntries(_ entries: [CodeViewerEntry]) -> [CodeViewerEntry] {
        var seen = Set<String>()
        var deduped: [CodeViewerEntry] = []

        for entry in entries {
            let key = "\(entry.name.lowercased())|\((entry.language ?? "").lowercased())|\(entry.content)"
            if seen.insert(key).inserted {
                deduped.append(entry)
            }
        }
        return deduped
    }

    private func codeViewerEntryName(
        fallbackTitle: String,
        fallbackLanguage: String?
    ) -> String {
        if let fileName = fileName(fromCodeTitle: fallbackTitle) {
            return fileName
        }

        let cleanedTitle = fallbackTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "FILE · ", with: "")
        if !cleanedTitle.isEmpty {
            return cleanedTitle.lowercased() == "code"
                ? inferredSnippetFileName(language: fallbackLanguage, index: 1)
                : cleanedTitle
        }

        return inferredSnippetFileName(language: fallbackLanguage, index: 1)
    }

    private func inferredSnippetFileName(language: String?, index: Int) -> String {
        let baseName = "snippet-\(index)"
        let normalizedLanguage = (language ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let ext = snippetFileExtension(for: normalizedLanguage) else {
            return baseName
        }
        return "\(baseName).\(ext)"
    }

    private func snippetFileExtension(for normalizedLanguage: String) -> String? {
        switch normalizedLanguage {
        case "swift":
            return "swift"
        case "python", "py":
            return "py"
        case "javascript", "js":
            return "js"
        case "typescript", "ts":
            return "ts"
        case "html", "htm", "xhtml":
            return "html"
        case "css":
            return "css"
        case "json":
            return "json"
        case "yaml", "yml":
            return "yml"
        case "xml":
            return "xml"
        case "java":
            return "java"
        case "kotlin":
            return "kt"
        case "go", "golang":
            return "go"
        case "rust", "rs":
            return "rs"
        case "c":
            return "c"
        case "cpp", "c++", "cxx":
            return "cpp"
        case "csharp", "c#", "cs":
            return "cs"
        case "php":
            return "php"
        case "ruby", "rb":
            return "rb"
        case "bash", "shell", "sh":
            return "sh"
        case "sql":
            return "sql"
        case "markdown", "md":
            return "md"
        default:
            return nil
        }
    }

    private func codeViewerInitialIndex(
        entries: [CodeViewerEntry],
        title: String,
        language: String?,
        selectedContent: String
    ) -> Int {
        guard !entries.isEmpty else { return 0 }

        if let fileName = fileName(fromCodeTitle: title),
           let index = entries.firstIndex(where: {
               $0.name.caseInsensitiveCompare(fileName) == .orderedSame
           }) {
            return index
        }

        if let index = entries.firstIndex(where: { $0.content == selectedContent }) {
            return index
        }

        let normalizedLanguage = (language ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !normalizedLanguage.isEmpty,
           let index = entries.firstIndex(where: {
               ($0.language ?? "")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
                   .lowercased() == normalizedLanguage
           }) {
            return index
        }

        let prefix = String(selectedContent.prefix(180))
        if !prefix.isEmpty,
           let index = entries.firstIndex(where: {
               $0.content.hasPrefix(prefix)
           }) {
            return index
        }

        return 0
    }

    private func estimatedCodeLineCount(_ text: String) -> Int {
        if text.isEmpty {
            return 0
        }
        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
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
            runningCodeToken = token
            codeRunErrors[token] = nil
            codeRunOutputs[token] = nil
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
        if pendingPythonRun?.token == token {
            pendingPythonRun = nil
        }
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
        InteractivePythonSessionSheet(
            payload: payload,
            onClose: { snapshot, wasStopped in
                if let snapshot {
                    let rendered = snapshot.exitCode == 0
                        ? snapshot.output
                        : "\(snapshot.output)\n\n[退出码 \(snapshot.exitCode ?? 1)]"
                    if snapshot.exitCode == 0 {
                        codeRunOutputs[payload.token] = rendered
                        codeRunErrors[payload.token] = nil
                    } else {
                        codeRunOutputs[payload.token] = nil
                        codeRunErrors[payload.token] = rendered
                    }
                    if !wasStopped && snapshot.exitCode == 0 {
                        feedback(.success, "代码运行完成")
                    } else {
                        feedback(.light, wasStopped ? "已结束运行" : "代码运行失败")
                    }
                } else if wasStopped {
                    codeRunErrors[payload.token] = "运行已结束。"
                    feedback(.light, "已结束运行")
                }

                if pendingPythonRun?.id == payload.id {
                    pendingPythonRun = nil
                }
                if runningCodeToken == payload.token {
                    runningCodeToken = nil
                }
            }
        )
    }

    private var canGenerateFrontendProject: Bool {
        actionMessage.role == .assistant && FrontendProjectBuilder.canGenerateProject(from: actionMessage)
    }

    private var canGeneratePPT: Bool {
        guard actionMessage.role == .assistant else { return false }
        guard !actionMessage.isStreaming else { return false }
        guard !actionMessage.isImageGenerationPlaceholder, !actionMessage.isVideoGenerationPlaceholder else { return false }
        return PPTGenerationService.canGenerate(from: actionMessage)
    }

    private var shouldShowPPTCard: Bool {
        generatedPPTPayload != nil
    }

    private var canGenerateWord: Bool {
        guard actionMessage.role == .assistant else { return false }
        guard !actionMessage.isStreaming else { return false }
        guard !actionMessage.isImageGenerationPlaceholder, !actionMessage.isVideoGenerationPlaceholder else { return false }
        return WordGenerationService.canGenerate(from: actionMessage)
    }

    private var shouldShowWordCard: Bool {
        generatedWordPayload != nil
    }

    private var canGenerateExcel: Bool {
        guard actionMessage.role == .assistant else { return false }
        guard !actionMessage.isStreaming else { return false }
        guard !actionMessage.isImageGenerationPlaceholder, !actionMessage.isVideoGenerationPlaceholder else { return false }
        return ExcelGenerationService.canGenerate(from: actionMessage)
    }

    private var shouldOfferExcelGeneration: Bool {
        guard canGenerateExcel else { return false }
        let normalized = triggeringUserPromptText
        guard !normalized.isEmpty else { return false }
        return normalized.contains("excel")
            || normalized.contains("xlsx")
            || normalized.contains("csv")
            || normalized.contains("tsv")
            || normalized.contains("表格")
            || normalized.contains("sheet")
            || normalized.contains("工作表")
    }

    private var shouldShowExcelCard: Bool {
        shouldOfferExcelGeneration
    }

    private var shouldAutoGenerateExcelCard: Bool {
        guard shouldOfferExcelGeneration else { return false }
        guard generatedExcelPayload == nil else { return false }
        guard !isGeneratingExcel else { return false }
        guard !hasAutoTriggeredExcelGeneration else { return false }

        let normalized = actionMessage.copyableText.lowercased()
        return normalized.contains("excel")
            || normalized.contains("xlsx")
            || normalized.contains("表格")
            || normalized.contains("工资")
            || normalized.contains("sheet")
    }

    private var pptGenerationCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.blue)
                Text("PPT 文件")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            if let generatedPPTPayload {
                officeDocumentFileCard(
                    iconSystemName: "doc.richtext.fill",
                    accentColor: Color(red: 0.89, green: 0.39, blue: 0.22),
                    fileURL: generatedPPTPayload.fileURL,
                    metaText: "生成于 \(generatedTimestampText(generatedPPTPayload.generatedAt)) · \(fileSizeText(for: generatedPPTPayload.fileURL))",
                    primaryLabel: "查看",
                    secondaryLabel: "下载",
                    primaryAction: { previewPPTFile(generatedPPTPayload) },
                    secondaryAction: { sharePPTFile(generatedPPTPayload) }
                )
            } else {
                Text("根据当前回复自动生成 .pptx 文件，并支持查看与分享。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(isGeneratingPPT ? "PPT 生成中…" : "生成 PPT") {
                    generatePPTFile()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.08, green: 0.36, blue: 0.86))
                .font(.caption2)
                .disabled(isGeneratingPPT || !canGeneratePPT)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MinisTheme.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MinisTheme.subtleStroke, lineWidth: 0.8)
        )
    }

    private var wordGenerationCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.green)
                Text("Word 文档")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            if let generatedWordPayload {
                officeDocumentFileCard(
                    iconSystemName: "doc.text.fill",
                    accentColor: Color(red: 0.15, green: 0.43, blue: 0.90),
                    fileURL: generatedWordPayload.fileURL,
                    metaText: "生成于 \(generatedTimestampText(generatedWordPayload.generatedAt)) · \(fileSizeText(for: generatedWordPayload.fileURL))",
                    primaryLabel: "查看",
                    secondaryLabel: "下载",
                    primaryAction: { previewWordFile(generatedWordPayload) },
                    secondaryAction: { shareWordFile(generatedWordPayload) }
                )
            } else {
                Text("根据当前回复自动生成 .docx 文档，并支持查看与分享。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(isGeneratingWord ? "Word 生成中…" : "生成 Word") {
                    generateWordFile()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.52, blue: 0.32))
                .font(.caption2)
                .disabled(isGeneratingWord || !canGenerateWord)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MinisTheme.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MinisTheme.subtleStroke, lineWidth: 0.8)
        )
    }

    private var excelGenerationCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.teal)
                Text("Excel 表格")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            if let generatedExcelPayload {
                if let firstSheet = generatedExcelPayload.sheets.first {
                    spreadsheetPreviewCard(fileName: firstSheet.name, sheet: firstSheet)
                }
                officeDocumentFileCard(
                    iconSystemName: "tablecells.fill",
                    accentColor: Color(red: 0.14, green: 0.60, blue: 0.36),
                    fileURL: generatedExcelPayload.fileURL,
                    metaText: "生成于 \(generatedTimestampText(generatedExcelPayload.generatedAt)) · \(fileSizeText(for: generatedExcelPayload.fileURL))",
                    primaryLabel: "查看",
                    secondaryLabel: "下载",
                    primaryAction: { previewExcelFile(generatedExcelPayload) },
                    secondaryAction: { shareExcelFile(generatedExcelPayload) }
                )
            } else {
                Text("优先提取回复中的表格（Markdown/CSV/TSV）生成 .xlsx，并支持查看与分享。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(isGeneratingExcel ? "Excel 生成中…" : "生成 Excel") {
                    generateExcelFile()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.08, green: 0.52, blue: 0.58))
                .font(.caption2)
                .disabled(isGeneratingExcel || !shouldOfferExcelGeneration)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MinisTheme.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MinisTheme.subtleStroke, lineWidth: 0.8)
        )
    }

    private func officeDocumentFileCard(
        iconSystemName: String,
        accentColor: Color,
        fileURL: URL,
        metaText: String,
        primaryLabel: String,
        secondaryLabel: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accentColor.opacity(0.14))
                    Image(systemName: iconSystemName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 5) {
                    Text(fileURL.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(metaText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                officeFileActionButton(title: primaryLabel, systemImage: "doc.text.magnifyingglass", action: primaryAction)
                Divider()
                    .frame(height: 24)
                officeFileActionButton(title: secondaryLabel, systemImage: "arrow.down.to.line", action: secondaryAction)
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MinisTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MinisTheme.subtleStroke, lineWidth: 1)
        )
    }

    private func officeFileActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func generateFrontendProject(mode: FrontendProjectBuilder.BuildMode) {
        guard canGenerateFrontendProject else {
            saveFeedback = "当前消息没有可识别的项目代码。"
            return
        }
        guard !isBuildingFrontendProject else { return }
        isBuildingFrontendProject = true

        frontendBuildRequestID &+= 1
        let requestID = frontendBuildRequestID
        let sourceMessage = actionMessage

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FrontendProjectBuilder.buildProject(
                    from: sourceMessage,
                    mode: mode,
                    useParseCache: false
                )
            }
            DispatchQueue.main.async {
                guard frontendBuildRequestID == requestID else { return }
                isBuildingFrontendProject = false

                switch result {
                case .success(let buildResult):
                    let fileCount = buildResult.writtenRelativePaths.count
                    if buildResult.shouldAutoOpenPreview {
                        let previewFileURL = buildResult.previewEntryFileURL ?? buildResult.entryFileURL
                        let title = "网页预览 · \(previewFileURL.lastPathComponent)"
                        activeHTMLPreview = HTMLPreviewPayload(
                            title: title,
                            html: buildResult.previewEntryHTML ?? buildResult.entryHTML,
                            baseURL: buildResult.projectDirectoryURL,
                            entryFileURL: previewFileURL
                        )
                    }

                    switch mode {
                    case .createNewProject:
                        if buildResult.shouldAutoOpenPreview {
                            feedback(.success, "已生成项目并预览（\(fileCount) 文件）")
                        } else {
                            feedback(.success, "已生成项目（\(fileCount) 文件）")
                        }
                    case .overwriteLatestProject:
                        if buildResult.shouldAutoOpenPreview {
                            feedback(.success, "已覆盖更新并预览（\(fileCount) 文件）")
                        } else {
                            feedback(.success, "已覆盖更新（\(fileCount) 文件）")
                        }
                    }
                case .failure(let error):
                    let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    saveFeedback = text
                }
            }
        }
    }

    private func generatePPTFile() {
        guard canGeneratePPT else {
            saveFeedback = "当前消息没有可识别的 PPT 大纲内容。"
            return
        }
        guard !isGeneratingPPT else { return }

        let sourceMessage = actionMessage
        isGeneratingPPT = true
        pptGenerationTask?.cancel()

        pptGenerationTask = Task {
            defer {
                Task { @MainActor in
                    isGeneratingPPT = false
                    pptGenerationTask = nil
                }
            }

            do {
                let result = try await PPTGenerationService.shared.generate(from: sourceMessage)
                try Task.checkCancellation()
                await MainActor.run {
                    let outline = PPTGenerationService.extractOutline(from: sourceMessage)
                        ?? PPTGenerationService.Outline(title: result.fileName, slides: [])
                    generatedPPTPayload = GeneratedPPTPayload(
                        fileURL: result.fileURL,
                        slideCount: result.slideCount,
                        generatedAt: Date(),
                        outline: outline
                    )
                    feedback(.success, "已生成 PPT（\(result.slideCount) 页）")
                }
            } catch is CancellationError {
                await MainActor.run {
                    feedback(.light, "已取消 PPT 生成")
                }
            } catch {
                let messageText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    saveFeedback = messageText
                    feedback(.light, "PPT 生成失败")
                }
            }
        }
    }

    private func generateWordFile() {
        guard canGenerateWord else {
            saveFeedback = "当前消息没有可识别的 Word 文档内容。"
            return
        }
        guard !isGeneratingWord else { return }

        let sourceMessage = actionMessage
        isGeneratingWord = true
        wordGenerationTask?.cancel()

        wordGenerationTask = Task {
            defer {
                Task { @MainActor in
                    isGeneratingWord = false
                    wordGenerationTask = nil
                }
            }

            do {
                let result = try await WordGenerationService.shared.generate(from: sourceMessage)
                try Task.checkCancellation()
                await MainActor.run {
                    let blocks = WordGenerationService.extractBlocks(from: sourceMessage)
                    generatedWordPayload = GeneratedWordPayload(
                        fileURL: result.fileURL,
                        blockCount: result.blockCount,
                        generatedAt: Date(),
                        blocks: blocks
                    )
                    feedback(.success, "已生成 Word（\(result.blockCount) 段）")
                }
            } catch is CancellationError {
                await MainActor.run {
                    feedback(.light, "已取消 Word 生成")
                }
            } catch {
                let messageText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    saveFeedback = messageText
                    feedback(.light, "Word 生成失败")
                }
            }
        }
    }

    private func generateExcelFile() {
        guard canGenerateExcel else {
            saveFeedback = "当前消息没有可识别的表格内容。"
            return
        }
        guard !isGeneratingExcel else { return }

        let sourceMessage = actionMessage
        isGeneratingExcel = true
        excelGenerationTask?.cancel()

        excelGenerationTask = Task {
            defer {
                Task { @MainActor in
                    isGeneratingExcel = false
                    excelGenerationTask = nil
                }
            }

            do {
                let result = try await ExcelGenerationService.shared.generate(from: sourceMessage)
                try Task.checkCancellation()
                await MainActor.run {
                    let sheets = ExcelGenerationService.extractSheets(from: sourceMessage)
                    generatedExcelPayload = GeneratedExcelPayload(
                        fileURL: result.fileURL,
                        sheetCount: result.sheetCount,
                        rowCount: result.rowCount,
                        generatedAt: Date(),
                        sheets: sheets
                    )
                    feedback(.success, "已生成 Excel（\(result.sheetCount) 表）")
                }
            } catch is CancellationError {
                await MainActor.run {
                    feedback(.light, "已取消 Excel 生成")
                }
            } catch {
                let messageText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    saveFeedback = messageText
                    feedback(.light, "Excel 生成失败")
                }
            }
        }
    }

    private func previewPPTFile(_ payload: GeneratedPPTPayload) {
        guard FileManager.default.fileExists(atPath: payload.fileURL.path) else {
            saveFeedback = "PPT 文件不存在，请重新生成。"
            return
        }
        activePPTPreview = PPTPreviewPayload(
            fileURL: payload.fileURL,
            title: payload.fileURL.deletingPathExtension().lastPathComponent,
            generatedAt: payload.generatedAt,
            document: .powerPoint(
                title: payload.outline.title,
                slides: payload.outline.slides,
                slideCount: payload.slideCount
            )
        )
    }

    private func previewWordFile(_ payload: GeneratedWordPayload) {
        guard FileManager.default.fileExists(atPath: payload.fileURL.path) else {
            saveFeedback = "Word 文件不存在，请重新生成。"
            return
        }
        activePPTPreview = PPTPreviewPayload(
            fileURL: payload.fileURL,
            title: payload.fileURL.deletingPathExtension().lastPathComponent,
            generatedAt: payload.generatedAt,
            document: .word(
                blocks: payload.blocks,
                blockCount: payload.blockCount
            )
        )
    }

    private func previewExcelFile(_ payload: GeneratedExcelPayload) {
        guard FileManager.default.fileExists(atPath: payload.fileURL.path) else {
            saveFeedback = "Excel 文件不存在，请重新生成。"
            return
        }
        activePPTPreview = PPTPreviewPayload(
            fileURL: payload.fileURL,
            title: payload.fileURL.deletingPathExtension().lastPathComponent,
            generatedAt: payload.generatedAt,
            document: .excel(
                sheets: payload.sheets,
                sheetCount: payload.sheetCount,
                rowCount: payload.rowCount
            )
        )
    }

    private func sharePPTFile(_ payload: GeneratedPPTPayload) {
        shareGeneratedDocument(
            at: payload.fileURL,
            missingMessage: "PPT 文件不存在，请重新生成。"
        )
    }

    private func shareWordFile(_ payload: GeneratedWordPayload) {
        shareGeneratedDocument(
            at: payload.fileURL,
            missingMessage: "Word 文件不存在，请重新生成。"
        )
    }

    private func shareExcelFile(_ payload: GeneratedExcelPayload) {
        shareGeneratedDocument(
            at: payload.fileURL,
            missingMessage: "Excel 文件不存在，请重新生成。"
        )
    }

    private func shareGeneratedDocument(at fileURL: URL, missingMessage: String) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            saveFeedback = missingMessage
            return
        }
        activeShareSheet = ShareSheetPayload(fileURL: fileURL)
    }

    private func generatedTimestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func fileSizeText(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let bytes = values?.fileSize ?? 0
        guard bytes > 0 else { return "大小未知" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var canPlayAssistantReply: Bool {
        guard actionMessage.role == .assistant else { return false }
        guard !actionMessage.isStreaming else { return false }
        guard !actionMessage.isImageGenerationPlaceholder, !actionMessage.isVideoGenerationPlaceholder else { return false }

        let hasText = !actionMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTextFiles = actionMessage.fileAttachments.contains { attachment in
            attachment.binaryBase64 == nil
                && !attachment.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasText || hasTextFiles || !actionMessage.imageAttachments.isEmpty || !actionMessage.videoAttachments.isEmpty
    }

    private var isPlayingAssistantReply: Bool {
        speechPlayback.isPlaying(messageID: actionMessage.id)
    }

    private func toggleAssistantSpeechPlayback() {
        if isPlayingAssistantReply {
            speechPlayback.stop(messageID: actionMessage.id)
            feedback(.light, "已停止朗读")
            return
        }

        if speechPlayback.speak(message: actionMessage) {
            feedback(.light, "正在朗读…")
        } else {
            feedback(.light, "当前消息没有可朗读内容")
        }
    }

    private func resolvedCodeActionContent(
        title: String,
        language: String?,
        displayContent: String
    ) -> String {
        let cleanedDisplay = removingPreviewTruncationMarkers(from: displayContent)
        let shouldRecoverFromSource = hasPreviewTruncationMarker(in: displayContent)
        guard shouldRecoverFromSource, sourceMessage != nil else { return cleanedDisplay }

        if let fileName = fileName(fromCodeTitle: title) {
            if let attachment = actionMessage.fileAttachments.first(where: {
                $0.binaryBase64 == nil && $0.fileName.caseInsensitiveCompare(fileName) == .orderedSame
            }) {
                let normalized = removingPreviewTruncationMarkers(from: attachment.textContent)
                if !normalized.isEmpty {
                    return normalized
                }
            }

            if let matched = actionMessageStructuredSegments().first(where: {
                if case let .file(name, _, _) = $0 {
                    return name.caseInsensitiveCompare(fileName) == .orderedSame
                }
                return false
            }), case let .file(_, _, content) = matched {
                let normalized = removingPreviewTruncationMarkers(from: content)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }

        let prefix = String(cleanedDisplay.prefix(180))
        for segment in actionMessageStructuredSegments() {
            switch segment {
            case .code(_, let candidateContent):
                if matchesActionCodeCandidate(
                    expectedPrefix: prefix,
                    candidateContent: candidateContent
                ) {
                    return removingPreviewTruncationMarkers(from: candidateContent)
                }
            case .file(_, _, let candidateContent):
                if matchesActionCodeCandidate(
                    expectedPrefix: prefix,
                    candidateContent: candidateContent
                ) {
                    return removingPreviewTruncationMarkers(from: candidateContent)
                }
            default:
                continue
            }
        }

        return cleanedDisplay
    }

    private func actionMessageStructuredSegments() -> [MessageSegment] {
        MessageContentParser.parse(actionMessage)
    }

    private func matchesActionCodeCandidate(
        expectedPrefix: String,
        candidateContent: String
    ) -> Bool {
        let normalizedCandidate = removingPreviewTruncationMarkers(from: candidateContent)
        guard !normalizedCandidate.isEmpty else { return false }
        guard !expectedPrefix.isEmpty else { return false }
        return normalizedCandidate.hasPrefix(expectedPrefix)
    }

    private func normalizedCodeViewerContent(_ text: String) -> String {
        let cleaned = removingPreviewTruncationMarkers(from: text)
        return unwrapSingleFencedCodeContentIfNeeded(cleaned)
    }

    private func unwrapSingleFencedCodeContentIfNeeded(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        let lines = normalized.components(separatedBy: "\n")
        guard !lines.isEmpty else { return normalized }

        let firstLine = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let isTickFence = firstLine.hasPrefix("```")
        let isWaveFence = firstLine.hasPrefix("~~~")
        guard isTickFence || isWaveFence else { return normalized }

        let closingPattern = isTickFence
            ? #"^`{3,}\s*$"#
            : #"^~{3,}\s*$"#
        var closingIndex: Int?
        if lines.count > 1 {
            for index in stride(from: lines.count - 1, through: 1, by: -1) {
                let candidate = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.range(of: closingPattern, options: .regularExpression) != nil {
                    closingIndex = index
                    break
                }
            }
        }

        let contentLines: [String]
        if let closingIndex, closingIndex > 0 {
            contentLines = Array(lines[1..<closingIndex])
        } else {
            contentLines = Array(lines.dropFirst())
        }

        let content = contentLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? normalized : content
    }

    private func fileName(fromCodeTitle title: String) -> String? {
        let prefix = "FILE · "
        guard title.hasPrefix(prefix) else { return nil }
        let fileName = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return fileName.isEmpty ? nil : fileName
    }

    private func removingPreviewTruncationMarkers(from text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let hadTruncationMarker = normalized.contains("[附件预览过长，已截断显示。]")
            || normalized.contains("[该消息过长，已在聊天页截断显示。]")

        normalized = normalized.replacingOccurrences(
            of: #"\s*\[(?:附件预览过长，已截断显示。|该消息过长，已在聊天页截断显示。)\]\s*"#,
            with: "\n",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )

        if hadTruncationMarker {
            normalized = normalized.replacingOccurrences(
                of: #"\n(?:`{3,}|~{3,})\s*$"#,
                with: "",
                options: .regularExpression
            )
        }

        // Guard against malformed trailing markdown fences like `` / ``` / ~~~
        // that occasionally leak into viewer content.
        normalized = normalized.replacingOccurrences(
            of: #"(?:\n|\A)\s*[`~]{2,}\s*$"#,
            with: "",
            options: .regularExpression
        )

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasPreviewTruncationMarker(in text: String) -> Bool {
        text.contains("[附件预览过长，已截断显示。]")
            || text.contains("[该消息过长，已在聊天页截断显示。]")
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
        activeHTMLPreview = HTMLPreviewPayload(
            title: title,
            html: trimmed,
            baseURL: nil,
            entryFileURL: nil
        )
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
    private func messageVideo(_ attachment: ChatVideoAttachment) -> some View {
        let revealID = attachment.requestURLString.isEmpty
            ? attachment.id.uuidString
            : attachment.requestURLString

        if let normalizedURL = normalizedRemoteURLString(attachment.requestURLString) {
            GeneratedImageRevealCard(revealID: revealID) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.86),
                                    Color.black.opacity(0.68)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.92))

                        Text("点击预览视频")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
                .frame(maxWidth: 300, maxHeight: 170, alignment: .leading)
                .onTapGesture {
                    activeVideoPreview = VideoPreviewPayload(urlString: normalizedURL)
                }
                .contextMenu {
                    videoContextActions(for: attachment, normalizedURL: normalizedURL)
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

    @ViewBuilder
    private func videoContextActions(for attachment: ChatVideoAttachment, normalizedURL: String) -> some View {
        if !attachment.requestURLString.isEmpty {
            Button("复制视频链接") {
                UIPasteboard.general.string = attachment.requestURLString
            }
        }
        Button("打开视频") {
            if let url = URL(string: normalizedURL) {
                UIApplication.shared.open(url)
            }
        }
    }

    private var codeBackgroundColor: Color {
        MinisTheme.codeCard
    }

    private var codeViewportBackgroundColor: Color {
        MinisTheme.codeViewport
    }

    private var codePrimaryTextColor: UIColor {
        MinisTheme.codeText
    }

    private var codeCardBorderColor: Color {
        MinisTheme.codeStroke
    }

    private var userBubbleColor: Color {
        colorScheme == .dark ? Color(red: 0.20, green: 0.20, blue: 0.22) : MinisTheme.userBubble
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

    private func openLatestProjectPreviewFromProgress() {
        guard let entryFileURL = FrontendProjectBuilder.latestEntryFileURL() else {
            saveFeedback = "latest 目录里还没有可预览的入口文件。"
            return
        }

        do {
            let html = try String(contentsOf: entryFileURL, encoding: .utf8)
            activeHTMLPreview = HTMLPreviewPayload(
                title: "latest 预览 · \(entryFileURL.lastPathComponent)",
                html: html,
                baseURL: FrontendProjectBuilder.latestProjectURL() ?? entryFileURL.deletingLastPathComponent(),
                entryFileURL: entryFileURL
            )
        } catch {
            saveFeedback = "读取 latest 预览失败：\(error.localizedDescription)"
        }
    }
}

private struct FrontendProgressPayload {
    let state: String
    let fileCount: Int
    let hasEntry: Bool

    var isStreaming: Bool {
        state == "streaming"
    }

    static func parse(from raw: String) -> FrontendProgressPayload? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              first == "[IEXA_PROJECT_PROGRESS]" || first == "[IEXA_FRONTEND_PROGRESS]" else {
            return nil
        }

        var state = "streaming"
        var files = 0
        var entry = false

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "state":
                state = value.lowercased()
            case "files":
                files = max(0, Int(value) ?? 0)
            case "entry":
                entry = (Int(value) ?? 0) > 0
            default:
                continue
            }
        }

        return FrontendProgressPayload(state: state, fileCount: files, hasEntry: entry)
    }
}

private enum FrontendProgressStepState {
    case pending
    case running
    case completed
}

private struct FrontendProgressStep: Identifiable {
    let title: String
    let state: FrontendProgressStepState

    var id: String { title }

    var trailing: String {
        switch state {
        case .pending:
            return "等待"
        case .running:
            return "进行中"
        case .completed:
            return "完成"
        }
    }

    var iconColor: Color {
        switch state {
        case .pending:
            return Color.white.opacity(0.55)
        case .running:
            return Color.cyan
        case .completed:
            return Color.green
        }
    }

    var trailingColor: Color {
        switch state {
        case .pending:
            return Color.white.opacity(0.62)
        case .running:
            return Color.cyan.opacity(0.95)
        case .completed:
            return Color.green.opacity(0.95)
        }
    }
}

private struct ImageGenerationPlaceholderPattern: View {
    let phase: TimeInterval

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MinisTheme.elevatedBackground)

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
    let baseURL: URL?
    let entryFileURL: URL?
}

private struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let source: ImagePreviewSheet.Source
}

private struct VideoPreviewPayload: Identifiable {
    let id = UUID()
    let urlString: String
}

private struct GeneratedPPTPayload: Identifiable {
    let id = UUID()
    let fileURL: URL
    let slideCount: Int
    let generatedAt: Date
    let outline: PPTGenerationService.Outline
}

private struct GeneratedWordPayload: Identifiable {
    let id = UUID()
    let fileURL: URL
    let blockCount: Int
    let generatedAt: Date
    let blocks: [WordGenerationService.Block]
}

private struct GeneratedExcelPayload: Identifiable {
    let id = UUID()
    let fileURL: URL
    let sheetCount: Int
    let rowCount: Int
    let generatedAt: Date
    let sheets: [ExcelGenerationService.Sheet]
}

private struct PPTPreviewPayload: Identifiable {
    let id = UUID()
    let fileURL: URL
    let title: String
    let generatedAt: Date
    let document: OfficePreviewDocument
}

private enum OfficePreviewDocument {
    case powerPoint(title: String, slides: [PPTGenerationService.Outline.Slide], slideCount: Int)
    case word(blocks: [WordGenerationService.Block], blockCount: Int)
    case excel(sheets: [ExcelGenerationService.Sheet], sheetCount: Int, rowCount: Int)
}

private struct ShareSheetPayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private struct PendingPythonRun: Identifiable {
    let id = UUID()
    let token: String
    let code: String
}

private struct InteractivePythonSessionSheet: View {
    let payload: PendingPythonRun
    let onClose: (PythonInteractiveSessionSnapshot?, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    @State private var snapshot: PythonInteractiveSessionSnapshot?
    @State private var finalSnapshot: PythonInteractiveSessionSnapshot?
    @State private var inputText = ""
    @State private var isStarting = true
    @State private var isSending = false
    @State private var sessionError: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var didReportClose = false
    @State private var wasStopped = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header

                Divider()
                    .overlay(Color.white.opacity(0.12))

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let sessionError {
                            Text(sessionError)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.red.opacity(0.92))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let outputText = currentOutput, !outputText.isEmpty {
                            Text(outputText)
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.94))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        } else if isStarting {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(.white)
                                Text("正在启动交互式 Python 会话…")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.72))
                            }
                        } else {
                            Text("等待程序输出…")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.54))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.26))
                )
                .padding(.horizontal, 16)
                .padding(.top, 18)

                Spacer(minLength: 0)

                inputPanel
            }
            .background(Color(red: 0.16, green: 0.17, blue: 0.20).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .interactiveDismissDisabled(true)
            .task {
                await startSessionIfNeeded()
            }
            .onDisappear {
                pollTask?.cancel()
                reportCloseIfNeeded()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Running Python")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)

                    if isSessionRunning {
                        ProgressView()
                            .scaleEffect(0.82)
                            .tint(Color(red: 0.63, green: 0.78, blue: 1.0))
                    }
                }

                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
            }

            Spacer(minLength: 0)

            if isSessionRunning {
                Button {
                    Task { await stopSession(shouldDismiss: false) }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await closeSheet() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isWaitingForInput ? ">>> Input" : "程序运行中")
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(isWaitingForInput ? 0.92 : 0.5))

            HStack(spacing: 10) {
                TextField(
                    isWaitingForInput ? "输入后回车发送" : "等待程序请求输入…",
                    text: $inputText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .submitLabel(.send)
                .focused($inputFocused)
                .disabled(!isWaitingForInput || isSending)
                .onSubmit {
                    submitInput()
                }

                Button("发送") {
                    submitInput()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(canSubmitInput ? Color.black : Color.white.opacity(0.42))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(canSubmitInput ? Color.white : Color.white.opacity(0.08))
                )
                .disabled(!canSubmitInput)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 26)
        .background(Color(red: 0.16, green: 0.17, blue: 0.20))
    }

    private var currentOutput: String? {
        let text = (snapshot?.output ?? finalSnapshot?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var isSessionRunning: Bool {
        if isStarting { return true }
        if let snapshot {
            return !snapshot.isFinished
        }
        return false
    }

    private var isWaitingForInput: Bool {
        snapshot?.isWaitingForInput == true && snapshot?.isFinished == false
    }

    private var canSubmitInput: Bool {
        isWaitingForInput && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private var statusText: String {
        if let sessionError {
            return sessionError
        }
        if isStarting {
            return "初始化运行环境…"
        }
        if let snapshot {
            if snapshot.isFinished {
                return snapshot.exitCode == 0 ? "运行完成" : "运行结束，退出码 \(snapshot.exitCode ?? 1)"
            }
            if snapshot.isWaitingForInput {
                return "等待输入…"
            }
            return "脚本执行中…"
        }
        return "准备中…"
    }

    private func startSessionIfNeeded() async {
        guard snapshot == nil, finalSnapshot == nil, sessionError == nil else { return }
        do {
            let started = try await PythonExecutionService.shared.startInteractiveSession(code: payload.code)
            await MainActor.run {
                snapshot = started
                finalSnapshot = started
                isStarting = false
                if started.isWaitingForInput {
                    inputFocused = true
                }
                startPolling(sessionID: started.sessionID)
            }
        } catch {
            await MainActor.run {
                sessionError = error.localizedDescription
                isStarting = false
            }
        }
    }

    private func startPolling(sessionID: String) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    let next = try await PythonExecutionService.shared.pollInteractiveSession(sessionID: sessionID)
                    await MainActor.run {
                        snapshot = next
                        finalSnapshot = next
                        if next.isWaitingForInput {
                            inputFocused = true
                        }
                    }
                    if next.isFinished {
                        break
                    }
                } catch {
                    await MainActor.run {
                        sessionError = error.localizedDescription
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func submitInput() {
        guard canSubmitInput, let sessionID = snapshot?.sessionID else { return }
        let value = inputText
        inputText = ""
        isSending = true

        Task {
            do {
                let next = try await PythonExecutionService.shared.sendInteractiveInput(
                    sessionID: sessionID,
                    input: value
                )
                await MainActor.run {
                    snapshot = next
                    finalSnapshot = next
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    sessionError = error.localizedDescription
                    isSending = false
                }
            }
        }
    }

    private func stopSession(shouldDismiss: Bool) async {
        wasStopped = true
        pollTask?.cancel()
        if let sessionID = snapshot?.sessionID {
            let stopped = await PythonExecutionService.shared.stopInteractiveSession(sessionID: sessionID)
            await MainActor.run {
                if let stopped {
                    snapshot = stopped
                    finalSnapshot = stopped
                }
            }
        }
        if shouldDismiss {
            await MainActor.run {
                dismiss()
            }
        }
    }

    private func closeSheet() async {
        if isSessionRunning {
            await stopSession(shouldDismiss: true)
            return
        }
        await MainActor.run {
            dismiss()
        }
    }

    private func reportCloseIfNeeded() {
        guard !didReportClose else { return }
        didReportClose = true
        onClose(finalSnapshot ?? snapshot, wasStopped)
    }
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

private struct VideoPreviewSheet: View {
    let urlString: String
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .background(Color.black.ignoresSafeArea())
                .onAppear {
                    guard let url = URL(string: urlString) else { return }
                    let item = AVPlayerItem(url: url)
                    player.replaceCurrentItem(with: item)
                }
                .onDisappear {
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("打开链接") {
                            if let url = URL(string: urlString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
                .navigationTitle("视频预览")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct OfficePreviewSheet: View {
    let payload: PPTPreviewPayload
    @Environment(\.dismiss) private var dismiss
    @State private var showsShareSheet = false
    @State private var selectedExcelSheetIndex = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(payload.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(metaText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    switch payload.document {
                    case .powerPoint(let title, let slides, let slideCount):
                        powerPointPreview(title: title, slides: slides, slideCount: slideCount)
                    case .word(let blocks, let blockCount):
                        wordPreview(blocks: blocks, blockCount: blockCount)
                    case .excel(let sheets, _, let rowCount):
                        excelPreview(sheets: sheets, rowCount: rowCount)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
            .background(MinisTheme.appBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("预览")
                        .font(.system(size: 20, weight: .semibold))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomActionBar
            }
            .sheet(isPresented: $showsShareSheet) {
                ShareSheet(activityItems: [payload.fileURL])
            }
        }
    }

    private var metaText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        let timeText = formatter.string(from: payload.generatedAt)
        let sizeText = fileSizeText(for: payload.fileURL)
        return "生成于 \(timeText) · \(sizeText)"
    }

    private func fileSizeText(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let bytes = values?.fileSize ?? 0
        guard bytes > 0 else { return "大小未知" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            bottomActionButton(title: "分享", systemImage: "square.and.arrow.up")
            bottomActionButton(title: "下载", systemImage: "arrow.down.to.line")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(MinisTheme.panelBackground)
    }

    private func bottomActionButton(title: String, systemImage: String) -> some View {
        Button {
            showsShareSheet = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(MinisTheme.panelBackground)
            )
        }
        .buttonStyle(.plain)
    }

    private func powerPointPreview(
        title: String,
        slides: [PPTGenerationService.Outline.Slide],
        slideCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            TabView {
                ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("第 \(index + 1) 页")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(slideCount) 张")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Text(slide.title)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(slide.bullets, id: \.self) { bullet in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 9)
                                    Text(bullet)
                                        .font(.system(size: 19, weight: .medium))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(MinisTheme.panelBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(MinisTheme.subtleStroke, lineWidth: 1)
                    )
                    .padding(.bottom, 22)
                }
            }
            .frame(height: 420)
            .tabViewStyle(.page(indexDisplayMode: .always))
        }
    }

    private func wordPreview(
        blocks: [WordGenerationService.Block],
        blockCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("文档内容 · \(blockCount) 段")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block.kind {
                    case .heading1:
                        Text(block.text)
                            .font(.system(size: 30, weight: .bold))
                    case .heading2:
                        Text(block.text)
                            .font(.system(size: 23, weight: .semibold))
                    case .paragraph:
                        Text(block.text)
                            .font(.system(size: 18))
                            .lineSpacing(6)
                    case .bullet:
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 7, height: 7)
                                .padding(.top, 9)
                            Text(block.text)
                                .font(.system(size: 18))
                                .lineSpacing(6)
                        }
                    }
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(MinisTheme.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(MinisTheme.subtleStroke, lineWidth: 1)
            )
        }
    }

    private func excelPreview(
        sheets: [ExcelGenerationService.Sheet],
        rowCount: Int
    ) -> some View {
        let safeIndex = min(selectedExcelSheetIndex, max(0, sheets.count - 1))
        let activeSheet = sheets.isEmpty ? nil : sheets[safeIndex]

        return VStack(alignment: .leading, spacing: 14) {
            Text("表格内容 · 共 \(rowCount) 行")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            if sheets.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(sheets.enumerated()), id: \.offset) { index, sheet in
                            Button {
                                selectedExcelSheetIndex = index
                            } label: {
                                Text(sheet.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(index == safeIndex ? Color.green : .primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(index == safeIndex ? Color.green.opacity(0.12) : MinisTheme.panelBackground)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let activeSheet {
                officeExcelGrid(sheet: activeSheet)
            }
        }
    }

    private func officeExcelGrid(sheet: ExcelGenerationService.Sheet) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(sheet.headers.enumerated()), id: \.offset) { _, header in
                    Text(header)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .background(MinisTheme.panelBackground)
                }
            }

            ForEach(Array(sheet.rows.enumerated()), id: \.offset) { _, row in
                Divider()
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 15)
                            .background(MinisTheme.panelBackground)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(MinisTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(MinisTheme.subtleStroke, lineWidth: 1)
        )
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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

private struct SweepShimmerText: View {
    let text: String
    let font: Font
    let baseColor: Color
    @State private var sweepProgress: CGFloat = 0

    init(_ text: String, font: Font, baseColor: Color = .secondary) {
        self.text = text
        self.font = font
        self.baseColor = baseColor
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(font)
                .foregroundStyle(baseColor)

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let shimmerWidth = max(48, width * 1.2)
                let travel = width + shimmerWidth * 2.6

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.12), location: 0.16),
                        .init(color: .white.opacity(0.85), location: 0.50),
                        .init(color: .white.opacity(0.16), location: 0.84),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: shimmerWidth, height: max(22, proxy.size.height))
                .offset(x: -shimmerWidth + travel * sweepProgress)
                .blendMode(.plusLighter)
                .mask(
                    Text(text)
                        .font(font)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
                .allowsHitTesting(false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .clipped()
        .onAppear {
            sweepProgress = 0
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                sweepProgress = 1
            }
        }
    }
}

private struct ThinkingDotsWaveView: UIViewRepresentable {
    let dotSize: CGFloat
    let spacing: CGFloat

    func makeUIView(context: Context) -> DotWaveContainerView {
        let view = DotWaveContainerView()
        view.configure(dotSize: dotSize, spacing: spacing)
        return view
    }

    func updateUIView(_ uiView: DotWaveContainerView, context: Context) {
        uiView.configure(dotSize: dotSize, spacing: spacing)
        uiView.startAnimatingIfNeeded()
    }

    final class DotWaveContainerView: UIView {
        private var dotLayers: [CALayer] = []
        private var configuredDotSize: CGFloat = 0
        private var configuredSpacing: CGFloat = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(dotSize: CGFloat, spacing: CGFloat) {
            let normalizedDotSize = max(3, dotSize)
            let normalizedSpacing = max(1, spacing)
            guard normalizedDotSize != configuredDotSize || normalizedSpacing != configuredSpacing || dotLayers.isEmpty else {
                return
            }

            configuredDotSize = normalizedDotSize
            configuredSpacing = normalizedSpacing

            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            dotLayers.removeAll()

            let totalWidth = normalizedDotSize * 3 + normalizedSpacing * 2
            let startX = max(0, (bounds.width > 0 ? bounds.width : totalWidth) - totalWidth) * 0.5
            let originY = max(0, (bounds.height > 0 ? bounds.height : normalizedDotSize) - normalizedDotSize) * 0.5

            for index in 0..<3 {
                let dotLayer = CALayer()
                dotLayer.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.52).cgColor
                dotLayer.cornerRadius = normalizedDotSize * 0.5
                dotLayer.frame = CGRect(
                    x: startX + CGFloat(index) * (normalizedDotSize + normalizedSpacing),
                    y: originY,
                    width: normalizedDotSize,
                    height: normalizedDotSize
                )
                layer.addSublayer(dotLayer)
                dotLayers.append(dotLayer)
            }
            startAnimatingIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !dotLayers.isEmpty else { return }

            let totalWidth = configuredDotSize * 3 + configuredSpacing * 2
            let startX = max(0, bounds.width - totalWidth) * 0.5
            let originY = max(0, bounds.height - configuredDotSize) * 0.5

            for (index, dotLayer) in dotLayers.enumerated() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                dotLayer.frame = CGRect(
                    x: startX + CGFloat(index) * (configuredDotSize + configuredSpacing),
                    y: originY,
                    width: configuredDotSize,
                    height: configuredDotSize
                )
                CATransaction.commit()
            }
        }

        func startAnimatingIfNeeded() {
            guard !dotLayers.isEmpty else { return }

            for (index, dotLayer) in dotLayers.enumerated() {
                guard dotLayer.animation(forKey: "iexa.wave.offset") == nil else { continue }

                let begin = CACurrentMediaTime() + Double(index) * 0.12

                let position = CABasicAnimation(keyPath: "transform.translation.y")
                position.fromValue = 0
                position.toValue = -3.5
                position.duration = 0.36
                position.autoreverses = true
                position.repeatCount = .infinity
                position.beginTime = begin
                position.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                position.isRemovedOnCompletion = false

                let opacity = CABasicAnimation(keyPath: "opacity")
                opacity.fromValue = 0.38
                opacity.toValue = 1.0
                opacity.duration = 0.36
                opacity.autoreverses = true
                opacity.repeatCount = .infinity
                opacity.beginTime = begin
                opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                opacity.isRemovedOnCompletion = false

                dotLayer.add(position, forKey: "iexa.wave.offset")
                dotLayer.add(opacity, forKey: "iexa.wave.opacity")
            }
        }
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

