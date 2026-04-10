import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var config: ChatConfig
    @Published var draftMessage = ""
    @Published var messages: [ChatMessage] = [] {
        didSet {
            ChatSessionStore.save(messages)
        }
    }
    @Published var isSending = false
    @Published var errorMessage = ""
    @Published var statusMessage = "准备就绪"
    @Published var testLogs: [String] = []

    private let service: ChatService

    init(service: ChatService = ChatService()) {
        self.service = service
        self.config = ChatConfigStore.load()
        self.messages = ChatSessionStore.load()
    }

    func sendCurrentMessage() async {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        errorMessage = ""
        statusMessage = "正在发送请求…"
        isSending = true

        let historyBeforeSend = messages
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        draftMessage = ""

        let placeholderID = UUID()
        messages.append(ChatMessage(id: placeholderID, role: .assistant, content: "", isStreaming: config.streamEnabled))

        do {
            let fullReply = try await service.sendMessage(
                config: config,
                history: historyBeforeSend,
                message: text,
                onEvent: { [weak self] delta in
                    Task { @MainActor in
                        self?.appendStreamingText(delta, to: placeholderID)
                    }
                }
            )
            finishStreamingMessage(id: placeholderID, finalContent: fullReply)
            statusMessage = "消息发送成功"
            appendLog("聊天测试成功：收到完整回复。")
        } catch {
            removeMessage(id: placeholderID)
            errorMessage = error.localizedDescription
            statusMessage = "发送失败"
            appendLog("聊天测试失败：\(error.localizedDescription)")
        }

        isSending = false
    }

    func saveConfig() {
        config.apiURL = ChatConfigStore.normalizedURL(config.apiURL)
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        ChatConfigStore.save(config)
        statusMessage = "配置已保存"
        appendLog("配置测试：配置已保存。")
    }

    func resetConfig() {
        ChatConfigStore.reset()
        config = ChatConfigStore.load()
        statusMessage = "配置已重置"
        appendLog("配置测试：配置已重置为默认值。")
    }

    func clearMessages() {
        messages.removeAll()
        statusMessage = "会话已清空"
        appendLog("UI 测试：消息列表已清空。")
    }

    func loadDemoContent() {
        if config.apiURL.isEmpty {
            config.apiURL = ChatConfig.default.apiURL
        }
        if config.model.isEmpty {
            config.model = ChatConfig.default.model
        }
        draftMessage = "你好，请介绍一下你自己。"
        appendLog("UI 测试：已填充示例配置和示例消息。")
    }

    func runConnectionTest() async {
        statusMessage = "正在执行接口测试…"
        let result = await service.testConnection(config: config)
        statusMessage = result
        appendLog("接口测试：\(result)")
    }

    func runStreamSmokeTest() async {
        draftMessage = "请回复：stream ok"
        appendLog("流式测试：已写入测试消息。")
        await sendCurrentMessage()
    }

    private func appendStreamingText(_ text: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += text
        messages[index].isStreaming = config.streamEnabled
    }

    private func finishStreamingMessage(id: UUID, finalContent: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = finalContent
        messages[index].isStreaming = false
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    private func appendLog(_ log: String) {
        testLogs.insert("[\(Date().formatted(date: .omitted, time: .standard))] \(log)", at: 0)
    }
}
