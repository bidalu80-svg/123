# Terminal Agent (Zero Dependency)

This module is a standalone terminal tester for the same chat API used by the iOS app.

It uses only Swift standard libraries (`Foundation`) and does not require npm/pip/brew packages.

## Quick Start

```bash
swift ios/Tools/terminal_agent.swift --api-url https://your-host.com --api-key sk-xxx --prompt "你好"
```

## Agent Mode

```bash
swift ios/Tools/terminal_agent.swift --api-url https://your-host.com --agent web --web-out ./web --prompt "做一个单页网站"
```

When `--agent web` is used, the assistant is instructed to output files in `[[file:...]]` format.
If the output matches this format, files are written into `--web-out` directory.

Preview with zero dependency:

```bash
open ./web/index.html
```

## Interactive Mode

```bash
swift ios/Tools/terminal_agent.swift --api-url https://your-host.com --interactive
```
