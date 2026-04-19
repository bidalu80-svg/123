import SwiftUI
import UIKit

struct SettingsScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var authViewModel: AuthViewModel
    @State private var projectActionFeedback: String?
    @State private var latestPreviewPayload: LatestFrontendPreviewPayload?

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
                Toggle("前端自动生成模式", isOn: $viewModel.config.frontendAutoBuildEnabled)
                Text(viewModel.config.frontendAutoBuildEnabled
                    ? "开启后会注入前端生成提示词，并在助手回复完成后自动落盘到 latest 并弹出预览。"
                    : "关闭后仅保留普通聊天，不自动生成本地前端项目。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("启用消息音效（发送/回复完成）", isOn: $viewModel.config.soundEffectsEnabled)
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
            }

            Section("前端项目") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("项目根目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(FrontendProjectBuilder.projectsRootPathDisplay())
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("latest 目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(FrontendProjectBuilder.latestProjectPathDisplay())
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Button("复制根目录") {
                        UIPasteboard.general.string = FrontendProjectBuilder.projectsRootPathDisplay()
                        projectActionFeedback = "已复制项目根目录。"
                    }
                    .buttonStyle(.bordered)

                    Button("复制 latest") {
                        UIPasteboard.general.string = FrontendProjectBuilder.latestProjectPathDisplay()
                        projectActionFeedback = "已复制 latest 路径。"
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Button("打开 latest 预览") {
                        openLatestProjectPreview()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.06, green: 0.36, blue: 0.86))
                    .foregroundStyle(.white)

                    Button("清空 latest", role: .destructive) {
                        clearLatestProject()
                    }
                    .buttonStyle(.bordered)
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
                statusRow("前端自动生成", value: viewModel.config.frontendAutoBuildEnabled ? "开启" : "关闭")
                statusRow("记忆模式", value: viewModel.config.memoryModeEnabled ? "开启" : "关闭")
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

    private func openLatestProjectPreview() {
        guard let entryFileURL = FrontendProjectBuilder.latestEntryFileURL() else {
            projectActionFeedback = "latest 目录里还没有可预览的 HTML 文件。"
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
            projectActionFeedback = "latest 目录已清空。"
        } catch {
            projectActionFeedback = "清空 latest 失败：\(error.localizedDescription)"
        }
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
