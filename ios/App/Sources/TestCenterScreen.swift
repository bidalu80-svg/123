import SwiftUI

struct TestCenterScreen: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        List {
            Section("快速测试") {
                Button("接口测试") {
                    Task { await viewModel.runConnectionTest() }
                }
                Button("拉取模型测试") {
                    Task { await viewModel.refreshAvailableModels() }
                }
                Button("流式测试") {
                    Task { await viewModel.runStreamSmokeTest() }
                }
                NavigationLink("流式渲染实验室（UIKit）") {
                    StreamingRenderLabScreen()
                }
                Button("UI 测试（填充示例）") {
                    viewModel.loadDemoContent()
                }
                Button("UI 测试（清空当前会话）") {
                    viewModel.clearCurrentSessionMessages()
                }
            }

            Section("测试说明") {
                Text("接口测试：验证站点、鉴权和服务器状态码。")
                Text("拉取模型测试：从 /v1/models 获取可用模型，并可在配置页选择。")
                Text("流式测试：验证 data: 分片、停止能力、代码块流式渲染。")
                Text("接口模式：可在配置页或顶部菜单切换 Chat / Image / Audio / Embedding / Models。")
                Text("UI 测试：验证会话侧栏、附件发送、复制和清空交互。")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CornerClockBadge()
            }
        }
    }
}
