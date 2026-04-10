import SwiftUI

struct ChatScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showErrorAlert = false

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
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastID = viewModel.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            TextField("输入消息内容…", text: $viewModel.draftMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)

            HStack {
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
                .disabled(viewModel.isSending)
            }
        }
        .padding()
    }
}
