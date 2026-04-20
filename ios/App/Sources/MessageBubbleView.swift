import SwiftUI
import UIKit
import Photos
import AVKit
import QuickLook

struct MessageBubbleView: View {
    let message: ChatMessage
    let sourceMessage: ChatMessage?
    let codeThemeMode: CodeThemeMode
    let apiKey: String
    let apiBaseURL: String
    let showsAssistantActionBar: Bool
    let onRegenerate: (() -> Void)?
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
    @State private var pendingPythonRun: PendingPythonRun?
    @State private var waitingDotPulse = false
    @State private var frontendProgressPulse = false
    @State private var isGeneratingPPT = false
    @State private var generatedPPTPayload: GeneratedPPTPayload?
    @State private var isGeneratingWord = false
    @State private var generatedWordPayload: GeneratedWordPayload?
    @State private var isGeneratingExcel = false
    @State private var generatedExcelPayload: GeneratedExcelPayload?
    @State private var activePPTPreview: PPTPreviewPayload?
    @State private var activeShareSheet: ShareSheetPayload?
    @State private var pptGenerationTask: Task<Void, Never>?
    @State private var wordGenerationTask: Task<Void, Never>?
    @State private var excelGenerationTask: Task<Void, Never>?
    private let chatUIFont = UIFont(name: "PingFangSC-Medium", size: 16) ?? UIFont.systemFont(ofSize: 16, weight: .medium)

    init(
        message: ChatMessage,
        sourceMessage: ChatMessage? = nil,
        codeThemeMode: CodeThemeMode,
        apiKey: String,
        apiBaseURL: String,
        showsAssistantActionBar: Bool,
        onRegenerate: (() -> Void)?
    ) {
        self.message = message
        self.sourceMessage = sourceMessage
        self.codeThemeMode = codeThemeMode
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.showsAssistantActionBar = showsAssistantActionBar
        self.onRegenerate = onRegenerate
    }

