import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit
import Combine

struct ChatScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("chatapp.config.onboarding.done") private var hasCompletedInitialConfig = false

    private let sidebarWidth: CGFloat = 286
    private let edgeDragActivationWidth: CGFloat = 28
    private let headerCenterMinHorizontalInset: CGFloat = 76
    private let maxRenderedMessages = 56
    private let maxRenderedCharacters = 90_000
    private let maxSingleRenderedMessageChars = 28_000
    private let maxSingleRenderedCodeMessageChars = 65_000
    private let maxRenderedFilePreviewChars = 4_000
    private let autoSessionRotateMessageCount = 60
    private let autoSessionRotateCharacterCount = 100_000
    private let autoSessionRotateAssistantCharacterCount = 70_000
    private let autoSessionRotateSingleAssistantCharacterCount = 12_000
    private let autoSessionRotateViewportOverflowRatio: CGFloat = 4.0
    private let autoSessionRotateViewportOverflowAbsoluteGap: CGFloat = 180
    private let autoSessionRotateViewportMinAssistantCharacters = 32_000
    private let autoSessionRotateViewportMinMessageCount = 20
    private static let frontendOverlayCodeEntriesCacheLimit = 8

    private struct OutgoingEcho {
        let id: UUID
        let content: String
        let imageAttachments: [ChatImageAttachment]
        let fileAttachment: ChatFileAttachment?
        let createdAt: Date
    }

    private struct TokenUsageToast: Equatable {
        let trigger: Int
        let usage: ChatTokenUsage
    }

    private struct SessionRotateToast: Equatable {
        let trigger: Int
        let message: String
    }

    private struct FrontendBuildOverlayState: Equatable {
        let messageID: UUID
        let title: String
        let subtitle: String
        let stepIndex: Int
        let stepTotal: Int
        let fileCount: Int
        let hasEntryPreview: Bool
        let isCompleted: Bool
        let codeEntries: [CodeViewerEntry]
    }

    private struct FrontendOverlayCodeEntriesCacheEntry {
        let signature: String
        let entries: [CodeViewerEntry]
    }

    private static var frontendOverlayCodeEntriesCache: [UUID: FrontendOverlayCodeEntriesCacheEntry] = [:]
    private static var frontendOverlayCodeEntriesCacheOrder: [UUID] = []

    private let starterPrompts: [(title: String, subtitle: String)] = [
        ("写一个 Swift 网络请求封装", "支持 async/await 和错误重试"),
        ("帮我排查 iOS 卡顿", "给出 Instruments 的定位步骤"),
        ("设计一个 Python 爬虫", "可并发抓取并写入 SQLite"),
        ("写一个 React 登录页", "含表单校验和错误提示"),
        ("实现 Go 限流中间件", "基于令牌桶并附测试"),
        ("写一个 SQL 优化方案", "分析慢查询并给索引建议"),
        ("做一个 Node 文件上传 API", "支持分片上传和断点续传"),
        ("实现 Redis 缓存策略", "防穿透、防击穿、防雪崩"),
        ("写一个 Linux 排障脚本", "一键采集 CPU/内存/磁盘日志"),
        ("讲解 Git 冲突处理", "给出最安全的回滚流程"),
        ("设计一个消息队列消费器", "保证幂等与失败重试"),
        ("写一个算法题答案", "滑动窗口求最长无重复子串")
    ]

    @State private var showErrorAlert = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showAttachmentSheet = false
    @State private var showFileImporter = false
    @State private var showCameraPicker = false
    @State private var isSidebarOpen = false
    @State private var showSettingsSheet = false
    @State private var showTestSheet = false
    @State private var isPinnedToBottom = true
    @State private var starterPromptDeck: [(title: String, subtitle: String)] = []
    @State private var sidebarDragOffset: CGFloat = 0
    @State private var recentAssets: [PHAsset] = []
    @State private var recentThumbnails: [String: UIImage] = [:]
    @State private var sidebarAnimationLock = false
    @FocusState private var isComposerFocused: Bool
    @StateObject private var speechToText = SpeechToTextService(localeIdentifier: "zh-CN")
    @State private var speechDraftPrefix = ""
    @State private var showInitialConfigSheet = false
    @State private var autoFrontendPreview: AutoFrontendPreviewPayload?
    @State private var lastAutoBuiltAssistantMessageID: UUID?
    @State private var noFileDirectiveAssistantIDs: Set<UUID> = []
    @State private var autoBuildEligibleAssistantIDs: Set<UUID> = []
    @State private var autoBuildInFlightAssistantIDs: Set<UUID> = []
    @State private var composerMeasuredHeight: CGFloat = 0
    @State private var composerStableHeight: CGFloat = 58
    @State private var keyboardOverlapHeight: CGFloat = 0
    @State private var headerLeadingWidth: CGFloat = 36
    @State private var headerTrailingWidth: CGFloat = 108
    @State private var transcriptMetrics = ChatTranscriptMetrics()
    @State private var transcriptCommandSequence = 0
    @State private var transcriptCommand: ChatTranscriptCommand?
    @State private var pendingMessageDeletionIDs: Set<UUID> = []
    @State private var pendingMessageDeletionTasks: [UUID: Task<Void, Never>] = [:]
    @State private var pendingOutgoingEcho: OutgoingEcho?
    @State private var autoRotatedSessionIDs: Set<UUID> = []
    @State private var tokenUsageToast: TokenUsageToast?
    @State private var tokenUsageHideTask: Task<Void, Never>?
    @State private var sessionRotateToast: SessionRotateToast?
    @State private var sessionRotateToastTrigger: Int = 0
    @State private var sessionRotateHideTask: Task<Void, Never>?
    @State private var frontendOverlayFileIndex: Int = 0
    @State private var frontendOverlayMessageID: UUID?
    @State private var frontendOverlayManualSelectionUntil: Date = .distantPast
    @State private var activeFrontendCodeViewer: CodeViewerPayload?

    var body: some View {
        ZStack(alignment: .leading) {
            sessionSidebar

            mainContent
                .overlay {
                    if sidebarRevealWidth > 0.01 {
                        Color.black.opacity(0.16 * sidebarRevealProgress)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: 40 * sidebarRevealProgress, style: .continuous)
                )
                .shadow(
                    color: Color.black.opacity(0.16 * sidebarRevealProgress),
                    radius: 22 * sidebarRevealProgress,
                    x: 0,
                    y: 0
                )
                .offset(x: sidebarRevealWidth)
                .zIndex(1)

            if sidebarRevealWidth > 0.01 {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: sidebarWidth)
                        .allowsHitTesting(false)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            setSidebarOpen(false)
                        }
                }
                .ignoresSafeArea()
                .zIndex(3)
            }
        }
        .navigationBarHidden(true)
        .simultaneousGesture(sidebarDragGesture)
        .onChange(of: viewModel.errorMessage) { _, newValue in
            showErrorAlert = !newValue.isEmpty
        }
        .onAppear {
            refreshStarterPromptsIfNeeded()
            ensureRecentPhotoAssets()
            seedAutoFrontendBuildCursor()
            if !hasCompletedInitialConfig {
                showInitialConfigSheet = true
            }
        }
        .onChange(of: viewModel.messages) { oldMessages, newMessages in
            runAutoFrontendBuildIfNeeded(previousMessages: oldMessages, newMessages: newMessages)
            reconcilePendingOutgoingEcho(with: newMessages)
            if !viewModel.isSending, newMessages.count > oldMessages.count {
                maybeAutoRotateLongConversation(using: newMessages)
            }
        }
        .onChange(of: viewModel.tokenUsageFlashTrigger) { _, trigger in
            guard trigger > 0, let usage = viewModel.latestTokenUsage else { return }
            presentTokenUsageToast(usage, trigger: trigger)
        }
        .onChange(of: viewModel.isSending) { _, isSending in
            guard !isSending else { return }
            maybeAutoRotateLongConversation(using: viewModel.messages)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard !viewModel.isSending else { return }
                maybeAutoRotateLongConversation(using: viewModel.messages)
            }
        }
        .onChange(of: transcriptMetrics) { _, metrics in
            guard !viewModel.isSending else { return }
            guard metrics.contentHeight > metrics.viewportHeight + 8 else { return }
            maybeAutoRotateLongConversation(using: viewModel.messages)
        }
        .onChange(of: viewModel.currentSessionID) { _, _ in
            pendingOutgoingEcho = nil
            frontendOverlayMessageID = nil
            frontendOverlayFileIndex = 0
            frontendOverlayManualSelectionUntil = .distantPast
            Self.frontendOverlayCodeEntriesCache.removeAll()
            Self.frontendOverlayCodeEntriesCacheOrder.removeAll()
            DispatchQueue.main.async {
                seedAutoFrontendBuildCursor()
            }
        }
        .onChange(of: viewModel.isPrivateMode) { _, _ in
            pendingOutgoingEcho = nil
            frontendOverlayMessageID = nil
            frontendOverlayFileIndex = 0
            frontendOverlayManualSelectionUntil = .distantPast
            Self.frontendOverlayCodeEntriesCache.removeAll()
            Self.frontendOverlayCodeEntriesCacheOrder.removeAll()
            DispatchQueue.main.async {
                seedAutoFrontendBuildCursor()
            }
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { newValue in
            let clamped = max(0, ceil(newValue))
            if abs(clamped - composerMeasuredHeight) > 0.5 {
                composerMeasuredHeight = clamped
            }
            let inferredComposerOnlyHeight = max(0, clamped - keyboardOverlapHeight)
            let stableCandidate = inferredComposerOnlyHeight >= 36 ? inferredComposerOnlyHeight : clamped
            if stableCandidate >= 36, abs(stableCandidate - composerStableHeight) > 0.5 {
                composerStableHeight = stableCandidate
            }
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                        await MainActor.run {
                            viewModel.addDraftImage(data: data, mimeType: mimeType)
                        }
                    }
                }
                await MainActor.run {
                    selectedPhotoItems = []
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            handleKeyboardFrameNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            updateKeyboardOverlapHeight(0)
        }
        .onChange(of: keyboardOverlapHeight) { _, _ in
            guard isPinnedToBottom else { return }
            issueTranscriptCommand(.scrollToBottom(animated: false))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard isPinnedToBottom else { return }
                issueTranscriptCommand(.scrollToBottom(animated: false))
            }
        }
        .onChange(of: speechToText.transcript) { _, newValue in
            applySpeechTranscript(newValue)
        }
        .onDisappear {
            speechToText.stopRecording()
            cancelPendingMessageDeletionTasks()
            tokenUsageHideTask?.cancel()
            tokenUsageHideTask = nil
            sessionRotateHideTask?.cancel()
            sessionRotateHideTask = nil
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .sheet(isPresented: $showAttachmentSheet) {
            attachmentSheet
                .presentationDetents([.fraction(0.52), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraImagePicker { image in
                if let data = image.jpegData(compressionQuality: 0.9) {
                    viewModel.addDraftImage(data: data, mimeType: "image/jpeg")
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                .item
            ],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("错误", isPresented: $showErrorAlert) {
            Button("确定") {
                viewModel.errorMessage = ""
                showErrorAlert = false
            }
        } message: {
            Text(viewModel.errorMessage)
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                SettingsScreen()
            }
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showTestSheet) {
            NavigationStack {
                TestCenterScreen()
            }
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showInitialConfigSheet) {
            NavigationStack {
                InitialConfigSheet(
                    isPresented: $showInitialConfigSheet,
                    onComplete: {
                        hasCompletedInitialConfig = true
                    }
                )
            }
            .environmentObject(viewModel)
            .interactiveDismissDisabled(true)
        }
        .sheet(item: $autoFrontendPreview) { payload in
            HTMLPreviewSheet(
                title: payload.title,
                html: payload.html,
                baseURL: payload.baseURL,
                entryFileURL: payload.entryFileURL
            )
        }
        .sheet(item: $activeFrontendCodeViewer) { payload in
            CodeViewerSheet(
                payload: payload,
                codeThemeMode: viewModel.config.codeThemeMode
            )
        }
    }

    private var mainContent: some View {
        messageList
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .background(Color(.systemBackground))
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.2)
                    }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ComposerHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color(.secondarySystemBackground).opacity(0.22)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    if let toast = tokenUsageToast {
                        tokenUsageToastView(toast)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let toast = sessionRotateToast {
                        sessionRotateToastView(toast)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 78)
                .padding(.leading, 14)
            }
            .overlay(alignment: .bottomLeading) {
                if let overlay = frontendBuildOverlayState {
                    frontendBuildFloatingCard(overlay)
                        .padding(.leading, 12)
                        .padding(.bottom, max(10, transcriptBottomReservedInset + 10))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("IEXA")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            ZStack {
                HStack(spacing: 10) {
                    headerLeadingControls
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: HeaderLeadingWidthPreferenceKey.self,
                                    value: proxy.size.width
                                )
                            }
                        )

                    Spacer(minLength: 0)

                    headerTrailingControls
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: HeaderTrailingWidthPreferenceKey.self,
                                    value: proxy.size.width
                                )
                            }
                        )
                }
                .zIndex(0)

                headerModelSelector
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, headerCenterHorizontalInset)
                    .zIndex(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .onPreferenceChange(HeaderLeadingWidthPreferenceKey.self) { newValue in
            let width = ceil(newValue)
            if width > 0, abs(width - headerLeadingWidth) > 0.5 {
                headerLeadingWidth = width
            }
        }
        .onPreferenceChange(HeaderTrailingWidthPreferenceKey.self) { newValue in
            let width = ceil(newValue)
            if width > 0, abs(width - headerTrailingWidth) > 0.5 {
                headerTrailingWidth = width
            }
        }
    }

    private var headerCenterHorizontalInset: CGFloat {
        max(headerCenterMinHorizontalInset, max(headerLeadingWidth, headerTrailingWidth) + 10)
    }

    private var headerLeadingControls: some View {
        Button {
            setSidebarOpen(!isSidebarOpen)
        } label: {
            TwoLineMenuIcon()
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .frame(width: 36, alignment: .leading)
    }

    private var headerModelSelector: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isCurrentModelAvailable ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(headerModelName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

            Text(headerModelVendorName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前模型 \(headerModelName)，厂商 \(headerModelVendorName)")
    }

    private var headerModelName: String {
        let model = viewModel.config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "未选择模型" : formatModelDisplayName(model)
    }

    private func formatModelDisplayName(_ raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard !normalized.isEmpty else { return raw }

        let tokens = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return raw }

        return tokens.map { token in
            let lowered = token.lowercased()
            if lowered == "gpt" || lowered == "o1" || lowered == "o3" || lowered == "o4" {
                return lowered.uppercased()
            }
            if lowered.allSatisfy({ $0.isNumber || $0 == "." }) {
                return token
            }
            guard let first = lowered.first else { return token }
            return String(first).uppercased() + String(lowered.dropFirst())
        }
        .joined(separator: " ")
    }

    private var headerModelVendorName: String {
        let model = viewModel.config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let directVendor = detectModelVendor(model)
        if directVendor != "Unknown" {
            return directVendor
        }
        let hostVendor = detectVendorFromAPIURL(viewModel.config.normalizedBaseURL)
        return hostVendor == "Unknown" ? "未知厂商" : hostVendor
    }

    private var headerTrailingControls: some View {
        HStack(spacing: 8) {
            if !viewModel.isNetworkReachable {
                Text("离线")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.red.opacity(0.1))
                    )
            }

            Button {
                viewModel.setPrivateMode(!viewModel.isPrivateMode)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            viewModel.isPrivateMode
                                ? Color(red: 0.14, green: 0.21, blue: 0.38)
                                : Color(.secondarySystemBackground)
                        )

                    Image("PrivateModeIcon")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .opacity(viewModel.isPrivateMode ? 1 : 0.72)
                }
                .frame(width: 36, height: 36)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(
                            viewModel.isPrivateMode
                                ? Color(red: 0.29, green: 0.44, blue: 0.78)
                                : Color.black.opacity(0.1),
                            lineWidth: 0.9
                        )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPrivateMode ? "关闭私密聊天" : "开启私密聊天")

            Menu {
                Button("新建会话", systemImage: "square.and.pencil") {
                    viewModel.createNewSession()
                }
                Button("配置", systemImage: "gearshape") {
                    showSettingsSheet = true
                }
                Button("测试中心", systemImage: "checkmark.circle") {
                    showTestSheet = true
                }
                Divider()
                Button("示例", systemImage: "wand.and.stars") {
                    viewModel.loadDemoContent()
                }
                Button("清空", systemImage: "trash") {
                    viewModel.clearCurrentSessionMessages()
                }
                Button("停止", systemImage: "stop.circle") {
                    viewModel.stopGenerating()
                }
                .disabled(!viewModel.isSending)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 36, alignment: .trailing)
    }

    private func tokenUsageToastView(_ toast: TokenUsageToast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.84))

            Text("Token消耗")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))

            tokenMetricBadge(
                symbol: "arrow.up",
                value: toast.usage.inputTokens,
                tint: .primary.opacity(0.86)
            )
            tokenMetricBadge(
                symbol: "arrow.down",
                value: toast.usage.outputTokens,
                tint: .primary.opacity(0.86)
            )
            tokenMetricBadge(
                symbol: "arrow.up.arrow.down",
                value: toast.usage.cachedTokens,
                tint: .primary.opacity(0.72)
            )

            Button {
                dismissTokenUsageToast()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .padding(.leading, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭 Token 提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.46), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 9, x: 0, y: 4)
    }

    private func tokenMetricBadge(symbol: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(compactTokenCount(value))
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
    }

    private func compactTokenCount(_ value: Int) -> String {
        let safe = max(0, value)
        if safe >= 1_000_000 {
            return String(format: "%.1fm", Double(safe) / 1_000_000.0)
        }
        if safe >= 1_000 {
            return String(format: "%.1fk", Double(safe) / 1_000.0)
        }
        return String(safe)
    }

    private func presentTokenUsageToast(_ usage: ChatTokenUsage, trigger: Int) {
        tokenUsageHideTask?.cancel()
        tokenUsageHideTask = nil

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.1)) {
            tokenUsageToast = TokenUsageToast(trigger: trigger, usage: usage)
        }

        tokenUsageHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            dismissTokenUsageToast()
        }
    }

    private func dismissTokenUsageToast() {
        tokenUsageHideTask?.cancel()
        tokenUsageHideTask = nil
        withAnimation(.easeOut(duration: 0.22)) {
            tokenUsageToast = nil
        }
    }

    private func sessionRotateToastView(_ toast: SessionRotateToast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group.bubble.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.84))

            Text(toast.message)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(2)

            Button {
                dismissSessionRotateToast()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .padding(.leading, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭会话切换提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.46), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 9, x: 0, y: 4)
    }

    private func presentSessionRotateToast(
        _ message: String = "当前对话窗口已上限，已为您创建新的对话窗口"
    ) {
        sessionRotateHideTask?.cancel()
        sessionRotateHideTask = nil
        sessionRotateToastTrigger &+= 1

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.1)) {
            sessionRotateToast = SessionRotateToast(trigger: sessionRotateToastTrigger, message: message)
        }

        sessionRotateHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            dismissSessionRotateToast()
        }
    }

    private func dismissSessionRotateToast() {
        sessionRotateHideTask?.cancel()
        sessionRotateHideTask = nil
        withAnimation(.easeOut(duration: 0.22)) {
            sessionRotateToast = nil
        }
    }


    private var messageList: some View {
        GeometryReader { geometry in
            NativeTranscriptScrollView(
                historyContent: AnyView(transcriptHistoryContent()),
                historyVersion: transcriptHistoryVersion,
                streamingLeadContent: nil,
                streamingLeadSignature: nil,
                streamingMessage: activeStreamingRenderedMessage,
                codeThemeSignature: codeThemeRenderSignature,
                codeThemeMode: viewModel.config.codeThemeMode,
                apiKey: viewModel.config.apiKey,
                apiBaseURL: viewModel.config.normalizedBaseURL,
                shellExecutionEnabled: viewModel.config.shellExecutionEnabled,
                shellExecutionURLString: viewModel.config.shellExecutionURLString,
                shellExecutionTimeout: viewModel.config.shellExecutionTimeout,
                shellExecutionWorkingDirectory: viewModel.config.shellExecutionWorkingDirectory,
                bottomReservedInset: transcriptBottomReservedInset,
                command: transcriptCommand,
                onMetricsChanged: { metrics in
                    if transcriptMetrics != metrics {
                        transcriptMetrics = metrics
                    }
                    if isPinnedToBottom != metrics.isAtBottom {
                        isPinnedToBottom = metrics.isAtBottom
                    }
                }
            )
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .onAppear {
                issueTranscriptCommand(.scrollToBottom(animated: false))
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let lastMessage = viewModel.messages.last else { return }
                if lastMessage.role == .user {
                    isPinnedToBottom = true
                }
                if isPinnedToBottom || lastMessage.role == .user {
                    issueTranscriptCommand(.scrollToBottom(animated: false))
                }
            }
            .onChange(of: viewModel.streamScrollTrigger) { _, _ in
                if isPinnedToBottom && !shouldUseCodeViewportTailFollow {
                    issueTranscriptCommand(.scrollToBottom(animated: false))
                }
            }
            .overlay(alignment: .bottom) {
                if shouldShowCenterScrollDownButton {
                    scrollDownButton()
                        .padding(.bottom, 12)
                }
            }
            .overlay {
                if shouldShowPrivateModeCenterNotice {
                    privateModeCenterNotice
                        .padding(.horizontal, 30)
                        .padding(.bottom, 30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func transcriptHistoryContent() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if isRenderingWindowed {
                renderWindowNotice
            }

            ForEach(frozenRenderedMessages, id: \.id) { message in
                let isLatestAssistant = message.id == latestFrozenAssistantMessageID
                let displayMessage = makeDisplaySafeMessage(message)
                let isDeleting = pendingMessageDeletionIDs.contains(message.id)
                let canDelete = message.role == .assistant && !message.isStreaming

                DissolvingMessageRow(
                    isDeleting: isDeleting,
                    seed: message.id.dissolveSeed
                ) {
                    MessageBubbleView(
                        message: displayMessage,
                        sourceMessage: message,
                        codeThemeMode: viewModel.config.codeThemeMode,
                        apiKey: viewModel.config.apiKey,
                        apiBaseURL: viewModel.config.normalizedBaseURL,
                        shellExecutionEnabled: viewModel.config.shellExecutionEnabled,
                        shellExecutionURLString: viewModel.config.shellExecutionURLString,
                        shellExecutionTimeout: viewModel.config.shellExecutionTimeout,
                        shellExecutionWorkingDirectory: viewModel.config.shellExecutionWorkingDirectory,
                        showsAssistantActionBar: message.role == .assistant && !message.isStreaming && !isDeleting,
                        onRegenerate: (isLatestAssistant
                            && (viewModel.config.endpointMode == .chatCompletions || viewModel.config.endpointMode == .responses)
                            && !viewModel.isPrivateMode) ? {
                            Task { await viewModel.regenerateLastAssistantReply() }
                        } : nil,
                        onDelete: canDelete ? {
                            scheduleAssistantMessageDeletion(message)
                        } : nil
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !viewModel.draftImageAttachments.isEmpty {
                draftImagePreviewStrip
            }

            if let file = viewModel.draftFileAttachment {
                draftFilePreview(file)
            }

            if shouldShowStarterPrompts {
                starterPromptStrip
            }

            HStack(alignment: .center, spacing: 12) {
                Button {
                    showAttachmentSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color(.secondarySystemBackground))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.04), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)

                composerInputContainer
            }
            .padding(.vertical, 2)
            .padding(.leading, 0)
            .padding(.trailing, 0)
            .background(Color.clear)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider().opacity(0.18)
        }
    }

    private var composerInputContainer: some View {
        HStack(alignment: .center, spacing: 10) {
            textInputArea

            Button {
                if viewModel.isSending {
                    viewModel.stopGenerating()
                } else if shouldUseVoicePrimaryAction {
                    if speechToText.isRecording {
                        stopVoiceTranscription()
                    } else {
                        Task { await startVoiceTranscription() }
                    }
                } else {
                    if speechToText.isRecording {
                        stopVoiceTranscription()
                    }
                    sendCurrentComposerMessage()
                }
            } label: {
                Group {
                    if viewModel.isSending {
                        Image(systemName: "stop.fill")
                    } else if shouldUseVoicePrimaryAction {
                        Image(systemName: speechToText.isRecording ? "waveform" : "waveform.path")
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(canTapPrimaryComposerButton ? Color.black : Color(.systemGray3))
                )
            }
            .disabled(!canTapPrimaryComposerButton)
        }
        .frame(minHeight: 34)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(viewModel.isPrivateMode ? Color.black : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(viewModel.isPrivateMode ? Color.white.opacity(0.18) : Color.black.opacity(0.04), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.025), radius: 6, x: 0, y: 2)
    }

    private var textInputArea: some View {
        TextField(
            "",
            text: $viewModel.draftMessage,
            prompt: Text(composerPlaceholderText)
                .foregroundColor(composerPlaceholderColor),
            axis: .vertical
        )
            .lineLimit(1...6)
            .submitLabel(.send)
            .focused($isComposerFocused)
            .onSubmit {
                guard viewModel.canSend else { return }
                sendCurrentComposerMessage()
            }
            .font(.system(size: 15))
            .foregroundStyle(viewModel.isPrivateMode ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
    }

    private var composerPlaceholderColor: Color {
        viewModel.isPrivateMode ? Color.white.opacity(0.88) : Color.secondary
    }

    private var composerPlaceholderText: String {
        let transcript = speechToText.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if speechToText.isRecording && transcript.isEmpty {
            return "请说话"
        }
        if viewModel.isPrivateMode {
            return "私密聊天，内容不会保存"
        }
        return "有问题，尽管问"
    }

    private var shouldUseVoicePrimaryAction: Bool {
        if viewModel.config.endpointMode == .models { return false }
        if viewModel.isSending { return false }
        let trimmed = viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            && viewModel.draftImageAttachments.isEmpty
            && viewModel.draftFileAttachment == nil
    }

    private var shouldShowStarterPrompts: Bool {
        guard viewModel.messages.isEmpty else { return false }
        return viewModel.draftMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var canTapPrimaryComposerButton: Bool {
        viewModel.isSending || shouldUseVoicePrimaryAction || viewModel.canSend
    }

    private func seedAutoFrontendBuildCursor() {
        lastAutoBuiltAssistantMessageID = viewModel.messages
            .last(where: { $0.role == .assistant })?
            .id
        let currentAssistantIDs = Set(viewModel.messages.compactMap { message in
            message.role == .assistant ? message.id : nil
        })
        noFileDirectiveAssistantIDs.formIntersection(currentAssistantIDs)
        autoBuildEligibleAssistantIDs.formIntersection(currentAssistantIDs)
        autoBuildInFlightAssistantIDs.formIntersection(currentAssistantIDs)
    }

    private func runAutoFrontendBuildIfNeeded(
        previousMessages: [ChatMessage],
        newMessages: [ChatMessage]
    ) {
        guard shouldAutoBuildFrontendFromAssistantReply else {
            autoBuildInFlightAssistantIDs.removeAll()
            return
        }
        guard let latestAssistant = newMessages.last(where: { $0.role == .assistant }) else { return }

        if shouldSkipAutoProjectBuild(for: latestAssistant, in: newMessages) {
            noFileDirectiveAssistantIDs.insert(latestAssistant.id)
            autoBuildEligibleAssistantIDs.remove(latestAssistant.id)
            autoBuildInFlightAssistantIDs.remove(latestAssistant.id)
            autoFrontendPreview = nil
            if !latestAssistant.isStreaming {
                viewModel.statusMessage = "已按要求仅展示代码（未生成项目文件）"
            }
            return
        }

        let shouldAttemptBuild =
            shouldAttemptAutoProjectBuild(for: latestAssistant, in: newMessages)
            || assistantContainsExplicitProjectPayload(latestAssistant)

        if latestAssistant.isStreaming {
            if shouldAttemptBuild {
                autoBuildInFlightAssistantIDs.insert(latestAssistant.id)
                noFileDirectiveAssistantIDs.remove(latestAssistant.id)
            } else {
                autoBuildInFlightAssistantIDs.remove(latestAssistant.id)
            }
            return
        }

        autoBuildInFlightAssistantIDs.remove(latestAssistant.id)
        guard latestAssistant.id != lastAutoBuiltAssistantMessageID else { return }

        let previousVersion = previousMessages.first(where: { $0.id == latestAssistant.id })
        if let previousVersion, previousVersion.isStreaming == false {
            lastAutoBuiltAssistantMessageID = latestAssistant.id
            return
        }

        lastAutoBuiltAssistantMessageID = latestAssistant.id

        if !shouldAttemptBuild {
            noFileDirectiveAssistantIDs.insert(latestAssistant.id)
            autoBuildEligibleAssistantIDs.remove(latestAssistant.id)
            autoBuildInFlightAssistantIDs.remove(latestAssistant.id)
            autoFrontendPreview = nil
            return
        }
        noFileDirectiveAssistantIDs.remove(latestAssistant.id)

        guard FrontendProjectBuilder.canGenerateProject(from: latestAssistant) else {
            autoBuildEligibleAssistantIDs.remove(latestAssistant.id)
            return
        }

        do {
            let result = try FrontendProjectBuilder.buildProject(
                from: latestAssistant,
                mode: .overwriteLatestProject
            )
            autoBuildEligibleAssistantIDs.insert(latestAssistant.id)
            autoBuildInFlightAssistantIDs.remove(latestAssistant.id)
            if result.shouldAutoOpenPreview {
                autoFrontendPreview = AutoFrontendPreviewPayload(
                    title: "自动预览 · \(result.entryFileURL.lastPathComponent)",
                    html: result.entryHTML,
                    baseURL: result.projectDirectoryURL,
                    entryFileURL: result.entryFileURL
                )
                viewModel.statusMessage = "项目已自动更新并预览（\(result.writtenRelativePaths.count) 文件）"
            } else {
                autoFrontendPreview = nil
                viewModel.statusMessage = "项目文件已自动落盘（\(result.writtenRelativePaths.count) 文件）"
            }
        } catch {
            // Auto mode should stay non-blocking; report status but avoid interrupting chat.
            autoBuildEligibleAssistantIDs.remove(latestAssistant.id)
            autoBuildInFlightAssistantIDs.remove(latestAssistant.id)
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            viewModel.statusMessage = "项目自动落盘失败：\(reason)"
        }
    }

    private func shouldSkipAutoProjectBuild(for assistant: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == assistant.id }), index > 0 else {
            return false
        }
        let prefix = messages[..<index]
        guard let latestUser = prefix.last(where: { $0.role == .user }) else {
            return false
        }
        return containsNoFileDirective(latestUser.content)
    }

    private func shouldAttemptAutoProjectBuild(for assistant: ChatMessage, in messages: [ChatMessage]) -> Bool {
        if assistantContainsExplicitProjectPayload(assistant) {
            return true
        }

        guard let index = messages.firstIndex(where: { $0.id == assistant.id }), index > 0 else {
            return false
        }
        let prefix = messages[..<index]
        guard let latestUser = prefix.last(where: { $0.role == .user }) else {
            return false
        }
        return containsProjectBuildIntent(latestUser.content)
    }

    private func assistantContainsExplicitProjectPayload(_ assistant: ChatMessage) -> Bool {
        let normalized = assistant.content.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.range(
            of: #"\[\[file:(.+?)\]\]"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        return assistant.fileAttachments.contains { attachment in
            attachment.binaryBase64 == nil
                && !attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !attachment.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func containsProjectBuildIntent(_ raw: String) -> Bool {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return false }
        if containsNoFileDirective(normalized) { return false }

        let intentMarkers = [
            "生成项目",
            "创建项目",
            "项目结构",
            "工程结构",
            "完整项目",
            "完整工程",
            "搭建项目",
            "初始化项目",
            "初始化工程",
            "脚手架",
            "仓库结构",
            "目录结构",
            "模块划分",
            "多文件",
            "多模块",
            "生成代码文件",
            "输出文件结构",
            "按[[file:",
            "写入latest",
            "自动落盘",
            "服务端项目",
            "后端项目",
            "api项目",
            "命令行工具",
            "cli工具",
            "sdk项目",
            "库项目",
            "project",
            "codebase",
            "scaffold",
            "boilerplate",
            "starter template",
            "multi module",
            "repository structure",
            "directory structure",
            "backend project",
            "api service",
            "cli project",
            "library project",
            "sdk project",
            "generate project",
            "create project",
            "build project",
            "multi-file",
            "repo structure"
        ]

        if intentMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        if containsLanguageProjectIntent(normalized) {
            return true
        }

        if normalized.range(
            of: #"(做|写|搭|建|生成|创建|开发|搞|初始化)(一个|个|套)?[^\n]{0,28}(网站|网页|页面|项目|前端|应用|app|demo|登录页|注册页|后台|服务|接口|api|后端|脚手架|命令行|cli|工具|sdk|库|package|模块|机器人|爬虫|微服务)"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        if normalized.range(
            of: #"(网站|网页|页面|项目|前端|应用|app|demo|登录页|注册页|后台|服务|接口|api|后端|脚手架|命令行|cli|工具|sdk|库|package|模块|机器人|爬虫|微服务)[^\n]{0,20}(做|写|搭|建|生成|创建|开发|搞|初始化)"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    private func containsLanguageProjectIntent(_ raw: String) -> Bool {
        let languages = [
            "python", "py", "java", "kotlin", "swift", "go", "golang", "rust",
            "c#", "csharp", "c++", "cpp", "c语言", "node", "nodejs", "typescript",
            "javascript", "js", "php", "ruby", "scala", "dart", "lua", "sql"
        ]
        let nouns = [
            "项目", "工程", "脚手架", "模板", "服务", "后端", "接口", "api",
            "命令行", "cli", "工具", "sdk", "库", "模块", "包", "微服务", "机器人", "爬虫"
        ]

        for language in languages {
            for noun in nouns {
                if raw.contains("\(language)\(noun)") || raw.contains("\(noun)\(language)") {
                    return true
                }
            }
        }

        if raw.range(
            of: #"\b(rust|go|golang|java|kotlin|swift|python|php|ruby|scala|dart|lua|typescript|javascript|node|nodejs|csharp|c#|cpp|c\+\+)\b[^\n]{0,24}\b(project|service|backend|api|cli|tool|sdk|library|package|scaffold|template|boilerplate)\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if raw.range(
            of: #"\b(project|service|backend|api|cli|tool|sdk|library|package|scaffold|template|boilerplate)\b[^\n]{0,24}\b(rust|go|golang|java|kotlin|swift|python|php|ruby|scala|dart|lua|typescript|javascript|node|nodejs|csharp|c#|cpp|c\+\+)\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    private func containsNoFileDirective(_ raw: String) -> Bool {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return false }

        let directiveMarkers = [
            "不做成文件",
            "不要做成文件",
            "别做成文件",
            "不要生成文件",
            "别生成文件",
            "不生成文件",
            "不要落盘",
            "别落盘",
            "不落盘",
            "不要写入文件",
            "不要写入latest",
            "只要代码",
            "仅要代码",
            "仅展示代码",
            "只展示代码",
            "不要项目",
            "别做项目",
            "不创建项目",
            "不用项目结构",
            "do not create file",
            "do not create files",
            "don't create file",
            "don't create files",
            "do not write file",
            "do not write files",
            "don't write file",
            "don't write files",
            "inline code only",
            "just show code",
            "code only",
            "single snippet",
            "no files"
        ]

        return directiveMarkers.contains { normalized.contains($0) }
    }


    private func scrollDownButton() -> some View {
        Button {
            issueTranscriptCommand(.pageDown)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(Color(.systemBackground))
                        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                )
        }
        .buttonStyle(.plain)
    }

    private var starterPromptStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("编程推荐")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("换一批") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        refreshStarterPrompts(force: true)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(activeStarterPrompts.enumerated()), id: \.offset) { _, prompt in
                        Button {
                            sendStarterPrompt(prompt)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(prompt.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(prompt.subtitle)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 168, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
        }
    }



    private var attachmentSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("IEXA")
                        .font(.system(size: 21, weight: .bold))
                    Spacer()
                    Button("全部照片") {
                        showAttachmentSheet = false
                        showPhotoPicker = true
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.blue)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Button {
                            startCameraFromAttachmentSheet()
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                                    .frame(width: 92, height: 92)
                                Image(systemName: "camera")
                                    .font(.system(size: 30, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        ForEach(recentAssets, id: \.localIdentifier) { asset in
                            Button {
                                Task { await pickRecentAsset(asset) }
                            } label: {
                                if let image = recentThumbnails[asset.localIdentifier] {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 92, height: 92)
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                        .frame(width: 92, height: 92)
                                        .overlay {
                                            ProgressView()
                                        }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider()
                    .opacity(0.5)

                VStack(alignment: .leading, spacing: 14) {
                    quickToolRow(icon: "photo.on.rectangle.angled", title: "发送图片", subtitle: "从相册选择照片") {
                        showAttachmentSheet = false
                        showPhotoPicker = true
                    }
                    quickToolRow(icon: "camera", title: "拍照发送", subtitle: "打开相机立即拍摄") {
                        startCameraFromAttachmentSheet()
                    }
                    quickToolRow(icon: "doc.text", title: "发送文件", subtitle: "上传任意单文件（自动解码）") {
                        showAttachmentSheet = false
                        showFileImporter = true
                    }
                    quickToolRow(icon: "paperplane", title: "粘贴并发送", subtitle: "快速发送剪贴板文本") {
                        showAttachmentSheet = false
                        pasteClipboardIntoDraft(sendAfterPaste: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .onAppear {
                ensureRecentPhotoAssets()
            }
        }
    }

    private func quickToolRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var activeStarterPrompts: [(title: String, subtitle: String)] {
        if starterPromptDeck.isEmpty {
            return Array(starterPrompts.prefix(4))
        }
        return starterPromptDeck
    }

    private var shouldShowScrollJumpButtons: Bool {
        let assistantMessages = viewModel.messages.filter { $0.role == .assistant }
        let maxLength = assistantMessages.map { $0.content.count }.max() ?? 0
        let totalLength = assistantMessages.reduce(0) { $0 + $1.content.count }
        return maxLength >= 380 || totalLength >= 1200
    }

    private var shouldShowCenterScrollDownButton: Bool {
        shouldShowScrollJumpButtons && transcriptMetrics.canScroll && !isPinnedToBottom
    }

    private var shouldShowPrivateModeCenterNotice: Bool {
        viewModel.isPrivateMode && viewModel.messages.isEmpty
    }

    private var privateModeCenterNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "ghost")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.85))

            Text("私密聊天")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)

            Text("此聊天不会出现在历史记录中，并将被彻底删除")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: 320)
    }

    private var latestAssistantMessageID: UUID? {
        viewModel.messages.last(where: { $0.role == .assistant })?.id
    }

    private var latestFrozenAssistantMessageID: UUID? {
        frozenRenderedMessages.last(where: { $0.role == .assistant })?.id
    }

    private var displayMessages: [ChatMessage] {
        if let echo = pendingOutgoingEchoMessage {
            return viewModel.messages + [echo]
        }
        return viewModel.messages
    }

    private var renderedMessages: [ChatMessage] {
        let source = displayMessages
        guard !source.isEmpty else { return [] }

        var forceIncludeIDs = Set<UUID>()
        if let last = source.last {
            forceIncludeIDs.insert(last.id)
            if last.role == .assistant, source.count >= 2 {
                let previous = source[source.count - 2]
                if previous.role == .user {
                    forceIncludeIDs.insert(previous.id)
                }
            }
        }

        var selected: [ChatMessage] = []
        var budget = 0

        for message in source.reversed() {
            let weight = renderWeight(for: message)
            let shouldForceInclude = forceIncludeIDs.contains(message.id)
            if !selected.isEmpty &&
                !shouldForceInclude &&
                (selected.count >= maxRenderedMessages || budget + weight > maxRenderedCharacters) {
                break
            }
            selected.append(message)
            budget += weight
        }

        return Array(selected.reversed())
    }

    private var activeStreamingRenderedMessage: ChatMessage? {
        guard let last = renderedMessages.last,
              last.role == .assistant,
              last.isStreaming else {
            return nil
        }
        return makeDisplaySafeMessage(last, preserveStreamingState: true)
    }

    private var activeStreamingLeadUserMessage: ChatMessage? {
        guard let active = activeStreamingRenderedMessage else {
            return nil
        }
        guard let activeIndex = displayMessages.lastIndex(where: { $0.id == active.id }),
              activeIndex > 0 else {
            return nil
        }
        let candidate = makeDisplaySafeMessage(displayMessages[activeIndex - 1])
        return candidate.role == .user ? candidate : nil
    }

    private var activeStreamingLeadSignature: String? {
        separateStreamingLeadUserMessage.map {
            "\($0.id.uuidString)|\($0.content.count)|\($0.imageAttachments.count)|\($0.videoAttachments.count)|\($0.fileAttachments.count)|\(codeThemeRenderSignature)"
        }
    }

    private var pendingOutgoingEchoMessage: ChatMessage? {
        guard let echo = pendingOutgoingEcho else { return nil }
        guard !hasMatchingUserMessage(for: echo, in: viewModel.messages) else { return nil }
        let fileAttachments = echo.fileAttachment.map { [$0] } ?? []
        return ChatMessage(
            id: echo.id,
            role: .user,
            content: echo.content,
            createdAt: echo.createdAt,
            imageAttachments: echo.imageAttachments,
            fileAttachments: fileAttachments
        )
    }

    private var separateStreamingLeadUserMessage: ChatMessage? {
        guard let lead = activeStreamingLeadUserMessage else { return nil }
        if frozenRenderedMessages.contains(where: { $0.id == lead.id }) {
            return nil
        }
        return lead
    }

    private var codeThemeRenderSignature: String {
        let resolvedAppearance: String
        switch viewModel.config.codeThemeMode {
        case .vscodeDark:
            resolvedAppearance = "dark"
        case .githubLight:
            resolvedAppearance = "light"
        case .followApp:
            resolvedAppearance = colorScheme == .dark ? "dark" : "light"
        }
        return "\(viewModel.config.codeThemeMode.rawValue)|\(resolvedAppearance)"
    }

    private var shouldUseCodeViewportTailFollow: Bool {
        guard let active = activeStreamingRenderedMessage else { return false }
        let normalized = active.content.lowercased()
        if normalized.contains("```") || normalized.contains("[[file:") {
            return true
        }
        return false
    }

    private var activeStreamingLeadContent: AnyView? {
        guard let leadUser = separateStreamingLeadUserMessage else { return nil }
        return AnyView(
            MessageBubbleView(
                message: leadUser,
                codeThemeMode: viewModel.config.codeThemeMode,
                apiKey: viewModel.config.apiKey,
                apiBaseURL: viewModel.config.normalizedBaseURL,
                shellExecutionEnabled: viewModel.config.shellExecutionEnabled,
                shellExecutionURLString: viewModel.config.shellExecutionURLString,
                shellExecutionTimeout: viewModel.config.shellExecutionTimeout,
                shellExecutionWorkingDirectory: viewModel.config.shellExecutionWorkingDirectory,
                showsAssistantActionBar: false,
                onRegenerate: nil
            )
            .padding(.horizontal, 18)
        )
    }

    private var frozenRenderedMessages: [ChatMessage] {
        guard let activeStreamingRenderedMessage,
              renderedMessages.last?.id == activeStreamingRenderedMessage.id else {
            return renderedMessages
        }
        return Array(renderedMessages.dropLast())
    }

    private var isRenderingWindowed: Bool {
        renderedMessages.count < displayMessages.count
    }

    private var transcriptHistoryVersion: String {
        let ids = frozenRenderedMessages.map(\.id.uuidString).joined(separator: ",")
        let lengths = frozenRenderedMessages.map { String($0.content.count) }.joined(separator: ",")
        let attachments = frozenRenderedMessages
            .map { "\($0.imageAttachments.count)-\($0.videoAttachments.count)-\($0.fileAttachments.count)" }
            .joined(separator: ",")
        let windowFlag = isRenderingWindowed ? "1" : "0"
        let deletingIDs = pendingMessageDeletionIDs
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
        return "\(windowFlag)|\(ids)|\(lengths)|\(attachments)|\(deletingIDs)|\(codeThemeRenderSignature)"
    }

    private var transcriptBottomReservedInset: CGFloat {
        let measured = max(0, composerMeasuredHeight)
        let stable = max(44, composerStableHeight)
        let keyboard = max(0, keyboardOverlapHeight)
        guard keyboard > 0 else { return max(stable, measured) }

        // Keyboard transition can temporarily inflate measured inset; normalize to composer-only height.
        let candidateWithoutKeyboard = measured - keyboard
        if candidateWithoutKeyboard >= 24 {
            return max(stable, candidateWithoutKeyboard)
        }

        if measured > stable + 48 {
            return stable
        }
        return max(stable, measured)
    }

    private func handleKeyboardFrameNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let endFrameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }

        let endFrame = endFrameValue.cgRectValue
        let screenHeight = UIScreen.main.bounds.height
        let safeBottom = currentWindowSafeAreaBottomInset()
        let overlap = max(0, screenHeight - endFrame.minY - safeBottom)
        updateKeyboardOverlapHeight(overlap)
    }

    private func updateKeyboardOverlapHeight(_ value: CGFloat) {
        let normalized = max(0, value)
        if abs(normalized - keyboardOverlapHeight) > 0.5 {
            keyboardOverlapHeight = normalized
        }
    }

    private func currentWindowSafeAreaBottomInset() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    private var renderWindowNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
            Text("会话较长，已仅渲染最近 \(renderedMessages.count) 条消息以保持稳定")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func makeDisplaySafeMessage(_ message: ChatMessage, preserveStreamingState: Bool = false) -> ChatMessage {
        var safe = message

        if let masked = frontendProgressDisplayMessage(for: safe) {
            safe = masked
        }

        let hasCodeLikePayload = safe.content.contains("```") || safe.content.contains("[[file:")
        let singleMessageLimit = hasCodeLikePayload
            ? maxSingleRenderedCodeMessageChars
            : maxSingleRenderedMessageChars

        if safe.content.count > singleMessageLimit {
            safe.content = clippedContentForRender(
                safe.content,
                limit: singleMessageLimit
            )
            if !preserveStreamingState {
                safe.isStreaming = false
            }
        }

        if !safe.fileAttachments.isEmpty {
            safe.fileAttachments = safe.fileAttachments.map { file in
                var clipped = file
                if clipped.textContent.count > maxRenderedFilePreviewChars {
                    clipped.textContent = String(clipped.textContent.prefix(maxRenderedFilePreviewChars))
                        + "\n\n[附件预览过长，已截断显示。]"
                }
                return clipped
            }
        }

        return safe
    }

    private func clippedContentForRender(_ raw: String, limit: Int) -> String {
        guard raw.count > limit else { return raw }

        var clipped = String(raw.prefix(limit))
        let fenceCount = clipped.components(separatedBy: "```").count - 1
        if fenceCount % 2 == 1 {
            clipped += "\n```"
        }
        return clipped + "\n\n[该消息过长，已在聊天页截断显示。]"
    }

    private func frontendProgressDisplayMessage(for message: ChatMessage) -> ChatMessage? {
        guard shouldHideFrontendCodeInChat else { return nil }
        guard message.role == .assistant else { return nil }
        guard shouldMaskFrontendCode(for: message, in: viewModel.messages) else { return nil }
        guard !noFileDirectiveAssistantIDs.contains(message.id) else { return nil }
        guard !message.isImageGenerationPlaceholder, !message.isVideoGenerationPlaceholder else { return nil }

        var masked = message
        masked.fileAttachments = []
        let stripped = stripFrontendProjectPayload(from: message.content)
        if !stripped.isEmpty {
            masked.content = stripped
            return masked
        }

        let codeEntries = frontendOverlayCodeEntries(from: message)
        let detectedCount = max(
            codeEntries.count,
            FrontendProjectBuilder.chatProgressSnapshot(from: message)?.detectedFileCount ?? 0
        )

        if message.isStreaming {
            if let current = codeEntries.last {
                masked.content = "正在后台生成项目文件（\(max(detectedCount, 1)) 个）· 当前：\(current.name)"
            } else {
                masked.content = "正在后台生成项目文件，请稍候…"
            }
        } else {
            let hasPreview = FrontendProjectBuilder.latestEntryFileURL() != nil
            if let current = codeEntries.last {
                masked.content = hasPreview
                    ? "项目文件已在后台写入完成（共 \(max(detectedCount, 1)) 个文件），最新文件：\(current.name)。可在左下角卡片继续预览或查看代码。"
                    : "项目文件已在后台写入完成（共 \(max(detectedCount, 1)) 个文件），最新文件：\(current.name)。"
            } else {
                masked.content = hasPreview
                    ? "项目文件已在后台写入完成，可在左下角卡片点击预览。"
                    : "项目文件已在后台写入完成。"
            }
        }
        return masked
    }

    private var shouldHideFrontendCodeInChat: Bool {
        true
    }

    private func shouldMaskFrontendCode(for message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard shouldHideFrontendCodeInChat else { return false }
        guard message.role == .assistant else { return false }
        guard !noFileDirectiveAssistantIDs.contains(message.id) else { return false }

        if assistantContainsExplicitProjectPayload(message) {
            return true
        }
        if autoBuildEligibleAssistantIDs.contains(message.id) {
            return true
        }
        if autoBuildInFlightAssistantIDs.contains(message.id) {
            return true
        }
        return FrontendProjectBuilder.canGenerateProject(from: message)
            && shouldAttemptAutoProjectBuild(for: message, in: messages)
    }

    private var frontendBuildOverlayState: FrontendBuildOverlayState? {
        guard shouldHideFrontendCodeInChat else { return nil }
        guard let assistant = viewModel.messages.last(where: { $0.role == .assistant }) else { return nil }
        guard shouldMaskFrontendCode(for: assistant, in: viewModel.messages) else { return nil }
        guard !assistant.isImageGenerationPlaceholder, !assistant.isVideoGenerationPlaceholder else { return nil }

        let snapshot = FrontendProjectBuilder.chatProgressSnapshot(from: assistant)
            ?? FrontendProjectBuilder.ChatProgressSnapshot(
                detectedFileCount: 0,
                hasEntryHTML: false
            )
        let codeEntries = frontendOverlayCodeEntries(from: assistant)
        let detectedFileCount = max(snapshot.detectedFileCount, codeEntries.count)

        let totalSteps = 4
        let stepIndex: Int
        let title: String
        let subtitle: String
        if assistant.isStreaming {
            if detectedFileCount <= 0 {
                stepIndex = 1
                title = "解析文件结构"
            } else if detectedFileCount <= 1 {
                stepIndex = 2
                title = "生成项目代码"
            } else {
                stepIndex = 3
                title = "写入 latest 目录"
            }
            subtitle = "后台自动写入 · \(max(detectedFileCount, 1)) 个文件"
        } else {
            stepIndex = totalSteps
            title = snapshot.hasEntryHTML ? "准备入口预览" : "整理项目索引"
            subtitle = "后台写入完成 · \(max(detectedFileCount, 1)) 个文件"
        }

        return FrontendBuildOverlayState(
            messageID: assistant.id,
            title: title,
            subtitle: subtitle,
            stepIndex: stepIndex,
            stepTotal: totalSteps,
            fileCount: max(detectedFileCount, 1),
            hasEntryPreview: snapshot.hasEntryHTML || FrontendProjectBuilder.latestEntryFileURL() != nil,
            isCompleted: !assistant.isStreaming,
            codeEntries: codeEntries
        )
    }

    private func frontendBuildFloatingCard(_ overlay: FrontendBuildOverlayState) -> some View {
        let selectedEntry = frontendOverlaySelectedEntry(for: overlay)
        let safeFileIndex = frontendOverlaySafeFileIndex(for: overlay)
        let totalFiles = max(overlay.codeEntries.count, 1)

        return HStack(alignment: .bottom, spacing: 10) {
            Button {
                openFrontendOverlayCodeViewer(overlay)
            } label: {
                frontendBuildMiniPreviewTile(entry: selectedEntry)
            }
            .buttonStyle(.plain)
            .disabled(selectedEntry == nil)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: overlay.isCompleted ? "checkmark.circle.fill" : "doc.badge.gearshape.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(overlay.isCompleted ? Color.green : Color.blue)
                    Text(overlay.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        moveFrontendOverlayFile(by: -1, overlay: overlay)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                frontendOverlayCanMove(by: -1, overlay: overlay)
                                    ? Color.secondary
                                    : Color.secondary.opacity(0.45)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!frontendOverlayCanMove(by: -1, overlay: overlay))

                    Text("\(safeFileIndex + 1)/\(totalFiles)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        moveFrontendOverlayFile(by: 1, overlay: overlay)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                frontendOverlayCanMove(by: 1, overlay: overlay)
                                    ? Color.secondary
                                    : Color.secondary.opacity(0.45)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!frontendOverlayCanMove(by: 1, overlay: overlay))
                }

                Text(frontendOverlaySubtitle(overlay: overlay, selectedEntry: selectedEntry))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: Double(overlay.stepIndex), total: Double(overlay.stepTotal))
                    .progressViewStyle(.linear)
                    .tint(overlay.isCompleted ? Color.green : Color.blue)

                HStack(spacing: 10) {
                    if !overlay.codeEntries.isEmpty {
                        Button {
                            openFrontendOverlayCodeViewer(overlay)
                        } label: {
                            Text("查看代码")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color(red: 0.08, green: 0.45, blue: 0.90))
                        }
                        .buttonStyle(.plain)
                    }

                    if overlay.isCompleted && overlay.hasEntryPreview {
                        Button {
                            openLatestProjectPreviewFromFloatingCard()
                        } label: {
                            HStack(spacing: 4) {
                                Text("👉")
                                Text("预览入口")
                                    .underline()
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.08, green: 0.45, blue: 0.90))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 336, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.2 : 0.45), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.12), radius: 10, x: 0, y: 4)
        .onAppear {
            syncFrontendOverlayFileIndex(for: overlay)
        }
        .onChange(of: overlay.messageID) { _, _ in
            syncFrontendOverlayFileIndex(for: overlay)
        }
        .onChange(of: overlay.codeEntries.count) { _, _ in
            syncFrontendOverlayFileIndex(for: overlay)
        }
    }

    private func frontendBuildMiniPreviewTile(entry: CodeViewerEntry?) -> some View {
        let previewText = frontendOverlayPreviewSnippet(for: entry?.content ?? "")
        let highlighted = CodeHighlighter.highlighted(
            previewText,
            language: entry?.language,
            colorScheme: colorScheme,
            codeThemeMode: viewModel.config.codeThemeMode
        )

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.12, blue: 0.22),
                            Color(red: 0.05, green: 0.06, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.name ?? "准备中…")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.78))

                if previewText.isEmpty {
                    Text("正在读取项目代码…")
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cyan.opacity(0.92))
                } else {
                    Text(highlighted)
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
        .frame(width: 96, height: 76)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 5, x: 0, y: 2)
    }

    private func frontendOverlaySubtitle(
        overlay: FrontendBuildOverlayState,
        selectedEntry: CodeViewerEntry?
    ) -> String {
        if let selectedEntry {
            return "\(overlay.subtitle) · \(selectedEntry.name)"
        }
        return overlay.subtitle
    }

    private func frontendOverlaySafeFileIndex(for overlay: FrontendBuildOverlayState) -> Int {
        guard !overlay.codeEntries.isEmpty else { return 0 }
        return min(max(frontendOverlayFileIndex, 0), overlay.codeEntries.count - 1)
    }

    private func frontendOverlaySelectedEntry(for overlay: FrontendBuildOverlayState) -> CodeViewerEntry? {
        guard !overlay.codeEntries.isEmpty else { return nil }
        return overlay.codeEntries[frontendOverlaySafeFileIndex(for: overlay)]
    }

    private func frontendOverlayCanMove(by delta: Int, overlay: FrontendBuildOverlayState) -> Bool {
        guard !overlay.codeEntries.isEmpty else { return false }
        let target = frontendOverlaySafeFileIndex(for: overlay) + delta
        return target >= 0 && target < overlay.codeEntries.count
    }

    private func moveFrontendOverlayFile(by delta: Int, overlay: FrontendBuildOverlayState) {
        guard frontendOverlayCanMove(by: delta, overlay: overlay) else { return }
        let target = frontendOverlaySafeFileIndex(for: overlay) + delta
        frontendOverlayFileIndex = min(max(target, 0), max(0, overlay.codeEntries.count - 1))
        frontendOverlayManualSelectionUntil = Date().addingTimeInterval(8)
    }

    private func syncFrontendOverlayFileIndex(for overlay: FrontendBuildOverlayState) {
        let maxIndex = max(0, overlay.codeEntries.count - 1)

        if frontendOverlayMessageID != overlay.messageID {
            frontendOverlayMessageID = overlay.messageID
            frontendOverlayFileIndex = maxIndex
            return
        }

        frontendOverlayFileIndex = min(max(frontendOverlayFileIndex, 0), maxIndex)

        if overlay.isCompleted {
            frontendOverlayManualSelectionUntil = .distantPast
            return
        }

        if Date() >= frontendOverlayManualSelectionUntil {
            frontendOverlayFileIndex = maxIndex
        }
    }

    private func openFrontendOverlayCodeViewer(_ overlay: FrontendBuildOverlayState) {
        guard !overlay.codeEntries.isEmpty else { return }
        activeFrontendCodeViewer = CodeViewerPayload(
            title: "项目代码",
            entries: overlay.codeEntries,
            initialIndex: frontendOverlaySafeFileIndex(for: overlay)
        )
    }

    private func frontendOverlayPreviewSnippet(for content: String) -> String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        var collected: [String] = []
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let clipped = line.count > 34 ? String(line.prefix(34)) + "…" : line
            collected.append(clipped)
            if collected.count >= 3 {
                break
            }
        }

        if collected.isEmpty {
            return normalized.count > 80 ? String(normalized.prefix(80)) + "…" : normalized
        }
        return collected.joined(separator: "\n")
    }

    private func frontendOverlayCodeEntries(from message: ChatMessage) -> [CodeViewerEntry] {
        let signature = frontendOverlayCodeEntriesSignature(for: message)
        if let cached = Self.frontendOverlayCodeEntriesCache[message.id], cached.signature == signature {
            return cached.entries
        }

        let segments = MessageContentParser.parse(message)
        var entries: [CodeViewerEntry] = []
        var snippetIndex = 1

        for segment in segments {
            switch segment {
            case .file(let name, let language, let content):
                let normalized = removeRenderTruncationMarkers(from: content)
                guard !normalized.isEmpty else { continue }
                entries.append(
                    CodeViewerEntry(
                        name: name,
                        language: language,
                        content: normalized
                    )
                )
            case .code(let language, let content):
                let normalized = removeRenderTruncationMarkers(from: content)
                guard !normalized.isEmpty else { continue }
                entries.append(
                    CodeViewerEntry(
                        name: frontendOverlaySnippetName(language: language, index: snippetIndex),
                        language: language,
                        content: normalized
                    )
                )
                snippetIndex += 1
            default:
                continue
            }
        }

        var seen = Set<String>()
        var deduped: [CodeViewerEntry] = []
        for entry in entries {
            let contentPrefixHash = String(entry.content.prefix(180)).hashValue
            let contentSuffixHash = String(entry.content.suffix(180)).hashValue
            let key = "\(entry.name.lowercased())|\((entry.language ?? "").lowercased())|\(entry.content.count)|\(contentPrefixHash)|\(contentSuffixHash)"
            if seen.insert(key).inserted {
                deduped.append(entry)
            }
        }

        Self.frontendOverlayCodeEntriesCache[message.id] = FrontendOverlayCodeEntriesCacheEntry(
            signature: signature,
            entries: deduped
        )
        Self.frontendOverlayCodeEntriesCacheOrder.removeAll(where: { $0 == message.id })
        Self.frontendOverlayCodeEntriesCacheOrder.append(message.id)
        while Self.frontendOverlayCodeEntriesCacheOrder.count > Self.frontendOverlayCodeEntriesCacheLimit {
            let removedID = Self.frontendOverlayCodeEntriesCacheOrder.removeFirst()
            Self.frontendOverlayCodeEntriesCache.removeValue(forKey: removedID)
        }

        return deduped
    }

    private func frontendOverlayCodeEntriesSignature(for message: ChatMessage) -> String {
        let content = message.content
        let prefixHash = String(content.prefix(240)).hashValue
        let suffixHash = String(content.suffix(240)).hashValue
        return [
            message.id.uuidString,
            message.isStreaming ? "1" : "0",
            String(content.count),
            String(prefixHash),
            String(suffixHash),
            String(message.fileAttachments.count)
        ].joined(separator: "|")
    }

    private func removeRenderTruncationMarkers(from text: String) -> String {
        text
            .replacingOccurrences(of: "\n\n[附件预览过长，已截断显示。]", with: "")
            .replacingOccurrences(of: "\n\n[该消息过长，已在聊天页截断显示。]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func frontendOverlaySnippetName(language: String?, index: Int) -> String {
        let base = "snippet-\(index)"
        let normalized = (language ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let ext = frontendOverlaySnippetExtension(for: normalized) else {
            return base
        }
        return "\(base).\(ext)"
    }

    private func frontendOverlaySnippetExtension(for language: String) -> String? {
        switch language {
        case "python", "py":
            return "py"
        case "javascript", "js":
            return "js"
        case "typescript", "ts":
            return "ts"
        case "tsx":
            return "tsx"
        case "jsx":
            return "jsx"
        case "swift":
            return "swift"
        case "html", "htm", "xhtml":
            return "html"
        case "css":
            return "css"
        case "scss":
            return "scss"
        case "less":
            return "less"
        case "json":
            return "json"
        case "yaml", "yml":
            return "yml"
        case "xml":
            return "xml"
        case "toml":
            return "toml"
        case "ini":
            return "ini"
        case "bash", "shell", "sh":
            return "sh"
        case "zsh":
            return "zsh"
        case "powershell", "ps1":
            return "ps1"
        case "go":
            return "go"
        case "rust", "rs":
            return "rs"
        case "java":
            return "java"
        case "kotlin":
            return "kt"
        case "c":
            return "c"
        case "cpp", "c++", "cc", "cxx":
            return "cpp"
        case "csharp", "c#", "cs":
            return "cs"
        case "scala":
            return "scala"
        case "dart":
            return "dart"
        case "lua":
            return "lua"
        case "php":
            return "php"
        case "ruby", "rb":
            return "rb"
        case "sql":
            return "sql"
        case "dockerfile":
            return "dockerfile"
        case "makefile":
            return "makefile"
        case "markdown", "md":
            return "md"
        default:
            return nil
        }
    }

    private func openLatestProjectPreviewFromFloatingCard() {
        guard let payload = latestFrontendPreviewPayload() else {
            viewModel.statusMessage = "latest 目录里还没有可预览入口文件。"
            return
        }
        autoFrontendPreview = payload
    }

    private func latestFrontendPreviewPayload() -> AutoFrontendPreviewPayload? {
        guard let entryFileURL = FrontendProjectBuilder.latestEntryFileURL() else {
            return nil
        }
        guard let html = try? String(contentsOf: entryFileURL, encoding: .utf8) else {
            return nil
        }
        return AutoFrontendPreviewPayload(
            title: "项目预览 · \(entryFileURL.lastPathComponent)",
            html: html,
            baseURL: FrontendProjectBuilder.latestProjectURL() ?? entryFileURL.deletingLastPathComponent(),
            entryFileURL: entryFileURL
        )
    }

    private func stripFrontendProjectPayload(from raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(
            of: #"(?is)\[\[file:[^\]]+\]\].*?(?:\[\[endfile\]\]|$)"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)```.*?(?:```|$)"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"`{2,}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldAutoBuildFrontendFromAssistantReply: Bool {
        true
    }

    private func renderWeight(for message: ChatMessage) -> Int {
        let textWeight = message.content.count
        let fileWeight = message.fileAttachments.reduce(0) { partial, file in
            partial + min(file.textContent.count, maxRenderedFilePreviewChars)
        }
        let imageWeight = message.imageAttachments.count * 800
        let videoWeight = message.videoAttachments.count * 1_600
        return textWeight + fileWeight + imageWeight + videoWeight + 200
    }

    private func modelVendorSubtitle(_ rawModel: String, apiURL: String) -> String {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return "Unknown · 模型" }
        let direct = detectModelVendor(model)
        if direct != "Unknown" {
            return "\(direct) · \(model)"
        }
        let fromHost = detectVendorFromAPIURL(apiURL)
        return "\(fromHost) · \(model)"
    }

    private func detectModelVendor(_ model: String) -> String {
        let lowered = model.lowercased()

        if lowered.hasPrefix("gpt") || lowered.hasPrefix("o1") || lowered.hasPrefix("o3") || lowered.hasPrefix("o4") {
            return "OpenAI"
        }
        if lowered.contains("claude") {
            return "Anthropic"
        }
        if lowered.contains("gemini") {
            return "Google"
        }
        if lowered.contains("deepseek") {
            return "DeepSeek"
        }
        if lowered.contains("qwen") {
            return "Alibaba"
        }
        if lowered.contains("kimi") || lowered.contains("moonshot") {
            return "Moonshot"
        }
        if lowered.contains("grok") || lowered.contains("xai") {
            return "xAI"
        }
        if lowered.contains("minimax") || lowered.hasPrefix("abab") {
            return "MiniMax"
        }
        if lowered.contains("glm") || lowered.contains("zhipu") {
            return "Zhipu"
        }
        if lowered.contains("baichuan") {
            return "Baichuan"
        }
        if lowered.contains("yi-") || lowered.contains("lingyi") || lowered.contains("01-ai") {
            return "01.AI"
        }
        if lowered.contains("command-r") || lowered.contains("cohere") {
            return "Cohere"
        }
        if lowered.contains("sonar") || lowered.contains("perplexity") {
            return "Perplexity"
        }
        if lowered.contains("groq") {
            return "Groq"
        }
        if lowered.contains("together") {
            return "Together"
        }
        if lowered.contains("fireworks") {
            return "Fireworks"
        }
        if lowered.contains("llama") {
            return "Meta"
        }
        if lowered.contains("mistral") {
            return "Mistral"
        }
        if lowered.contains("doubao") {
            return "ByteDance"
        }
        if lowered.contains("ernie") || lowered.contains("wenxin") {
            return "Baidu"
        }
        return "Unknown"
    }

    private func detectVendorFromAPIURL(_ apiURL: String) -> String {
        let normalized = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let host = URL(string: normalized)?.host?.lowercased() else {
            return "Unknown"
        }

        if host.contains("openai") {
            return "OpenAI"
        }
        if host.contains("anthropic") {
            return "Anthropic"
        }
        if host.contains("google") || host.contains("gemini") {
            return "Google"
        }
        if host.contains("deepseek") {
            return "DeepSeek"
        }
        if host.contains("qwen") || host.contains("aliyun") || host.contains("dashscope") {
            return "Alibaba"
        }
        if host.contains("moonshot") || host.contains("kimi") {
            return "Moonshot"
        }
        if host.contains("x.ai") || host.contains("xai") || host.contains("grok") {
            return "xAI"
        }
        if host.contains("minimax") || host.contains("abab") {
            return "MiniMax"
        }
        if host.contains("zhipu") || host.contains("bigmodel") || host.contains("glm") {
            return "Zhipu"
        }
        if host.contains("baichuan") {
            return "Baichuan"
        }
        if host.contains("01.ai") || host.contains("lingyi") || host.contains("yi") {
            return "01.AI"
        }
        if host.contains("cohere") {
            return "Cohere"
        }
        if host.contains("perplexity") || host.contains("sonar") {
            return "Perplexity"
        }
        if host.contains("groq") {
            return "Groq"
        }
        if host.contains("together") {
            return "Together"
        }
        if host.contains("fireworks") {
            return "Fireworks"
        }
        if host.contains("meta") || host.contains("llama") {
            return "Meta"
        }
        if host.contains("mistral") {
            return "Mistral"
        }
        if host.contains("doubao") || host.contains("volces") || host.contains("bytedance") {
            return "ByteDance"
        }
        if host.contains("baidu") || host.contains("wenxin") {
            return "Baidu"
        }
        if host.contains("siliconflow") {
            return "SiliconFlow"
        }
        if host.contains("tencent") || host.contains("hunyuan") {
            return "Tencent"
        }
        return "Unknown"
    }

    private func scheduleAssistantMessageDeletion(_ message: ChatMessage) {
        guard message.role == .assistant, !message.isStreaming else { return }
        guard !pendingMessageDeletionIDs.contains(message.id) else { return }

        let messageID = message.id
        pendingMessageDeletionTasks[messageID]?.cancel()
        pendingMessageDeletionIDs.insert(messageID)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        pendingMessageDeletionTasks[messageID] = Task { [messageID] in
            do {
                try await Task.sleep(nanoseconds: 380_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                pendingMessageDeletionTasks[messageID] = nil
                viewModel.deleteMessage(id: messageID)
                pendingMessageDeletionIDs.remove(messageID)
            }
        }
    }

    private func sendStarterPrompt(_ prompt: (title: String, subtitle: String)) {
        guard !viewModel.isSending else { return }

        let title = prompt.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = prompt.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let composed = subtitle.isEmpty ? title : "\(title)\n\(subtitle)"
        guard !composed.isEmpty else { return }

        isComposerFocused = false
        viewModel.draftMessage = composed
        sendCurrentComposerMessage()
    }

    private func cancelPendingMessageDeletionTasks() {
        for task in pendingMessageDeletionTasks.values {
            task.cancel()
        }
        pendingMessageDeletionTasks.removeAll()
        pendingMessageDeletionIDs.removeAll()
    }

    private func refreshStarterPromptsIfNeeded() {
        if starterPromptDeck.isEmpty {
            refreshStarterPrompts(force: true)
        }
    }

    private func refreshStarterPrompts(force: Bool = false) {
        guard force || starterPromptDeck.isEmpty else { return }
        starterPromptDeck = Array(starterPrompts.shuffled().prefix(4))
    }

    private var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("聊天记录")
                    .font(.system(size: 30, weight: .bold))
                Spacer()
                Button {
                    viewModel.createNewSession()
                    setSidebarOpen(false)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.systemGray5))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ScrollsToTopConfigurator(enabled: false)
                        .frame(width: 0, height: 0)
                    ForEach(viewModel.sessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            Divider()
            Button(role: .destructive) {
                viewModel.clearAllSessions()
                setSidebarOpen(false)
            } label: {
                Label("一键清空全部会话", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var sidebarRevealWidth: CGFloat {
        let base = isSidebarOpen ? sidebarWidth : 0
        return min(max(base + sidebarDragOffset, 0), sidebarWidth)
    }

    private var sidebarRevealProgress: CGFloat {
        guard sidebarWidth > 0 else { return 0 }
        return min(max(sidebarRevealWidth / sidebarWidth, 0), 1)
    }

    private var sidebarDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.35 else {
                    return
                }

                if !isSidebarOpen && value.startLocation.x > edgeDragActivationWidth {
                    return
                }

                if isSidebarOpen {
                    sidebarDragOffset = min(0, value.translation.width)
                } else {
                    sidebarDragOffset = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.35 else {
                    settleSidebar(to: isSidebarOpen)
                    return
                }

                if !isSidebarOpen && value.startLocation.x > edgeDragActivationWidth {
                    settleSidebar(to: isSidebarOpen)
                    return
                }

                let projected = value.translation.width + (value.predictedEndTranslation.width - value.translation.width) * 0.25
                let finalReveal = min(
                    max((isSidebarOpen ? sidebarWidth : 0) + projected, 0),
                    sidebarWidth
                )

                settleSidebar(to: finalReveal > sidebarWidth * 0.5)
            }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                viewModel.selectSession(session.id)
                setSidebarOpen(false)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(session.previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(viewModel.currentSessionID == session.id ? Color.blue.opacity(0.12) : Color(.secondarySystemBackground))
                )
            }
            .buttonStyle(.plain)

            HStack {
                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    viewModel.deleteSession(session.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var draftImagePreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.draftImageAttachments) { attachment in
                    draftImagePreview(attachment)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func draftImagePreview(_ attachment: ChatImageAttachment) -> some View {
        if let data = attachment.decodedImageData, let uiImage = UIImage(data: data) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    viewModel.removeDraftImage(id: attachment.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
    }

    private func draftFilePreview(_ file: ChatFileAttachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.caption)
                    .lineLimit(1)
                Text(file.mimeType)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            Button("移除") {
                viewModel.removeDraftFile()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.16, green: 0.16, blue: 0.18))
            .foregroundStyle(.white)
            .font(.caption2)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func startCameraFromAttachmentSheet() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            viewModel.errorMessage = "当前设备不支持拍照。"
            return
        }
        showAttachmentSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showCameraPicker = true
        }
    }

    private func pasteClipboardIntoDraft(sendAfterPaste: Bool) {
        let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pasted.isEmpty else {
            viewModel.statusMessage = "剪贴板没有可用文本"
            return
        }
        viewModel.draftMessage = pasted
        viewModel.statusMessage = "已粘贴剪贴板文本"
        isComposerFocused = true
        if sendAfterPaste {
            sendCurrentComposerMessage()
        }
    }

    private func sendCurrentComposerMessage() {
        guard viewModel.canSend else { return }
        if rotateSessionBeforeSendIfNeeded() {
            return
        }
        stagePendingOutgoingEchoIfNeeded()
        isPinnedToBottom = true
        issueTranscriptCommand(.scrollToBottom(animated: false))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard isPinnedToBottom else { return }
            issueTranscriptCommand(.scrollToBottom(animated: false))
        }
        Task { @MainActor in
            await viewModel.sendCurrentMessage()
            reconcilePendingOutgoingEcho(with: viewModel.messages, forceClearWhenIdle: true)
            issueTranscriptCommand(.scrollToBottom(animated: false))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard isPinnedToBottom else { return }
                issueTranscriptCommand(.scrollToBottom(animated: false))
            }
        }
    }

    private func stagePendingOutgoingEchoIfNeeded() {
        let trimmed = viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = viewModel.draftImageAttachments
        let file = viewModel.draftFileAttachment
        guard !trimmed.isEmpty || !images.isEmpty || file != nil else { return }

        pendingOutgoingEcho = OutgoingEcho(
            id: UUID(),
            content: trimmed,
            imageAttachments: images,
            fileAttachment: file,
            createdAt: Date()
        )
    }

    private func reconcilePendingOutgoingEcho(
        with messages: [ChatMessage],
        forceClearWhenIdle: Bool = false
    ) {
        guard let echo = pendingOutgoingEcho else { return }
        if hasMatchingUserMessage(for: echo, in: messages) {
            pendingOutgoingEcho = nil
            return
        }
        if forceClearWhenIdle && !viewModel.isSending {
            pendingOutgoingEcho = nil
        }
    }

    private func hasMatchingUserMessage(for echo: OutgoingEcho, in messages: [ChatMessage]) -> Bool {
        let expectedText = echo.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedImageCount = echo.imageAttachments.count
        let expectedFileName = echo.fileAttachment?.fileName

        return messages.suffix(12).contains { message in
            guard message.role == .user else { return false }
            guard abs(message.createdAt.timeIntervalSince(echo.createdAt)) < 12 else { return false }
            guard message.content.trimmingCharacters(in: .whitespacesAndNewlines) == expectedText else { return false }
            guard message.imageAttachments.count == expectedImageCount else { return false }
            let fileName = message.fileAttachments.first?.fileName
            return fileName == expectedFileName
        }
    }

    private func maybeAutoRotateLongConversation(using messages: [ChatMessage]) {
        autoRotatedSessionIDs.formIntersection(Set(viewModel.sessions.map(\.id)))
        guard !viewModel.isPrivateMode else { return }
        guard !viewModel.isSending else { return }
        guard !transcriptMetrics.isUserInteracting else { return }
        guard !messages.isEmpty else { return }
        guard let latest = messages.last else { return }
        // Only rotate after an assistant reply is fully finished.
        guard latest.role == .assistant, !latest.isStreaming else { return }
        guard let sessionID = viewModel.currentSessionID else { return }
        guard !autoRotatedSessionIDs.contains(sessionID) else { return }
        let totalCharacters = totalMessageCharacterCount(messages)
        let totalAssistantCharacters = totalAssistantCharacterCount(messages)
        let latestAssistantCharacters = latest.content.count

        let exceededByMessageCount = messages.count >= autoSessionRotateMessageCount
        let exceededByTotalCharacters = totalCharacters >= autoSessionRotateCharacterCount
        let exceededByAssistantCharacters = totalAssistantCharacters >= autoSessionRotateAssistantCharacterCount
        let exceededBySingleAssistantReply = latestAssistantCharacters >= autoSessionRotateSingleAssistantCharacterCount
        let viewportOverflow = viewportOverflowState(
            assistantCharacters: totalAssistantCharacters,
            messageCount: messages.count
        )
        let exceededByViewportOverflow = viewportOverflow.exceeded

        guard exceededByMessageCount
            || exceededByTotalCharacters
            || exceededByAssistantCharacters
            || exceededBySingleAssistantReply
            || exceededByViewportOverflow else {
            return
        }

        autoRotatedSessionIDs.insert(sessionID)
        viewModel.createNewSession()
        if exceededBySingleAssistantReply {
            viewModel.statusMessage = "本条回复过长（>\(autoSessionRotateSingleAssistantCharacterCount) 字），已自动开启新会话以保持流畅。旧会话仍可在侧栏查看。"
        } else if exceededByAssistantCharacters {
            viewModel.statusMessage = "助手内容累计过长，已自动开启新会话以保持流畅。旧会话仍可在侧栏查看。"
        } else if exceededByTotalCharacters {
            viewModel.statusMessage = "当前会话总内容过长，已自动开启新会话以保持流畅。旧会话仍可在侧栏查看。"
        } else if exceededByViewportOverflow {
            let ratioText = String(format: "%.1f", viewportOverflow.ratio)
            viewModel.statusMessage = "当前窗口内容高度约为视口 \(ratioText)x，已自动开启新会话以保证完整显示与流畅滑动。旧会话仍可在侧栏查看。"
        } else {
            viewModel.statusMessage = "当前会话超过 \(autoSessionRotateMessageCount) 条，已自动开启新会话以保持流畅。旧会话仍可在侧栏查看。"
        }
        presentSessionRotateToast()
        isPinnedToBottom = true
        issueTranscriptCommand(.scrollToBottom(animated: false))
    }

    private func rotateSessionBeforeSendIfNeeded() -> Bool {
        guard !viewModel.isPrivateMode else { return false }
        guard !viewModel.messages.isEmpty else { return false }
        guard !viewModel.isSending else { return false }
        guard let sessionID = viewModel.currentSessionID else { return false }

        let totalCharacters = totalMessageCharacterCount(viewModel.messages)
        let totalAssistantCharacters = totalAssistantCharacterCount(viewModel.messages)
        let latestAssistantCharacters = viewModel.messages.last(where: { $0.role == .assistant })?.content.count ?? 0
        let exceededHardLimit =
            viewModel.messages.count >= autoSessionRotateMessageCount
            || totalCharacters >= autoSessionRotateCharacterCount
            || totalAssistantCharacters >= autoSessionRotateAssistantCharacterCount
            || latestAssistantCharacters >= autoSessionRotateSingleAssistantCharacterCount
        guard exceededHardLimit else { return false }

        autoRotatedSessionIDs.insert(sessionID)
        viewModel.createNewSession()
        isPinnedToBottom = true
        issueTranscriptCommand(.scrollToBottom(animated: false))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            issueTranscriptCommand(.scrollToBottom(animated: false))
        }
        viewModel.statusMessage = "当前会话已达到长会话阈值，已切换到新会话；请再次点击发送。"
        presentSessionRotateToast()
        return true
    }

    private func viewportOverflowState(
        assistantCharacters: Int,
        messageCount: Int
    ) -> (exceeded: Bool, ratio: CGFloat, gap: CGFloat) {
        let viewportHeight = max(1, transcriptMetrics.viewportHeight)
        let contentHeight = max(viewportHeight, transcriptMetrics.contentHeight)
        let gap = max(0, contentHeight - viewportHeight)
        let ratio = contentHeight / viewportHeight
        let canTriggerByViewport =
            assistantCharacters >= autoSessionRotateViewportMinAssistantCharacters
            && messageCount >= autoSessionRotateViewportMinMessageCount
        let exceededByRatio = canTriggerByViewport
            && ratio >= autoSessionRotateViewportOverflowRatio
            && gap >= autoSessionRotateViewportOverflowAbsoluteGap
        let exceededByGap = canTriggerByViewport
            && gap >= (autoSessionRotateViewportOverflowAbsoluteGap * 2)
        return (exceededByRatio || exceededByGap, ratio, gap)
    }

    private func totalMessageCharacterCount(_ messages: [ChatMessage]) -> Int {
        messages.reduce(into: 0) { total, message in
            total += message.content.count
            total += message.fileAttachments.reduce(into: 0) { partial, file in
                partial += min(file.textContent.count, maxRenderedFilePreviewChars)
            }
        }
    }

    private func totalAssistantCharacterCount(_ messages: [ChatMessage]) -> Int {
        messages.reduce(into: 0) { total, message in
            guard message.role == .assistant else { return }
            total += message.content.count
            total += message.fileAttachments.reduce(into: 0) { partial, file in
                partial += min(file.textContent.count, maxRenderedFilePreviewChars)
            }
        }
    }

    private func startVoiceTranscription() async {
        speechDraftPrefix = viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await speechToText.startRecording()
            viewModel.statusMessage = "正在语音转文本（中文）…"
            isComposerFocused = true
        } catch {
            viewModel.errorMessage = "语音识别启动失败：\(error.localizedDescription)"
        }
    }

    private func stopVoiceTranscription() {
        speechToText.stopRecording()
        viewModel.statusMessage = "语音识别已停止"
    }

    private func applySpeechTranscript(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard speechToText.isRecording || !cleaned.isEmpty else { return }
        let base = speechDraftPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            viewModel.draftMessage = base
            return
        }
        viewModel.draftMessage = base.isEmpty ? cleaned : "\(base)\n\(cleaned)"
    }

    private func ensureRecentPhotoAssets() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized, .limited:
            loadRecentAssets()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                guard status == .authorized || status == .limited else { return }
                DispatchQueue.main.async {
                    loadRecentAssets()
                }
            }
        default:
            break
        }
    }

    private func loadRecentAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 14
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        recentAssets = assets
        loadThumbnails(for: assets)
    }

    private func loadThumbnails(for assets: [PHAsset]) {
        let manager = PHCachingImageManager()
        let target = CGSize(width: 240, height: 240)
        for asset in assets {
            manager.requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFill,
                options: nil
            ) { image, _ in
                guard let image else { return }
                DispatchQueue.main.async {
                    recentThumbnails[asset.localIdentifier] = image
                }
            }
        }
    }

    private func pickRecentAsset(_ asset: PHAsset) async {
        if let image = await requestImage(for: asset),
           let data = image.jpegData(compressionQuality: 0.9) {
            await MainActor.run {
                viewModel.addDraftImage(data: data, mimeType: "image/jpeg")
                showAttachmentSheet = false
            }
        } else {
            await MainActor.run {
                viewModel.errorMessage = "读取照片失败，请从“全部照片”重试。"
            }
        }
    }

    private func requestImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data, let image = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            viewModel.errorMessage = "文件读取失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                viewModel.errorMessage = "请选择单个文件，暂不支持文件夹。"
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let maxBytes = 5 * 1024 * 1024
                guard data.count <= maxBytes else {
                    viewModel.errorMessage = "文件过大，请选择 5MB 以内的单文件。"
                    return
                }

                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "text/plain"
                let loweredMime = mimeType.lowercased()
                let loweredExt = url.pathExtension.lowercased()
                let isAudioFile = loweredMime.hasPrefix("audio/")
                    || ["mp3", "wav", "m4a", "aac", "ogg", "flac"].contains(loweredExt)

                if isAudioFile {
                    let preview = "已附加音频文件（\(mimeType)，\(formattedByteSize(data.count))）。当前在“语音转文字”模式可直接转写。"
                    viewModel.setDraftBinaryFile(
                        name: url.lastPathComponent,
                        mimeType: loweredMime.hasPrefix("audio/") ? mimeType : "audio/\(loweredExt)",
                        textPreview: preview,
                        data: data
                    )
                    viewModel.statusMessage = "已附加音频：\(url.lastPathComponent)"
                    return
                }

                if let decoded = decodeFileText(data) {
                    let content = normalizeImportedText(decoded)
                    viewModel.setDraftFile(name: url.lastPathComponent, mimeType: mimeType, text: content)
                } else {
                    let content = makeBinaryPreview(data: data)
                    viewModel.setDraftFile(name: url.lastPathComponent, mimeType: mimeType, text: content)
                }
                viewModel.statusMessage = "已附加文件：\(url.lastPathComponent)"
            } catch {
                viewModel.errorMessage = "文件读取失败：\(error.localizedDescription)"
            }
        }
    }

    private func decodeFileText(_ data: Data) -> String? {
        var converted: NSString?
        var usedLossy = ObjCBool(false)
        _ = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: &usedLossy
        )
        if let converted {
            let text = (converted as String).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return converted as String
            }
        }

        var encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16BigEndian,
            .utf16LittleEndian,
            .utf32,
            .utf32BigEndian,
            .utf32LittleEndian,
            .ascii,
            .isoLatin1,
            .windowsCP1252
        ]

        let ianaNames = ["GB18030", "GBK", "GB2312", "Big5", "Shift_JIS", "EUC-JP", "EUC-KR"]
        for name in ianaNames {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding == kCFStringEncodingInvalidId { continue }
            let raw = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            encodings.append(String.Encoding(rawValue: raw))
        }

        for encoding in encodings {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return text
            }
        }

        return nil
    }

    private func normalizeImportedText(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let maxCharacters = 180_000
        if normalized.count <= maxCharacters {
            return normalized
        }
        return String(normalized.prefix(maxCharacters)) + "\n\n[文件内容过长，已截断展示前 \(maxCharacters) 个字符]"
    }

    private func makeBinaryPreview(data: Data) -> String {
        let maxBytes = 4096
        let prefix = data.prefix(maxBytes)
        var lines: [String] = []
        lines.append("[文件不是可直接解码的纯文本，已转为十六进制预览]")

        let bytes = Array(prefix)
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(offset + 16, bytes.count)])
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = chunk.map { byte -> String in
                if (32...126).contains(Int(byte)) {
                    return String(UnicodeScalar(Int(byte))!)
                }
                return "."
            }.joined()
            let paddedHex = hex.count >= 47 ? hex : hex + String(repeating: " ", count: 47 - hex.count)
            lines.append(String(format: "%04X  %@  %@", offset, paddedHex, ascii))
            offset += 16
        }

        if data.count > maxBytes {
            lines.append("... [仅展示前 \(maxBytes) 字节]")
        }
        return lines.joined(separator: "\n")
    }

    private func formattedByteSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func issueTranscriptCommand(_ kind: ChatTranscriptCommand.Kind) {
        transcriptCommandSequence &+= 1
        transcriptCommand = ChatTranscriptCommand(id: transcriptCommandSequence, kind: kind)
    }

    private func settleSidebar(to open: Bool) {
        sidebarAnimationLock = true
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
            isSidebarOpen = open
            sidebarDragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            sidebarAnimationLock = false
        }
    }

    private func setSidebarOpen(_ open: Bool, force: Bool = false) {
        if !force && sidebarAnimationLock { return }
        guard isSidebarOpen != open else { return }
        settleSidebar(to: open)
    }
}

