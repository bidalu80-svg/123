# Embedded CPython Setup (iOS)

目标：让 iOS App 在本地直接运行完整 Python（支持 `import/def/try/...`），不依赖后端代理。

## 现状
- App 已内置自动探测逻辑：优先加载 `Python.framework`（若存在），否则回退到轻量兼容运行器。
- 入口代码：
  - `ios/App/Sources/EmbeddedCPythonRuntime.swift`
  - `ios/App/Sources/PythonExecutionService.swift`

## 你需要准备
1. `Python.framework`（iOS device 架构）
2. Python 标准库（建议放在 App 资源目录：`PythonRuntime/lib/python3.x`）

推荐来源：BeeWare 的 `Python-Apple-support`（预编译 Apple 平台 Python 运行时）。

## 放置约定
1. 把 framework 放到：
   - `ios/Vendor/Python.framework`（或等价位置，后续在 Xcode 工程中 Embed）
2. 把标准库放到：
   - `ios/App/Resources/PythonRuntime/lib/python3.x/...`

运行时会自动设置：
- `PYTHONHOME=<AppResources>/PythonRuntime`
- `PYTHONPATH=<AppResources>/PythonRuntime/lib/python3.x`

## Xcode/XcodeGen 侧要求
1. 将 `Python.framework` 加入 `ChatApp` target 的 `Frameworks, Libraries, and Embedded Content`
2. 选择 `Embed & Sign`
3. 确保 `PythonRuntime` 目录被打进 App Resources

## 当前仓库状态（已自动化）
- `ios/project.yml` 已声明 `Vendor/Python.xcframework` 作为依赖并 `embed + codeSign`。
- GitHub Actions `build-ios-ipa.yml` 已自动：
  - 下载 BeeWare iOS 支持包
  - 放置 `Vendor/Python.xcframework`
  - 准备 `App/Resources/PythonRuntime/lib/python3.13`
  - 覆盖 arm64 `lib-dynload` 扩展模块

## 验证方式
在聊天里运行：

```python
import os
print("ok", os.name)
```

若输出正常且无“本地运行器暂不支持”提示，说明已启用完整 CPython。

## 常见问题
1. 仍提示未检测到嵌入 CPython
- 检查 `Python.framework` 是否真的被 Embed 到 `.app/Frameworks`
- 检查签名是否有效（`Embed & Sign`）

2. `import` 失败
- 多数是 `PythonRuntime/lib/python3.x` 没有打进包，或 `python3.x` 目录层级不对

3. 只在模拟器可用，真机失败
- 检查 framework 架构是否包含 `arm64`（iOS device）
