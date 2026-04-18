import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

struct ChatScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @AppStorage("chatapp.config.onboarding.done") private var hasCompletedInitialConfig = false

    private let sidebarWidth: CGFloat = 286
    private let edgeDragActivationWidth: CGFloat = 28
    private let headerCenterMinHorizontalInset: CGFloat = 76
    private let maxRenderedMessages = 120
    private let maxRenderedCharacters = 260_000
    private let maxSingleRenderedMessageChars = 80_000
    private let maxRenderedFilePreviewChars = 18_000
    private let starterPrompts: [(title: String, subtitle: String)] = [
        ("创作一幅插图", "为烘焙店"),
        ("告诉我一个冷知识", "关于罗马帝国"),
        ("提出建议", "根据我的数据"),
        ("设计一款编程游戏", "以有趣的方式教授基础知识")
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
    @State private var headerLeadingWidth: CGFloat = 36
    @State private var headerTrailingWidth: CGFloat = 108
    @State private var transcriptMetrics = ChatTranscriptMetrics()
    @State private var transcriptCommandSequence = 0
    @State private var transcriptCommand: ChatTranscriptCommand?

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
            if !hasCompletedInitialConfig {
                showInitialConfigSheet = true
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
        .onChange(of: speechToText.transcript) { _, newValue in
            applySpeechTranscript(newValue)
        }
        .onDisappear {
            speechToText.stopRecording()
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
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("IEXA")
                .font(.system(size: 12, weight: .medium))
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
        Menu {
            Section("接口模式") {
                ForEach(APIEndpointMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.config.endpointMode = mode
                    } label: {
                        if viewModel.config.endpointMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }

            Divider()

            Button(viewModel.isLoadingModels ? "拉取中…" : "拉取模型列表") {
                Task { await viewModel.refreshAvailableModels() }
            }
            .disabled(viewModel.isLoadingModels)

            Divider()

            ForEach(modelMenuOptions, id: \.self) { model in
                Button {
                    viewModel.applySelectedModel(model)
                } label: {
                    if model == viewModel.config.model {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isCurrentModelAvailable ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(modelVendorSubtitle(viewModel.config.model, apiURL: viewModel.config.normalizedBaseURL))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
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


    private var messageList: some View {
        GeometryReader { geometry in
            NativeTranscriptScrollView(
                historyContent: AnyView(transcriptHistoryContent()),
                historyVersion: transcriptHistoryVersion,
                streamingLeadContent: activeStreamingLeadContent,
                streamingLeadSignature: activeStreamingLeadSignature,
                streamingMessage: activeStreamingRenderedMessage,
                codeThemeMode: viewModel.config.codeThemeMode,
                apiKey: viewModel.config.apiKey,
                apiBaseURL: viewModel.config.normalizedBaseURL,
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
                if isPinnedToBottom {
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

            ForEach(frozenRenderedMessages) { message in
                let isLatestAssistant = message.id == latestFrozenAssistantMessageID
                let displayMessage = makeDisplaySafeMessage(message)
                MessageBubbleView(
                    message: displayMessage,
                    codeThemeMode: viewModel.config.codeThemeMode,
                    apiKey: viewModel.config.apiKey,
                    apiBaseURL: viewModel.config.normalizedBaseURL,
                    showsAssistantActionBar: message.role == .assistant && !message.isStreaming,
                    onRegenerate: (isLatestAssistant && viewModel.config.endpointMode == .chatCompletions && !viewModel.isPrivateMode) ? {
                        Task { await viewModel.regenerateLastAssistantReply() }
                    } : nil
                )
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

            if viewModel.messages.isEmpty {
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
                    Task { await viewModel.sendCurrentMessage() }
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
                Task { await viewModel.sendCurrentMessage() }
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

    private var canTapPrimaryComposerButton: Bool {
        viewModel.isSending || shouldUseVoicePrimaryAction || viewModel.canSend
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
                Text("推荐")
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
                            viewModel.draftMessage = "\(prompt.title)\n\(prompt.subtitle)"
                            isComposerFocused = true
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

    private var modelMenuOptions: [String] {
        let fromAPI = viewModel.availableModels
        if !fromAPI.isEmpty {
            return fromAPI
        }
        let fallback = ["gpt-5.4", "gpt-5.2", "gpt-4.1"]
        var merged: [String] = [viewModel.config.model]
        for model in fallback where !merged.contains(model) {
            merged.append(model)
        }
        return merged
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

    private var renderedMessages: [ChatMessage] {
        let source = viewModel.messages
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
        guard let active = activeStreamingRenderedMessage,
              renderedMessages.last?.id == active.id,
              renderedMessages.count >= 2 else {
            return nil
        }
        let candidate = makeDisplaySafeMessage(renderedMessages[renderedMessages.count - 2])
        return candidate.role == .user ? candidate : nil
    }

    private var activeStreamingLeadSignature: String? {
        activeStreamingLeadUserMessage.map {
            "\($0.id.uuidString)|\($0.content.count)|\($0.imageAttachments.count)|\($0.fileAttachments.count)"
        }
    }

    private var activeStreamingLeadContent: AnyView? {
        guard let leadUser = activeStreamingLeadUserMessage else { return nil }
        return AnyView(
            MessageBubbleView(
                message: leadUser,
                codeThemeMode: viewModel.config.codeThemeMode,
                apiKey: viewModel.config.apiKey,
                apiBaseURL: viewModel.config.normalizedBaseURL,
                showsAssistantActionBar: false,
                onRegenerate: nil
            )
            .padding(.horizontal, 12)
        )
    }

    private var frozenRenderedMessages: [ChatMessage] {
        guard let activeStreamingRenderedMessage,
              renderedMessages.last?.id == activeStreamingRenderedMessage.id else {
            return renderedMessages
        }
        var frozen = Array(renderedMessages.dropLast())
        if let lead = activeStreamingLeadUserMessage,
           frozen.last?.id == lead.id {
            frozen.removeLast()
        }
        return frozen
    }

    private var isRenderingWindowed: Bool {
        renderedMessages.count < viewModel.messages.count
    }

    private var transcriptHistoryVersion: String {
        let ids = frozenRenderedMessages.map(\.id.uuidString).joined(separator: ",")
        let lengths = frozenRenderedMessages.map { String($0.content.count) }.joined(separator: ",")
        let windowFlag = isRenderingWindowed ? "1" : "0"
        return "\(windowFlag)|\(ids)|\(lengths)"
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

        if safe.content.count > maxSingleRenderedMessageChars {
            safe.content = String(safe.content.prefix(maxSingleRenderedMessageChars))
                + "\n\n[该消息过长，已在聊天页截断显示。]"
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

    private func renderWeight(for message: ChatMessage) -> Int {
        let textWeight = message.content.count
        let fileWeight = message.fileAttachments.reduce(0) { partial, file in
            partial + min(file.textContent.count, maxRenderedFilePreviewChars)
        }
        let imageWeight = message.imageAttachments.count * 800
        return textWeight + fileWeight + imageWeight + 200
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
            Task { await viewModel.sendCurrentMessage() }
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

private struct ChatTranscriptMetrics: Equatable {
    var canScroll: Bool = false
    var isAtBottom: Bool = true
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
    let codeThemeMode: CodeThemeMode
    let apiKey: String
    let apiBaseURL: String
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
            codeThemeMode: codeThemeMode,
            apiKey: apiKey,
            apiBaseURL: apiBaseURL,
            command: command,
            onMetricsChanged: onMetricsChanged
        )
    }

    final class Controller: UIViewController, UIScrollViewDelegate {
        private enum StreamingRenderMode {
            case native
            case rich
        }

        private let scrollView = UIScrollView()
        private let stackView = UIStackView()
        private let historyHostingController = UIHostingController(rootView: AnyView(EmptyView()))
        private let streamingLeadHostingController = UIHostingController(rootView: AnyView(EmptyView()))
        private let streamingRichHostingController = UIHostingController(rootView: AnyView(EmptyView()))
        private let streamingView = NativeStreamingAssistantView()
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
        private var streamingRenderMode: StreamingRenderMode = .native

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

            streamingView.translatesAutoresizingMaskIntoConstraints = false
            streamingView.isHidden = true
            stackView.addArrangedSubview(streamingView)

            streamingRichHostingController.sizingOptions = [.intrinsicContentSize]
            streamingRichHostingController.view.backgroundColor = .clear
            streamingRichHostingController.view.translatesAutoresizingMaskIntoConstraints = false
            streamingRichHostingController.view.isHidden = true
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
            codeThemeMode: CodeThemeMode,
            apiKey: String,
            apiBaseURL: String,
            command: ChatTranscriptCommand?,
            onMetricsChanged: @escaping (ChatTranscriptMetrics) -> Void
        ) {
            self.onMetricsChanged = onMetricsChanged

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
                if streamingIdentityChanged {
                    streamingRenderMode = .native
                }
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
                    streamingLeadHostingController.rootView = AnyView(EmptyView())
                    streamingLeadHostingController.view.isHidden = true
                }
                lastStreamingLeadSignature = nil
                streamingLeadChanged = true
            }

            let newStreamingSignature = streamingMessage.map {
                "\($0.id.uuidString)|\($0.content.count)|\($0.imageAttachments.count)|\($0.fileAttachments.count)"
            }
            if let streamingMessage {
                pendingStreamingHideWorkItem?.cancel()
                pendingStreamingHideWorkItem = nil
                let shouldUseRichRenderer =
                    streamingRenderMode == .rich
                    || Self.shouldUseRichStreamingRenderer(for: streamingMessage)

                if shouldUseRichRenderer {
                    streamingRenderMode = .rich
                    if newStreamingSignature != lastStreamingSignature || streamingRichHostingController.view.isHidden {
                        UIView.performWithoutAnimation {
                            let richView = AnyView(
                                MessageBubbleView(
                                    message: streamingMessage,
                                    codeThemeMode: codeThemeMode,
                                    apiKey: apiKey,
                                    apiBaseURL: apiBaseURL,
                                    showsAssistantActionBar: false,
                                    onRegenerate: nil
                                )
                                .padding(.horizontal, 12)
                            )
                            streamingRichHostingController.rootView = richView
                            streamingRichHostingController.view.invalidateIntrinsicContentSize()
                            streamingRichHostingController.view.isHidden = false
                            streamingView.reset()
                            streamingView.isHidden = true
                        }
                        lastStreamingSignature = newStreamingSignature
                    }
                } else {
                    streamingRenderMode = .native
                    if newStreamingSignature != lastStreamingSignature
                        || streamingView.isHidden
                        || !streamingRichHostingController.view.isHidden {
                        UIView.performWithoutAnimation {
                            streamingRichHostingController.rootView = AnyView(EmptyView())
                            streamingRichHostingController.view.isHidden = true
                            streamingView.isHidden = false
                            streamingView.apply(message: streamingMessage)
                        }
                        lastStreamingSignature = newStreamingSignature
                    }
                }
            } else if !streamingView.isHidden || !streamingRichHostingController.view.isHidden || lastStreamingSignature != nil {
                let hideStreamingView: () -> Void = { [weak self] in
                    guard let self else { return }
                    UIView.performWithoutAnimation {
                        self.streamingView.reset()
                        self.streamingView.isHidden = true
                        self.streamingRichHostingController.rootView = AnyView(EmptyView())
                        self.streamingRichHostingController.view.isHidden = true
                    }
                    self.lastStreamingSignature = nil
                    self.streamingRenderMode = .native
                    self.pendingStreamingHideWorkItem = nil
                    self.reportMetrics()
                }

                if historyChanged {
                    pendingStreamingHideWorkItem?.cancel()
                    let workItem = DispatchWorkItem(block: hideStreamingView)
                    pendingStreamingHideWorkItem = workItem
                    DispatchQueue.main.async(execute: workItem)
                } else {
                    pendingStreamingHideWorkItem?.cancel()
                    pendingStreamingHideWorkItem = nil
                    hideStreamingView()
                }
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
            let metrics = ChatTranscriptMetrics(
                canScroll: canScroll,
                isAtBottom: !canScroll || (!isDraggingUp && bottomDistance <= 28)
            )

            if metrics != lastReportedMetrics {
                lastReportedMetrics = metrics
                onMetricsChanged(metrics)
            }
        }

        private func normalizeShortContentOffsetIfNeeded() {
            guard !canScroll else { return }
            let topOffsetY = -scrollView.contentInset.top
            guard abs(scrollView.contentOffset.y - topOffsetY) > 1 else { return }
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

        private static func shouldUseRichStreamingRenderer(for message: ChatMessage) -> Bool {
            if !message.imageAttachments.isEmpty || !message.fileAttachments.isEmpty {
                return true
            }

            let text = message.content
            if text.contains("```") {
                return true
            }

            let hasTableRow = text.range(
                of: #"(?m)^\s*\|.+\|\s*$"#,
                options: .regularExpression
            ) != nil
            let hasTableSeparator = text.range(
                of: #"(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#,
                options: .regularExpression
            ) != nil
            return hasTableRow && hasTableSeparator
        }
    }
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

private final class NativeStreamingAssistantView: UIView {
    private enum RenderStyle {
        case body
        case code
    }

    private let containerStack = UIStackView()
    private let identityStack = UIStackView()
    private let identityIconView = UIImageView()
    private let identityNameLabel = UILabel()
    private let textView = UITextView()
    private let imageProgressStack = UIStackView()
    private let imageProgressCard = ImageGenerationProgressCardView()
    private let imageProgressLabel = UILabel()
    private let waitingDotStack = UIStackView()
    private let waitingDotView = UIView()
    private let waitingDotSpacer = UIView()

    private var currentMessageID: UUID?
    private var currentSourceUTF16Length = 0
    private var pendingDisplayText = ""
    private var streamDisplayLink: CADisplayLink?
    private var lastDisplayLinkTimestamp: CFTimeInterval = 0
    private var pendingLayoutCharacters = 0
    private var pendingGradientCharacters = 0
    private var pendingFenceTickCount = 0
    private var inCodeBlock = false
    private var waitingForCodeLanguageLine = false
    private var languageProbe = ""
    private var waitingDotAnimationRunning = false
    private var lastTailGradientRanges: [NSRange] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDisplayLinkIfNeeded()
    }

    func apply(message: ChatMessage) {
        let shouldShowImageProgress =
            message.isImageGenerationPlaceholder
            && message.imageAttachments.isEmpty

        imageProgressStack.isHidden = !shouldShowImageProgress
        waitingDotStack.isHidden = true
        textView.isHidden = shouldShowImageProgress

        if shouldShowImageProgress {
            stopWaitingDotAnimationIfNeeded()
            pendingDisplayText.removeAll(keepingCapacity: false)
            stopDisplayLinkIfNeeded()
            currentMessageID = message.id
            currentSourceUTF16Length = 0
            pendingLayoutCharacters = 0
            pendingGradientCharacters = 0
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            return
        }

        let sourceText: String
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sourceText = Self.streamingSectionizedText(message.content)
        } else if !message.imageAttachments.isEmpty {
            sourceText = "正在接收图片…"
        } else {
            sourceText = ""
        }

        let shouldShowWaitingDot = sourceText.isEmpty && message.imageAttachments.isEmpty
        waitingDotStack.isHidden = !shouldShowWaitingDot
        textView.isHidden = shouldShowWaitingDot

        if shouldShowWaitingDot {
            startWaitingDotAnimationIfNeeded()
            pendingDisplayText.removeAll(keepingCapacity: false)
            stopDisplayLinkIfNeeded()
            currentMessageID = message.id
            currentSourceUTF16Length = 0
            pendingLayoutCharacters = 0
            pendingGradientCharacters = 0
            resetParserState()
            textView.attributedText = NSAttributedString()
            lastTailGradientRanges.removeAll(keepingCapacity: false)
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            return
        } else {
            stopWaitingDotAnimationIfNeeded()
        }

        let sourceUTF16Length = sourceText.utf16.count

        if currentMessageID == message.id, sourceUTF16Length >= currentSourceUTF16Length {
            let rawSuffix = (sourceText as NSString).substring(from: currentSourceUTF16Length)
            if !rawSuffix.isEmpty {
                let displaySuffix = Self.streamingDisplayDeltaText(rawSuffix)
                enqueueStreamingDisplayText(displaySuffix)
            }
        } else {
            pendingDisplayText.removeAll(keepingCapacity: false)
            stopDisplayLinkIfNeeded()
            resetParserState()
            textView.attributedText = NSAttributedString()
            let displayText = Self.streamingDisplayDeltaText(sourceText)
            pendingLayoutCharacters = 0
            pendingGradientCharacters = 0
            if !displayText.isEmpty {
                enqueueStreamingDisplayText(displayText)
            } else {
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        currentMessageID = message.id
        currentSourceUTF16Length = sourceUTF16Length
    }

    func reset() {
        pendingDisplayText.removeAll(keepingCapacity: false)
        stopDisplayLinkIfNeeded()
        currentMessageID = nil
        currentSourceUTF16Length = 0
        pendingLayoutCharacters = 0
        pendingGradientCharacters = 0
        resetParserState()
        imageProgressStack.isHidden = true
        waitingDotStack.isHidden = true
        stopWaitingDotAnimationIfNeeded()
        textView.isHidden = false
        textView.attributedText = nil
        lastTailGradientRanges.removeAll(keepingCapacity: false)
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyStreamingTailGradient()
        }
    }

    override var intrinsicContentSize: CGSize {
        let textWidth = max(bounds.width - 12, 0)
        guard textWidth > 1 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 44)
        }

        if !imageProgressStack.isHidden {
            let labelSize = imageProgressLabel.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            )
            let baseHeight: CGFloat = 8 + 18 + 6 + 300 + 10 + 14
            let totalHeight = baseHeight + ceil(labelSize.height)
            return CGSize(width: UIView.noIntrinsicMetric, height: totalHeight)
        }

        if !waitingDotStack.isHidden {
            let totalHeight: CGFloat = 8 + 18 + 6 + 14 + 14
            return CGSize(width: UIView.noIntrinsicMetric, height: totalHeight)
        }

        let fitted = textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let totalHeight = 10 + 18 + 6 + fitted.height + 14
        return CGSize(width: UIView.noIntrinsicMetric, height: totalHeight)
    }

    private func setup() {
        backgroundColor = .clear

        containerStack.axis = .vertical
        containerStack.alignment = .fill
        containerStack.spacing = 6
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])

        identityStack.axis = .horizontal
        identityStack.alignment = .center
        identityStack.spacing = 7

        identityIconView.translatesAutoresizingMaskIntoConstraints = false
        identityIconView.image = UIImage(systemName: "sparkles")
        identityIconView.tintColor = .white
        identityIconView.contentMode = .center
        identityIconView.backgroundColor = .black
        identityIconView.layer.cornerRadius = 5
        identityIconView.layer.masksToBounds = true
        identityIconView.layer.borderWidth = 0.8
        identityIconView.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        NSLayoutConstraint.activate([
            identityIconView.widthAnchor.constraint(equalToConstant: 18),
            identityIconView.heightAnchor.constraint(equalToConstant: 18)
        ])

        identityNameLabel.text = "IEXA"
        identityNameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        identityNameLabel.textColor = .label

        identityStack.addArrangedSubview(identityIconView)
        identityStack.addArrangedSubview(identityNameLabel)
        identityStack.addArrangedSubview(UIView())
        containerStack.addArrangedSubview(identityStack)

        imageProgressStack.axis = .vertical
        imageProgressStack.alignment = .leading
        imageProgressStack.spacing = 10
        imageProgressStack.isHidden = true

        imageProgressCard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageProgressCard.widthAnchor.constraint(equalToConstant: 300),
            imageProgressCard.heightAnchor.constraint(equalToConstant: 300)
        ])

        imageProgressLabel.text = "正在生成图片…"
        imageProgressLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        imageProgressLabel.textColor = .secondaryLabel

        imageProgressStack.addArrangedSubview(imageProgressCard)
        imageProgressStack.addArrangedSubview(imageProgressLabel)
        containerStack.addArrangedSubview(imageProgressStack)

        waitingDotStack.axis = .horizontal
        waitingDotStack.alignment = .leading
        waitingDotStack.distribution = .fill
        waitingDotStack.spacing = 0
        waitingDotStack.isHidden = true

        waitingDotView.translatesAutoresizingMaskIntoConstraints = false
        waitingDotView.backgroundColor = .black
        waitingDotView.layer.cornerRadius = 3.5
        waitingDotView.layer.masksToBounds = true
        NSLayoutConstraint.activate([
            waitingDotView.widthAnchor.constraint(equalToConstant: 7),
            waitingDotView.heightAnchor.constraint(equalToConstant: 7)
        ])
        waitingDotView.setContentHuggingPriority(.required, for: .horizontal)
        waitingDotView.setContentCompressionResistancePriority(.required, for: .horizontal)

        waitingDotSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        waitingDotSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        waitingDotStack.addArrangedSubview(waitingDotView)
        waitingDotStack.addArrangedSubview(waitingDotSpacer)
        containerStack.addArrangedSubview(waitingDotStack)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isUserInteractionEnabled = true
        textView.isScrollEnabled = false
        textView.isOpaque = false
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = []
        textView.backgroundColor = .clear
        textView.layer.backgroundColor = UIColor.clear.cgColor
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.layer.masksToBounds = true
        containerStack.addArrangedSubview(textView)
    }

    private var bodyTextAttributes: [NSAttributedString.Key: Any] {
        let bodyFont = UIFont(name: "PingFangSC-Medium", size: 16) ?? UIFont.systemFont(ofSize: 16, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4.2
        paragraph.paragraphSpacing = 2
        return [
            .font: bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
    }

    private var codeTextAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.8
        paragraph.paragraphSpacing = 4
        return [
            .font: UIFont.monospacedSystemFont(ofSize: 13.5, weight: .medium),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
    }

    private func appendStreamingText(_ rawText: String) -> Int {
        guard !rawText.isEmpty else { return 0 }

        let storage = textView.textStorage
        storage.beginEditing()
        defer {
            storage.endEditing()
        }

        var visibleAppended = 0
        var runText = ""
        var runStyle: RenderStyle = inCodeBlock ? .code : .body

        func flushRun() {
            guard !runText.isEmpty else { return }
            let attributes = runStyle == .code ? codeTextAttributes : bodyTextAttributes
            storage.append(NSAttributedString(string: runText, attributes: attributes))
            visibleAppended += runText.count
            runText.removeAll(keepingCapacity: true)
        }

        func appendPendingBackticksAsLiteral() {
            guard pendingFenceTickCount > 0 else { return }
            runStyle = inCodeBlock ? .code : .body
            runText.append(String(repeating: "`", count: pendingFenceTickCount))
            pendingFenceTickCount = 0
        }

        for character in rawText {
            if character == "`" {
                pendingFenceTickCount += 1
                if pendingFenceTickCount == 3 {
                    flushRun()
                    pendingFenceTickCount = 0
                    inCodeBlock.toggle()
                    waitingForCodeLanguageLine = inCodeBlock
                    languageProbe.removeAll(keepingCapacity: false)
                    runStyle = inCodeBlock ? .code : .body
                }
                continue
            }

            appendPendingBackticksAsLiteral()

            if inCodeBlock && waitingForCodeLanguageLine {
                if character == "\n" {
                    waitingForCodeLanguageLine = false
                    languageProbe.removeAll(keepingCapacity: false)
                } else if character == " " || character == "\t" || languageProbe.count >= 20 {
                    waitingForCodeLanguageLine = false
                    let fallback = languageProbe + String(character)
                    languageProbe.removeAll(keepingCapacity: false)
                    if !fallback.isEmpty {
                        let nextStyle: RenderStyle = .code
                        if nextStyle != runStyle {
                            flushRun()
                            runStyle = nextStyle
                        }
                        runText.append(fallback)
                    }
                } else {
                    languageProbe.append(character)
                }
                continue
            }

            let nextStyle: RenderStyle = inCodeBlock ? .code : .body
            if nextStyle != runStyle {
                flushRun()
                runStyle = nextStyle
            }
            runText.append(character)
        }

        flushRun()
        pendingGradientCharacters += visibleAppended
        if rawText.contains("\n") || pendingGradientCharacters >= 14 {
            applyStreamingTailGradient()
            pendingGradientCharacters = 0
        }
        return visibleAppended
    }

    private func resetParserState() {
        pendingFenceTickCount = 0
        inCodeBlock = false
        waitingForCodeLanguageLine = false
        languageProbe.removeAll(keepingCapacity: false)
    }

    private func shouldInvalidateLayout(forRawSuffix suffix: String, appendedVisibleCharacters: Int) -> Bool {
        guard appendedVisibleCharacters > 0 else { return false }
        pendingLayoutCharacters += appendedVisibleCharacters
        if suffix.contains("\n") || pendingLayoutCharacters >= 24 {
            pendingLayoutCharacters = 0
            return true
        }
        return false
    }

    private func enqueueStreamingDisplayText(_ text: String) {
        guard !text.isEmpty else { return }
        pendingDisplayText.append(text)
        startDisplayLinkIfNeeded()
    }

    @objc
    private func handleStreamingDisplayTick(_ link: CADisplayLink) {
        guard !pendingDisplayText.isEmpty else {
            stopDisplayLinkIfNeeded()
            return
        }

        if lastDisplayLinkTimestamp > 0, link.timestamp - lastDisplayLinkTimestamp < (1.0 / 60.0) {
            return
        }
        lastDisplayLinkTimestamp = link.timestamp

        let step = displayStepSize(for: pendingDisplayText.count)
        let chunk = consumeDisplayPrefix(maxCharacters: step)
        guard !chunk.isEmpty else { return }

        let appendedVisibleCharacters = appendStreamingText(chunk)
        if shouldInvalidateLayout(forRawSuffix: chunk, appendedVisibleCharacters: appendedVisibleCharacters) {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private func consumeDisplayPrefix(maxCharacters: Int) -> String {
        guard maxCharacters > 0, !pendingDisplayText.isEmpty else { return "" }
        let end = pendingDisplayText.index(
            pendingDisplayText.startIndex,
            offsetBy: maxCharacters,
            limitedBy: pendingDisplayText.endIndex
        ) ?? pendingDisplayText.endIndex
        let prefix = String(pendingDisplayText[..<end])
        pendingDisplayText.removeSubrange(..<end)
        return prefix
    }

    private func displayStepSize(for pendingCharacters: Int) -> Int {
        switch pendingCharacters {
        case 700...:
            return 10
        case 360...:
            return 8
        case 180...:
            return 6
        case 96...:
            return 5
        case 40...:
            return 3
        case 16...:
            return 2
        default:
            return 1
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard streamDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleStreamingDisplayTick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        } else {
            link.preferredFramesPerSecond = 60
        }
        link.add(to: .main, forMode: .common)
        streamDisplayLink = link
        lastDisplayLinkTimestamp = 0
    }

    private func stopDisplayLinkIfNeeded() {
        streamDisplayLink?.invalidate()
        streamDisplayLink = nil
        lastDisplayLinkTimestamp = 0
        if pendingGradientCharacters > 0 {
            applyStreamingTailGradient()
            pendingGradientCharacters = 0
        }
    }

    private func applyStreamingTailGradient() {
        let storage = textView.textStorage

        if !lastTailGradientRanges.isEmpty {
            let totalLength = storage.length
            for rawRange in lastTailGradientRanges {
                guard rawRange.location < totalLength else { continue }
                let clampedLength = min(rawRange.length, totalLength - rawRange.location)
                guard clampedLength > 0 else { continue }
                storage.addAttribute(
                    .foregroundColor,
                    value: UIColor.label,
                    range: NSRange(location: rawRange.location, length: clampedLength)
                )
            }
            lastTailGradientRanges.removeAll(keepingCapacity: true)
        }

        let length = storage.length
        guard length > 0 else { return }

        let tipCount = min(4, length)
        let midCount = min(10, max(0, length - tipCount))
        let fadeCount = min(14, max(0, length - tipCount - midCount))
        let base = UIColor.label
        let tipColor = base.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.58 : 0.46)
        let midColor = base.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.72 : 0.62)
        let fadeColor = base.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.86 : 0.80)

        var ranges: [NSRange] = []
        var cursor = length

        if tipCount > 0 {
            let range = NSRange(location: cursor - tipCount, length: tipCount)
            storage.addAttribute(.foregroundColor, value: tipColor, range: range)
            ranges.append(range)
            cursor -= tipCount
        }

        if midCount > 0 {
            let range = NSRange(location: cursor - midCount, length: midCount)
            storage.addAttribute(.foregroundColor, value: midColor, range: range)
            ranges.append(range)
            cursor -= midCount
        }

        if fadeCount > 0 {
            let range = NSRange(location: cursor - fadeCount, length: fadeCount)
            storage.addAttribute(.foregroundColor, value: fadeColor, range: range)
            ranges.append(range)
        }

        lastTailGradientRanges = ranges
    }

    private func startWaitingDotAnimationIfNeeded() {
        guard !waitingDotAnimationRunning else { return }
        waitingDotAnimationRunning = true

        waitingDotView.layer.removeAllAnimations()
        waitingDotView.alpha = 0.95
        waitingDotView.transform = .identity

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0.30
        opacityAnimation.toValue = 0.95
        opacityAnimation.duration = 0.62
        opacityAnimation.autoreverses = true
        opacityAnimation.repeatCount = .infinity
        opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        waitingDotView.layer.add(opacityAnimation, forKey: "breathingOpacity")

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 0.68
        scaleAnimation.toValue = 1.0
        scaleAnimation.duration = 0.62
        scaleAnimation.autoreverses = true
        scaleAnimation.repeatCount = .infinity
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        waitingDotView.layer.add(scaleAnimation, forKey: "breathingScale")
    }

    private func stopWaitingDotAnimationIfNeeded() {
        guard waitingDotAnimationRunning else { return }
        waitingDotAnimationRunning = false
        waitingDotView.layer.removeAnimation(forKey: "breathingOpacity")
        waitingDotView.layer.removeAnimation(forKey: "breathingScale")
        waitingDotView.alpha = 1
        waitingDotView.transform = .identity
    }

    private static func normalizedStreamingText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func streamingSectionizedText(_ raw: String) -> String {
        let text = normalizedStreamingText(raw)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 280, !trimmed.contains("```") else { return text }

        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard paragraphs.count >= 3 else { return text }

        var chunks: [String] = []
        var buffer: [String] = []
        var bufferLength = 0

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            chunks.append(buffer.joined(separator: "\n\n"))
            buffer.removeAll(keepingCapacity: true)
            bufferLength = 0
        }

        for paragraph in paragraphs {
            let candidateLength = bufferLength + paragraph.count + (buffer.isEmpty ? 0 : 2)
            let shouldBreakForHeading = !buffer.isEmpty && isSectionHeading(paragraph)
            let shouldBreakForLength = candidateLength >= 420

            if shouldBreakForHeading || shouldBreakForLength {
                flushBuffer()
            }

            buffer.append(paragraph)
            bufferLength += paragraph.count + (buffer.count > 1 ? 2 : 0)

            if bufferLength >= 320 {
                flushBuffer()
            }
        }

        flushBuffer()
        guard chunks.count >= 2 else { return text }

        return chunks.joined(separator: "\n\n▎▎▎\n\n")
    }

    private static func isSectionHeading(_ paragraph: String) -> Bool {
        let firstLine = paragraph
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return false }

        if firstLine.hasPrefix("#") { return true }
        if firstLine.hasSuffix("：") || firstLine.hasSuffix(":") { return true }
        if firstLine.count <= 24 && !firstLine.contains("。") && !firstLine.contains("，") {
            return true
        }
        return false
    }

    private static func streamingDisplayDeltaText(_ raw: String) -> String {
        var text = normalizedStreamingText(raw)
        text = text.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*•]\\s+", with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*\\d+[\\.)、]\\s+", with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*>\\s?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*([-*_])\\1{2,}\\s*$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<!`)`([^`\\n]+)`(?!`)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text
    }
}

private final class ImageGenerationProgressCardView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground
        layer.cornerRadius = 16
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let dotColor = UIColor.label.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.24 : 0.20)
        context.setFillColor(dotColor.cgColor)

        let spacing: CGFloat = 18
        let radius: CGFloat = 1.25
        var y: CGFloat = 12
        while y < rect.height - 8 {
            var x: CGFloat = 12
            while x < rect.width - 8 {
                context.fillEllipse(
                    in: CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
                x += spacing
            }
            y += spacing
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = UIColor.black.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.14 : 0.08).cgColor
        setNeedsDisplay()
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