private struct HeaderLeadingWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HeaderTrailingWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChatTranscriptMetrics: Equatable {
    var canScroll: Bool = false
    var isAtBottom: Bool = true
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var isUserInteracting: Bool = false
}

private struct ChatTranscriptCommand: Equatable {
    enum Kind: Equatable {
        case scrollToBottom(animated: Bool)
        case pageDown
    }

    let id: Int
    let kind: Kind
}

private struct NativeTranscriptScrollView: UIViewControllerRepresentable {
    let historyContent: AnyView
    let historyVersion: String
    let streamingLeadContent: AnyView?
    let streamingLeadSignature: String?
    let streamingMessage: ChatMessage?
    let codeThemeSignature: String
    let codeThemeMode: CodeThemeMode
    let apiKey: String
    let apiBaseURL: String
    let shellExecutionEnabled: Bool
    let shellExecutionURLString: String
    let shellExecutionTimeout: Double
    let shellExecutionWorkingDirectory: String
    let bottomReservedInset: CGFloat
    let command: ChatTranscriptCommand?
    let onMetricsChanged: (ChatTranscriptMetrics) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onMetricsChanged: onMetricsChanged)
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.update(
            historyContent: historyContent,
            historyVersion: historyVersion,
            streamingLeadContent: streamingLeadContent,
            streamingLeadSignature: streamingLeadSignature,
            streamingMessage: streamingMessage,
            codeThemeSignature: codeThemeSignature,
            codeThemeMode: codeThemeMode,
            apiKey: apiKey,
            apiBaseURL: apiBaseURL,
            shellExecutionEnabled: shellExecutionEnabled,
            shellExecutionURLString: shellExecutionURLString,
            shellExecutionTimeout: shellExecutionTimeout,
            shellExecutionWorkingDirectory: shellExecutionWorkingDirectory,
            bottomReservedInset: bottomReservedInset,
            command: command,
            onMetricsChanged: onMetricsChanged
        )
    }

    final class Controller: UIViewController, UIScrollViewDelegate {
        private let scrollView = UIScrollView()
        private let stackView = UIStackView()
        private let historyHostingController = UIHostingController(rootView: AnyView(EmptyView()))
        private let streamingLeadHostingController = UIHostingController(rootView: AnyView(EmptyView()))
        private let streamingRichHostingController = UIHostingController(rootView: AnyView(EmptyView()))
        private let spacerView = UIView()
        private var onMetricsChanged: (ChatTranscriptMetrics) -> Void
        private var lastReportedMetrics = ChatTranscriptMetrics()
        private var lastAppliedCommandID: Int?
        private var pendingCommand: ChatTranscriptCommand?
        private var lastHistoryVersion: String?
        private var lastStreamingSignature: String?
        private var lastStreamingLeadSignature: String?
        private var lastStreamingMessageID: UUID?
        private var pendingStreamingHideWorkItem: DispatchWorkItem?
        private var appliedBottomReservedInset: CGFloat = 0

        init(onMetricsChanged: @escaping (ChatTranscriptMetrics) -> Void) {
            self.onMetricsChanged = onMetricsChanged
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            pendingStreamingHideWorkItem?.cancel()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear

            scrollView.backgroundColor = .clear
            scrollView.delegate = self
            scrollView.alwaysBounceVertical = true
            scrollView.keyboardDismissMode = .interactive
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.scrollsToTop = true
            scrollView.delaysContentTouches = false
            scrollView.canCancelContentTouches = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scrollView)

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: view.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])

            stackView.axis = .vertical
            stackView.alignment = .fill
            stackView.spacing = 16
            stackView.isLayoutMarginsRelativeArrangement = true
            stackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 12, bottom: 18, trailing: 12)
            stackView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(stackView)

            historyHostingController.sizingOptions = [.intrinsicContentSize]
            historyHostingController.view.backgroundColor = .clear
            historyHostingController.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(historyHostingController)
            stackView.addArrangedSubview(historyHostingController.view)
            historyHostingController.didMove(toParent: self)

            streamingLeadHostingController.sizingOptions = [.intrinsicContentSize]
            streamingLeadHostingController.view.backgroundColor = .clear
            streamingLeadHostingController.view.translatesAutoresizingMaskIntoConstraints = false
            streamingLeadHostingController.view.isHidden = true
            addChild(streamingLeadHostingController)
            stackView.addArrangedSubview(streamingLeadHostingController.view)
            streamingLeadHostingController.didMove(toParent: self)

            streamingRichHostingController.sizingOptions = [.intrinsicContentSize]
            streamingRichHostingController.view.backgroundColor = .clear
            streamingRichHostingController.view.translatesAutoresizingMaskIntoConstraints = false
            streamingRichHostingController.view.isHidden = true
            streamingRichHostingController.view.isUserInteractionEnabled = false
            addChild(streamingRichHostingController)
            stackView.addArrangedSubview(streamingRichHostingController.view)
            streamingRichHostingController.didMove(toParent: self)

            spacerView.backgroundColor = .clear
            spacerView.setContentHuggingPriority(.defaultLow, for: .vertical)
            spacerView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            stackView.addArrangedSubview(spacerView)

            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
                stackView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor)
            ])
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            normalizeShortContentOffsetIfNeeded()
            applyPendingCommandIfNeeded()
            reportMetrics()
        }

        func update(
            historyContent: AnyView,
            historyVersion: String,
            streamingLeadContent: AnyView?,
            streamingLeadSignature: String?,
            streamingMessage: ChatMessage?,
            codeThemeSignature: String,
            codeThemeMode: CodeThemeMode,
            apiKey: String,
            apiBaseURL: String,
            shellExecutionEnabled: Bool,
            shellExecutionURLString: String,
            shellExecutionTimeout: Double,
            shellExecutionWorkingDirectory: String,
            bottomReservedInset: CGFloat,
            command: ChatTranscriptCommand?,
            onMetricsChanged: @escaping (ChatTranscriptMetrics) -> Void
        ) {
            self.onMetricsChanged = onMetricsChanged

            let normalizedBottomInset = max(0, bottomReservedInset)
            if abs(normalizedBottomInset - appliedBottomReservedInset) > 0.5 {
                appliedBottomReservedInset = normalizedBottomInset
                scrollView.contentInset.bottom = normalizedBottomInset
                scrollView.scrollIndicatorInsets.bottom = normalizedBottomInset
            }

            let historyChanged = historyVersion != lastHistoryVersion
            let streamingMessageID = streamingMessage?.id
            let streamingIdentityChanged = streamingMessageID != lastStreamingMessageID
            if historyChanged || streamingIdentityChanged {
                UIView.performWithoutAnimation {
                    historyHostingController.rootView = historyContent
                    historyHostingController.view.invalidateIntrinsicContentSize()
                }
                lastHistoryVersion = historyVersion
                lastStreamingMessageID = streamingMessageID
            }

            var streamingLeadChanged = false
            if let streamingLeadContent {
                let normalizedLeadSignature = streamingLeadSignature ?? "streaming-lead-visible"
                if normalizedLeadSignature != lastStreamingLeadSignature || streamingLeadHostingController.view.isHidden {
                    UIView.performWithoutAnimation {
                        streamingLeadHostingController.rootView = streamingLeadContent
                        streamingLeadHostingController.view.invalidateIntrinsicContentSize()
                        streamingLeadHostingController.view.isHidden = false
                    }
                    lastStreamingLeadSignature = normalizedLeadSignature
                    streamingLeadChanged = true
                }
            } else if !streamingLeadHostingController.view.isHidden || lastStreamingLeadSignature != nil {
                UIView.performWithoutAnimation {
                    streamingLeadHostingController.view.isHidden = true
                }
                lastStreamingLeadSignature = nil
                streamingLeadChanged = true
            }

            let newStreamingSignature = streamingMessage.map {
                "\($0.id.uuidString)|\($0.content.count)|\($0.imageAttachments.count)|\($0.videoAttachments.count)|\($0.fileAttachments.count)|\(codeThemeSignature)"
            }
            if let streamingMessage {
                pendingStreamingHideWorkItem?.cancel()
                pendingStreamingHideWorkItem = nil
                if newStreamingSignature != lastStreamingSignature
                    || streamingRichHostingController.view.isHidden {
                    UIView.performWithoutAnimation {
                        let richView = AnyView(
                            MessageBubbleView(
                                message: streamingMessage,
                                codeThemeMode: codeThemeMode,
                                apiKey: apiKey,
                                apiBaseURL: apiBaseURL,
                                shellExecutionEnabled: shellExecutionEnabled,
                                shellExecutionURLString: shellExecutionURLString,
                                shellExecutionTimeout: shellExecutionTimeout,
                                shellExecutionWorkingDirectory: shellExecutionWorkingDirectory,
                                showsAssistantActionBar: false,
                                onRegenerate: nil
                            )
                            .padding(.horizontal, 18)
                        )
                        streamingRichHostingController.rootView = richView
                        streamingRichHostingController.view.invalidateIntrinsicContentSize()
                        streamingRichHostingController.view.isHidden = false
                    }
                    lastStreamingSignature = newStreamingSignature
                }
            } else if !streamingRichHostingController.view.isHidden || lastStreamingSignature != nil {
                pendingStreamingHideWorkItem?.cancel()
                pendingStreamingHideWorkItem = nil
                UIView.performWithoutAnimation {
                    streamingRichHostingController.view.isHidden = true
                }
                lastStreamingSignature = nil
                reportMetrics()
            }

            var commandChanged = false
            if let command, command.id != lastAppliedCommandID {
                pendingCommand = command
                commandChanged = true
            }

            view.setNeedsLayout()
            if historyChanged || commandChanged || streamingLeadChanged || streamingIdentityChanged {
                view.layoutIfNeeded()
                applyPendingCommandIfNeeded()
            }
            reportMetrics()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            normalizeShortContentOffsetIfNeeded()
            reportMetrics()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                reportMetrics()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportMetrics()
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            let topOffsetY = -scrollView.contentInset.top
            if scrollView.contentOffset.y < topOffsetY {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: topOffsetY), animated: false)
            }
            reportMetrics()
        }

        private func applyPendingCommandIfNeeded() {
            guard let command = pendingCommand, command.id != lastAppliedCommandID else { return }

            switch command.kind {
            case .scrollToBottom(let animated):
                if canScroll {
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottomOffsetY), animated: animated)
                } else {
                    normalizeShortContentOffsetIfNeeded()
                }
            case .pageDown:
                if canScroll {
                    let pageStep = min(max(scrollView.bounds.height * 0.32, 140), 240)
                    let targetY = min(scrollView.contentOffset.y + pageStep, bottomOffsetY)
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: true)
                } else {
                    normalizeShortContentOffsetIfNeeded()
                }
            }

            lastAppliedCommandID = command.id
            pendingCommand = nil
            reportMetrics()
        }

        private func reportMetrics() {
            let bottomDistance = bottomOffsetY - scrollView.contentOffset.y
            let translationY = scrollView.panGestureRecognizer.translation(in: scrollView).y
            let isDraggingUp = scrollView.isDragging && translationY < -4
            let isUserInteracting = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            let metrics = ChatTranscriptMetrics(
                canScroll: canScroll,
                isAtBottom: !canScroll || (!isDraggingUp && bottomDistance <= 28),
                contentHeight: max(0, scrollView.contentSize.height),
                viewportHeight: max(0, scrollView.bounds.height),
                isUserInteracting: isUserInteracting
            )

            if metrics != lastReportedMetrics {
                lastReportedMetrics = metrics
                onMetricsChanged(metrics)
            }
        }

        private func normalizeShortContentOffsetIfNeeded() {
            guard !canScroll else { return }
            guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else { return }
            let topOffsetY = -scrollView.contentInset.top
            guard abs(scrollView.contentOffset.y - topOffsetY) > 8 else { return }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: topOffsetY), animated: false)
        }

        private var canScroll: Bool {
            scrollView.contentSize.height > scrollView.bounds.height + 8
        }

        private var bottomOffsetY: CGFloat {
            max(
                -scrollView.contentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
            )
        }
    }
}

