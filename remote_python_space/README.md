# Remote Python Space

给 ChatApp 用的免费远端 Python 执行通道，目标平台是 Hugging Face Spaces（Docker）。

## 接口

- `GET /health`
- `POST /v1/python/execute`

请求体示例：

```json
{
  "mode": "run_file",
  "entry_path": "main.py",
  "stdin": "",
  "timeout": 180,
  "files": [
    {
      "path": "main.py",
      "content_base64": "cHJpbnQoImhlbGxvIikK"
    }
  ]
}
```

支持的 `mode`：

- `run_file`
- `unit_tests`
- `compile_all`

## Hugging Face Spaces 部署

1. 新建一个 `Docker` 类型的 Space
2. 把本目录全部上传
3. 在 Space Secrets 中设置：

```text
REMOTE_PYTHON_API_KEY=你的密钥
```

4. 部署完成后，记下你的公开地址，例如：

```text
https://your-name-your-space.hf.space
```

5. 在 ChatApp 设置里开启“远端 Python 执行”

建议填写：

- 地址：`https://your-name-your-space.hf.space/v1/python/execute`
- API Key：和 `REMOTE_PYTHON_API_KEY` 一致

## 说明

- 这是“增强版远端 Python”方案，适合带纯 Python 依赖的项目
- 免费 Space 会休眠，首次唤醒可能较慢
- 带原生扩展的大包（如 `numpy`、`pandas`、`lxml`、`cryptography`）不保证免费环境能稳定装好
