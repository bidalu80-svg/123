#!/usr/bin/env python3
"""
Minimal shell execution HTTP service for IEXA remote terminal run.

Routes:
- POST /v1/shell/execute
- POST /shell/execute
- GET  /healthz

Request JSON:
{
  "command": "cmake -S . -B build && cmake --build build",
  "cwd": "latest",
  "timeout": 90
}
"""

import json
import os
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict


HOST = os.getenv("SHELL_EXEC_HOST", "0.0.0.0")
PORT = int(os.getenv("SHELL_EXEC_PORT", "8787"))
TOKEN = os.getenv("SHELL_EXEC_TOKEN", "").strip()
MAX_COMMAND_LENGTH = int(os.getenv("SHELL_EXEC_MAX_COMMAND_LENGTH", "8000"))
DEFAULT_TIMEOUT = int(os.getenv("SHELL_EXEC_DEFAULT_TIMEOUT", "90"))
MAX_TIMEOUT = int(os.getenv("SHELL_EXEC_MAX_TIMEOUT", "300"))
ROOT_DIR = Path(os.getenv("SHELL_EXEC_ROOT", os.getcwd())).resolve()
FINAL_CWD_MARKER = "__IEXA_FINAL_CWD__="


def clamp_timeout(raw_timeout: Any) -> int:
    try:
        value = int(float(raw_timeout))
    except (TypeError, ValueError):
        value = DEFAULT_TIMEOUT
    return max(5, min(value, MAX_TIMEOUT))


def resolve_working_directory(raw_cwd: Any) -> Path:
    if not isinstance(raw_cwd, str) or not raw_cwd.strip():
        return ROOT_DIR

    candidate = Path(raw_cwd.strip())
    if not candidate.is_absolute():
        candidate = ROOT_DIR / candidate
    candidate = candidate.resolve()

    if candidate != ROOT_DIR and ROOT_DIR not in candidate.parents:
        raise ValueError("cwd out of allowed root")
    if not candidate.exists() or not candidate.is_dir():
        raise ValueError("cwd not found")
    return candidate


class ShellExecuteHandler(BaseHTTPRequestHandler):
    server_version = "IEXA-ShellExecute/1.0"

    def do_GET(self) -> None:
        if self.path.rstrip("/") in ("/healthz", "/health"):
            self._send_json(200, {"ok": True, "service": "shell-execute"})
            return
        self._send_json(404, {"error": {"message": "Not Found"}})

    def do_POST(self) -> None:
        if self.path.rstrip("/") not in ("/v1/shell/execute", "/shell/execute"):
            self._send_json(404, {"error": {"message": "Not Found"}})
            return

        if TOKEN:
            auth = self.headers.get("Authorization", "").strip()
            if auth != f"Bearer {TOKEN}":
                self._send_json(401, {"error": {"message": "Unauthorized"}})
                return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": {"message": "Invalid Content-Length"}})
            return

        if length <= 0:
            self._send_json(400, {"error": {"message": "Empty body"}})
            return

        raw_body = self.rfile.read(length)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except Exception:
            self._send_json(400, {"error": {"message": "Invalid JSON"}})
            return

        if not isinstance(payload, dict):
            self._send_json(400, {"error": {"message": "Invalid payload"}})
            return

        command = str(payload.get("command", "")).strip()
        if not command:
            self._send_json(400, {"error": {"message": "command is required"}})
            return
        if len(command) > MAX_COMMAND_LENGTH:
            self._send_json(400, {"error": {"message": "command too long"}})
            return

        try:
            cwd = resolve_working_directory(payload.get("cwd", ""))
        except ValueError as error:
            self._send_json(400, {"error": {"message": str(error)}})
            return

        timeout = clamp_timeout(payload.get("timeout", DEFAULT_TIMEOUT))

        started = time.time()
        try:
            shell_argv = build_shell_command(command)
            completed = subprocess.run(
                shell_argv,
                cwd=str(cwd),
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            duration_ms = int((time.time() - started) * 1000)
            stdout_raw = completed.stdout or ""
            stderr = completed.stderr or ""
            stdout, final_cwd = split_final_cwd(stdout_raw)
            output = stdout.strip()
            if stderr.strip():
                output = f"{output}\n\n[stderr]\n{stderr}".strip()

            self._send_json(
                200,
                {
                    "success": completed.returncode == 0,
                    "exitCode": completed.returncode,
                    "stdout": stdout,
                    "stderr": stderr,
                    "output": output,
                    "durationMs": duration_ms,
                    "cwd": str(cwd),
                    "finalCwd": final_cwd or str(cwd),
                },
            )
        except subprocess.TimeoutExpired as error:
            duration_ms = int((time.time() - started) * 1000)
            stdout_raw = (error.stdout or "") if isinstance(error.stdout, str) else ""
            stderr = (error.stderr or "") if isinstance(error.stderr, str) else ""
            stdout, final_cwd = split_final_cwd(stdout_raw)
            merged = f"{stdout}\n\n[stderr]\n{stderr}".strip()
            if not merged:
                merged = f"Command timed out after {timeout}s."
            self._send_json(
                200,
                {
                    "success": False,
                    "exitCode": 124,
                    "stdout": stdout,
                    "stderr": stderr,
                    "output": merged,
                    "durationMs": duration_ms,
                    "cwd": str(cwd),
                    "finalCwd": final_cwd or str(cwd),
                },
            )
        except Exception as error:
            self._send_json(500, {"error": {"message": f"exec failed: {error}"}})

    def log_message(self, fmt: str, *args: Any) -> None:
        # Keep logs concise for server terminal usage.
        print(f"[{self.log_date_time_string()}] {self.address_string()} {fmt % args}")

    def _send_json(self, status: int, payload: Dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def build_shell_command(command: str) -> list[str]:
    shell = shutil.which("bash") or shutil.which("sh")
    if not shell:
        raise RuntimeError("bash/sh not found on server")

    wrapper = (
        f"{command}\n"
        "__iexa_status=$?\n"
        f"printf '\\n{FINAL_CWD_MARKER}%s\\n' \"$PWD\"\n"
        "exit $__iexa_status"
    )
    return [shell, "-lc", wrapper]


def split_final_cwd(stdout: str) -> tuple[str, str | None]:
    if FINAL_CWD_MARKER not in stdout:
        return stdout, None

    lines = stdout.splitlines()
    final_cwd = None
    kept_lines: list[str] = []

    for line in lines:
        if line.startswith(FINAL_CWD_MARKER):
            candidate = line[len(FINAL_CWD_MARKER):].strip()
            if candidate:
                final_cwd = candidate
            continue
        kept_lines.append(line)

    rebuilt = "\n".join(kept_lines)
    if stdout.endswith("\n") and rebuilt and not rebuilt.endswith("\n"):
        rebuilt += "\n"
    return rebuilt, final_cwd


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), ShellExecuteHandler)
    print(f"[shell-execute] listening on http://{HOST}:{PORT}")
    print(f"[shell-execute] root dir: {ROOT_DIR}")
    if TOKEN:
        print("[shell-execute] auth: enabled (Bearer token required)")
    else:
        print("[shell-execute] auth: disabled (set SHELL_EXEC_TOKEN to enable)")
    server.serve_forever()


if __name__ == "__main__":
    main()
