import SwiftUI

struct TestCenterScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        List {
            Section("快速测试") {
                Button("接口测试") {
                    Task {
                        await viewModel.runConnectionTest()
                    }
                }
                Button("流式测试") {
                    Task {
                        await viewModel.runStreamSmokeTest()
                    }
                }
                Button("配置测试") {
                    viewModel.saveConfig()
                }
                Button("UI 测试（填充示例）") {
                    viewModel.loadDemoContent()
                }
                Button("UI 测试（清空会话）") {
                    viewModel.clearMessages()
                }
            }

            Section("测试说明") {
                Text("接口测试：验证 API 地址、鉴权和服务器响应状态码。")
                Text("流式测试：发送一条测试消息，验证 data: 分片和 [DONE] 结束处理。")
                Text("配置测试：确认 API URL、Key、Model 已保存且重启后可恢复。")
                Text("UI 测试：验证聊天页输入、按钮、滚动、清空等交互。")
            }

            Section("测试日志") {
                if viewModel.testLogs.isEmpty {
                    Text("暂无测试日志")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.testLogs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("测试中心")
    }
}
