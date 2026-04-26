import Foundation

enum AdaptiveSkillRouter {
    private enum AutomaticSkill: CaseIterable {
        case ios
        case python
        case frontend

        var prompt: String {
            switch self {
            case .ios:
                return """
                [iOS 项目技能]
                当任务明显属于 iOS / Swift / Xcode 工程时：
                - 优先沿用现有 SwiftUI / UIKit 结构，不要把原生实现改写成网页式思路。
                - 修改尽量最小化，优先精确到具体 Swift 文件、Info.plist、entitlements 或资源配置。
                - 涉及签名、Capability、Bundle ID、Info.plist key、权限描述时，必须明确指出影响面。
                - UI 调整优先保持现有状态流、ViewModel 和导航结构，不要随意整页重写。
                """
            case .python:
                return """
                [Python 项目技能]
                当任务明显属于 Python 脚本或 Python 项目时：
                - 优先保留现有项目结构与依赖约束，能用标准库就不要额外加依赖。
                - 修复或新增代码时，优先补齐最小必要测试、运行入口或验证命令。
                - 涉及抓取、HTTP、编码、状态码时，要显式处理超时、编码和错误输出；抓中文网页时优先基于原始 bytes 自己 decode，不要直接盲信 requests.text。
                - 如果已有 requirements.txt / pyproject.toml / unittest 结构，优先顺着现有约定继续修改。
                """
            case .frontend:
                return """
                [前端项目技能]
                当前任务像是在继续一个已有前端项目：
                - 优先最小改动现有页面、组件、样式和入口文件，不要无故重写整个项目。
                - 保持现有构建方式、目录组织和依赖约定，确认入口、资源引用和移动端布局都能对上。
                - 若是修布局或交互问题，优先点名相关文件和改动范围，不要泛化成整站重构。
                """
            }
        }
    }

    static func systemPrompts(
        config: ChatConfig,
        message: ChatMessage,
        latestProjectContext: String?
    ) -> [String] {
        guard config.autoSkillActivationEnabled else { return [] }
        guard message.role == .user else { return [] }

        let messageText = normalized(message.copyableText)
        guard !messageText.isEmpty else { return [] }

        let workspaceText = normalized(latestProjectContext ?? "")
        let hasLatestProjectContext = !workspaceText.isEmpty

        let ranked = AutomaticSkill.allCases
            .map { skill in
                (
                    skill: skill,
                    score: score(
                        skill: skill,
                        messageText: messageText,
                        workspaceText: workspaceText,
                        hasLatestProjectContext: hasLatestProjectContext
                    )
                )
            }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score == $1.score {
                    return sortWeight(for: $0.skill) < sortWeight(for: $1.skill)
                }
                return $0.score > $1.score
            }

        guard let best = ranked.first else { return [] }
        return [best.skill.prompt]
    }

    private static func score(
        skill: AutomaticSkill,
        messageText: String,
        workspaceText: String,
        hasLatestProjectContext: Bool
    ) -> Int {
        switch skill {
        case .ios:
            let messageHits = keywordHits(in: messageText, markers: [
                "swift", "swiftui", "uikit", "xcode", "ipa", "plist", "info.plist",
                "entitlement", "bundle id", "provisioning", "signing",
                "ios", "iphone", "ipad", "apple 登录", "苹果登录", "真机", "签名"
            ])
            let workspaceHits = keywordHits(in: workspaceText, markers: [
                ".swift", "info.plist", "package.swift", "entitlements", "swiftui", "uikit"
            ])
            return messageHits * 4 + workspaceHits

        case .python:
            let messageHits = keywordHits(in: messageText, markers: [
                "python", "pytest", "unittest", "requirements.txt", "pyproject.toml",
                "pip", "venv", "编码", "状态码", "脚本", "爬虫"
            ])
            let workspaceHits = keywordHits(in: workspaceText, markers: [
                ".py", "requirements.txt", "pyproject.toml", "pytest", "unittest", "main.py"
            ])
            return messageHits * 4 + workspaceHits

        case .frontend:
            guard hasLatestProjectContext else { return 0 }
            let workspaceHits = keywordHits(in: workspaceText, markers: [
                "index.html", "package.json", "vite.config", "next.config", "src/", "styles.css",
                "tailwind", "react", "vue", "typescript", "javascript", ".css", ".tsx", ".jsx"
            ])
            guard workspaceHits > 0 else { return 0 }

            let editIntentHits = keywordHits(in: messageText, markers: [
                "继续", "接着", "修改", "调整", "修", "修复", "布局", "样式", "组件", "页面",
                "交互", "bug", "ui", "layout", "style", "component", "page", "fix", "update"
            ])
            return workspaceHits + editIntentHits * 3
        }
    }

    private static func keywordHits(in text: String, markers: [String]) -> Int {
        markers.reduce(into: 0) { partial, marker in
            if text.contains(marker) {
                partial += 1
            }
        }
    }

    private static func sortWeight(for skill: AutomaticSkill) -> Int {
        switch skill {
        case .ios:
            return 0
        case .python:
            return 1
        case .frontend:
            return 2
        }
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
