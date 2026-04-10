import SwiftUI
import PhotosUI
import UIKit

struct ChatScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showErrorAlert = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            composer
        }
        .navigationTitle("ChatApp")
        .navigationBarTitleDisplayMode(.inline)
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
        .alert("错误", isPresented: $showErrorAlert) {
            Button("确定") {
                viewModel.errorMessage = ""
                showErrorAlert = false
            }
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("状态：\(viewModel.statusMessage)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("模型：\(viewModel.config.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("示例") {
                viewModel.loadDemoContent()
            }
            .buttonStyle(.bordered)
            Button("清空") {
                viewModel.clearMessages()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty {
                        ContentUnavailableView(
                            "还没有消息",
                            systemImage: "text.bubble",
                            description: Text("填写配置后发送第一条消息，即可开始测试聊天、流式响应和 UI。")
                        )
                        .padding(.top, 80)
                    }

                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
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

            TextField("输入消息内容…", text: $viewModel.draftMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)

            HStack {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("图片", systemImage: "photo")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                if viewModel.draftImageAttachment != nil {
                    Button("移除") {
                        viewModel.removeDraftImage()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }

                Text("会话数：\(viewModel.messages.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(viewModel.isSending ? "发送中…" : "发送") {
                    Task {
                        await viewModel.sendCurrentMessage()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSending || (viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.draftImageAttachment == nil))
            }
        }
        .padding()
    }

    @ViewBuilder
    private func draftImagePreview(_ attachment: ChatImageAttachment) -> some View {
        if let data = attachment.decodedImageData, let uiImage = UIImage(data: data) {
            HStack(spacing: 12) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("已选择图片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(attachment.mimeType)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("移除") {
                    viewModel.removeDraftImage()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = viewModel.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
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
