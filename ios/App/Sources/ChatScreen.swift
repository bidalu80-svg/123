import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ChatScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    private let sidebarWidth: CGFloat = 280
    private let edgeDragActivationWidth: CGFloat = 28

    @State private var showErrorAlert = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var isSidebarOpen = false
    @State private var showSettingsSheet = false
    @State private var showTestSheet = false
    @GestureState private var sidebarDragTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            mainContent
                .offset(x: sidebarRevealWidth)
                .disabled(sidebarRevealWidth > 0.01)
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: isSidebarOpen)

            if sidebarRevealWidth > 0.01 {
                Color.black.opacity(0.22 * (sidebarRevealWidth / sidebarWidth))
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9)) {
                            isSidebarOpen = false
                        }
                    }
            }

            sessionSidebar
                .offset(x: sidebarRevealWidth - sidebarWidth)
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: isSidebarOpen)
        }
        .navigationBarHidden(true)
        .highPriorityGesture(sidebarDragGesture)
        .onChange(of: viewModel.errorMessage) { _, newValue in
            showErrorAlert = !newValue.isEmpty
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    let mimeType = newItem.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                    await MainActor.run {
                        viewModel.setDraftImage(data: data, mimeType: mimeType)
                        selectedPhotoItem = nil
                    }
                }
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
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
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.15)
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("IEXA")
                    .font(.title3.weight(.semibold))
            }

            Spacer()
            Button {
                viewModel.createNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Menu {
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
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if viewModel.messages.isEmpty {
                        ContentUnavailableView(
                            "今天想聊点什么？",
                            systemImage: "message",
                            description: Text("你可以发送文本、图片或代码文件。")
                        )
                        .padding(.top, 96)
                    }

                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(message: message, codeThemeMode: viewModel.config.codeThemeMode)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: viewModel.streamScrollTrigger) { _, _ in
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let attachment = viewModel.draftImageAttachment {
                draftImagePreview(attachment)
            }

            if let file = viewModel.draftFileAttachment {
                draftFilePreview(file)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("发送图片", systemImage: "photo")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("发送文件", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.systemGray6)))
                }
                .buttonStyle(.plain)

                TextField("有问题，尽管问", text: $viewModel.draftMessage, axis: .vertical)
                    .lineLimit(1...6)
                    .submitLabel(.send)
                    .onSubmit {
                        guard viewModel.canSend else { return }
                        Task { await viewModel.sendCurrentMessage() }
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
                    .foregroundStyle(viewModel.canSend || viewModel.isSending ? Color.white : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(viewModel.canSend || viewModel.isSending ? Color.black : Color(.systemGray6)))
                }
                .disabled(!viewModel.canSend && !viewModel.isSending)
            }
            .padding(10)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider().opacity(0.18)
        }
    }

    private var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("聊天记录")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.createNewSession()
                    isSidebarOpen = false
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }
            .padding()

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
        .frame(width: 250)
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

    private var sidebarDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($sidebarDragTranslation) { value, state, _ in
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
    private func draftImagePreview(_ attachment: ChatImageAttachment) -> some View {
        if let data = attachment.decodedImageData, let uiImage = UIImage(data: data) {
            HStack(spacing: 10) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("已添加图片")
                        .font(.caption)
                    Text(attachment.mimeType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("移除") {
                    viewModel.removeDraftImage()
                }
                .buttonStyle(.borderedProminent)
                .font(.caption2)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
