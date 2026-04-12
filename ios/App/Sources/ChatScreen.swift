import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

struct ChatScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    private let sidebarWidth: CGFloat = 286
    private let edgeDragActivationWidth: CGFloat = 28
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
                            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
                                isSidebarOpen = false
                            }
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
                .plainText,
                .sourceCode,
                .json,
                .xml,
                .commaSeparatedText,
                .text
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
    }

    private var mainContent: some View {
        messageList
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
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
        HStack(spacing: 10) {
            Button {
                isSidebarOpen.toggle()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Text("IEXA")
                .font(.custom("Didot", size: 28))
                .italic()
                .kerning(1.2)
                .foregroundStyle(.primary)

            Menu {
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
                        .frame(width: 8, height: 8)
                    Text(shortModelName(viewModel.config.model))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
            .buttonStyle(.plain)

            Spacer()
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(message: message, codeThemeMode: viewModel.config.codeThemeMode)
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
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let lastMessage = viewModel.messages.last else { return }
                if isPinnedToBottom || lastMessage.role == .user {
                    scrollToBottom(proxy, animated: true)
                }
            }
            .onChange(of: viewModel.streamScrollTrigger) { _, _ in
                if isPinnedToBottom {
                    scrollToBottom(proxy, animated: false)
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

            HStack(alignment: .center, spacing: 10) {
                Button {
                    showAttachmentSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 23, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color(.systemGray6)))
                }
                .buttonStyle(.plain)

                TextField("有问题，尽管问", text: $viewModel.draftMessage)
                    .lineLimit(1)
                    .submitLabel(.send)
                    .onSubmit {
                        guard viewModel.canSend else { return }
                        Task { await viewModel.sendCurrentMessage() }
                    }
                    .font(.system(size: 17))
                    .frame(height: 38, alignment: .center)

                Button {
                    pasteClipboardIntoDraft(sendAfterPaste: false)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("粘贴到输入框", systemImage: "doc.on.clipboard") {
                        pasteClipboardIntoDraft(sendAfterPaste: false)
                    }
                    Button("粘贴并发送", systemImage: "paperplane") {
                        pasteClipboardIntoDraft(sendAfterPaste: true)
                    }
                    if viewModel.isSending {
                        Button("停止生成", systemImage: "stop.circle") {
                            viewModel.stopGenerating()
                        }
                    }
                }

                Button {
                    if viewModel.isSending {
                        viewModel.stopGenerating()
                    } else {
                        Task { await viewModel.sendCurrentMessage() }
                    }
                } label: {
                    Group {
                        if viewModel.isSending {
                            Image(systemName: "stop.fill")
                        } else if viewModel.canSend {
                            Image(systemName: "arrow.up")
                        } else {
                            Image(systemName: "waveform")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black))
                }
                .disabled(!viewModel.canSend && !viewModel.isSending)
            }
            .padding(.vertical, 6)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider().opacity(0.18)
        }
    }

    private var starterPromptStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("提示词")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("换一批") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        refreshStarterPrompts(force: true)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(activeStarterPrompts.enumerated()), id: \.offset) { _, prompt in
                        Button {
                            viewModel.draftMessage = "\(prompt.title)\n\(prompt.subtitle)"
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prompt.title)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(prompt.subtitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(.systemGray6))
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
                    quickToolRow(icon: "doc.text", title: "发送文件", subtitle: "上传文本和代码文件") {
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

    private func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "模型" }
        if trimmed.count <= 16 { return trimmed }
        return "\(trimmed.prefix(16))…"
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
                    isSidebarOpen = false
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
                isSidebarOpen = false
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

                withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
                    isSidebarOpen = finalReveal > sidebarWidth * 0.5
                }
            }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                viewModel.selectSession(session.id)
                isSidebarOpen = false
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
        if sendAfterPaste {
            Task { await viewModel.sendCurrentMessage() }
        }
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
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 1024 * 1024 else {
                    viewModel.errorMessage = "文件过大，请选择 1MB 以内文本/代码文件。"
                    return
                }

                guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
                    viewModel.errorMessage = "当前仅支持 UTF 文本/代码文件。"
                    return
                }

                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "text/plain"
                viewModel.setDraftFile(name: url.lastPathComponent, mimeType: mimeType, text: content)
            } catch {
                viewModel.errorMessage = "文件读取失败：\(error.localizedDescription)"
            }
        }
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
