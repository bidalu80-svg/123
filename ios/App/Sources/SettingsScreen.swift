import SwiftUI
import UIKit

struct SettingsScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        Form {
            Section("接口配置") {
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

                        Spacer()
                        Text("实际请求：\(viewModel.config.completionURLString)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                    Text("模型名称（用于发送聊天请求）")
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
                        .disabled(viewModel.isLoadingModels)

                        Spacer()
                        Text("模型接口：\(viewModel.config.modelsURLString)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section("请求选项") {
                Toggle("启用流式输出", isOn: $viewModel.config.streamEnabled)
                HStack {
                    Text("超时")
                    Spacer()
                    Text("\(Int(viewModel.config.timeout)) 秒")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewModel.config.timeout, in: 5...120, step: 5)

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

            Section("状态") {
                statusRow("保存策略", value: "自动保存已开启")
                statusRow("当前状态", value: viewModel.statusMessage)
                statusRow("当前模型", value: viewModel.config.model)
                statusRow("流式模式", value: viewModel.config.streamEnabled ? "开启" : "关闭")
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