private struct DissolvingMessageRow<Content: View>: View {
    let isDeleting: Bool
    let seed: UInt64
    let content: Content
    @State private var progress: CGFloat = 0

    init(
        isDeleting: Bool,
        seed: UInt64,
        @ViewBuilder content: () -> Content
    ) {
        self.isDeleting = isDeleting
        self.seed = seed
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .opacity(1 - Double(progress))
                .scaleEffect(1 - progress * 0.02, anchor: .center)
                .blur(radius: progress * 2.8)

            if progress > 0.001 {
                MessageDissolveParticles(progress: progress, seed: seed)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(true)
        .onAppear {
            if isDeleting {
                triggerDissolve()
            }
        }
        .onChange(of: isDeleting) { _, newValue in
            if newValue {
                triggerDissolve()
            } else {
                progress = 0
            }
        }
    }

    private func triggerDissolve() {
        progress = 0
        withAnimation(.easeOut(duration: 0.34)) {
            progress = 1
        }
    }
}

private struct MessageDissolveParticles: View {
    let progress: CGFloat
    let seed: UInt64

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let particleCount = 48
                let clampedProgress = min(max(progress, 0), 1)

                for index in 0..<particleCount {
                    let baseXUnit = seededUnit(index * 7 + 1)
                    let baseYUnit = seededUnit(index * 7 + 2)
                    let driftXUnit = seededUnit(index * 7 + 3) - 0.5
                    let driftYUnit = seededUnit(index * 7 + 4)
                    let radiusUnit = seededUnit(index * 7 + 5)
                    let alphaUnit = seededUnit(index * 7 + 6)

                    let baseX = baseXUnit * size.width
                    let baseY = baseYUnit * size.height
                    let driftX = driftXUnit * size.width * 0.28 * clampedProgress
                    let driftY = (0.05 + driftYUnit * 0.24) * size.height * clampedProgress
                    let centerX = baseX + driftX
                    let centerY = baseY - driftY

                    let radius = (1.0 + radiusUnit * 2.4) * max(0.25, 1 - clampedProgress * 0.52)
                    let opacity = Double(max(0, 1 - clampedProgress * 1.25))
                        * Double(0.36 + alphaUnit * 0.64)
                    guard opacity > 0.01 else { continue }

                    let particleRect = CGRect(
                        x: centerX - radius,
                        y: centerY - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: particleRect),
                        with: .color(Color.primary.opacity(opacity))
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private func seededUnit(_ index: Int) -> CGFloat {
        var value = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15
        value ^= value >> 33
        value &*= 0xFF51AFD7ED558CCD
        value ^= value >> 33
        value &*= 0xC4CEB9FE1A85EC53
        value ^= value >> 33
        let bucket = value & 0xFFFF
        return CGFloat(bucket) / 65535
    }
}

private extension UUID {
    var dissolveSeed: UInt64 {
        withUnsafeBytes(of: uuid) { rawBuffer in
            rawBuffer.reduce(UInt64(1469598103934665603)) { partial, byte in
                (partial ^ UInt64(byte)) &* 1099511628211
            }
        }
    }
}

private struct AutoFrontendPreviewPayload: Identifiable {
    let id = UUID()
    let title: String
    let html: String
    let baseURL: URL?
    let entryFileURL: URL?
}

private struct ScrollsToTopConfigurator: UIViewRepresentable {
    let enabled: Bool

