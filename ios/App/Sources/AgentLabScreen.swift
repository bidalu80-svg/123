import SwiftUI
import UIKit

struct AgentLabScreen: View {
    @State private var copiedMessage: String = ""

    private let quickCommand = "swift ios/Tools/terminal_agent.swift --api-url https://your-host.com --api-key sk-xxx --prompt \"你好\""
    private let webAgentCommand = "swift ios/Tools/terminal_agent.swift --api-url https://your-host.com --agent web --web-out ./web --prompt \"做一个单页网站\""
    private let interactiveCommand = "swift ios/Tools/terminal_agent.swift --api-url https://your-host.com --interactive"

    var body: some View {
        List {
            Section("终端 Agent 测试") {
                Text("这个模块用于快速验证 IEXA 的 agent 能力：聊天接口、多文件项目输出，以及本地工作区文件操作。")
                    .font(.subheadline)
            }

            Section("快速命令") {
                commandRow(title: "单次请求", command: quickCommand)
                commandRow(title: "Web Agent 模式", command: webAgentCommand)
                commandRow(title: "交互模式", command: interactiveCommand)
            }

            Section("Web 模式说明") {
                Text("1. 使用 --agent web 后，AI 会按 [[file:...]] 格式返回网站文件。")
                Text("2. 使用 --web-out 指定输出目录，例如 ./web。")
                Text("3. 生成后可直接打开 ./web/index.html 预览。")
            }

            Section("当前限制") {
                Text("1. App 当前主要支持本地工作区文件读写，以及 Python 项目的本地验证。")
                Text("2. 网站类项目可直接生成入口文件并在 App 内预览。")
                Text("3. Go、Rust、Java、Node、PHP 等项目暂不在 iPhone 本地执行。")
            }

            if !copiedMessage.isEmpty {
                Section("状态") {
                    Text(copiedMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Agent 测试")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CornerClockBadge()
            }
        }
    }

    @ViewBuilder
    private func commandRow(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(command)
                .font(.footnote.monospaced())
                .textSelection(.enabled)

            Button("复制命令") {
                UIPasteboard.general.string = command
                copiedMessage = "已复制：\(title)"
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.06, green: 0.36, blue: 0.86))
            .foregroundStyle(.white)
        }
        .padding(.vertical, 4)
    }
}
