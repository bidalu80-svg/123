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

### 7) CI 自动嵌入 CPython（已接通）
- `ios/project.yml` 已添加 `Vendor/Python.xcframework` 依赖（`embed + codeSign`）。
- `.github/workflows/build-ios-ipa.yml` 已自动执行：
  - 下载 BeeWare `Python-3.13-iOS-support.b13.tar.gz`
  - 解包并注入 `Vendor/Python.xcframework`
  - 生成 `App/Resources/PythonRuntime/lib/python3.13`
  - 覆盖 iOS arm64 `lib-dynload` 扩展模块
  - 裁剪 `test/idlelib/tkinter/turtledemo/ensurepip` 以控制体积
- `.gitignore` 已忽略：
  - `ios/Vendor/Python.xcframework/`
  - `ios/App/Resources/PythonRuntime/`

---

## 2026-04-14 本轮要点（v2.2）

### 1) 接口模式可切换（核心）
- 目标：把 OpenAI 风格常用接口做成可切换模式，便于直接在 App 内测试。
- 新增模式：
  - `Chat` -> `/v1/chat/completions`
  - `Image` -> `/v1/images/generations`
  - `Audio` -> `/v1/audio/transcriptions`
  - `Embedding` -> `/v1/embeddings`
  - `Models` -> `/v1/models`
- 实现文件：
  - `ios/App/Sources/ChatConfig.swift`
  - `ios/App/Sources/ChatService.swift`
  - `ios/App/Sources/ChatViewModel.swift`
  - `ios/App/Sources/SettingsScreen.swift`
  - `ios/App/Sources/ChatScreen.swift`

### 2) 配置能力增强
- `ChatConfig` 新增：
  - `endpointMode`
  - 各接口 path（chat/image/audio/embedding/models）
  - 生图尺寸 `imageGenerationSize`
- `Settings` 页新增：
  - 接口模式选择器
  - 各 endpoint 路径可编辑
  - 当前生效 endpoint URL 显示

### 3) 发送链路按模式分流
- `ChatService.sendMessage` 现在按模式路由：
  - Chat: 走原有流式/非流式聊天
  - Image: 调用生图接口并回显图片
  - Embedding: 调用向量接口并回显维度+前几维
  - Models: 直接回显模型列表
  - Audio: 支持 multipart 音频转写（需音频附件）

### 4) 文件与音频附件能力
- 单文件导入继续支持“任意单文件”，文本自动解码。
- 对音频文件（mp3/wav/m4a/aac/ogg/flac）：
  - 保留二进制 base64 以支持 `/v1/audio/transcriptions`
  - 草稿区显示“音频已附加”提示
- 相关文件：
  - `ios/App/Sources/ChatMessage.swift`
  - `ios/App/Sources/ChatViewModel.swift`
  - `ios/App/Sources/ChatScreen.swift`

### 5) 其他本轮优化
- 图片加载失败修复增强：
  - URL 归一化、鉴权头重试、JSON 二次取图
  - 文件：`ios/App/Sources/RemoteImageView.swift`
- Python `notification` 兼容 shim：
  - 文件：`ios/App/Sources/EmbeddedCPythonRuntime.swift`
- 跨会话记忆：
  - 文件：`ios/App/Sources/ConversationMemoryStore.swift`
- 中文语音转文本输入：
  - 文件：`ios/App/Sources/SpeechToTextService.swift`
  - 权限：`Info.plist` 增加麦克风和语音识别说明
- 模型厂商识别扩展：
  - 增加 MiniMax / Zhipu / Perplexity / Cohere / Groq / Together / Fireworks 等识别
- 聊天气泡头像图标升级为渐变聊天徽标：
  - 文件：`ios/App/Sources/MessageBubbleView.swift`

### 6) 测试补充
- `ios/Tests/ChatConfigStoreTests.swift` 增加 endpoint 归一化覆盖。
- `ios/Tests/ChatServiceTests.swift` 增加 image / embeddings request builder 覆盖。

### 7) 本次 IPA 重新构建结果
- 提交：
  - `b5f0373` (`main`)
- GitHub Actions：
  - Workflow: `Build iOS IPA`
  - Run: `24381110916`
  - 链接：`https://github.com/Return-end/blankai-ios/actions/runs/24381110916`
- 产物（已下载到本地）：
  - `artifacts/run-24381110916/chatapp-ipa/exported/IEXA.ipa`

---

## 2026-04-14 本轮追加要点（v2.3）

### 1) 助手消息操作栏显示策略
- 调整为：每条助手消息都显示底部操作栏（复制、点赞、点踩、更多）。
- 重试按钮仍仅对“最新一条助手消息”生效，避免老消息触发错误重试语义。
- 文件：
  - `ios/App/Sources/ChatScreen.swift`

### 2) 图标与回复风格升级（保持品牌 IEXA）
- 保持品牌名称 `IEXA` 不变，仅调整左侧助手小图标视觉风格（Minis 风格方向）。
- 系统提示词加入“结构化回答偏好”约束，默认更有层次（先结论再要点）。
- 文本解析器改进：
  - 保留并强化列表符号 `•`
  - 对纯短行组自动进行 bullet 化，减少“无指示的逐行文本块”
- 文件：
  - `ios/App/Sources/MessageBubbleView.swift`
  - `ios/App/Sources/ChatService.swift`
  - `ios/App/Sources/MessageContentParser.swift`

