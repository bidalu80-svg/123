import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var config: ChatConfig {
        didSet {
            guard autoSaveEnabled else { return }
            ChatConfigStore.save(config)
        }
    }

    @Published var draftMessage = ""
    @Published var messages: [ChatMessage] = []
    @Published var sessions: [ChatSession] = []
    @Published var currentSessionID: UUID?

    @Published var isSending = false
    @Published var errorMessage = ""
    @Published var statusMessage = "准备就绪"
    @Published var testLogs: [String] = []

    @Published var draftImageAttachment: ChatImageAttachment?
    @Published var draftFileAttachment: ChatFileAttachment?

    @Published var streamScrollTrigger: Int = 0
    @Published var availableModels: [String] = []
    @Published var selectedModelFromList: String = ""
    @Published var isLoadingModels = false

    private let service: ChatService
    private var autoSaveEnabled = false
    private var lastStreamScrollSignal: Date = .distantPast
    private var inflightSendTask: Task<ChatReply, Error>?

    init(service: ChatService = ChatService()) {
        self.service = service
        self.config = ChatConfigStore.load()
        self.sessions = ChatSessionStore.loadSessions()
        self.currentSessionID = ChatSessionStore.loadCurrentSessionID()

        if sessions.isEmpty {
            let first = ChatSession(title: "新会话")
            sessions = [first]
            currentSessionID = first.id
            persistSessions()
        }

        if currentSessionID == nil || sessions.first(where: { $0.id == currentSessionID }) == nil {
            currentSessionID = sessions.first?.id
        }

        syncMessagesFromCurrentSession()
        selectedModelFromList = config.model
        autoSaveEnabled = true
    }

    var preferredColorScheme: ColorScheme? {
        switch config.themeMode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var sessionCountText: String {
        "会话数：\(sessions.count)"
    }

    var canSend: Bool {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isSending && (!text.isEmpty || draftImageAttachment != nil || draftFileAttachment != nil)
    }

    func sendCurrentMessage() async {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = draftImageAttachment
        let file = draftFileAttachment
        guard !text.isEmpty || image != nil || file != nil else { return }
        guard !isSending else { return }

        errorMessage = ""
        statusMessage = "正在发送请求…"
        isSending = true

        let userMessage = ChatMessage(
            role: .user,
            content: text,
            imageAttachments: image.map { [$0] } ?? [],
            fileAttachments: file.map { [$0] } ?? []
        )

        var historyBeforeSend: [ChatMessage] = []
        if let current = currentSessionIndex {
            historyBeforeSend = sessions[current].messages
            sessions[current].messages.append(userMessage)
            sessions[current].updatedAt = Date()
            sessions[current].title = buildSessionTitle(from: sessions[current])
            messages = sessions[current].messages
        }

        draftMessage = ""
        draftImageAttachment = nil
        draftFileAttachment = nil

        let placeholderID = UUID()
        let placeholder = ChatMessage(
            id: placeholderID,
            role: .assistant,
            content: "",
            isStreaming: config.streamEnabled
        )
        appendMessageToCurrentSession(placeholder)
        persistSessions()
        signalStreamScroll(force: true)

        let task = Task<ChatReply, Error> { [service, config] in
            try await service.sendMessage(
                config: config,
                history: historyBeforeSend,
                message: userMessage,
                onEvent: { [weak self] chunk in
                    Task { @MainActor in
                        self?.appendStreamingChunk(chunk, to: placeholderID)
                    }
                }
            )
        }
        inflightSendTask = task

        do {
            let reply = try await task.value
            finishStreamingMessage(id: placeholderID, reply: reply)
            statusMessage = "消息发送成功"
            appendLog("聊天测试成功：收到完整回复。")
        } catch is CancellationError {
            finishCancellation(id: placeholderID)
        } catch {
            removeMessage(id: placeholderID)
            errorMessage = error.localizedDescription
            statusMessage = "发送失败"
            appendLog("聊天测试失败：\(error.localizedDescription)")
        }

        inflightSendTask = nil
        isSending = false
        persistSessions()
    }

    func stopGenerating() {
        inflightSendTask?.cancel()
        inflightSendTask = nil
    }

    func saveConfig() {
        config = normalizedConfigForSave(config)
        statusMessage = "配置已保存"
        appendLog("配置测试：配置已保存。")
    }

    func resetConfig() {
        ChatConfigStore.reset()
        autoSaveEnabled = false
        config = ChatConfigStore.load()
        selectedModelFromList = config.model
        autoSaveEnabled = true
        statusMessage = "配置已重置"
        appendLog("配置测试：配置已重置为默认值。")
    }

    func clearCurrentSessionMessages() {
        guard let index = currentSessionIndex else { return }
        sessions[index].messages.removeAll()
        sessions[index].updatedAt = Date()
        messages = []
        persistSessions()
        statusMessage = "当前会话已清空"
        appendLog("UI 测试：当前会话消息已清空。")
    }

    func clearAllSessions() {
        sessions.removeAll()
        let first = ChatSession(title: "新会话")
        sessions = [first]
        currentSessionID = first.id
        messages = []
        persistSessions()
        statusMessage = "全部会话已清空"
        appendLog("UI 测试：全部会话已清空。")
    }

    func createNewSession() {
        let session = ChatSession(title: "新会话")
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        messages = []
        persistSessions()
    }

    func selectSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        currentSessionID = id
        syncMessagesFromCurrentSession()
        persistSessions()
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            let first = ChatSession(title: "新会话")
            sessions = [first]
            currentSessionID = first.id
        } else if currentSessionID == id {
            currentSessionID = sessions.first?.id
        }
        syncMessagesFromCurrentSession()
        persistSessions()
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
        let result = await service.testConnection(config: normalizedConfigForSave(config))
        statusMessage = result
        appendLog("接口测试：\(result)")
    }

    func runStreamSmokeTest() async {
        draftMessage = "请回复：stream ok"
        appendLog("流式测试：已写入测试消息。")
        await sendCurrentMessage()
    }

    func refreshAvailableModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            let models = try await service.fetchModels(config: normalizedConfigForSave(config))
            availableModels = models
            if !models.contains(config.model), let first = models.first {
                config.model = first
            }
            selectedModelFromList = config.model
            statusMessage = "模型列表已更新（\(models.count) 个）"
            appendLog("模型测试：已获取 \(models.count) 个模型。")
        } catch {
            appendLog("模型测试失败：\(error.localizedDescription)")
            statusMessage = "模型列表获取失败"
            errorMessage = error.localizedDescription
        }
    }

    func applySelectedModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.model = trimmed
        selectedModelFromList = trimmed
    }

    func setDraftImage(data: Data, mimeType: String) {
        draftImageAttachment = ChatImageAttachment.fromImageData(data, mimeType: mimeType)
    }

    func removeDraftImage() {
        draftImageAttachment = nil
    }

    func setDraftFile(name: String, mimeType: String, text: String) {
        draftFileAttachment = ChatFileAttachment(
            fileName: name,
            mimeType: mimeType,
            textContent: text
        )
    }

    func removeDraftFile() {
        draftFileAttachment = nil
    }

    private var currentSessionIndex: Int? {
        guard let currentSessionID else { return nil }
        return sessions.firstIndex(where: { $0.id == currentSessionID })
    }

    private func appendStreamingChunk(_ chunk: StreamChunk, to id: UUID) {
        guard let index = currentSessionIndex,
              let msgIndex = sessions[index].messages.firstIndex(where: { $0.id == id }) else { return }

        if !chunk.deltaText.isEmpty {
            sessions[index].messages[msgIndex].content += chunk.deltaText
            sessions[index].messages[msgIndex].isStreaming = config.streamEnabled
        }

        if !chunk.imageURLs.isEmpty {
            let newImages = chunk.imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
            sessions[index].messages[msgIndex].imageAttachments.append(contentsOf: newImages)
            sessions[index].messages[msgIndex].imageAttachments = deduplicateImages(sessions[index].messages[msgIndex].imageAttachments)
        }

        sessions[index].updatedAt = Date()
        messages = sessions[index].messages
        signalStreamScroll()
    }

    private func finishStreamingMessage(id: UUID, reply: ChatReply) {
        guard let index = currentSessionIndex,
              let msgIndex = sessions[index].messages.firstIndex(where: { $0.id == id }) else { return }

        sessions[index].messages[msgIndex].content = reply.text
        sessions[index].messages[msgIndex].imageAttachments = deduplicateImages(
            sessions[index].messages[msgIndex].imageAttachments + reply.imageAttachments
        )
        sessions[index].messages[msgIndex].isStreaming = false
        sessions[index].updatedAt = Date()
        sessions[index].title = buildSessionTitle(from: sessions[index])
        messages = sessions[index].messages
        signalStreamScroll(force: true)
    }

    private func finishCancellation(id: UUID) {
        guard let index = currentSessionIndex,
              let msgIndex = sessions[index].messages.firstIndex(where: { $0.id == id }) else { return }

        sessions[index].messages[msgIndex].isStreaming = false
        if sessions[index].messages[msgIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            sessions[index].messages[msgIndex].imageAttachments.isEmpty {
            sessions[index].messages.remove(at: msgIndex)
        }

        sessions[index].updatedAt = Date()
        sessions[index].title = buildSessionTitle(from: sessions[index])
        messages = sessions[index].messages
        statusMessage = "已停止生成"
        appendLog("聊天测试：用户已停止本次生成。")
    }

    private func appendMessageToCurrentSession(_ message: ChatMessage) {
        guard let index = currentSessionIndex else { return }
        sessions[index].messages.append(message)
        sessions[index].updatedAt = Date()
        messages = sessions[index].messages
    }

    private func removeMessage(id: UUID) {
        guard let index = currentSessionIndex else { return }
        sessions[index].messages.removeAll { $0.id == id }
        sessions[index].updatedAt = Date()
        sessions[index].title = buildSessionTitle(from: sessions[index])
        messages = sessions[index].messages
    }

    private func appendLog(_ log: String) {
        testLogs.insert("[\(Date().formatted(date: .omitted, time: .standard))] \(log)", at: 0)
    }

    private func persistSessions() {
        ChatSessionStore.saveSessions(sessions, currentSessionID: currentSessionID)
    }

    private func syncMessagesFromCurrentSession() {
        guard let index = currentSessionIndex else {
            messages = []
            return
        }
        messages = sessions[index].messages
    }

    private func signalStreamScroll(force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastStreamScrollSignal) >= 0.08 {
            streamScrollTrigger &+= 1
            lastStreamScrollSignal = now
        }
    }

    private func buildSessionTitle(from session: ChatSession) -> String {
        if let firstUser = session.messages.first(where: { $0.role == .user }) {
            let text = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return String(text.prefix(24))
            }
            if let file = firstUser.fileAttachments.first {
                return file.fileName
            }
            if !firstUser.imageAttachments.isEmpty {
                return "图片会话"
            }
        }
        return "新会话"
    }

    private func deduplicateImages(_ images: [ChatImageAttachment]) -> [ChatImageAttachment] {
        var seen = Set<String>()
        var result: [ChatImageAttachment] = []
        for image in images {
            let key = image.requestURLString
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            result.append(image)
        }
        return result
    }

    private func normalizedConfigForSave(_ input: ChatConfig) -> ChatConfig {
        ChatConfig(
            apiURL: ChatConfigStore.normalizedBaseURL(input.apiURL),
            apiKey: input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: input.model.trimmingCharacters(in: .whitespacesAndNewlines),
            timeout: min(max(input.timeout, 5), 120),
            streamEnabled: input.streamEnabled,
            themeMode: input.themeMode,
            codeThemeMode: input.codeThemeMode
        )
    }
}
