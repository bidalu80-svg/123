import Foundation
import SwiftUI
import UIKit
import Network

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var config: ChatConfig {
        didSet {
            updateCurrentModelAvailability()
            guard autoSaveEnabled else { return }
            ChatConfigStore.save(config)
        }
    }

    @Published var draftMessage = ""
    @Published var messages: [ChatMessage] = []
    @Published var sessions: [ChatSession] = []
    @Published var currentSessionID: UUID?
    @Published var isPrivateMode = false

    @Published var isSending = false
    @Published var errorMessage = ""
    @Published var statusMessage = "准备就绪"
    @Published var testLogs: [String] = []

    @Published var draftImageAttachments: [ChatImageAttachment] = []
    @Published var draftFileAttachment: ChatFileAttachment?

    @Published var streamScrollTrigger: Int = 0
    @Published var availableModels: [String] = []
    @Published var selectedModelFromList: String = ""
    @Published var isLoadingModels = false
    @Published var isNetworkReachable = true
    @Published var isCurrentModelAvailable = false
    @Published var isShowingModelStatusRefresh = false
    @Published private(set) var hasValidatedModelList = false
    @Published var memoryEntries: [ConversationMemoryItem] = []
    @Published var isLoadingMemoryEntries = false

    private let service: ChatService
    private var autoSaveEnabled = false
    private let streamScrollThrottleInterval: TimeInterval = 0.11
    private var lastStreamScrollSignal: Date = .distantPast
    private var inflightSendTask: Task<ChatReply, Error>?
    private var privateMessages: [ChatMessage] = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "chatapp.network.monitor")

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
        updateCurrentModelAvailability()
        autoSaveEnabled = true
        startNetworkMonitor()
        Task {
            await prewarmRealtimeContext()
            await refreshMemoryEntries()
        }
    }

    deinit {
        pathMonitor?.cancel()
        pathMonitor = nil
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
        if config.endpointMode == .models {
            return !isSending
        }
        return !isSending && (!text.isEmpty || !draftImageAttachments.isEmpty || draftFileAttachment != nil)
    }

    var networkStatusText: String {
        isNetworkReachable ? "在线" : "离线"
    }

    func setPrivateMode(_ enabled: Bool) {
        guard enabled != isPrivateMode else { return }

        if isSending {
            stopGenerating()
        }

        isPrivateMode = enabled
        if enabled {
            privateMessages = []
            messages = []
            statusMessage = "已开启私密聊天（不会保存聊天记录）"
            appendLog("私密聊天：已开启（本次对话仅保存在内存）。")
        } else {
            privateMessages = []
            syncMessagesFromCurrentSession()
            statusMessage = "已关闭私密聊天"
            appendLog("私密聊天：已关闭（恢复普通会话）。")
        }
    }

    func sendCurrentMessage() async {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftImageAttachments
        let file = draftFileAttachment
        let hasPayload = !text.isEmpty || !images.isEmpty || file != nil
        if config.endpointMode != .models, !hasPayload { return }
        guard !isSending else { return }
        guard isNetworkReachable else {
            errorMessage = "当前网络不可用，请检查网络后重试。"
            statusMessage = "网络离线"
            appendLog("聊天发送失败：设备当前离线。")
            return
        }

        errorMessage = ""
        statusMessage = "正在请求\(config.endpointMode.title)…"
        isSending = true
        if config.soundEffectsEnabled {
            SoundEffectPlayer.playSend()
        }
        defer {
            inflightSendTask = nil
            isSending = false
            persistSessions()
            endBackgroundSendTask()
        }

        let userMessage = ChatMessage(
            role: .user,
            content: text.isEmpty && config.endpointMode == .models ? "列出可用模型" : text,
            imageAttachments: images,
            fileAttachments: file.map { [$0] } ?? []
        )

        var historyBeforeSend: [ChatMessage] = []
        if isPrivateMode {
            historyBeforeSend = privateMessages
            privateMessages.append(userMessage)
            messages = privateMessages
        } else if let current = currentSessionIndex {
            historyBeforeSend = sessions[current].messages
            sessions[current].messages.append(userMessage)
            sessions[current].updatedAt = Date()
            sessions[current].title = buildSessionTitle(from: sessions[current])
            messages = sessions[current].messages
        }

        draftMessage = ""
        draftImageAttachments = []
        draftFileAttachment = nil

        let placeholderID = UUID()
        let placeholder = ChatMessage(
            id: placeholderID,
            role: .assistant,
            content: "",
            isStreaming: config.streamEnabled && config.endpointMode == .chatCompletions
        )
        appendMessageToCurrentSession(placeholder)
        persistSessions()
        signalStreamScroll(force: true)
        beginBackgroundSendTask()

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
            statusMessage = "\(config.endpointMode.title)请求成功"
            appendLog("接口测试成功：\(config.endpointMode.title)已返回结果。")
        } catch is CancellationError {
            finishCancellation(id: placeholderID)
        } catch {
            if hasRenderableContent(for: placeholderID) {
                finishInterruption(id: placeholderID, error: error)
            } else {
                removeMessage(id: placeholderID)
                removeMessage(id: userMessage.id)
                errorMessage = error.localizedDescription
                statusMessage = "发送失败"
                appendLog("聊天测试失败：\(error.localizedDescription)")
            }
        }
    }

    func stopGenerating() {
        inflightSendTask?.cancel()
        inflightSendTask = nil
        endBackgroundSendTask()
    }

    func regenerateLastAssistantReply() async {
        guard !isPrivateMode else { return }
        guard !isSending, isNetworkReachable, let index = currentSessionIndex else { return }

        let sessionMessages = sessions[index].messages
        guard let lastUserIndex = sessionMessages.lastIndex(where: { $0.role == .user }) else { return }
        let userMessage = sessionMessages[lastUserIndex]
        let historyBeforeSend = Array(sessionMessages[..<lastUserIndex])

        sessions[index].messages.removeAll { $0.role == .assistant && $0.createdAt >= userMessage.createdAt }
        messages = sessions[index].messages
        persistSessions()

        errorMessage = ""
        statusMessage = "正在重新生成…"
        isSending = true
        if config.soundEffectsEnabled {
            SoundEffectPlayer.playSend()
        }
        defer {
            inflightSendTask = nil
            isSending = false
            persistSessions()
            endBackgroundSendTask()
        }

        let placeholderID = UUID()
        let placeholder = ChatMessage(
            id: placeholderID,
            role: .assistant,
            content: "",
            isStreaming: config.streamEnabled && config.endpointMode == .chatCompletions
        )
        appendMessageToCurrentSession(placeholder)
        persistSessions()
        signalStreamScroll(force: true)
        beginBackgroundSendTask()

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
            statusMessage = "重新生成成功"
            appendLog("聊天测试：已重新生成上一条回复。")
        } catch is CancellationError {
            finishCancellation(id: placeholderID)
        } catch {
            if hasRenderableContent(for: placeholderID) {
                finishInterruption(id: placeholderID, error: error)
            } else {
                removeMessage(id: placeholderID)
                errorMessage = error.localizedDescription
                statusMessage = "重新生成失败"
                appendLog("重新生成失败：\(error.localizedDescription)")
            }
        }
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
        hasValidatedModelList = false
        availableModels = []
        updateCurrentModelAvailability()
        statusMessage = "配置已重置"
        appendLog("配置测试：配置已重置为默认值。")
    }

    func clearCurrentSessionMessages() {
        if isPrivateMode {
            privateMessages.removeAll()
            messages = []
            statusMessage = "私密聊天已清空"
            appendLog("私密聊天：已清空当前私密消息。")
            return
        }

        guard let index = currentSessionIndex else { return }
        sessions[index].messages.removeAll()
        sessions[index].updatedAt = Date()
        messages = []
        persistSessions()
        statusMessage = "当前会话已清空"
        appendLog("UI 测试：当前会话消息已清空。")
    }

    func clearAllSessions() {
        if isPrivateMode {
            privateMessages.removeAll()
            messages = []
            statusMessage = "私密聊天已清空"
            appendLog("私密聊天：已清空。")
            return
        }

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

    func refreshMemoryEntries() async {
        isLoadingMemoryEntries = true
        defer { isLoadingMemoryEntries = false }
        memoryEntries = await service.loadMemoryEntries()
    }

    func clearAllMemoryEntries() async {
        await service.clearAllMemoryEntries()
        memoryEntries = []
        statusMessage = "已清空全部记忆"
        appendLog("记忆管理：已清空全部跨会话记忆。")
    }

    func removeMemoryEntry(id: UUID) async {
        await service.removeMemoryEntry(id: id)
        memoryEntries.removeAll { $0.id == id }
        statusMessage = "已删除记忆条目"
        appendLog("记忆管理：已删除 1 条记忆。")
    }

    func removeMemoryEntries(ids: [UUID]) async {
        await service.removeMemoryEntries(ids: ids)
        let deleting = Set(ids)
        memoryEntries.removeAll { deleting.contains($0.id) }
        statusMessage = "已批量删除记忆条目"
        appendLog("记忆管理：已批量删除 \(ids.count) 条记忆。")
    }


    func refreshAvailableModels(silent: Bool = false) async {
        if !silent {
            isLoadingModels = true
        } else {
            isShowingModelStatusRefresh = true
        }
        defer {
            if !silent {
                isLoadingModels = false
            } else {
                isShowingModelStatusRefresh = false
            }
        }

        do {
            let models = try await service.fetchModels(config: normalizedConfigForSave(config))
            availableModels = models
            hasValidatedModelList = true
            selectedModelFromList = config.model
            updateCurrentModelAvailability()
            if !silent {
                statusMessage = "模型列表已更新（\(models.count) 个）"
                appendLog("模型测试：已获取 \(models.count) 个模型。")
            }
        } catch {
            availableModels = []
            hasValidatedModelList = false
            updateCurrentModelAvailability()
            if !silent {
                appendLog("模型测试失败：\(error.localizedDescription)")
                statusMessage = "模型列表获取失败"
                errorMessage = error.localizedDescription
            }
        }
    }

    func applySelectedModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.model = trimmed
        selectedModelFromList = trimmed
    }

    func addDraftImage(data: Data, mimeType: String) {
        let attachment = ChatImageAttachment.fromImageData(data, mimeType: mimeType)
        draftImageAttachments.append(attachment)
        draftImageAttachments = deduplicateImages(draftImageAttachments)
    }

    func removeDraftImage(id: UUID) {
        draftImageAttachments.removeAll { $0.id == id }
    }

    func clearDraftImages() {
        draftImageAttachments = []
    }

    func setDraftFile(name: String, mimeType: String, text: String) {
        draftFileAttachment = ChatFileAttachment(
            fileName: name,
            mimeType: mimeType,
            textContent: text,
            binaryBase64: nil
        )
    }

    func setDraftBinaryFile(name: String, mimeType: String, textPreview: String, data: Data) {
        draftFileAttachment = ChatFileAttachment(
            fileName: name,
            mimeType: mimeType,
            textContent: textPreview,
            binaryBase64: data.base64EncodedString()
        )
    }

    func appDidEnterBackground() {
        guard isSending else { return }
        beginBackgroundSendTask()
        statusMessage = "已切到后台，正在尽力保持连接…"
        appendLog("应用进入后台：已申请后台任务，尽力维持本次请求。")
    }


    func appDidBecomeActive() {
        if isSending {
            statusMessage = "已回到前台，继续接收中…"
            appendLog("应用回到前台：继续处理本次请求。")
        }

        guard !isLoadingModels else { return }
        Task {
            async let prewarm: Void = prewarmRealtimeContext()
            async let refreshModels: Void = refreshAvailableModels(silent: true)
            _ = await (prewarm, refreshModels)
        }
    }

    func removeDraftFile() {
        draftFileAttachment = nil
    }

    private func prewarmRealtimeContext() async {
        let normalized = normalizedConfigForSave(config)
        guard normalized.realtimeContextEnabled else { return }
        await service.prewarmRealtimeContext(config: normalized)
    }

    private func updateCurrentModelAvailability() {
        let trimmed = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNetworkReachable, !trimmed.isEmpty, hasValidatedModelList else {
            isCurrentModelAvailable = false
            return
        }

        isCurrentModelAvailable = availableModels.contains(trimmed)
    }

    private var currentSessionIndex: Int? {
        sessions.firstIndex { $0.id == currentSessionID }
    }

    private func appendStreamingChunk(_ chunk: StreamChunk, to id: UUID) {
        if isPrivateMode {
            guard let msgIndex = privateMessages.firstIndex(where: { $0.id == id }) else { return }

            if !chunk.deltaText.isEmpty {
                privateMessages[msgIndex].content += chunk.deltaText
                privateMessages[msgIndex].isStreaming = config.streamEnabled
            }

            if !chunk.imageURLs.isEmpty {
                let newImages = chunk.imageURLs.map { ChatImageAttachment(dataURL: $0, mimeType: "image/*", remoteURL: $0) }
                privateMessages[msgIndex].imageAttachments.append(contentsOf: newImages)
                privateMessages[msgIndex].imageAttachments = deduplicateImages(privateMessages[msgIndex].imageAttachments)
            }

            messages = privateMessages
            signalStreamScroll()
            return
        }

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
        if isPrivateMode {
            guard let msgIndex = privateMessages.firstIndex(where: { $0.id == id }) else { return }
            privateMessages[msgIndex].content = reply.text
            privateMessages[msgIndex].imageAttachments = deduplicateImages(
                privateMessages[msgIndex].imageAttachments + reply.imageAttachments
            )
            privateMessages[msgIndex].isStreaming = false
            messages = privateMessages
            signalStreamScroll(force: true)
            if config.soundEffectsEnabled {
                SoundEffectPlayer.playReplyComplete()
            }
            return
        }

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
        if config.soundEffectsEnabled {
            SoundEffectPlayer.playReplyComplete()
        }
    }

    private func finishCancellation(id: UUID) {
        if isPrivateMode {
            guard let msgIndex = privateMessages.firstIndex(where: { $0.id == id }) else { return }
            privateMessages[msgIndex].isStreaming = false
            if privateMessages[msgIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                privateMessages[msgIndex].imageAttachments.isEmpty {
                privateMessages.remove(at: msgIndex)
            }
            messages = privateMessages
            statusMessage = "已停止生成"
            appendLog("私密聊天：已停止本次生成。")
            return
        }

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

    private func finishInterruption(id: UUID, error: Error) {
        if isPrivateMode {
            guard let msgIndex = privateMessages.firstIndex(where: { $0.id == id }) else { return }
            privateMessages[msgIndex].isStreaming = false
            messages = privateMessages
            statusMessage = "连接中断，已保留已生成内容"
            appendLog("私密聊天中断：\(error.localizedDescription)")
            return
        }

        guard let index = currentSessionIndex,
              let msgIndex = sessions[index].messages.firstIndex(where: { $0.id == id }) else { return }

        sessions[index].messages[msgIndex].isStreaming = false
        sessions[index].updatedAt = Date()
        sessions[index].title = buildSessionTitle(from: sessions[index])
        messages = sessions[index].messages
        statusMessage = "连接中断，已保留已生成内容"
        appendLog("聊天中断：\(error.localizedDescription)")
    }

    private func appendMessageToCurrentSession(_ message: ChatMessage) {
        if isPrivateMode {
            privateMessages.append(message)
            messages = privateMessages
            return
        }

        guard let index = currentSessionIndex else { return }
        sessions[index].messages.append(message)
        sessions[index].updatedAt = Date()
        messages = sessions[index].messages
    }

    private func removeMessage(id: UUID) {
        if isPrivateMode {
            privateMessages.removeAll { $0.id == id }
            messages = privateMessages
            return
        }

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
        guard !isPrivateMode else { return }
        ChatSessionStore.saveSessions(sessions, currentSessionID: currentSessionID)
    }

    private func syncMessagesFromCurrentSession() {
        if isPrivateMode {
            messages = privateMessages
            return
        }

        guard let index = currentSessionIndex else {
            messages = []
            return
        }
        messages = sessions[index].messages
    }

    private func signalStreamScroll(force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastStreamScrollSignal) >= streamScrollThrottleInterval {
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

    private func hasRenderableContent(for id: UUID) -> Bool {
        if isPrivateMode {
            guard let msgIndex = privateMessages.firstIndex(where: { $0.id == id }) else { return false }
            let message = privateMessages[msgIndex]
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty || !message.imageAttachments.isEmpty
        }

        guard let index = currentSessionIndex,
              let msgIndex = sessions[index].messages.firstIndex(where: { $0.id == id }) else { return false }

        let message = sessions[index].messages[msgIndex]
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty || !message.imageAttachments.isEmpty
    }

    private func beginBackgroundSendTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "chat-send-stream") { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.statusMessage = "后台时间即将结束，系统可能暂停当前连接"
                self.appendLog("后台任务到期：不再主动取消，是否持续由系统调度决定。")
                self.endBackgroundSendTask()
            }
        }
    }

    private func endBackgroundSendTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func normalizedConfigForSave(_ input: ChatConfig) -> ChatConfig {
        ChatConfig(
            apiURL: ChatConfigStore.normalizedBaseURL(input.apiURL),
            apiKey: input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: input.model.trimmingCharacters(in: .whitespacesAndNewlines),
            endpointMode: input.endpointMode,
            chatCompletionsPath: ChatConfigStore.normalizeEndpointPath(input.chatCompletionsPath, fallback: ChatConfig.defaultChatCompletionsPath),
            imagesGenerationsPath: ChatConfigStore.normalizeEndpointPath(input.imagesGenerationsPath, fallback: ChatConfig.defaultImagesGenerationsPath),
            audioTranscriptionsPath: ChatConfigStore.normalizeEndpointPath(input.audioTranscriptionsPath, fallback: ChatConfig.defaultAudioTranscriptionsPath),
            embeddingsPath: ChatConfigStore.normalizeEndpointPath(input.embeddingsPath, fallback: ChatConfig.defaultEmbeddingsPath),
            modelsPath: ChatConfigStore.normalizeEndpointPath(input.modelsPath, fallback: ChatConfig.defaultModelsPath),
            imageGenerationSize: input.imageGenerationSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ChatConfig.default.imageGenerationSize
                : input.imageGenerationSize.trimmingCharacters(in: .whitespacesAndNewlines),
            timeout: min(max(input.timeout, 5), 120),
            streamEnabled: input.streamEnabled,
            themeMode: input.themeMode,
            codeThemeMode: input.codeThemeMode,
            realtimeContextEnabled: input.realtimeContextEnabled,
            weatherContextEnabled: input.weatherContextEnabled,
            weatherLocation: input.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            marketContextEnabled: input.marketContextEnabled,
            marketSymbols: input.marketSymbols.trimmingCharacters(in: .whitespacesAndNewlines),
            hotNewsContextEnabled: input.hotNewsContextEnabled,
            hotNewsCount: min(max(input.hotNewsCount, 1), 12),
            soundEffectsEnabled: input.soundEffectsEnabled
        )
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let reachable = path.status == .satisfied
                if self.isNetworkReachable == reachable { return }

                self.isNetworkReachable = reachable
                self.updateCurrentModelAvailability()
                if reachable {
                    self.statusMessage = self.isSending ? "网络恢复，继续接收中…" : "网络已恢复"
                    self.appendLog("网络状态：已恢复连接。")
                } else {
                    self.statusMessage = self.isSending ? "网络中断，正在等待恢复…" : "网络离线"
                    self.appendLog("网络状态：连接中断。")
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }
}
