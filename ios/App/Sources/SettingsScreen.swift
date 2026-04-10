import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        Form {
            Section("接口配置") {
                TextField("API URL", text: $viewModel.config.apiURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $viewModel.config.apiKey)
                TextField("Model", text: $viewModel.config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                Button("保存配置") {
                    viewModel.saveConfig()
                }
                Button("测试连接") {
                    Task {
                        await viewModel.runConnectionTest()
                    }
                }
                Button("重置配置", role: .destructive) {
                    viewModel.resetConfig()
                }
            }

            Section("当前状态") {
                statusRow("状态", value: viewModel.statusMessage)
                statusRow("当前模型", value: viewModel.config.model)
                statusRow("流式模式", value: viewModel.config.streamEnabled ? "开启" : "关闭")
            }
        }
        .navigationTitle("配置")
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
