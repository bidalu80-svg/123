#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT_DIR = Path(os.getenv("LOCAL_MCP_ROOT", os.getcwd())).resolve()
MAX_OUTPUT = int(os.getenv("LOCAL_MCP_MAX_OUTPUT", "12000"))
DEFAULT_TIMEOUT = int(os.getenv("LOCAL_MCP_DEFAULT_TIMEOUT", "90"))


def send_message(payload: dict[str, Any]) -> None:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    sys.stdout.write(f"Content-Length: {len(data)}\r\n\r\n")
    sys.stdout.flush()
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def read_message() -> dict[str, Any] | None:
    headers: dict[str, str] = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        decoded = line.decode("utf-8", errors="replace").strip()
        if ":" in decoded:
            key, value = decoded.split(":", 1)
            headers[key.strip().lower()] = value.strip()

    length = int(headers.get("content-length", "0"))
    if length <= 0:
        return None
    body = sys.stdin.buffer.read(length)
    return json.loads(body.decode("utf-8"))


def text_result(text: str, rendered_log: str) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": text}],
        "structuredContent": {
            "renderedLog": rendered_log,
            "output": text,
        },
    }


def sanitize_relative_path(raw_path: str) -> str | None:
    value = raw_path.strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    while value.startswith("/"):
        value = value[1:]
    if not value or ".." in value.split("/"):
        return None
    cleaned = [segment.strip() for segment in value.split("/") if segment.strip()]
    if not cleaned:
        return None
    return "/".join(cleaned)


def resolve_path(raw_path: str) -> tuple[Path, str]:
    normalized = sanitize_relative_path(raw_path)
    if not normalized:
        raise ValueError(f"invalid path: {raw_path}")
    target = (ROOT_DIR / normalized).resolve()
    if target != ROOT_DIR and ROOT_DIR not in target.parents:
        raise ValueError("path escapes root")
    return target, normalized


def clip_output(text: str) -> str:
    compact = text.strip()
    if len(compact) <= MAX_OUTPUT:
        return compact
    return compact[:MAX_OUTPUT] + "\n...[truncated]"


def tool_list() -> list[dict[str, Any]]:
    return [
        {
            "name": "list_dir",
            "description": "List directory entries in latest workspace.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "limit": {"type": "integer"},
                },
            },
        },
        {
            "name": "read_file",
            "description": "Read a text file from latest workspace.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "startLine": {"type": "integer"},
                    "endLine": {"type": "integer"},
                    "maxCharacters": {"type": "integer"},
                },
                "required": ["path"],
            },
        },
        {
            "name": "write_file",
            "description": "Write a file in latest workspace.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
            },
        },
        {
            "name": "edit_file",
            "description": "Replace exact text in a file.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "oldText": {"type": "string"},
                    "newText": {"type": "string"},
                },
                "required": ["path", "oldText", "newText"],
            },
        },
        {
            "name": "grep_files",
            "description": "Search text in files.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "path": {"type": "string"},
                    "limit": {"type": "integer"},
                },
                "required": ["query"],
            },
        },
        {
            "name": "delete_path",
            "description": "Delete a file or directory.",
            "inputSchema": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
            },
        },
        {
            "name": "clear_workspace",
            "description": "Clear latest workspace.",
            "inputSchema": {"type": "object", "properties": {}},
        },
        {
            "name": "run_python_file",
            "description": "Run a Python file from latest workspace.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "stdin": {"type": "string"},
                    "timeout": {"type": "integer"},
                },
                "required": ["path"],
            },
        },
    ]


