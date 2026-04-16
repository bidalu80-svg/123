import SwiftUI
import UIKit

struct SettingsScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var authViewModel: AuthViewModel

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

                    TextField("例如 gpt-5.4-pro", text: $viewModel.config.model)
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
                statusRow("记忆模式", value: viewModel.config.memoryModeEnabled ? "开启" : "关闭")
            }
        }
        .navigationTitle("配置")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CornerClockBadge()
            }
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
}
