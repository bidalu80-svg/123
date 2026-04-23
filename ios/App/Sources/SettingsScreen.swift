import SwiftUI
import UIKit

struct SettingsScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var authViewModel: AuthViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var projectActionFeedback: String?
    @State private var latestPreviewPayload: LatestFrontendPreviewPayload?
    @State private var projectBrowserPayload: FrontendProjectBrowserPayload?

    var body: some View {
        Form {
            Section("接口配置") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("发送接口模式")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("发送接口模式", selection: $viewModel.config.endpointMode) {
                        ForEach(APIEndpointMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("站点地址（用于拼接接口，示例：https://xxx.com）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("https://xxx.com", text: $viewModel.config.apiURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack(spacing: 10) {
                        Button("粘贴") {
                            viewModel.config.apiURL = UIPasteboard.general.string ?? ""
                        }
                        .buttonStyle(.bordered)

                        Button("清空", role: .destructive) {
                            viewModel.config.apiURL = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("接口路径（可填相对路径，也可直接填完整 URL）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("聊天路径，如 /v1/chat/completions", text: $viewModel.config.chatCompletionsPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("响应路径，如 /v1/responses", text: $viewModel.config.responsesPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack(spacing: 10) {
                        Button("默认 /v1") {
                            applyEndpointPathPreset(includeV1: true)
                        }
                        .buttonStyle(.bordered)

                        Button("去掉 /v1") {
                            applyEndpointPathPreset(includeV1: false)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("当前模式完整 URL：\(activeEndpointPreviewURL)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key（用于鉴权访问接口）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SecureField("输入 API Key", text: $viewModel.config.apiKey)

                    HStack(spacing: 10) {
                        Button("粘贴") {
                            viewModel.config.apiKey = UIPasteboard.general.string ?? ""
                        }
                        .buttonStyle(.bordered)

                        Button("清空", role: .destructive) {
                            viewModel.config.apiKey = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("模型名称（用于当前接口请求）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("例如 gpt-5.4", text: $viewModel.config.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !viewModel.availableModels.isEmpty {
                        Picker("可用模型", selection: Binding(
                            get: { viewModel.config.model },
                            set: { viewModel.applySelectedModel($0) }
                        )) {
                            ForEach(viewModel.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }

                    HStack {
                        Button(viewModel.isLoadingModels ? "拉取中…" : "拉取可用模型") {
                            Task { await viewModel.refreshAvailableModels() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .foregroundStyle(.white)
                        .disabled(viewModel.isLoadingModels)
                    }
                }
            }

            Section("请求选项") {
                Toggle("启用流式输出", isOn: $viewModel.config.streamEnabled)
                Text("项目代码模块已默认开启：无需手动开关，始终支持多语言项目文件生成与查看。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("启用远端终端运行", isOn: $viewModel.config.shellExecutionEnabled)
                VStack(alignment: .leading, spacing: 8) {
                    Text("终端执行接口（可填相对路径或完整 URL）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("/v1/shell/execute", text: $viewModel.config.shellExecutionPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("工作目录（可选，如 latest）", text: $viewModel.config.shellExecutionWorkingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Text("终端超时")
                        Spacer()
                        Text("\(Int(viewModel.config.shellExecutionTimeout)) 秒")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $viewModel.config.shellExecutionTimeout, in: 5...300, step: 5)

                    Text("完整终端 URL：\(viewModel.config.shellExecutionURLString)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                Toggle("启用消息音效（发送/回复完成）", isOn: $viewModel.config.soundEffectsEnabled)
                Toggle("自动朗读 AI 回复", isOn: $viewModel.config.replySpeechPlaybackEnabled)
                Picker("回复声线", selection: $viewModel.config.replySpeechVoicePreset) {
                    ForEach(ReplySpeechVoicePreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .disabled(!viewModel.config.replySpeechPlaybackEnabled)
                Toggle("开启记忆模式", isOn: $viewModel.config.memoryModeEnabled)

                Text(viewModel.config.memoryModeEnabled ? "开启后会记录可复用的用户偏好，并在后续聊天中注入跨会话记忆。" : "关闭后不会记录新记忆，也不会把已有记忆注入请求。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("超时")
                    Spacer()
                    Text("\(Int(viewModel.config.timeout)) 秒")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewModel.config.timeout, in: 5...120, step: 5)

                Toggle("注入实时日期时间", isOn: $viewModel.config.realtimeContextEnabled)

                if viewModel.config.realtimeContextEnabled {
                    Toggle("注入天气信息", isOn: $viewModel.config.weatherContextEnabled)

                    if viewModel.config.weatherContextEnabled {
                        TextField("天气城市（如 Shanghai / 北京）", text: $viewModel.config.weatherLocation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Toggle("注入市场价格（油价/金价/股市）", isOn: $viewModel.config.marketContextEnabled)

                    if viewModel.config.marketContextEnabled {
                        TextField("市场代码（逗号分隔）", text: $viewModel.config.marketSymbols)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Text("示例：GC=F,CL=F,BZ=F,^GSPC,^IXIC,^DJI,AAPL,NVDA,TSLA")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("注入热门事件", isOn: $viewModel.config.hotNewsContextEnabled)

                    if viewModel.config.hotNewsContextEnabled {
                        Stepper(value: $viewModel.config.hotNewsCount, in: 1...12) {
                            Text("热门事件条数：\(viewModel.config.hotNewsCount)")
                        }
                    }

                    Text("模型不会自动知道实时世界信息；启用后会在每次请求前注入时间、天气、市场和热门事件摘要。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Picker("主题", selection: $viewModel.config.themeMode) {
                    Text("跟随系统").tag(AppThemeMode.system)
                    Text("浅色").tag(AppThemeMode.light)
                    Text("深色").tag(AppThemeMode.dark)
                }

                Picker("代码高亮", selection: $viewModel.config.codeThemeMode) {
                    Text("跟随应用").tag(CodeThemeMode.followApp)
                    Text("VS Dark").tag(CodeThemeMode.vscodeDark)
                    Text("GitHub Light").tag(CodeThemeMode.githubLight)
                }
                .tint(colorScheme == .dark ? .white : .primary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("内置技能（中文显示）")
                        .font(.subheadline.weight(.semibold))
                    Text("可按技能为 AI 注入默认提示词；每个技能都支持自定义内容。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(BuiltinAISkill.allCases, id: \.self) { skill in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: builtinSkillEnabledBinding(skill)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("\(skill.rawValue) · \(skill.descriptionCN)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            if isBuiltinSkillEnabled(skill) {
                                Text("提示词（可修改）")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: builtinSkillPromptBinding(skill))
                                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                                    .frame(minHeight: 140)
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color(.secondarySystemBackground))
                                    )
                                HStack {
                                    Spacer()
                                    Button("恢复默认") {
                                        resetBuiltinSkillPrompt(skill)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("项目文件") {
                projectPathCard(
                    title: "项目根目录",
                    path: FrontendProjectBuilder.projectsRootPathDisplay()
                ) {
                    openProjectsRootBrowser()
                }

                projectPathCard(
                    title: "latest 目录",
                    path: FrontendProjectBuilder.latestProjectPathDisplay()
                ) {
                    openLatestProjectBrowser()
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 120), spacing: 10),
                        GridItem(.flexible(minimum: 120), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    FrontendProjectActionButton(
                        title: "打开预览",
                        subtitle: "加载 latest 入口页",
                        systemImage: "play.rectangle.fill",
                        tint: Color(red: 0.05, green: 0.36, blue: 0.88),
                        prominence: .primary
                    ) {
                        openLatestProjectPreview()
                    }

                    FrontendProjectActionButton(
                        title: "浏览 latest",
                        subtitle: "进入目录看代码",
                        systemImage: "doc.text.magnifyingglass",
                        tint: Color(red: 0.17, green: 0.43, blue: 0.86),
                        prominence: .secondary
                    ) {
                        openLatestProjectBrowser()
                    }

                    FrontendProjectActionButton(
                        title: "浏览根目录",
                        subtitle: "查看全部项目",
                        systemImage: "folder.badge.gearshape",
                        tint: Color(red: 0.08, green: 0.58, blue: 0.55),
                        prominence: .secondary
                    ) {
                        openProjectsRootBrowser()
                    }

                    FrontendProjectActionButton(
                        title: "清空 latest",
                        subtitle: "删除并重建目录",
                        systemImage: "trash",
                        tint: .red,
                        prominence: .danger
                    ) {
                        clearLatestProject()
                    }
                }
            }

            Section("操作") {
                Button("测试连接") {
                    Task { await viewModel.runConnectionTest() }
                }

                Button("重置配置", role: .destructive) {
                    viewModel.resetConfig()
                }
            }

            Section("应用") {
                NavigationLink("记忆管理") {
                    MemoryManagementScreen()
                }

                NavigationLink("关于 IEXA") {
                    AboutScreen()
                }
            }

            Section("账号") {
                statusRow("登录状态", value: authViewModel.isAuthenticated ? "已登录" : "未登录")
                statusRow("当前账号", value: authViewModel.currentUserPhone)

                if authViewModel.isAuthenticated {
                    Button("退出登录", role: .destructive) {
                        Task { await authViewModel.logout() }
                    }
                }
            }

            Section("状态") {
                statusRow("保存策略", value: "自动保存已开启")
                statusRow("当前状态", value: viewModel.statusMessage)
                statusRow("当前接口", value: viewModel.config.endpointMode.title)
                statusRow("当前模型", value: viewModel.config.model)
                statusRow("流式模式", value: viewModel.config.streamEnabled ? "开启" : "关闭")
                statusRow("远端终端", value: viewModel.config.shellExecutionEnabled ? "开启" : "关闭")
                statusRow("回复朗读", value: viewModel.config.replySpeechPlaybackEnabled ? "开启" : "关闭")
                if viewModel.config.replySpeechPlaybackEnabled {
                    statusRow("朗读声线", value: viewModel.config.replySpeechVoicePreset.title)
                }
                statusRow("记忆模式", value: viewModel.config.memoryModeEnabled ? "开启" : "关闭")
                statusRow("内置技能", value: "\(viewModel.config.enabledBuiltinSkillIDs.count) 个已启用")
            }
        }
        .navigationTitle("配置")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CornerClockBadge()
            }
        }
        .alert("提示", isPresented: projectFeedbackBinding) {
            Button("确定", role: .cancel) {
                projectActionFeedback = nil
            }
        } message: {
            Text(projectActionFeedback ?? "")
        }
        .sheet(item: $latestPreviewPayload) { payload in
            HTMLPreviewSheet(
                title: payload.title,
                html: payload.html,
                baseURL: payload.baseURL,
                entryFileURL: payload.entryFileURL
            )
        }
        .sheet(item: $projectBrowserPayload) { payload in
            NavigationStack {
                FrontendProjectBrowserScreen(
                    title: payload.title,
                    rootURL: payload.rootURL
                )
            }
        }
    }

    private var activeEndpointPreviewURL: String {
        viewModel.config.activeEndpointURLString
    }

    private func applyEndpointPathPreset(includeV1: Bool) {
        if includeV1 {
            viewModel.config.chatCompletionsPath = ChatConfig.defaultChatCompletionsPath
            viewModel.config.responsesPath = ChatConfig.defaultResponsesPath
            viewModel.config.imagesGenerationsPath = ChatConfig.defaultImagesGenerationsPath
            viewModel.config.videoGenerationsPath = ChatConfig.defaultVideoGenerationsPath
            viewModel.config.audioTranscriptionsPath = ChatConfig.defaultAudioTranscriptionsPath
            viewModel.config.embeddingsPath = ChatConfig.defaultEmbeddingsPath
            viewModel.config.modelsPath = ChatConfig.defaultModelsPath
        } else {
            viewModel.config.chatCompletionsPath = "/chat/completions"
            viewModel.config.responsesPath = "/responses"
            viewModel.config.imagesGenerationsPath = "/images/generations"
            viewModel.config.videoGenerationsPath = "/videos/generations"
            viewModel.config.audioTranscriptionsPath = "/audio/transcriptions"
            viewModel.config.embeddingsPath = "/embeddings"
            viewModel.config.modelsPath = "/models"
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func isBuiltinSkillEnabled(_ skill: BuiltinAISkill) -> Bool {
        viewModel.config.enabledBuiltinSkillIDs.contains(skill.rawValue)
    }

    private func builtinSkillEnabledBinding(_ skill: BuiltinAISkill) -> Binding<Bool> {
        Binding(
            get: { isBuiltinSkillEnabled(skill) },
            set: { enabled in
                var enabledSet = Set(viewModel.config.enabledBuiltinSkillIDs)
                if enabled {
                    enabledSet.insert(skill.rawValue)
                } else {
                    enabledSet.remove(skill.rawValue)
                }
                viewModel.config.enabledBuiltinSkillIDs = BuiltinAISkill.allCases
                    .map(\.rawValue)
                    .filter { enabledSet.contains($0) }
            }
        )
    }

    private func builtinSkillPromptBinding(_ skill: BuiltinAISkill) -> Binding<String> {
        Binding(
            get: { viewModel.config.customBuiltinSkillPrompts[skill.rawValue] ?? skill.defaultPrompt },
            set: { newValue in
                var prompts = viewModel.config.customBuiltinSkillPrompts
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    prompts.removeValue(forKey: skill.rawValue)
                } else {
                    prompts[skill.rawValue] = newValue
                }
                viewModel.config.customBuiltinSkillPrompts = prompts
            }
        )
    }

    private func resetBuiltinSkillPrompt(_ skill: BuiltinAISkill) {
        var prompts = viewModel.config.customBuiltinSkillPrompts
        prompts[skill.rawValue] = skill.defaultPrompt
        viewModel.config.customBuiltinSkillPrompts = prompts
    }

    private func openLatestProjectPreview() {
        guard let entryFileURL = FrontendProjectBuilder.latestEntryFileURL() else {
            projectActionFeedback = "latest 目录里还没有可预览的入口文件。"
            return
        }

        do {
            let html = try String(contentsOf: entryFileURL, encoding: .utf8)
            latestPreviewPayload = LatestFrontendPreviewPayload(
                title: "latest 预览 · \(entryFileURL.lastPathComponent)",
                html: html,
                baseURL: FrontendProjectBuilder.latestProjectURL() ?? entryFileURL.deletingLastPathComponent(),
                entryFileURL: entryFileURL
            )
        } catch {
            projectActionFeedback = "读取 latest 预览失败：\(error.localizedDescription)"
        }
    }

    private func clearLatestProject() {
        do {
            try FrontendProjectBuilder.clearLatestProject()
            latestPreviewPayload = nil
            projectBrowserPayload = nil
            projectActionFeedback = "latest 目录已清空。"
        } catch {
            projectActionFeedback = "清空 latest 失败：\(error.localizedDescription)"
        }
    }

    private func openLatestProjectBrowser() {
        guard let latest = FrontendProjectBuilder.latestProjectURL() else {
            projectActionFeedback = "latest 目录不可用。"
            return
        }
        projectBrowserPayload = FrontendProjectBrowserPayload(
            title: "latest 文件",
            rootURL: latest
        )
    }

    private func openProjectsRootBrowser() {
        guard let root = FrontendProjectBuilder.projectsRootURL() else {
            projectActionFeedback = "项目根目录不可用。"
            return
        }
        projectBrowserPayload = FrontendProjectBrowserPayload(
            title: "项目文件",
            rootURL: root
        )
    }

    private func projectPathCard(
        title: String,
        path: String,
        onOpen: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Label(title, systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.86) : .secondary)
                Spacer()
                Button(action: onOpen) {
                    Label("打开", systemImage: "arrow.right.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.92) : Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color(.tertiarySystemBackground))
                        )
                }
                .buttonStyle(.plain)
            }

            Text(path)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private var projectFeedbackBinding: Binding<Bool> {
        Binding(
            get: { projectActionFeedback != nil },
            set: { newValue in
                if !newValue {
                    projectActionFeedback = nil
                }
            }
        )
    }
}

private struct LatestFrontendPreviewPayload: Identifiable {
    let id = UUID()
    let title: String
    let html: String
    let baseURL: URL?
    let entryFileURL: URL?
}

private struct FrontendProjectBrowserPayload: Identifiable {
    let id = UUID()
    let title: String
    let rootURL: URL
}

private enum FrontendProjectActionProminence {
    case primary
    case secondary
    case danger
}

private struct FrontendProjectActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let prominence: FrontendProjectActionProminence
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(subtitleColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(titleColor)
            .background(backgroundView)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(backgroundColor)
    }

    private var backgroundColor: Color {
        switch prominence {
        case .primary:
            return tint
        case .secondary:
            return tint.opacity(0.12)
        case .danger:
            return tint.opacity(0.12)
        }
    }

    private var titleColor: Color {
        switch prominence {
        case .primary:
            return .white
        case .secondary:
            return colorScheme == .dark ? Color.white.opacity(0.96) : tint
        case .danger:
            return colorScheme == .dark ? Color.white.opacity(0.96) : tint
        }
    }

    private var subtitleColor: Color {
        switch prominence {
        case .primary:
            return Color.white.opacity(0.9)
        case .secondary:
            return colorScheme == .dark ? Color.white.opacity(0.76) : tint.opacity(0.9)
        case .danger:
            return colorScheme == .dark ? Color.white.opacity(0.76) : tint.opacity(0.9)
        }
    }

    private var borderColor: Color {
        switch prominence {
        case .primary:
            return tint.opacity(0.95)
        case .secondary:
            return colorScheme == .dark ? Color.white.opacity(0.12) : tint.opacity(0.28)
        case .danger:
            return colorScheme == .dark ? Color.white.opacity(0.12) : tint.opacity(0.35)
        }
    }
}

private struct FrontendProjectFileEntry: Identifiable, Hashable {
    let relativePath: String
    let fileURL: URL
    let size: Int

    var id: String { relativePath }
}

private struct FrontendProjectBrowserScreen: View {
    let title: String
    let rootURL: URL

    @State private var files: [FrontendProjectFileEntry] = []
    @State private var loadingError: String?
    @State private var feedbackMessage: String?

    var body: some View {
        Group {
            if let loadingError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("目录读取失败")
                        .font(.headline)
                    Text(loadingError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else if files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("目录里还没有文件")
                        .font(.headline)
                    Text(rootURL.path)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List(files) { entry in
                    NavigationLink {
                        FrontendProjectFileViewerScreen(
                            entry: entry,
                            onDeleteSuccess: {
                                loadFiles()
                            }
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.relativePath)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text(fileSizeText(entry.size))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteFile(entry)
                        } label: {
                            Label("删文件", systemImage: "trash")
                        }

                        if let projectName = projectFolderName(for: entry), isProjectsRootBrowser {
                            Button(role: .destructive) {
                                deleteProjectFolder(named: projectName)
                            } label: {
                                Label("删项目", systemImage: "folder.badge.minus")
                            }
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteFile(entry)
                        } label: {
                            Label("删除文件", systemImage: "trash")
                        }
                        if let projectName = projectFolderName(for: entry), isProjectsRootBrowser {
                            Button(role: .destructive) {
                                deleteProjectFolder(named: projectName)
                            } label: {
                                Label("删除整个项目：\(projectName)", systemImage: "folder.badge.minus")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isProjectsRootBrowser {
                    Button {
                        cleanupGeneratedProjects()
                    } label: {
                        Image(systemName: "folder.badge.minus")
                    }
                    .accessibilityLabel("清理历史项目")
                }

                Button {
                    loadFiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .alert("提示", isPresented: feedbackBinding) {
            Button("确定", role: .cancel) {
                feedbackMessage = nil
            }
        } message: {
            Text(feedbackMessage ?? "")
        }
        .onAppear {
            loadFiles()
        }
    }

    private func loadFiles() {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            files = []
            loadingError = "目录不存在：\(rootURL.path)"
            return
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            loadingError = "无法遍历目录。"
            return
        }

        var collected: [FrontendProjectFileEntry] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            let relative = relativePath(fileURL)
            let size = values.fileSize ?? 0
            collected.append(
                FrontendProjectFileEntry(
                    relativePath: relative,
                    fileURL: fileURL,
                    size: size
                )
            )
        }

        collected.sort { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        files = collected
        loadingError = nil
    }

    private func relativePath(_ fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let absolute = fileURL.standardizedFileURL.path
        if absolute == rootPath {
            return fileURL.lastPathComponent
        }
        if absolute.hasPrefix(rootPath + "/") {
            return String(absolute.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private func fileSizeText(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var feedbackBinding: Binding<Bool> {
        Binding(
            get: { feedbackMessage != nil },
            set: { shown in
                if !shown {
                    feedbackMessage = nil
                }
            }
        )
    }

    private var isProjectsRootBrowser: Bool {
        guard let projectsRootURL = FrontendProjectBuilder.projectsRootURL() else { return false }
        return normalizedPath(rootURL) == normalizedPath(projectsRootURL)
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func projectFolderName(for entry: FrontendProjectFileEntry) -> String? {
        let components = entry.relativePath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count > 1 else { return nil }
        let name = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func deleteFile(_ entry: FrontendProjectFileEntry) {
        do {
            try removeItemWithinRoot(entry.fileURL)
            pruneEmptyParentDirectories(startingFrom: entry.fileURL.deletingLastPathComponent())
            loadFiles()
            feedbackMessage = "已删除 \(entry.relativePath)"
        } catch {
            feedbackMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func deleteProjectFolder(named projectName: String) {
        let targetURL = rootURL.appendingPathComponent(projectName, isDirectory: true)
        do {
            try removeItemWithinRoot(targetURL)
            loadFiles()
            feedbackMessage = "已删除项目 \(projectName)"
        } catch {
            feedbackMessage = "删除项目失败：\(error.localizedDescription)"
        }
    }

    private func cleanupGeneratedProjects() {
        guard isProjectsRootBrowser else { return }
        let fileManager = FileManager.default
        do {
            let items = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var removedCount = 0
            for item in items {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                let name = item.lastPathComponent
                if name == "latest" { continue }
                if name.lowercased().hasPrefix("site-") {
                    try removeItemWithinRoot(item)
                    removedCount += 1
                }
            }

            loadFiles()
            feedbackMessage = removedCount == 0
                ? "没有可清理的历史项目。"
                : "已清理 \(removedCount) 个历史项目。"
        } catch {
            feedbackMessage = "清理失败：\(error.localizedDescription)"
        }
    }

    private func removeItemWithinRoot(_ targetURL: URL) throws {
        let fileManager = FileManager.default
        let rootPath = normalizedPath(rootURL)
        let targetPath = normalizedPath(targetURL)

        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw NSError(
                domain: "FrontendProjectBrowser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "目标不在项目目录内。"]
            )
        }
        guard fileManager.fileExists(atPath: targetPath) else {
            throw NSError(
                domain: "FrontendProjectBrowser",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "目标不存在。"]
            )
        }
        try fileManager.removeItem(at: URL(fileURLWithPath: targetPath))
    }

    private func pruneEmptyParentDirectories(startingFrom folderURL: URL) {
        let fileManager = FileManager.default
        let rootPath = normalizedPath(rootURL)
        var current = folderURL.standardizedFileURL.resolvingSymlinksInPath()

        while current.path != rootPath {
            guard current.path.hasPrefix(rootPath + "/") else { break }
            guard let items = try? fileManager.contentsOfDirectory(atPath: current.path),
                  items.isEmpty else {
                break
            }
            try? fileManager.removeItem(at: current)
            let next = current.deletingLastPathComponent()
            if next.path == current.path {
                break
            }
            current = next
        }
    }
}

private struct FrontendProjectFileViewerScreen: View {
    let entry: FrontendProjectFileEntry
    var onDeleteSuccess: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var statusText: String = "读取中…"
    @State private var readError: String?
    @State private var feedbackMessage: String?

    var body: some View {
        Group {
            if let readError {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("无法读取文件")
                        .font(.headline)
                    Text(readError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(content)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                }
            }
        }
        .navigationTitle(entry.relativePath)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = content
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(content.isEmpty)

                Button(role: .destructive) {
                    deleteCurrentFile()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .alert("提示", isPresented: feedbackBinding) {
            Button("确定", role: .cancel) {
                feedbackMessage = nil
            }
        } message: {
            Text(feedbackMessage ?? "")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
        }
        .onAppear {
            loadFile()
        }
    }

    private func loadFile() {
        do {
            let data = try Data(contentsOf: entry.fileURL, options: [.mappedIfSafe])
            let maxBytes = 300_000
            let clipped = data.prefix(maxBytes)
            guard let text = decodeText(Data(clipped)) else {
                readError = "该文件不是可显示的文本格式。"
                content = ""
                statusText = "大小 \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
                return
            }

            var finalText = text
            var suffix = ""
            if data.count > maxBytes {
                suffix = "\n\n/* 文件过大，仅显示前 \(maxBytes) 字节 */"
                finalText.append(suffix)
            }
            content = finalText
            readError = nil

            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            let lineCount = max(1, finalText.components(separatedBy: "\n").count)
            statusText = "\(sizeText) · \(lineCount) 行"
        } catch {
            readError = error.localizedDescription
            content = ""
            statusText = "读取失败"
        }
    }

    private var feedbackBinding: Binding<Bool> {
        Binding(
            get: { feedbackMessage != nil },
            set: { shown in
                if !shown {
                    feedbackMessage = nil
                }
            }
        )
    }

    private func deleteCurrentFile() {
        do {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: entry.fileURL.path) else {
                feedbackMessage = "文件已不存在。"
                return
            }
            try fileManager.removeItem(at: entry.fileURL)
            onDeleteSuccess?()
            dismiss()
        } catch {
            feedbackMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func decodeText(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16LittleEndian,
            .utf16BigEndian,
            .unicode,
            .ascii
        ]

        for encoding in encodings {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        return nil
    }
}