    private var actionMessage: ChatMessage {
        sourceMessage ?? message
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
        .onDisappear {
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
        VStack(alignment: .leading, spacing: 6) {
            assistantIdentityHeader

            content

            if showsAssistantActionBar && frontendProgressPayload == nil {
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
                    .font(.custom("PingFangSC-Medium", size: 16))
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
            let displayText = normalizedStreamingText(message.content)
            if message.isImageGenerationPlaceholder && message.imageAttachments.isEmpty {
                imageGenerationProgressCard
            } else if message.isVideoGenerationPlaceholder && message.videoAttachments.isEmpty {
                videoGenerationProgressContainer(streamingTextAnimated: true)
            } else {
                let segments = parsedStreamingSegments(for: displayText)

                if segments.isEmpty {
                    if !message.imageAttachments.isEmpty || !message.videoAttachments.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(message.imageAttachments) { attachment in
                                messageImage(attachment)
                            }
                            ForEach(message.videoAttachments) { attachment in
                                messageVideo(attachment)
                            }
                        }
                    } else {
                        streamingWaitingDot
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            segmentView(segment, streamingTextAnimated: true)
                        }
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
                            .fill(Color(.secondarySystemBackground))
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
                .font(.custom("PingFangSC-Medium", size: 16))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let language, let content):
            codeBlock(title: (language ?? "code").uppercased(), content: content, language: language)
        case .file(let name, let language, let content):
            fileSegmentView(name: name, language: language, content: content)
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
            selectableTextContent(text, streamingTextAnimated: streamingTextAnimated)
        case .code(let language, let content):
            codeBlock(title: (language ?? "code").uppercased(), content: content, language: language)
        case .file(let name, let language, let content):
            fileSegmentView(name: name, language: language, content: content)
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
    private func fileSegmentView(name: String, language: String?, content: String) -> some View {
        let spreadsheetSheets = ExcelGenerationService.extractSheets(
            fromRawText: content,
            preferredName: (name as NSString).deletingPathExtension
        )

        if isSpreadsheetPreviewFile(name: name), let firstSheet = spreadsheetSheets.first {
            spreadsheetPreviewCard(fileName: name, sheet: firstSheet)
        } else {
            codeBlock(title: "FILE · \(name)", content: content, language: language)
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
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.16 : 0.08), lineWidth: 1)
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
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), lineWidth: 0.8)
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

    private func selectableTextContent(_ text: String, streamingTextAnimated: Bool = false) -> some View {
        SelectableLinkTextView(
            text: text,
            textColor: UIColor.label,
            linkColor: UIColor.secondaryLabel,
            font: chatUIFont,
            renderMarkdown: false,
            streamingAnimated: streamingTextAnimated
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBlock(title: String, content: String, language: String? = nil) -> some View {
        let actionContent = resolvedCodeActionContent(
            title: title,
            language: language,
            displayContent: content
        )
        let copyToken = "\(title)|\(language ?? "")|\(actionContent)"
        let isCopied = copiedCodeToken == copyToken
        let isRunning = runningCodeToken == copyToken
        let canRunPython = supportsPythonRun(language: language, title: title)
            && PythonExecutionService.isRunnableSnippet(actionContent)
        let canRunHTML = supportsHTMLPreview(language: language, title: title, content: actionContent)
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
                            requestPythonRun(actionContent, token: copyToken)
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? .red : Color(red: 0.08, green: 0.08, blue: 0.1))
                    .foregroundStyle(.white)
                }
                if canRunHTML {
                    Button("运行网页") {
                        openHTMLPreview(title: title, content: actionContent)
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.06, green: 0.36, blue: 0.86))
                    .foregroundStyle(.white)
                }
                Button(isCopied ? "已复制" : "复制代码") {
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
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .tint(isCopied ? .green : nil)
                .animation(.easeInOut(duration: 0.16), value: isCopied)
            }

            SelectableCodeTextView(
                text: content,
                textColor: UIColor.label,
                font: .monospacedSystemFont(ofSize: 15.5, weight: .medium),
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

    private var shouldShowExcelCard: Bool {
        generatedExcelPayload != nil
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
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), lineWidth: 0.8)
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
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), lineWidth: 0.8)
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
                .disabled(isGeneratingExcel || !canGenerateExcel)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08), lineWidth: 0.8)
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
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), lineWidth: 1)
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
        defer { isBuildingFrontendProject = false }

        do {
            let result = try FrontendProjectBuilder.buildProject(from: actionMessage, mode: mode)
            let fileCount = result.writtenRelativePaths.count
            if result.shouldAutoOpenPreview {
                let title = "网页预览 · \(result.entryFileURL.lastPathComponent)"
                activeHTMLPreview = HTMLPreviewPayload(
                    title: title,
                    html: result.entryHTML,
                    baseURL: result.projectDirectoryURL,
                    entryFileURL: result.entryFileURL
                )
            }

            switch mode {
            case .createNewProject:
                if result.shouldAutoOpenPreview {
                    feedback(.success, "已生成项目并预览（\(fileCount) 文件）")
                } else {
                    feedback(.success, "已生成项目（\(fileCount) 文件）")
                }
            case .overwriteLatestProject:
                if result.shouldAutoOpenPreview {
                    feedback(.success, "已覆盖更新并预览（\(fileCount) 文件）")
                } else {
                    feedback(.success, "已覆盖更新（\(fileCount) 文件）")
                }
            }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            saveFeedback = text
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
        guard sourceMessage != nil else { return cleanedDisplay }

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

        let prefix = String(cleanedDisplay.prefix(120))
        for segment in actionMessageStructuredSegments() {
            switch segment {
            case .code(let candidateLanguage, let candidateContent):
                if matchesActionCodeCandidate(
                    language: language,
                    expectedPrefix: prefix,
                    candidateLanguage: candidateLanguage,
                    candidateContent: candidateContent
                ) {
                    return removingPreviewTruncationMarkers(from: candidateContent)
                }
            case .file(_, let candidateLanguage, let candidateContent):
                if matchesActionCodeCandidate(
                    language: language,
                    expectedPrefix: prefix,
                    candidateLanguage: candidateLanguage,
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
        language: String?,
        expectedPrefix: String,
        candidateLanguage: String?,
        candidateContent: String
    ) -> Bool {
        let normalizedCandidate = removingPreviewTruncationMarkers(from: candidateContent)
        guard !normalizedCandidate.isEmpty else { return false }

        if !expectedPrefix.isEmpty && normalizedCandidate.hasPrefix(expectedPrefix) {
            return true
        }

        let normalizedLanguage = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCandidateLanguage = (candidateLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalizedLanguage.isEmpty && normalizedLanguage == normalizedCandidateLanguage
    }

    private func fileName(fromCodeTitle title: String) -> String? {
        let prefix = "FILE · "
        guard title.hasPrefix(prefix) else { return nil }
        let fileName = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return fileName.isEmpty ? nil : fileName
    }

    private func removingPreviewTruncationMarkers(from text: String) -> String {
        text
            .replacingOccurrences(of: "\n\n[附件预览过长，已截断显示。]", with: "")
            .replacingOccurrences(of: "\n\n[该消息过长，已在聊天页截断显示。]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
        .background(.thinMaterial)
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
                    .fill(Color(.systemBackground))
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
                            .fill(Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
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
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
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
                                            .fill(index == safeIndex ? Color.green.opacity(0.12) : Color(.systemBackground))
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
                        .background(Color(.systemBackground))
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
                            .background(Color(.systemBackground))
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
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

private final class ImageSaveCoordinator: NSObject {
    static let shared = ImageSaveCoordinator()
    var onComplete: ((Error?) -> Void)?

    @objc func handleSaveResult(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        onComplete?(error)
        onComplete = nil
    }
}

