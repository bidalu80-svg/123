import SwiftUI

struct AboutScreen: View {
    private var appVersionText: String {
        AppBuildInfo.versionLine
    }

    var body: some View {
        Form {
            Section("应用信息") {
                LabeledContent("应用名称", value: AppBuildInfo.appName)
                LabeledContent("作者", value: "blank")
                LabeledContent("版本", value: appVersionText)
            }

            Section("构建信息") {
                buildInfoRow("构建签名", value: AppBuildInfo.buildSignature)
                buildInfoRow("完整提交", value: AppBuildInfo.gitSHA)
                buildInfoRow("Actions Run", value: AppBuildInfo.runID)
                buildInfoRow("构建时间", value: AppBuildInfo.buildTimeDisplay)
            }

            Section("功能特点") {
                featureRow("多接口模式", detail: "统一支持聊天、生图、语音转写、向量与模型列表测试。")
                featureRow("会话管理", detail: "支持多会话、私密聊天、会话切换与历史持久化。")
                featureRow("多模态输入", detail: "支持图片、文件、音频附件与中文语音转文本输入。")
                featureRow("智能增强", detail: "可选注入时间、天气、市场、热点信息与记忆模式。")
                featureRow("开发效率", detail: "内置代码运行、HTML 预览与测试中心，便于快速验证。")
            }

            Section("产品说明") {
                Text("IEXA 是面向 AI 接口接入与能力验证的 iOS 客户端，强调可配置、可测试、可持续迭代的工程化体验。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于 IEXA")
    }

    private func featureRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func buildInfoRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