### 3) 配置页精简
- 按需求移除配置页中的 endpoint 路径和完整 URL 展示。
- 保留顶部/菜单内“接口模式切换”即可完成模式切换。
- 文件：
  - `ios/App/Sources/SettingsScreen.swift`

### 4) 私密聊天模式（新）
- 新增右上角 👻 私密开关。
- 开启后行为：
  - 输入框容器切换为深色风格
  - 对话仅保存在内存（`privateMessages`），不写入会话持久化
  - 关闭后恢复普通会话视图
- 影响点：
  - 发送、流式更新、停止、异常、清空等逻辑均区分私密/普通模式
  - `persistSessions()` 在私密模式下禁写
- 文件：
  - `ios/App/Sources/ChatViewModel.swift`
  - `ios/App/Sources/ChatScreen.swift`

### 5) 底部输入区交互重做（按需求）
- 移除独立话筒按钮。
- 右侧黑色圆按钮改为双态：
  - 无文本且无附件时：语音输入（再次点击停止）
  - 有文本或附件时：发送
  - 发送中：停止
- 文件：
  - `ios/App/Sources/ChatScreen.swift`

### 6) 首次启动强制配置弹窗（一次性）
- 新增首次使用 `InitialConfigSheet`：
  - 首次打开必须先填基础配置（API URL / API Key / Model）
  - 保存后写入本地标记 `chatapp.config.onboarding.done`
  - 后续二次启动不再弹出
- 文件：
  - `ios/App/Sources/ChatScreen.swift`

### 7) 本轮相关提交
- `968a40f` docs: 记录 v2.2 变更与构建
- `2b1e5d1` fix: 所有助手回复显示操作栏
- `e3c5753` feat: Minis 风格图标 + 更结构化回复
- `05689a1` refactor: 配置页隐藏接口路径/URL展示
- `e7e57ba` feat: 私密模式 + 双态黑色圆按钮 + 首次配置弹窗

### 8) 本轮 IPA 构建记录
- Run `24381253122`（success）
  - `artifacts/run-24381253122/chatapp-ipa/exported/IEXA.ipa`
- Run `24382713906`（success）
- Run `24383039887`（success）
- Run `24383150851`（success）
  - `artifacts/run-24383150851/chatapp-ipa/exported/IEXA.ipa`
- Run `24383946194`（success）
  - `artifacts/run-24383946194/chatapp-ipa/exported/IEXA.ipa`

### 9) 当前状态总结
- 接口切换、私密聊天、语音输入/发送双态、首次配置弹窗均已接通。
- 品牌保持 `IEXA`，并未改名为 `Minis`。

---

## 2026-04-15 本轮要点（v2.4）

### 1) 认证策略回调为“登录 + 注册”
- 登录页恢复为账号密码模式，显示：
  - `登录使用`
  - `注册使用`
- 已移除强依赖 Apple 登录的单按钮形态，避免描述文件能力不匹配导致不可用。
- 相关文件：
  - `ios/App/Sources/AuthScreen.swift`
  - `ios/UITests/ChatAppUITests.swift`

### 2) 设备限制策略（核心）
- 注册限制：
  - 同一设备仅允许成功注册 1 个账号。
- 登录限制：
  - 账号首次成功登录后绑定设备；
  - 后续仅允许该账号在同一设备登录；
  - 换设备登录将被拒绝（403）。
- 客户端实现：
  - 新增设备安装 ID（Keychain 持久化，失败回退 UserDefaults）。
  - 所有 auth 关键请求自动携带头：`X-Device-Install-ID`。
- 相关文件：
  - `ios/App/Sources/DeviceInstallIdentity.swift`
  - `ios/App/Sources/AuthService.swift`
  - `cloudflare/auth-worker/src/index.ts`

### 3) 管理员解绑设备（换机迁移）
- 新增接口：`POST /auth/admin/unbind-device`
- 仅管理员 token 可调用（`blank / 888888` 登录后拿 token）。
- 行为：
  - 删除账号设备绑定；
  - 撤销该账号当前有效会话；
  - 用户可在新设备重新登录并建立新绑定。
- 文档已补充：
  - `cloudflare/auth-worker/README.md`

### 4) Cloudflare Worker 线上部署
- Worker：`chatapp-auth-worker-v2`
- 地址：`https://chatapp-auth-worker-v2.bidalu9.workers.dev`
- 部署版本（当次）：`71dfc567-a803-4000-83b0-70b0c826adb7`
- `/auth/health` 已确认：
  - `accountDeviceBindingEnabled: true`
  - `adminDeviceUnbindEnabled: true`

### 5) 线上联调验证结果
- 对线上环境执行了端到端验证，覆盖：
  - 首次注册成功
  - 同设备二次注册拦截
  - 跨设备登录拦截（解绑前）
  - 管理员解绑成功
  - 解绑后新设备登录成功
  - 旧设备再次拦截
  - 无设备标识请求拦截（400）
- 本轮自动化验证结果：`10/10 通过`。

### 6) 最新 IPA 构建记录
- Run：`24452435817`（success）
- 链接：`https://github.com/bidalu80-svg/123/actions/runs/24452435817`
- Artifact：`chatapp-ipa`

### 7) 当前可用运维动作
- 管理员解绑命令（示意）：
  - 先 `POST /auth/login` 拿管理员 token
  - 再 `POST /auth/admin/unbind-device` 指定 `account`
- 该动作用于“用户换手机后无法登录”的人工放行。
