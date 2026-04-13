# IEXA iOS v2.0 记忆要点

## 版本目标
将 iOS 客户端从基础聊天测试版升级为更接近生产形态的 `IEXA`：
- 站点地址可只填域名
- 自动保存配置
- 支持模型列表拉取和切换
- 支持图片与文本/代码文件附件
- 支持 AI 图片回复展示
- 支持多会话侧栏、删除与一键清空
- 聊天回复样式清爽化（清理 `<think>`、标题符号等）
- 支持局部文字选择复制与 0.5 秒复制提示
- 右上角全局小日期周时间角标

## 核心实现文件
- 配置与 URL 规范：`ios/App/Sources/ChatConfig.swift`
- 消息与附件模型：`ios/App/Sources/ChatMessage.swift`
- 网络层与模型拉取：`ios/App/Sources/ChatService.swift`
- 流式分片解析：`ios/App/Sources/StreamParser.swift`
- 多会话持久化：`ios/App/Sources/ChatSessionStore.swift`
- 状态总控：`ios/App/Sources/ChatViewModel.swift`
- 聊天页与侧栏：`ios/App/Sources/ChatScreen.swift`
- 配置页：`ios/App/Sources/SettingsScreen.swift`
- 消息渲染：`ios/App/Sources/MessageBubbleView.swift`
- 内容分段与代码块流式显示：`ios/App/Sources/MessageContentParser.swift`
- 全局时间角标：`ios/App/Sources/CornerClockBadge.swift`

## 关键行为约定
1. 站点地址
- 用户输入 `https://xxx.com` 即可。
- 请求时自动拼接：
  - 聊天：`/v1/chat/completions`
  - 模型列表：`/v1/models`

2. 自动保存
- `ChatViewModel.config` 变更即写入 `UserDefaults`，无需手动点“保存配置”。

3. 模型列表
- 配置页“拉取可用模型”走 `/v1/models`。
- 返回 `data[].id` 填充模型选择器。

4. 附件
- 输入框左侧圆形 `+` 菜单支持：
  - 图片（Photo Picker）
  - 文本/代码文件（File Importer）
- 文件内容会被包装为 prompt block 发送给模型。

5. AI 图片回复
- 非流式与流式都支持解析 `image_url` / `output_image` 风格字段。
- 同时支持 markdown 内联图片链接提取。

6. 干净回复
- 最终回复落盘前清理：
  - `<think>...</think>`
  - markdown 标题井号前缀
  - `*` 列表符号规范化

7. 会话系统
- 支持多会话、切换、删除、全部清空。
- 聊天页右滑可拉出会话侧栏。

8. 品牌
- `ios/project.yml` 的 `PRODUCT_NAME` 已改为 `IEXA`。

## GitHub Actions IPA 构建说明
工作流文件：`.github/workflows/build-ios-ipa.yml`
- 依赖 iOS 签名密钥 secrets（证书、描述文件、Team ID 等）
- 触发方式：push 到 `main/master` 或手动 `workflow_dispatch`
- 产物：IPA + xcarchive artifact

## 下次迭代建议
1. 增加真正的 markdown 渲染层（表格/引用/列表更完整）
2. 附件支持多文件同时发送
3. 把会话存储升级到本地数据库（可检索、可分页）
4. 为模型列表与回复解析增加网络层单测（mock URLProtocol）

---

## 2026-04-13 本轮要点（v2.1）

### 1) Python 运行能力：改为本地零依赖
- 目标：不依赖后端代理，不走外网执行服务。
- 实现：`PythonExecutionService` 从远程 API 调用改为本地解释执行。
- 当前支持：
  - 变量赋值
  - `print(...)`
  - 算术表达式与括号
  - `if/else`
  - `while`
  - `for ... in range(...)`
  - `len(...)`
  - 布尔与比较表达式
- 保护策略：
  - 最大代码长度限制
  - 循环步数限制
  - 输出长度限制
- 文件：
  - `ios/App/Sources/PythonExecutionService.swift`
  - `ios/Tests/PythonExecutionServiceTests.swift`

### 2) HTML 代码运行：识别增强
- 目标：聊天代码块中更稳定地出现“运行网页”按钮。
- 增强点：
  - language/title 支持 `html` / `htm` / `xhtml` / `text/html`
  - 内容检测新增 `<head>` / `<body>` 关键标记
- 文件：
  - `ios/App/Sources/MessageBubbleView.swift`

### 3) 最新知识能力：实时上下文增强
- 市场范围扩展（默认 symbols）：
  - 商品：黄金、WTI、布伦特、白银、铜
  - 指数：标普、纳指、道指、罗素2000、日经、恒生、富时100、DAX
  - 个股：AAPL、NVDA、TSLA、MSFT、AMZN
- 热点新闻来源升级为多源聚合并去重：
  - Google News 中文
  - Google News 英文
  - Google News WORLD
  - Google News BUSINESS
- 文件：
  - `ios/App/Sources/ChatConfig.swift`
  - `ios/App/Sources/RealtimeContextProvider.swift`

### 4) 构建与产物记录（2026-04-13）
- 提交：
  - `8cba38d` (`main`)
- GitHub Actions：
  - Workflow: `Build iOS IPA`
  - Run: `24341287468`
  - 链接：`https://github.com/Return-end/blankai-ios/actions/runs/24341287468`
- 产物下载到本地：
  - `artifacts/ipa-24341287468/exported/IEXA.ipa`

### 5) 说明与限制
- 本地 Python 运行器是“可控子集解释器”，优先保障离线可用与安全边界。
- 若后续需要完整 CPython 兼容（第三方库、复杂语法、文件系统/网络等），建议单独规划沙箱与权限模型。

### 6) 完整 CPython 集成（已加接入层）
- 新增自动探测模块：若 App 内存在 `Python.framework`，优先走完整 CPython；否则回退轻量解释器。
- 新增文件：
  - `ios/App/Sources/EmbeddedCPythonRuntime.swift`
  - `ios/Tools/EMBEDDED_CPYTHON_SETUP.md`
- 使用提示：
  - 未检测到 `Python.framework` 时，运行输出会提示“当前为兼容模式”。