def execute_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name == "list_dir":
        raw_path = str(arguments.get("path", "")).strip()
        target = ROOT_DIR if not raw_path or raw_path == "." else resolve_path(raw_path)[0]
        limit = max(1, min(int(arguments.get("limit", 120)), 400))
        if not target.is_dir():
            return text_result(f"错误：目录 `{raw_path or '.'}` 不存在。", "查看目录")
        entries = sorted(target.iterdir(), key=lambda item: item.name.lower())
        rendered = [(item.name + "/" if item.is_dir() else item.name) for item in entries[:limit]]
        return text_result("\n".join(rendered) if rendered else "[empty]", "查看目录")

    if name == "read_file":
        target, normalized = resolve_path(str(arguments.get("path", "")))
        if not target.is_file():
            return text_result(f"错误：文件 `{normalized}` 不存在。", f"读取 `{normalized}`")
        content = target.read_text(encoding="utf-8")
        lines = content.replace("\r\n", "\n").split("\n")
        start_line = max(1, int(arguments.get("startLine", 1)))
        end_line = min(len(lines), int(arguments.get("endLine", min(len(lines), start_line + 199))))
        selected = [
            f"{index + 1}\t{line}"
            for index, line in enumerate(lines)
            if start_line <= index + 1 <= end_line
        ]
        return text_result(clip_output("\n".join(selected) or "[empty file]"), f"读取 `{normalized}`")

    if name == "write_file":
        target, normalized = resolve_path(str(arguments.get("path", "")))
        target.parent.mkdir(parents=True, exist_ok=True)
        content = str(arguments.get("content", ""))
        target.write_text(content, encoding="utf-8")
        return text_result(f"已写入 `{normalized}`（{len(content)} 字符）。", f"写入 `{normalized}`")

    if name == "edit_file":
        target, normalized = resolve_path(str(arguments.get("path", "")))
        if not target.is_file():
            return text_result(f"错误：文件 `{normalized}` 不存在。", f"编辑 `{normalized}`")
        old_text = str(arguments.get("oldText", ""))
        new_text = str(arguments.get("newText", ""))
        content = target.read_text(encoding="utf-8")
        if old_text not in content:
            return text_result(f"错误：在 `{normalized}` 中没有找到待替换文本。", f"编辑 `{normalized}`")
        target.write_text(content.replace(old_text, new_text, 1), encoding="utf-8")
        return text_result(f"已编辑 `{normalized}`。", f"编辑 `{normalized}`")

    if name == "grep_files":
        query = str(arguments.get("query", "")).strip()
        if not query:
            return text_result("错误：缺少搜索文本。", "搜索文本")
        raw_path = str(arguments.get("path", "")).strip()
        target = ROOT_DIR if not raw_path or raw_path == "." else resolve_path(raw_path)[0]
        limit = max(1, min(int(arguments.get("limit", 40)), 200))
        matches: list[str] = []
        files = [target] if target.is_file() else [item for item in target.rglob("*") if item.is_file()]
        for file in files:
            try:
                content = file.read_text(encoding="utf-8")
            except Exception:
                continue
            relative = file.relative_to(ROOT_DIR).as_posix()
            for index, line in enumerate(content.replace("\r\n", "\n").split("\n"), start=1):
                if query.lower() in line.lower():
                    matches.append(f"{relative}:{index}: {line}")
                    if len(matches) >= limit:
                        break
            if len(matches) >= limit:
                break
        return text_result("\n".join(matches) if matches else "未找到匹配项。", f"搜索 `{query}`")

    if name == "delete_path":
        target, normalized = resolve_path(str(arguments.get("path", "")))
        if not target.exists():
            return text_result(f"路径 `{normalized}` 不存在，无需删除。", f"删除 `{normalized}`")
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink()
        return text_result(f"已删除 `{normalized}`。", f"删除 `{normalized}`")

    if name == "clear_workspace":
        if ROOT_DIR.exists():
            for child in ROOT_DIR.iterdir():
                if child.is_dir():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        ROOT_DIR.mkdir(parents=True, exist_ok=True)
        return text_result("latest 工作区已清空。", "清空 latest 工作区")

    if name == "run_python_file":
        target, normalized = resolve_path(str(arguments.get("path", "")))
        if not target.is_file():
            return text_result(f"错误：Python 文件 `{normalized}` 不存在。", f"运行 `{normalized}`")
        timeout = max(5, min(int(arguments.get("timeout", DEFAULT_TIMEOUT)), 300))
        stdin_text = str(arguments.get("stdin", ""))
        completed = subprocess.run(
            [shutil.which("python3") or shutil.which("python") or "python3", normalized],
            cwd=str(ROOT_DIR),
            input=stdin_text,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        stdout = completed.stdout or ""
        stderr = completed.stderr or ""
        merged = stdout.strip()
        if stderr.strip():
            merged = f"{merged}\n\n[stderr]\n{stderr}".strip()
        if completed.returncode != 0:
            merged = f"{merged}\n\n[exit code {completed.returncode}]".strip()
        return text_result(clip_output(merged or "[no output]"), f"运行 `{normalized}`")

    return text_result(f"错误：未知工具 `{name}`。", f"执行 `{name}`")


def handle_request(message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    message_id = message.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": message_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "serverInfo": {"name": "iexa-local-mcp", "version": "1.0.0"},
                "capabilities": {"tools": {}},
            },
        }

    if method == "notifications/initialized":
        return None

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": message_id,
            "result": {"tools": tool_list()},
        }

    if method == "tools/call":
        params = message.get("params") or {}
        name = str(params.get("name", "")).strip()
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, dict):
            arguments = {}
        result = execute_tool(name, arguments)
        return {
            "jsonrpc": "2.0",
            "id": message_id,
            "result": result,
        }

    return {
        "jsonrpc": "2.0",
        "id": message_id,
        "error": {
            "code": -32601,
            "message": f"Method not found: {method}",
        },
    }


def main() -> None:
    while True:
        request = read_message()
        if request is None:
            break
        response = handle_request(request)
        if response is not None:
            send_message(response)


if __name__ == "__main__":
    main()
