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
    private let scrollTopAnchor = "scroll-top-anchor"
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
    @GestureState private var sidebarDragTranslation: CGFloat = 0
    @State private var recentAssets: [PHAsset] = []
    @State private var recentThumbnails: [String: UIImage] = [:]
    @State private var sidebarAnimationLock = false
    @FocusState private var isComposerFocused: Bool
    @StateObject private var speechToText = SpeechToTextService(localeIdentifier: "zh-CN")
    @State private var speechDraftPrefix = ""
    @State private var showInitialConfigSheet = false

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
                    color: Color.black.opacity(0.18 * sidebarRevealProgress),
                    radius: 24 * sidebarRevealProgress,
                    x: 0,
                    y: 0
                )
                .offset(x: sidebarRevealWidth)
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: isSidebarOpen)

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
            .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("IEXA")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 10) {
                Button {
                    setSidebarOpen(!isSidebarOpen)
                } label: {
                    TwoLineMenuIcon()
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .frame(width: 36, alignment: .leading)

                Spacer(minLength: 0)

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

                Spacer(minLength: 0)

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
                                .fill(viewModel.isPrivateMode ? Color.black : Color(.secondarySystemBackground))
                                .frame(width: 36, height: 36)

                            Text("👻")
                                .font(.system(size: 16))
                                .opacity(viewModel.isPrivateMode ? 1 : 0.8)
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
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }


    private var messageList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        Color.clear
                            .frame(height: 1)
                            .id(scrollTopAnchor)

                        ForEach(viewModel.messages) { message in
                            let isLatestAssistant = message.id == latestAssistantMessageID
                            MessageBubbleView(
                                message: message,
                                codeThemeMode: viewModel.config.codeThemeMode,
                                apiKey: viewModel.config.apiKey,
                                apiBaseURL: viewModel.config.normalizedBaseURL,
                                showsAssistantActionBar: message.role == .assistant && !message.isStreaming,
                                onRegenerate: (isLatestAssistant && viewModel.config.endpointMode == .chatCompletions && !viewModel.isPrivateMode) ? {
                                    Task { await viewModel.regenerateLastAssistantReply() }
                                } : nil
                            )
                                .id(message.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 12)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6).onChanged { _ in
                        if isPinnedToBottom {
                            isPinnedToBottom = false
                        }
                    }
                )
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    guard let lastMessage = viewModel.messages.last else { return }
                    if lastMessage.role == .user {
                        isPinnedToBottom = true
                    }
                    if isPinnedToBottom || lastMessage.role == .user {
                        scrollToBottom(proxy, animated: true)
                    }
                }
                .onChange(of: viewModel.streamScrollTrigger) { _, _ in
                    if isPinnedToBottom {
                        scrollToBottom(proxy, animated: false)
                    }
                }

                if shouldShowCenterScrollDownButton {
                    scrollDownButton(proxy: proxy)
                        .padding(.bottom, 12)
                }
            }
        }
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
        TextField(composerPlaceholderText, text: $viewModel.draftMessage, axis: .vertical)
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


    private func scrollDownButton(proxy: ScrollViewProxy) -> some View {
        Button {
            isPinnedToBottom = true
            scrollToBottom(proxy, animated: true)
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
        let fallback = ["gpt-5.4-pro", "gpt-5.4", "gpt-5.2", "gpt-4.1"]
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
        shouldShowScrollJumpButtons && !isPinnedToBottom
    }

    private var latestAssistantMessageID: UUID? {
        viewModel.messages.last(where: { $0.role == .assistant })?.id
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
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundStyle(Color.black.opacity(0.08)),
            alignment: .trailing
        )
    }

    private var sidebarRevealWidth: CGFloat {
        let base = isSidebarOpen ? sidebarWidth : 0
        return min(max(base + sidebarDragTranslation, 0), sidebarWidth)
    }

    private var sidebarRevealProgress: CGFloat {
        guard sidebarWidth > 0 else { return 0 }
        return min(max(sidebarRevealWidth / sidebarWidth, 0), 1)
    }

    private var sidebarDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($sidebarDragTranslation) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.35 else {
                    return
                }

                if !isSidebarOpen && value.startLocation.x > edgeDragActivationWidth {
                    return
                }

                if isSidebarOpen {
                    state = min(0, value.translation.width)
                } else {
                    state = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.35 else {
                    return
                }

                if !isSidebarOpen && value.startLocation.x > edgeDragActivationWidth {
                    return
                }

                let projected = value.translation.width + (value.predictedEndTranslation.width - value.translation.width) * 0.25
                let finalReveal = min(
                    max((isSidebarOpen ? sidebarWidth : 0) + projected, 0),
                    sidebarWidth
                )

                setSidebarOpen(finalReveal > sidebarWidth * 0.5, force: true)
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

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = viewModel.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func setSidebarOpen(_ open: Bool, force: Bool = false) {
        if !force && sidebarAnimationLock { return }
        guard isSidebarOpen != open else { return }
        sidebarAnimationLock = true
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
            isSidebarOpen = open
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            sidebarAnimationLock = false
        }
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
