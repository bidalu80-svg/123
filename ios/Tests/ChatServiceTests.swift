import XCTest
@testable import ChatApp

final class ChatServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        LocalMCPActionMemory.reset()
        super.tearDown()
    }

    func testBuildRequestIncludesModelMessagesAndStreamFlag() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "token-123", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [ChatMessage(role: .assistant, content: "history")]
        let requestMessage = ChatMessage(role: .user, content: "hello")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let first = try XCTUnwrap(messages.first)
        let last = try XCTUnwrap(messages.last)

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(first["role"] as? String, "system")
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(last["content"] as? String, "hello")
    }

    func testBuildRequestDoesNotDuplicateSystemIdentityWhenHistoryAlreadyHasSystemMessage() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [
            ChatMessage(role: .system, content: "你是 IEXA"),
            ChatMessage(role: .assistant, content: "history")
        ]
        let requestMessage = ChatMessage(role: .user, content: "你是谁")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemCount = messages.filter { ($0["role"] as? String) == "system" }.count

        XCTAssertEqual(systemCount, 1)
        XCTAssertEqual(messages.count, 3)
    }

    func testBuildRequestSystemPromptAvoidsRepeatedSelfIntroduction() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "帮我修一下这个函数")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let firstSystem = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(firstSystem.contains("不要反复强调名称"))
        XCTAssertTrue(firstSystem.contains("不要把“我是 IEXA”当作默认开场"))
    }

    func testBuildRequestSanitizesExecutedWorkspaceOperationHistory() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [
            ChatMessage(role: .user, content: "清空 latest"),
            ChatMessage(role: .assistant, content: "[[clear:latest]]")
        ]
        let requestMessage = ChatMessage(role: .user, content: "说说原因")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let assistantHistory = messages
            .filter { ($0["role"] as? String) == "assistant" }
            .compactMap { $0["content"] as? String }
            .joined(separator: "\n")

        XCTAssertFalse(assistantHistory.contains("[[clear:latest]]"))
        XCTAssertTrue(assistantHistory.contains("历史工作区操作已在本地执行"))
    }

    func testBuildRequestSupportsMultipleImageAttachments() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)
        let attachments = [
            ChatImageAttachment(dataURL: "data:image/png;base64,abcd", mimeType: "image/png"),
            ChatImageAttachment(dataURL: "data:image/jpeg;base64,efgh", mimeType: "image/jpeg")
        ]
        let requestMessage = ChatMessage(role: .user, content: "describe these", imageAttachments: attachments)

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let first = try XCTUnwrap(messages.first)
        let content = try XCTUnwrap(first["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 5)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        let prelude = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(prelude.contains("describe these"))
        XCTAssertTrue(prelude.contains("共 2 张图片"))
        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual(content[1]["text"] as? String, "[图片 1/2]")
        XCTAssertEqual(content[2]["type"] as? String, "image_url")
        XCTAssertEqual((content[2]["image_url"] as? [String: String])?["url"], attachments[0].requestURLString)
        XCTAssertEqual(content[3]["type"] as? String, "text")
        XCTAssertEqual(content[3]["text"] as? String, "[图片 2/2]")
        XCTAssertEqual(content[4]["type"] as? String, "image_url")
        XCTAssertEqual((content[4]["image_url"] as? [String: String])?["url"], attachments[1].requestURLString)
    }

    func testBuildRequestAddsImageContextPreludeForImageOnlyPrompt() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)
        let attachment = ChatImageAttachment(dataURL: "data:image/png;base64,abcd", mimeType: "image/png")
        let requestMessage = ChatMessage(role: .user, content: "", imageAttachments: [attachment])

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let first = try XCTUnwrap(messages.first)
        let content = try XCTUnwrap(first["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        let prelude = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(prelude.contains("[图片理解上下文]"))
        XCTAssertTrue(prelude.contains("共 1 张图片"))
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
    }

    func testBuildRequestTrimsLongHistoryToKeepPayloadResponsive() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let longText = String(repeating: "历史上下文内容。", count: 1200)
        let history: [ChatMessage] = (0..<40).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "\(index):\(longText)"
            )
        }
        let requestMessage = ChatMessage(role: .user, content: "继续")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        // system + trimmed history + latest message
        XCTAssertLessThanOrEqual(messages.count, 24)
    }

    func testBuildRequestDropsOlderInlineImageDataFromHistoryForSpeed() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let older = ChatMessage(
            role: .user,
            content: "旧图片",
            imageAttachments: [ChatImageAttachment(dataURL: "data:image/png;base64,old111", mimeType: "image/png")]
        )
        let latestWithImage = ChatMessage(
            role: .user,
            content: "新图片",
            imageAttachments: [ChatImageAttachment(dataURL: "data:image/png;base64,new222", mimeType: "image/png")]
        )
        let history = [older, ChatMessage(role: .assistant, content: "收到"), latestWithImage]
        let requestMessage = ChatMessage(role: .user, content: "继续分析")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        var inlineImageCount = 0
        for message in messages {
            guard let content = message["content"] as? [[String: Any]] else { continue }
            for item in content where (item["type"] as? String) == "image_url" {
                let image = item["image_url"] as? [String: Any]
                let url = image?["url"] as? String
                if let url, url.hasPrefix("data:image") {
                    inlineImageCount += 1
                }
            }
        }

        XCTAssertEqual(inlineImageCount, 1)
        let plainTextMessages = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(plainTextMessages.contains("本轮为提速已省略其二进制内容"))
    }

    func testChatImageAttachmentDecodeSupportsURLSafeBase64WithoutPadding() {
        let original = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFE, 0x2F, 0x10])
        let compact = original.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let brokenLines = "\(compact.prefix(5))\n\(compact.dropFirst(5))"

        let attachment = ChatImageAttachment(
            dataURL: "data:image/png;base64,\(brokenLines)",
            mimeType: "image/png"
        )

        XCTAssertEqual(attachment.decodedImageData, original)
    }

    func testChatImageAttachmentFromImageDataPreservesSVGDataURLAndMime() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><rect width="8" height="8" fill="#f40"/></svg>"#
        let data = Data(svg.utf8)

        let attachment = ChatImageAttachment.fromImageData(data, mimeType: "application/octet-stream")

        XCTAssertEqual(attachment.mimeType, "image/svg+xml")
        XCTAssertTrue(attachment.dataURL.hasPrefix("data:image/svg+xml;base64,"))
        XCTAssertEqual(attachment.decodedImageData, data)
    }

    func testBuildRequestIncludesRealtimeSystemContext() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "现在几点")

        let request = try ChatRequestBuilder.makeRequest(
            config: config,
            history: [],
            message: requestMessage,
            realtimeSystemContext: "当前日期时间：2026-04-13 18:20:00"
        )

        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "当前日期时间：2026-04-13 18:20:00")
    }

    func testBuildRequestIncludesCrossSessionMemoryContext() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "你好")

        let request = try ChatRequestBuilder.makeRequest(
            config: config,
            history: [],
            message: requestMessage,
            realtimeSystemContext: nil,
            memorySystemContext: "以下是用户跨会话记忆：\n• 我喜欢简洁回答"
        )

        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "以下是用户跨会话记忆：\n• 我喜欢简洁回答")
    }

    func testBuildRequestInjectsAdaptiveIOSSkillPromptForSwiftTask() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "帮我修一下这个 SwiftUI 页面和 Info.plist 配置")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContents = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertTrue(systemContents.contains(where: { $0.contains("[iOS 项目技能]") }))
    }

    func testBuildRequestInjectsAdaptivePythonSkillPromptForPythonTask() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "帮我修一下这个 Python 脚本的编码和状态码输出")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContents = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertTrue(systemContents.contains(where: { $0.contains("[Python 项目技能]") }))
    }

    func testBuildRequestInjectsAdaptiveFrontendSkillPromptForFrontendFollowup() throws {
        try? FrontendProjectBuilder.clearLatestProject()
        defer { try? FrontendProjectBuilder.clearLatestProject() }

        let seededProject = ChatMessage(
            role: .assistant,
            content: """
            [[file:index.html]]
            <!doctype html>
            <html><body><div class="card">OK</div></body></html>
            [[endfile]]

            [[file:package.json]]
            {"name":"demo","version":"1.0.0"}
            [[endfile]]
            """
        )
        _ = try FrontendProjectBuilder.buildProject(from: seededProject, mode: .overwriteLatestProject)

        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "继续调整这个页面的布局和样式")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [seededProject], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContents = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertTrue(systemContents.contains(where: { $0.contains("[前端项目技能]") }))
    }

    func testBuildRequestDoesNotInjectAdaptiveSkillsWhenDisabled() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        config.autoSkillActivationEnabled = false
        let requestMessage = ChatMessage(role: .user, content: "帮我修一下这个 SwiftUI 页面和 Info.plist 配置")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContents = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertFalse(systemContents.contains(where: { $0.contains("[iOS 项目技能]") }))
        XCTAssertFalse(systemContents.contains(where: { $0.contains("[Python 项目技能]") }))
        XCTAssertFalse(systemContents.contains(where: { $0.contains("[前端项目技能]") }))
    }

    func testBuildRequestInjectsProjectPromptOnlyForProjectIntent() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        config.frontendAutoBuildEnabled = true

        let normalMessage = ChatMessage(role: .user, content: "设计一款编程游戏，以有趣的方式教授基础知识")
        let projectMessage = ChatMessage(role: .user, content: "做一个登录网站页面项目")

        let normalRequest = try ChatRequestBuilder.makeRequest(config: config, history: [], message: normalMessage)
        let normalPayload = try XCTUnwrap(normalRequest.httpBody)
        let normalJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: normalPayload) as? [String: Any])
        let normalMessages = try XCTUnwrap(normalJSON["messages"] as? [[String: Any]])

        let projectRequest = try ChatRequestBuilder.makeRequest(config: config, history: [], message: projectMessage)
        let projectPayload = try XCTUnwrap(projectRequest.httpBody)
        let projectJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: projectPayload) as? [String: Any])
        let projectMessages = try XCTUnwrap(projectJSON["messages"] as? [[String: Any]])

        XCTAssertEqual(normalMessages.count, 2)
        XCTAssertEqual(projectMessages.count, 3)
        XCTAssertEqual(projectMessages[1]["role"] as? String, "system")
        XCTAssertTrue((projectMessages[1]["content"] as? String)?.contains("项目自动生成模式") == true)
    }

    func testBuildRequestDoesNotInjectProjectOrWorkspacePromptsForGeneralChat() throws {
        try? FrontendProjectBuilder.clearLatestProject()

        let seededProject = ChatMessage(
            role: .assistant,
            content: """
            [[file:index.html]]
            <!doctype html>
            <html><body>OK</body></html>
            [[endfile]]
            """
        )
        _ = try FrontendProjectBuilder.buildProject(from: seededProject, mode: .overwriteLatestProject)

        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [seededProject]
        let requestMessage = ChatMessage(role: .user, content: "详细介绍一下你自己")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContents = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertFalse(systemContents.contains(where: { $0.contains("项目自动生成模式") }))
        XCTAssertFalse(systemContents.contains(where: { $0.contains("[当前工作区上下文]") }))
        XCTAssertFalse(systemContents.contains(where: { $0.contains("当前任务更接近 agent 执行") }))
    }

    func testBuildRequestInjectsWorkspaceContextForProjectFollowup() throws {
        try? FrontendProjectBuilder.clearLatestProject()

        let seededProject = ChatMessage(
            role: .assistant,
            content: """
            [[file:index.html]]
            <!doctype html>
            <html><body>OK</body></html>
            [[endfile]]
            """
        )
        _ = try FrontendProjectBuilder.buildProject(from: seededProject, mode: .overwriteLatestProject)

        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [seededProject]
        let requestMessage = ChatMessage(role: .user, content: "继续修一下这个项目的报错")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: history, message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContents = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertTrue(systemContents.contains(where: { $0.contains("[当前工作区上下文]") }))
        XCTAssertTrue(systemContents.contains(where: { $0.contains("当前任务更接近 agent 执行") }))
        XCTAssertTrue(systemContents.contains(where: { $0.contains("MCP 风格意图路由智能体") }))
    }

    func testBuildRequestInjectsRecentLocalMCPContextForNaturalLanguageFollowup() throws {
        LocalMCPActionMemory.record(summary: "读取文件", path: "src/main.swift")
        LocalMCPActionMemory.record(summary: "编辑文件", path: "src/main.swift")

        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "把这个再改一下")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContents = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertTrue(systemContents.contains(where: { $0.contains("最近免费本地 MCP 上下文") }))
        XCTAssertTrue(systemContents.contains(where: { $0.contains("src/main.swift") }))
    }

    func testBuildRequestInjectsPythonRuntimePromptForStatusCodeScriptRequest() throws {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let requestMessage = ChatMessage(role: .user, content: "写一个无依赖 Python 脚本抓网页并输出状态码，避免乱码")

        let request = try ChatRequestBuilder.makeRequest(config: config, history: [], message: requestMessage)
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContents = messages
            .filter { ($0["role"] as? String) == "system" }
            .compactMap { $0["content"] as? String }

        XCTAssertTrue(systemContents.contains(where: { $0.contains("必须显式输出状态码") }))
        XCTAssertTrue(systemContents.contains(where: { $0.contains("避免中文乱码") }))
    }

    func testBuildImagesGenerationRequestUsesConfiguredEndpoint() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "token-123", model: "gpt-image", timeout: 30, streamEnabled: false)
        config.imagesGenerationsPath = "/v1/images/generations"
        config.imageGenerationSize = "1024x1024"

        let request = try ChatRequestBuilder.makeImagesGenerationRequest(config: config, prompt: "a cat")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/images/generations")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(json["model"] as? String, "gpt-image")
        XCTAssertEqual(json["prompt"] as? String, "a cat")
        XCTAssertEqual(json["size"] as? String, "1024x1024")
        XCTAssertEqual(json["response_format"] as? String, "b64_json")
        XCTAssertEqual(request.timeoutInterval, 180)
    }

    func testBuildImagesGenerationRequestUsesB64ForGPTImageModelWithSpaces() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "GPT Image 2", timeout: 30, streamEnabled: false)
        config.imagesGenerationsPath = "/v1/images/generations"
        config.imageGenerationSize = "1024x1024"

        let request = try ChatRequestBuilder.makeImagesGenerationRequest(config: config, prompt: "a cat")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "GPT Image 2")
        XCTAssertEqual(json["response_format"] as? String, "b64_json")
    }

    func testBuildImagesGenerationRequestUsesXAIShapeForGrokImagine() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "grok-imagine-1", timeout: 30, streamEnabled: false)
        config.imagesGenerationsPath = "/v1/images/generations"
        config.imageGenerationSize = "1024x1024"

        let request = try ChatRequestBuilder.makeImagesGenerationRequest(config: config, prompt: "a cat")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "grok-imagine-1")
        XCTAssertEqual(json["prompt"] as? String, "a cat")
        XCTAssertEqual(json["aspect_ratio"] as? String, "1:1")
        XCTAssertEqual(json["resolution"] as? String, "1k")
        XCTAssertNil(json["size"])
    }

    func testSendImageGenerationRetriesAfter524() async throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-image", timeout: 30, streamEnabled: false)
        config.endpointMode = .imageGenerations
        config.imagesGenerationsPath = "/v1/images/generations"

        var requestCount = 0
        URLProtocolStub.handler = { request in
            requestCount += 1
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: requestCount == 1 ? 524 : 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json"
                ])
            )
            let body = requestCount == 1
                ? #"{"error":{"message":"gateway timeout"}}"#
                : #"{"data":[{"url":"https://cdn.example.com/final.png"}],"revised_prompt":"a cat"}"#
            return (response, Data(body.utf8))
        }

        let service = makeStubbedChatService()
        let reply = try await service.sendMessage(
            config: config,
            history: [],
            message: ChatMessage(role: .user, content: "a cat"),
            onEvent: { _ in }
        )

        XCTAssertGreaterThanOrEqual(requestCount, 2)
        XCTAssertEqual(reply.imageAttachments.first?.requestURLString, "https://cdn.example.com/final.png")
    }

    func testSendImageGenerationUsesUrlAndAsyncHintsBeforeFallbackForGPTImage2() async throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-image-2", timeout: 30, streamEnabled: false)
        config.endpointMode = .imageGenerations
        config.imagesGenerationsPath = "/v1/images/generations"

        var capturedBodies: [[String: Any]] = []
        URLProtocolStub.handler = { request in
            let payload = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            capturedBodies.append(json)

            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json"
                ])
            )
            let body = #"{"data":[{"url":"https://cdn.example.com/final.png"}],"revised_prompt":"a cat"}"#
            return (response, Data(body.utf8))
        }

        let service = makeStubbedChatService()
        let reply = try await service.sendMessage(
            config: config,
            history: [],
            message: ChatMessage(role: .user, content: "a cat"),
            onEvent: { _ in }
        )

        let firstPayload = try XCTUnwrap(capturedBodies.first)
        XCTAssertEqual(firstPayload["response_format"] as? String, "url")
        XCTAssertEqual(firstPayload["background"] as? Bool, true)
        XCTAssertEqual(firstPayload["async"] as? Bool, true)
        XCTAssertEqual(firstPayload["wait_for_generation"] as? Bool, false)
        XCTAssertEqual(reply.imageAttachments.first?.requestURLString, "https://cdn.example.com/final.png")
    }

    func testSendImageGenerationPollsAsyncTaskUntilImageReady() async throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-image", timeout: 30, streamEnabled: false)
        config.endpointMode = .imageGenerations
        config.imagesGenerationsPath = "/v1/images/generations"

        var requestedURLs: [String] = []
        var streamedTexts: [String] = []
        URLProtocolStub.handler = { request in
            let url = try XCTUnwrap(request.url).absoluteString
            requestedURLs.append(url)

            if url == "https://example.com/v1/images/generations" {
                let response = try XCTUnwrap(
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 202, httpVersion: nil, headerFields: [
                        "Content-Type": "application/json"
                    ])
                )
                let body = #"{"task_id":"img-task-1","status":"queued","status_url":"https://example.com/v1/images/generations/img-task-1"}"#
                return (response, Data(body.utf8))
            }

            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json"
                ])
            )
            let body = #"{"status":"succeeded","data":[{"url":"https://cdn.example.com/final-polled.png"}],"revised_prompt":"a cat"}"#
            return (response, Data(body.utf8))
        }

        let service = makeStubbedChatService()
        let reply = try await service.sendMessage(
            config: config,
            history: [],
            message: ChatMessage(role: .user, content: "a cat"),
            onEvent: { chunk in
                if !chunk.deltaText.isEmpty {
                    streamedTexts.append(chunk.deltaText)
                }
            }
        )

        XCTAssertEqual(Array(requestedURLs.prefix(2)), [
            "https://example.com/v1/images/generations",
            "https://example.com/v1/images/generations/img-task-1"
        ])
        XCTAssertEqual(reply.imageAttachments.first?.requestURLString, "https://cdn.example.com/final-polled.png")
        XCTAssertTrue(streamedTexts.contains(where: { $0.contains("图片任务已提交") }))
        XCTAssertTrue(streamedTexts.contains(where: { $0.contains("图片生成完成") }))
    }

    func testSendChatCompletionsNonStreamingConvertsBareUnsplashURLToImageAttachment() async throws {
        URLProtocolStub.handler = { request in
            let body = #"{"choices":[{"message":{"content":"Ferrari 488:\nhttps://images.unsplash.com/photo-1542362567-b07e54358753"}}]}"#
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(body.utf8))
        }

        let service = makeStubbedChatService()
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)

        let reply = try await service.sendMessage(
            config: config,
            history: [],
            message: ChatMessage(role: .user, content: "分享几张跑车图给我"),
            onEvent: { _ in }
        )

        XCTAssertEqual(reply.imageAttachments.first?.requestURLString, "https://images.unsplash.com/photo-1542362567-b07e54358753")
        XCTAssertFalse(reply.text.contains("images.unsplash.com"))
        XCTAssertTrue(reply.text.contains("Ferrari 488"))
    }

    func testSendChatCompletionsNonStreamingProbesGenericBareURLImageAttachment() async throws {
        URLProtocolStub.handler = { request in
            let url = try XCTUnwrap(request.url).absoluteString

            if url == "https://example.com/v1/chat/completions" {
                let body = #"{"choices":[{"message":{"content":"Ferrari 488:\nhttps://example.com/ferrari"}}]}"#
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, Data(body.utf8))
            }

            XCTAssertEqual(request.httpMethod, "HEAD")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/jpeg"]
                )
            )
            return (response, Data())
        }

        let service = makeStubbedChatService()
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)

        let reply = try await service.sendMessage(
            config: config,
            history: [],
            message: ChatMessage(role: .user, content: "分享几张跑车图给我"),
            onEvent: { _ in }
        )

        XCTAssertEqual(reply.imageAttachments.first?.requestURLString, "https://example.com/ferrari")
        XCTAssertFalse(reply.text.contains("https://example.com/ferrari"))
    }

    func testBuildEmbeddingsRequestUsesConfiguredEndpoint() throws {
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "text-embedding", timeout: 30, streamEnabled: false)
        config.embeddingsPath = "/v1/embeddings"

        let request = try ChatRequestBuilder.makeEmbeddingsRequest(config: config, input: "hello world")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/embeddings")
        XCTAssertEqual(json["model"] as? String, "text-embedding")
        XCTAssertEqual(json["input"] as? String, "hello world")
    }

    func testResponseCleanerRemovesBareImageLinks() {
        let raw = "结论如下\nhttps://example.com/generated-image.png\n请查看"

        let cleaned = ResponseCleaner.cleanAssistantText(raw)

        XCTAssertFalse(cleaned.contains("generated-image.png"))
        XCTAssertTrue(cleaned.contains("结论如下"))
        XCTAssertTrue(cleaned.contains("请查看"))
    }

    func testResponseCleanerPreservesCodeBlocksWhileRemovingMarkdownArtifacts() {
        let raw = """
        # 标题

        **先说结论**
        - 第一条
        - 第二条

        [查看链接](https://example.com)
        ![图](https://example.com/a.png)

        ```python
        let value = 1
        if __name__ == "__main__":
            print("ok")
        ```

        ---
        > 引用
        """

        let cleaned = ResponseCleaner.cleanAssistantText(raw)

        XCTAssertFalse(cleaned.contains("# 标题"))
        XCTAssertFalse(cleaned.contains("**"))
        XCTAssertFalse(cleaned.contains("---"))
        XCTAssertFalse(cleaned.contains("!["))
        XCTAssertFalse(cleaned.contains("[查看链接]"))
        XCTAssertFalse(cleaned.contains("> 引用"))
        XCTAssertTrue(cleaned.contains("查看链接"))
        XCTAssertTrue(cleaned.contains("https://example.com"))
        XCTAssertTrue(cleaned.contains("第一条"))
        XCTAssertTrue(cleaned.contains("第二条"))
        XCTAssertTrue(cleaned.contains("```python"))
        XCTAssertTrue(cleaned.contains("let value = 1"))
        XCTAssertTrue(cleaned.contains("__name__"))
        XCTAssertTrue(cleaned.contains("__main__"))
    }

    func testMessageContentParserSplitsAssistantCodeBlockIntoDedicatedSegment() {
        let message = ChatMessage(
            role: .assistant,
            content: "分析如下\n```python\nprint(\"hi\")\n```\n执行完成"
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(
            segments,
            [
                .text("分析如下\n"),
                .code(language: "python", content: "print(\"hi\")"),
                .text("\n执行完成")
            ]
        )
    }

    func testMessageContentParserAfterCleanerStillProducesCodeSegment() {
        let raw = """
        **示例**

        ```swift
        let total = 3
        ```
        """
        let cleaned = ResponseCleaner.cleanAssistantText(raw)
        let message = ChatMessage(role: .assistant, content: cleaned)

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], .text("示例\n\n"))
        XCTAssertEqual(segments[1], .code(language: "swift", content: "let total = 3"))
    }

    func testMessageContentParserShowsUnclosedCodeFenceAsCodeImmediately() {
        let message = ChatMessage(
            role: .assistant,
            content: "先看代码\n```swift\nprint(\"streaming\")"
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], .text("先看代码\n"))
        XCTAssertEqual(segments[1], .code(language: "swift", content: "print(\"streaming\")"))
    }

    func testMessageContentParserStripsMarkdownSymbolsInDisplayText() {
        let message = ChatMessage(
            role: .assistant,
            content: "# 标题\n**加粗**\n- 列表项\n> 引用"
        )

        let segments = MessageContentParser.parse(message)
        let text = segments.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()

        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("- "))
        XCTAssertFalse(text.contains("> "))
        XCTAssertTrue(text.contains("标题"))
        XCTAssertTrue(text.contains("加粗"))
        XCTAssertTrue(text.contains("列表项"))
        XCTAssertTrue(text.contains("引用"))
    }

    func testMessageContentParserKeepsInlineNonImageURLAsText() {
        let message = ChatMessage(
            role: .assistant,
            content: "百度官网是：https://www.baidu.com"
        )

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 1)
        guard case .text(let text) = segments[0] else {
            XCTFail("Expected text segment")
            return
        }
        XCTAssertEqual(text, "百度官网是：https://www.baidu.com")
    }

    func testMessageContentParserAfterCleanerKeepsMarkdownLinkURLAsText() {
        let raw = "[百度官网](https://www.baidu.com)"
        let cleaned = ResponseCleaner.cleanAssistantText(raw)
        let message = ChatMessage(role: .assistant, content: cleaned)

        let segments = MessageContentParser.parse(message)

        XCTAssertEqual(segments.count, 1)
        guard case .text(let text) = segments[0] else {
            XCTFail("Expected text segment")
            return
        }
        XCTAssertEqual(text, "百度官网 https://www.baidu.com")
    }

    func testMessageContentParserConvertsNumberedListToBulletList() {
        let message = ChatMessage(
            role: .assistant,
            content: "1) 安装依赖\n2. 最小示例\n3、运行程序"
        )

        let segments = MessageContentParser.parse(message)
        let text = segments.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()

        XCTAssertFalse(text.contains("1)"))
        XCTAssertFalse(text.contains("2."))
        XCTAssertFalse(text.contains("3、"))
        XCTAssertTrue(text.contains("• 安装依赖"))
        XCTAssertTrue(text.contains("• 最小示例"))
        XCTAssertTrue(text.contains("• 运行程序"))
    }

    func testMessageContentParserExpandsGitHubRepositoryRefWithURL() {
        let message = ChatMessage(
            role: .assistant,
            content: "LangChain (langchain-ai/langchain)"
        )

        let segments = MessageContentParser.parse(message)
        let text = segments.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()

        XCTAssertTrue(text.contains("langchain-ai/langchain"))
        XCTAssertTrue(text.contains("https://github.com/langchain-ai/langchain"))
    }

    func testMessageContentParserParsesMarkdownTableIntoDedicatedSegment() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            | 关卡区域 | 主题 | 核心 |
            | --- | --- | --- |
            | 森林区 | 顺序执行 | 语句顺序 |
            | 河流区 | 循环 | for/while |
            """
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertEqual(segments.count, 1)

        guard case .table(let headers, let rows) = segments[0] else {
            XCTFail("Expected table segment")
            return
        }

        XCTAssertEqual(headers, ["关卡区域", "主题", "核心"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["森林区", "顺序执行", "语句顺序"])
        XCTAssertEqual(rows[1], ["河流区", "循环", "for/while"])
    }

    func testMessageContentParserDoesNotTreatPipeTextWithoutSeparatorAsTable() {
        let message = ChatMessage(
            role: .assistant,
            content: "这里有竖线 A|B|C，但并不是 Markdown 表格。"
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertEqual(segments.count, 1)

        guard case .text(let text) = segments[0] else {
            XCTFail("Expected plain text segment")
            return
        }
        XCTAssertTrue(text.contains("A|B|C"))
    }

    func testMessageContentParserSectionsLongAssistantTextWithDividers() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            第一部分：目标与边界

            我们先把目标说清楚：做一个轻量可玩、当天能跑通核心循环的小项目，不要一开始就把联网、账号、排行榜全部加上。

            第二部分：最小可用玩法

            屏幕出现目标，玩家在限定时间内点击；命中加分，未命中结束。这个循环先做稳定，再加速度曲线和特效。

            第三部分：技术拆分

            先做输入与碰撞，再做状态机和结算页面，最后加资源管理与音效。每一步都单独可验证，避免一次改太多。
            """
        )

        let segments = MessageContentParser.parse(message)
        let dividerCount = segments.reduce(0) { partial, segment in
            if case .divider = segment { return partial + 1 }
            return partial
        }

        XCTAssertGreaterThanOrEqual(dividerCount, 1)
        XCTAssertTrue(segments.contains { segment in
            if case .text(let value) = segment {
                return value.contains("第一部分")
            }
            return false
        })
    }

    func testMessageContentParserTurnsTSVCodeBlockIntoTableSegment() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```tsv
            产品\t一月\t二月
            A\t100\t120
            B\t80\t90
            ```
            """
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertEqual(segments.count, 1)
        guard case .table(let headers, let rows) = segments[0] else {
            XCTFail("Expected table segment from tsv code block")
            return
        }
        XCTAssertEqual(headers, ["产品", "一月", "二月"])
        XCTAssertEqual(rows, [["A", "100", "120"], ["B", "80", "90"]])
    }

    func testMessageContentParserInfersPythonLanguageForCodeBlockWithoutLabel() {
        let message = ChatMessage(
            role: .assistant,
            content: """
            ```
            def add(a, b):
                return a + b
            ```
            """
        )

        let segments = MessageContentParser.parse(message)
        XCTAssertEqual(segments.count, 1)
        guard case .code(let language, let content) = segments[0] else {
            XCTFail("Expected code segment")
            return
        }
        XCTAssertEqual(language?.lowercased(), "python")
        XCTAssertTrue(content.contains("def add"))
    }

    func testSendMessageUsesChatCompletionsAgentToolLoopToWriteWorkspaceFile() async throws {
        try? FrontendProjectBuilder.clearLatestProject()
        defer { try? FrontendProjectBuilder.clearLatestProject() }

        var requestBodies: [[String: Any]] = []
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            requestBodies.append(json)

            let payload: [String: Any]
            if requestBodies.count == 1 {
                let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
                XCTAssertTrue(tools.contains { (($0["function"] as? [String: Any])?["name"] as? String) == "write_file" })
                payload = [
                    "choices": [[
                        "message": [
                            "role": "assistant",
                            "content": "",
                            "tool_calls": [[
                                "id": "call_write_1",
                                "type": "function",
                                "function": [
                                    "name": "write_file",
                                    "arguments": #"{"path":"notes/todo.txt","content":"hello"}"#
                                ]
                            ]]
                        ]
                    ]]
                ]
            } else {
                let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
                XCTAssertTrue(messages.contains {
                    ($0["role"] as? String) == "tool"
                        && ($0["tool_call_id"] as? String) == "call_write_1"
                })
                payload = [
                    "choices": [[
                        "message": [
                            "role": "assistant",
                            "content": "已完成。"
                        ]
                    ]]
                ]
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, data)
        }

        let service = makeStubbedChatService()
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)
        config.endpointMode = .chatCompletions

        var streamedText = ""
        let reply = try await service.sendMessage(
            config: config,
            history: [],
            message: ChatMessage(role: .user, content: "请创建文件 notes/todo.txt，并写入 hello"),
            onEvent: { chunk in
                streamedText += chunk.deltaText
            }
        )

        XCTAssertEqual(requestBodies.count, 2)
        XCTAssertTrue(streamedText.contains("写入 `notes/todo.txt`"))
        XCTAssertTrue(reply.text.contains("写入 `notes/todo.txt`"))
        XCTAssertTrue(reply.text.contains("已完成。"))

        let latest = try XCTUnwrap(FrontendProjectBuilder.latestProjectURL())
        let content = try String(contentsOf: latest.appendingPathComponent("notes/todo.txt"), encoding: .utf8)
        XCTAssertEqual(content, "hello")
    }

    func testSendMessageUsesResponsesAgentToolLoopWithFunctionCallOutput() async throws {
        try? FrontendProjectBuilder.clearLatestProject()
        defer { try? FrontendProjectBuilder.clearLatestProject() }

        var requestBodies: [[String: Any]] = []
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            requestBodies.append(json)

            let payload: [String: Any]
            if requestBodies.count == 1 {
                let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
                XCTAssertTrue(tools.contains { ($0["name"] as? String) == "list_dir" })
                payload = [
                    "id": "resp_1",
                    "output": [[
                        "type": "function_call",
                        "id": "fc_1",
                        "call_id": "call_list_1",
                        "name": "list_dir",
                        "arguments": #"{"path":".","limit":10}"#
                    ]]
                ]
            } else {
                XCTAssertEqual(json["previous_response_id"] as? String, "resp_1")
                let input = try XCTUnwrap(json["input"] as? [[String: Any]])
                XCTAssertEqual(input.first?["type"] as? String, "function_call_output")
                XCTAssertEqual(input.first?["call_id"] as? String, "call_list_1")
                payload = [
                    "id": "resp_2",
                    "output": [[
                        "type": "message",
                        "content": [[
                            "type": "output_text",
                            "text": "目录已检查完毕。"
                        ]]
                    ]]
                ]
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, data)
        }

        let service = makeStubbedChatService()
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)
        config.endpointMode = .responses

        var streamedText = ""
        let reply = try await service.sendMessage(
            config: config,
            history: [],
            message: ChatMessage(role: .user, content: "请执行一下，先查看 latest 当前目录"),
            onEvent: { chunk in
                streamedText += chunk.deltaText
            }
        )

        XCTAssertEqual(requestBodies.count, 2)
        XCTAssertTrue(streamedText.contains("检查 latest 工作区状态"))
        XCTAssertTrue(reply.text.contains("检查 latest 工作区状态"))
        XCTAssertTrue(reply.text.contains("目录已检查完毕。"))
    }

    func testAgentToolLoopFeedsMultipleToolResultsBackInOriginalOrder() async throws {
        try? FrontendProjectBuilder.clearLatestProject()
        defer { try? FrontendProjectBuilder.clearLatestProject() }

        let latest = try XCTUnwrap(FrontendProjectBuilder.latestProjectURL())
        try "hello".write(to: latest.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        var requestBodies: [[String: Any]] = []
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            requestBodies.append(json)

            let payload: [String: Any]
            if requestBodies.count == 1 {
                payload = [
                    "choices": [[
                        "message": [
                            "role": "assistant",
                            "content": "",
                            "tool_calls": [
                                [
                                    "id": "call_list_1",
                                    "type": "function",
                                    "function": [
                                        "name": "list_dir",
                                        "arguments": #"{"path":".","limit":10}"#
                                    ]
                                ],
                                [
                                    "id": "call_read_1",
                                    "type": "function",
                                    "function": [
                                        "name": "read_file",
                                        "arguments": #"{"path":"README.md","maxCharacters":1000}"#
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            } else {
                let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
                let toolMessages = messages.filter { ($0["role"] as? String) == "tool" }
                XCTAssertEqual(toolMessages.count, 2)
                XCTAssertEqual(toolMessages.compactMap { $0["tool_call_id"] as? String }, ["call_list_1", "call_read_1"])
                XCTAssertTrue((toolMessages[0]["content"] as? String ?? "").contains("README.md"))
                XCTAssertTrue((toolMessages[1]["content"] as? String ?? "").contains("hello"))
                payload = [
                    "choices": [[
                        "message": [
                            "role": "assistant",
                            "content": "两个工具结果都收到了。"
                        ]
                    ]]
                ]
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, data)
        }

        let service = makeStubbedChatService()
        var config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: false)
        config.endpointMode = .chatCompletions

        let reply = try await service.sendMessage(
            config: config,
            history: [],
            message: ChatMessage(role: .user, content: "请查看目录，并读取文件 README.md"),
            onEvent: { _ in }
        )

        XCTAssertEqual(requestBodies.count, 2)
        XCTAssertTrue(reply.text.contains("README.md"))
        XCTAssertTrue(reply.text.contains("两个工具结果都收到了。"))
    }

    func testWebsiteCreationDoesNotUseAgentToolLoopForInitialProjectOutput() {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let message = ChatMessage(role: .user, content: "做一个公司官网")

        let shouldUse = ChatRequestBuilder.shouldUseAgentToolLoop(
            config: config,
            history: [],
            message: message
        )

        XCTAssertFalse(shouldUse)
    }

    func testExplicitWorkspaceMutationStillUsesAgentToolLoop() {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let message = ChatMessage(role: .user, content: "删除这个项目")

        let shouldUse = ChatRequestBuilder.shouldUseAgentToolLoop(
            config: config,
            history: [],
            message: message
        )

        XCTAssertTrue(shouldUse)
    }

    func testNaturalWorkspaceDeleteUsesAgentToolLoop() {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let message = ChatMessage(role: .user, content: "把 notes/todo.txt 删除")

        let shouldUse = ChatRequestBuilder.shouldUseAgentToolLoop(
            config: config,
            history: [],
            message: message
        )

        XCTAssertTrue(shouldUse)
    }

    func testFolderContentsDeleteUsesAgentToolLoopWithoutDirectInference() {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let message = ChatMessage(role: .user, content: "删除 docs 文件夹里的文件")

        let shouldUse = ChatRequestBuilder.shouldUseAgentToolLoop(
            config: config,
            history: [],
            message: message
        )

        XCTAssertTrue(shouldUse)
    }

    func testCasualFollowupDoesNotUseAgentToolLoopAfterWorkspaceCommandHistory() {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)
        let history = [
            ChatMessage(role: .user, content: "清空 latest"),
            ChatMessage(role: .assistant, content: "[[clear:latest]]")
        ]
        let message = ChatMessage(role: .user, content: "说说原因")

        let shouldUse = ChatRequestBuilder.shouldUseAgentToolLoop(
            config: config,
            history: history,
            message: message
        )

        XCTAssertFalse(shouldUse)
    }

    func testQwenProjectRequestDoesNotUseAgentToolLoop() {
        let config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "qwen/qwen3.6-plus", timeout: 30, streamEnabled: true)
        let message = ChatMessage(role: .user, content: "做一个前端网站")

        let shouldUse = ChatRequestBuilder.shouldUseAgentToolLoop(
            config: config,
            history: [],
            message: message
        )

        XCTAssertFalse(shouldUse)
    }

    private func makeStubbedChatService() -> ChatService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return ChatService(session: session)
    }
}

final class ChatViewModelTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    @MainActor
    func testRefreshAvailableModelsMarksCurrentModelAvailableOnlyAfterSuccessfulValidation() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            let body = "{\"data\":[{\"id\":\"gpt-test\"},{\"id\":\"other\"}]}"
            let data = try XCTUnwrap(body.data(using: .utf8))
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, data)
        }

        let viewModel = ChatViewModel(service: makeStubbedService())
        viewModel.config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)

        XCTAssertFalse(viewModel.hasValidatedModelList)
        XCTAssertFalse(viewModel.isCurrentModelAvailable)

        await viewModel.refreshAvailableModels()

        XCTAssertTrue(viewModel.hasValidatedModelList)
        XCTAssertEqual(viewModel.availableModels, ["gpt-test", "other"])
        XCTAssertTrue(viewModel.isCurrentModelAvailable)
    }

    @MainActor
    func testRefreshAvailableModelsFailureKeepsModelUnavailable() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 500, httpVersion: nil, headerFields: nil))
            return (response, Data())
        }

        let viewModel = ChatViewModel(service: makeStubbedService())
        viewModel.config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "gpt-test", timeout: 30, streamEnabled: true)

        await viewModel.refreshAvailableModels()

        XCTAssertFalse(viewModel.hasValidatedModelList)
        XCTAssertTrue(viewModel.availableModels.isEmpty)
        XCTAssertFalse(viewModel.isCurrentModelAvailable)
    }

    @MainActor
    func testRefreshAvailableModelsDoesNotAutoSwitchCurrentModel() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            let body = "{\"data\":[{\"id\":\"gpt-test\"},{\"id\":\"other\"}]}"
            let data = try XCTUnwrap(body.data(using: .utf8))
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, data)
        }

        let viewModel = ChatViewModel(service: makeStubbedService())
        viewModel.config = ChatConfig(apiURL: "https://example.com", apiKey: "", model: "custom-model", timeout: 30, streamEnabled: true)

        await viewModel.refreshAvailableModels()

        XCTAssertEqual(viewModel.config.model, "custom-model")
        XCTAssertEqual(viewModel.availableModels, ["gpt-test", "other"])
        XCTAssertFalse(viewModel.isCurrentModelAvailable)
        XCTAssertTrue(viewModel.hasValidatedModelList)
    }

    private func makeStubbedService() -> ChatService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return ChatService(session: session)
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
