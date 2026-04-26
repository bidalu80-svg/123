#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

HOST = os.getenv("MCP_BRIDGE_HOST", "0.0.0.0")
PORT = int(os.getenv("MCP_BRIDGE_PORT", "8790"))
TOKEN = os.getenv("MCP_BRIDGE_TOKEN", "").strip()
ROOT_DIR = Path(os.getenv("MCP_BRIDGE_ROOT", os.getcwd())).resolve()
DEFAULT_TIMEOUT = int(os.getenv("MCP_BRIDGE_DEFAULT_TIMEOUT", "90"))


class StdioMCPClient:
    def __init__(self) -> None:
        self._process: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._next_id = 1

    def _command(self) -> list[str]:
        raw = os.getenv("MCP_SERVER_COMMAND", "").strip()
        if raw:
            return raw.split(" ")
        return ["python3", "ios/Tools/local_mcp_server.py"]

    def _ensure_process(self) -> None:
        if self._process and self._process.poll() is None:
            return
        self._process = subprocess.Popen(
            self._command(),
            cwd=str(ROOT_DIR),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self._initialize()

    def _initialize(self) -> None:
        self._send_request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "iexa-mcp-bridge", "version": "1.0.0"},
            },
        )
        self._send_notification("notifications/initialized", {})

    def _write_message(self, payload: dict[str, Any]) -> None:
        assert self._process is not None and self._process.stdin is not None
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        header = f"Content-Length: {len(data)}\r\n\r\n".encode("utf-8")
        self._process.stdin.write(header)
        self._process.stdin.write(data)
        self._process.stdin.flush()

    def _read_message(self) -> dict[str, Any]:
        assert self._process is not None and self._process.stdout is not None
        headers: dict[str, str] = {}
        while True:
            line = self._process.stdout.readline()
            if not line:
                raise RuntimeError("MCP server closed stdout")
            if line in (b"\r\n", b"\n"):
                break
            decoded = line.decode("utf-8", errors="replace").strip()
            if ":" in decoded:
                key, value = decoded.split(":", 1)
                headers[key.strip().lower()] = value.strip()

        length = int(headers.get("content-length", "0"))
        if length <= 0:
            raise RuntimeError("Invalid MCP content-length")
        body = self._process.stdout.read(length)
        return json.loads(body.decode("utf-8"))

    def _send_request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self._ensure_process()
        assert self._process is not None
        with self._lock:
            message_id = self._next_id
            self._next_id += 1
            self._write_message(
                {
                    "jsonrpc": "2.0",
                    "id": message_id,
                    "method": method,
                    "params": params,
                }
            )
            while True:
                message = self._read_message()
                if message.get("id") == message_id:
                    return message

    def _send_notification(self, method: str, params: dict[str, Any]) -> None:
        self._ensure_process()
        with self._lock:
            self._write_message(
                {
                    "jsonrpc": "2.0",
                    "method": method,
                    "params": params,
                }
            )

    def list_tools(self) -> list[dict[str, Any]]:
        message = self._send_request("tools/list", {})
        result = message.get("result") or {}
        tools = result.get("tools") or []
        return tools if isinstance(tools, list) else []

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        message = self._send_request(
            "tools/call",
            {
                "name": name,
                "arguments": arguments,
            },
        )
        if "error" in message:
            raise RuntimeError(str(message["error"]))
        result = message.get("result")
        if not isinstance(result, dict):
            raise RuntimeError("Invalid MCP tool result")
        return result


CLIENT = StdioMCPClient()


def content_text(result: dict[str, Any]) -> str:
    content = result.get("content") or []
    if not isinstance(content, list):
        return ""
    texts: list[str] = []
    for item in content:
        if isinstance(item, dict) and item.get("type") == "text":
            texts.append(str(item.get("text", "")))
    return "\n".join([text for text in texts if text.strip()]).strip()


def rendered_log(tool_name: str, result: dict[str, Any]) -> str:
    structured = result.get("structuredContent")
    if isinstance(structured, dict):
        value = str(structured.get("renderedLog", "")).strip()
        if value:
            return value
    return f"执行 MCP 工具 `{tool_name}`"


class MCPBridgeHandler(BaseHTTPRequestHandler):
    server_version = "IEXA-MCP-Bridge/1.0"

    def do_GET(self) -> None:
        path = self.path.rstrip("/")
        if path in ("/healthz", "/health"):
            self._send_json(200, {"ok": True, "service": "mcp-bridge"})
            return
        if path in ("/v1/mcp/capabilities", "/mcp/capabilities"):
            if not self._authorize_if_needed():
                return
            tools = CLIENT.list_tools()
            self._send_json(200, {"ok": True, "rootDir": str(ROOT_DIR), "tools": tools})
            return
        self._send_json(404, {"error": {"message": "Not Found"}})

    def do_POST(self) -> None:
        path = self.path.rstrip("/")
        if path not in ("/v1/mcp/call_tool", "/mcp/call_tool", "/v1/mcp/list_tools", "/mcp/list_tools"):
            self._send_json(404, {"error": {"message": "Not Found"}})
            return
        if not self._authorize_if_needed():
            return
        payload = self._read_json_payload()
        if payload is None:
            return

        try:
            if path.endswith("/list_tools"):
                tools = CLIENT.list_tools()
                self._send_json(200, {"ok": True, "tools": tools})
                return

            tool_name = str(payload.get("tool", "")).strip()
            if not tool_name:
                self._send_json(400, {"error": {"message": "tool is required"}})
                return
            arguments = payload.get("arguments") or {}
            if not isinstance(arguments, dict):
                arguments = {}
            if "timeout" in payload and "timeout" not in arguments:
                arguments["timeout"] = payload["timeout"]

            result = CLIENT.call_tool(tool_name, arguments)
            self._send_json(
                200,
                {
                    "ok": True,
                    "tool": tool_name,
                    "renderedLog": rendered_log(tool_name, result),
                    "output": content_text(result),
                    "mcpResult": result,
                },
            )
        except Exception as error:
            self._send_json(500, {"error": {"message": f"mcp bridge failed: {error}"}})

    def _authorize_if_needed(self) -> bool:
        if not TOKEN:
            return True
        auth = self.headers.get("Authorization", "").strip()
        if auth == f"Bearer {TOKEN}":
            return True
        self._send_json(401, {"error": {"message": "Unauthorized"}})
        return False

    def _read_json_payload(self) -> dict[str, Any] | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": {"message": "Invalid Content-Length"}})
            return None
        if length <= 0:
            self._send_json(400, {"error": {"message": "Empty body"}})
            return None
        raw_body = self.rfile.read(length)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except Exception:
            self._send_json(400, {"error": {"message": "Invalid JSON"}})
            return None
        return payload if isinstance(payload, dict) else None

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), MCPBridgeHandler)
    print(f"[mcp-bridge] listening on http://{HOST}:{PORT}")
    print(f"[mcp-bridge] root dir: {ROOT_DIR}")
    server.serve_forever()


if __name__ == "__main__":
    main()