    func makeUIView(context: Context) -> ResolverView {
        let view = ResolverView(frame: .zero)
        view.enabled = enabled
        return view
    }

    func updateUIView(_ uiView: ResolverView, context: Context) {
        uiView.enabled = enabled
        uiView.resolve()
    }

    final class ResolverView: UIView {
        var enabled = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                scrollView.scrollsToTop = self.enabled
            }
        }
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var current = superview
        while let view = current {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }
}

private struct InitialConfigSheet: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    let onComplete: () -> Void

    private var canContinue: Bool {
        let url = viewModel.config.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = viewModel.config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !url.isEmpty && !model.isEmpty
    }

    var body: some View {
        Form {
            Section("首次使用配置") {
                Text("请先填写基础配置。保存后，下次打开将不再弹出这个窗口。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("站点地址（如 https://xxx.com）", text: $viewModel.config.apiURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("API Key（可选）", text: $viewModel.config.apiKey)

                TextField("模型名称（如 gpt-5.4）", text: $viewModel.config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Button("保存并开始使用") {
                    viewModel.saveConfig()
                    onComplete()
                    isPresented = false
                }
                .disabled(!canContinue)
            }
        }
        .navigationTitle("欢迎使用 IEXA")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TwoLineMenuIcon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule(style: .continuous)
                .frame(width: 18, height: 2.6)
            Capsule(style: .continuous)
                .frame(width: 12, height: 2.6)
        }
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraImagePicker

        init(_ parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }
    }
}
