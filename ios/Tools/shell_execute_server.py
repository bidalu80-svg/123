#!/usr/bin/env python3
"""
Session/PTTY shell server for IEXA.

Routes:
- POST /v1/shell/execute
- POST /shell/execute
- POST /v1/shell/session/start
- POST /shell/session/start
- POST /v1/shell/session/input
- POST /shell/session/input
- POST /v1/shell/session/signal
- POST /shell/session/signal
- POST /v1/shell/session/stop
- POST /shell/session/stop
- GET  /v1/shell/session/poll?sessionId=...
- GET  /shell/session/poll?sessionId=...
- GET  /v1/shell/capabilities
- GET  /shell/capabilities
- GET  /healthz
"""

from __future__ import annotations

import errno
import json
import os
import pty
import select
import shutil
import signal
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict
from urllib.parse import parse_qs, urlparse


HOST = os.getenv("SHELL_EXEC_HOST", "0.0.0.0")
PORT = int(os.getenv("SHELL_EXEC_PORT", "8787"))
TOKEN = os.getenv("SHELL_EXEC_TOKEN", "").strip()
MAX_COMMAND_LENGTH = int(os.getenv("SHELL_EXEC_MAX_COMMAND_LENGTH", "8000"))
DEFAULT_TIMEOUT = int(os.getenv("SHELL_EXEC_DEFAULT_TIMEOUT", "90"))
MAX_TIMEOUT = int(os.getenv("SHELL_EXEC_MAX_TIMEOUT", "300"))
ROOT_DIR = Path(os.getenv("SHELL_EXEC_ROOT", os.getcwd())).resolve()
SESSION_IDLE_TIMEOUT = int(os.getenv("SHELL_SESSION_IDLE_TIMEOUT", "3600"))
SESSION_MAX_BUFFER = int(os.getenv("SHELL_SESSION_MAX_BUFFER", "200000"))
DEFAULT_SESSION_SHELL = os.getenv("SHELL_SESSION_SHELL", "bash").strip() or "bash"
FINAL_CWD_MARKER = "__IEXA_FINAL_CWD__="

EXECUTE_ROUTES = {"/v1/shell/execute", "/shell/execute"}
SESSION_START_ROUTES = {"/v1/shell/session/start", "/shell/session/start"}
SESSION_INPUT_ROUTES = {"/v1/shell/session/input", "/shell/session/input"}
SESSION_SIGNAL_ROUTES = {"/v1/shell/session/signal", "/shell/session/signal"}
SESSION_STOP_ROUTES = {"/v1/shell/session/stop", "/shell/session/stop"}
SESSION_POLL_ROUTES = {"/v1/shell/session/poll", "/shell/session/poll"}
CAPABILITIES_ROUTES = {"/v1/shell/capabilities", "/shell/capabilities"}

SHELL_CANDIDATES = ["bash", "sh", "zsh", "fish", "pwsh"]
RUNTIME_CANDIDATES = {
    "python": ["python3", "python"],
    "node": ["node"],
    "npm": ["npm"],
    "pnpm": ["pnpm"],
    "yarn": ["yarn"],
    "bun": ["bun"],
    "deno": ["deno"],
    "php": ["php"],
    "ruby": ["ruby"],
    "go": ["go"],
    "java": ["java"],
    "javac": ["javac"],
    "cargo": ["cargo"],
    "rustc": ["rustc"],
    "swift": ["swift"],
    "gcc": ["gcc"],
    "g++": ["g++"],
    "clang": ["clang"],
    "cmake": ["cmake"],
    "make": ["make"],
    "git": ["git"],
    "docker": ["docker"],
}


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


def trailing_partial_marker(text: str) -> str:
    max_check = min(len(text), len(FINAL_CWD_MARKER) - 1)
    for length in range(max_check, 0, -1):
        suffix = text[-length:]
        if FINAL_CWD_MARKER.startswith(suffix):
            return suffix
    return ""


def discover_capabilities() -> Dict[str, Any]:
    shells: list[dict[str, str]] = []
    for candidate in SHELL_CANDIDATES:
        resolved = shutil.which(candidate)
        if resolved:
            shells.append({"name": candidate, "path": resolved})

    runtimes: dict[str, dict[str, str]] = {}
    for runtime, commands in RUNTIME_CANDIDATES.items():
        for command in commands:
            resolved = shutil.which(command)
            if resolved:
                runtimes[runtime] = {"command": command, "path": resolved}
                break

    return {
        "ok": True,
        "rootDir": str(ROOT_DIR),
        "defaultShell": DEFAULT_SESSION_SHELL,
        "shells": shells,
        "runtimes": runtimes,
    }


class PtyShellSession:
    def __init__(self, cwd: Path, shell_name: str):
        self.session_id = uuid.uuid4().hex
        self.cwd = str(cwd)
        self.shell_name = shell_name
        self.created_at = time.time()
        self.last_touched = self.created_at
        self.exit_code: int | None = None
        self.closed = False
        self._pending_output = ""
        self._marker_carry = ""
        self._lock = threading.Lock()

        master_fd, slave_fd = pty.openpty()
        self.master_fd = master_fd
        shell_path = shutil.which(shell_name) or shutil.which("bash")
        if not shell_path:
            os.close(master_fd)
            os.close(slave_fd)
            raise RuntimeError("bash not found on server")

        env = os.environ.copy()
        env["TERM"] = "xterm-256color"
        env["PS1"] = "root@minis:\\w# "
        env["PROMPT_COMMAND"] = f'printf "{FINAL_CWD_MARKER}%s\\n" "$PWD"'

        self.process = subprocess.Popen(
            [shell_path, "--noprofile", "--norc", "-i"],
            cwd=str(cwd),
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=env,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave_fd)
        os.set_blocking(self.master_fd, False)

        self._reader_thread = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader_thread.start()

    def _reader_loop(self) -> None:
        try:
            while True:
                if self.process.poll() is not None:
                    self._drain_available_output()
                    break

                readable, _, _ = select.select([self.master_fd], [], [], 0.12)
                if readable:
                    self._drain_available_output()
        finally:
            with self._lock:
                self.closed = True
                self.exit_code = self.process.poll()
            try:
                os.close(self.master_fd)
            except OSError:
                pass

    def _drain_available_output(self) -> None:
        while True:
            try:
                chunk = os.read(self.master_fd, 4096)
            except BlockingIOError:
                return
            except OSError as error:
                if error.errno in (errno.EIO, errno.EBADF):
                    return
                raise

            if not chunk:
                return

            text = chunk.decode("utf-8", errors="replace")
            self._consume_terminal_text(text)

    def _consume_terminal_text(self, text: str) -> None:
        normalized = text.replace("\r\n", "\n").replace("\r", "")

        with self._lock:
            buffer = self._marker_carry + normalized
            self._marker_carry = ""
            visible_parts: list[str] = []
            cursor = 0

            while True:
                marker_index = buffer.find(FINAL_CWD_MARKER, cursor)
                if marker_index < 0:
                    break

                visible_parts.append(buffer[cursor:marker_index])
                line_end = buffer.find("\n", marker_index)
                if line_end < 0:
                    self._pending_output += "".join(visible_parts)
                    self._marker_carry = buffer[marker_index:]
                    self._trim_pending_output_locked()
                    return

                cwd_candidate = buffer[marker_index + len(FINAL_CWD_MARKER):line_end].strip()
                if cwd_candidate:
                    self.cwd = cwd_candidate
                cursor = line_end + 1

            tail = buffer[cursor:]
            partial = trailing_partial_marker(tail)
            if partial:
                visible_tail = tail[:-len(partial)]
                self._marker_carry = partial
            else:
                visible_tail = tail

            self._pending_output += "".join(visible_parts) + visible_tail
            self._trim_pending_output_locked()

    def _trim_pending_output_locked(self) -> None:
        if len(self._pending_output) > SESSION_MAX_BUFFER:
            self._pending_output = self._pending_output[-SESSION_MAX_BUFFER:]

    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            output = self._pending_output
            self._pending_output = ""
            cwd = self.cwd
            exit_code = self.exit_code
            closed = self.closed
            self.last_touched = time.time()

        return {
            "sessionId": self.session_id,
            "output": output,
            "cwd": cwd,
            "isRunning": not closed,
            "exitCode": exit_code,
            "shell": self.shell_name,
        }

    def send_input(self, input_text: str, append_newline: bool = True) -> None:
        payload = input_text + ("\n" if append_newline else "")
        os.write(self.master_fd, payload.encode("utf-8", errors="ignore"))
        with self._lock:
            self.last_touched = time.time()

    def send_signal(self, signal_name: str) -> None:
        normalized = signal_name.strip().lower()
        if normalized in {"interrupt", "ctrl_c", "sigint"}:
            os.write(self.master_fd, b"\x03")
        elif normalized in {"eof", "ctrl_d"}:
            os.write(self.master_fd, b"\x04")
        elif normalized in {"terminate", "term", "sigterm"}:
            self.stop()
            return
        else:
            raise ValueError("unsupported signal")

        with self._lock:
            self.last_touched = time.time()

    def stop(self) -> Dict[str, Any]:
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except OSError:
            pass

        deadline = time.time() + 2.0
        while time.time() < deadline:
            if self.process.poll() is not None:
                break
            time.sleep(0.05)

        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except OSError:
                pass

        with self._lock:
            self.closed = True
            self.exit_code = self.process.poll()
            self.last_touched = time.time()

        return self.snapshot()

    def should_cleanup(self) -> bool:
        with self._lock:
            is_running = not self.closed
            last_touched = self.last_touched
        idle_seconds = time.time() - last_touched
        if idle_seconds > SESSION_IDLE_TIMEOUT:
            return True
        return (not is_running) and idle_seconds > 20


class ShellSessionManager:
    def __init__(self) -> None:
        self._sessions: dict[str, PtyShellSession] = {}
        self._lock = threading.Lock()

    def create(self, cwd: Path, shell_name: str) -> PtyShellSession:
        self.cleanup()
        session = PtyShellSession(cwd, shell_name)
        with self._lock:
            self._sessions[session.session_id] = session
        return session

    def get(self, session_id: str) -> PtyShellSession | None:
        with self._lock:
            return self._sessions.get(session_id)

    def remove(self, session_id: str) -> PtyShellSession | None:
        with self._lock:
            return self._sessions.pop(session_id, None)

    def cleanup(self) -> None:
        with self._lock:
            stale_ids = [session_id for session_id, session in self._sessions.items() if session.should_cleanup()]
        for session_id in stale_ids:
            session = self.remove(session_id)
            if session:
                session.stop()


SESSION_MANAGER = ShellSessionManager()


class ShellExecuteHandler(BaseHTTPRequestHandler):
    server_version = "IEXA-ShellExecute/2.0"

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path in ("/healthz", "/health"):
            self._send_json(200, {"ok": True, "service": "shell-execute"})
            return

        if path in CAPABILITIES_ROUTES:
            if not self._authorize_if_needed():
                return
            self._send_json(200, discover_capabilities())
            return

        if path in SESSION_POLL_ROUTES:
            if not self._authorize_if_needed():
                return
            self._handle_session_poll(parsed)
            return

        self._send_json(404, {"error": {"message": "Not Found"}})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path not in EXECUTE_ROUTES | SESSION_START_ROUTES | SESSION_INPUT_ROUTES | SESSION_SIGNAL_ROUTES | SESSION_STOP_ROUTES:
            self._send_json(404, {"error": {"message": "Not Found"}})
            return

        if not self._authorize_if_needed():
            return

        payload = self._read_json_payload()
        if payload is None:
            return

        if path in EXECUTE_ROUTES:
            self._handle_execute(payload)
            return
        if path in SESSION_START_ROUTES:
            self._handle_session_start(payload)
            return
        if path in SESSION_INPUT_ROUTES:
            self._handle_session_input(payload)
            return
        if path in SESSION_SIGNAL_ROUTES:
            self._handle_session_signal(payload)
            return
        if path in SESSION_STOP_ROUTES:
            self._handle_session_stop(payload)
            return

        self._send_json(404, {"error": {"message": "Not Found"}})

    def _authorize_if_needed(self) -> bool:
        if not TOKEN:
            return True
        auth = self.headers.get("Authorization", "").strip()
        if auth == f"Bearer {TOKEN}":
            return True
        self._send_json(401, {"error": {"message": "Unauthorized"}})
        return False

    def _read_json_payload(self) -> Dict[str, Any] | None:
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

        if not isinstance(payload, dict):
            self._send_json(400, {"error": {"message": "Invalid payload"}})
            return None

        return payload

    def _handle_execute(self, payload: Dict[str, Any]) -> None:
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
            completed = subprocess.run(
                build_shell_command(command),
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

    def _handle_session_start(self, payload: Dict[str, Any]) -> None:
        try:
            cwd = resolve_working_directory(payload.get("cwd", ""))
        except ValueError as error:
            self._send_json(400, {"error": {"message": str(error)}})
            return

        requested_shell = str(payload.get("shell", DEFAULT_SESSION_SHELL)).strip() or DEFAULT_SESSION_SHELL

        try:
            session = SESSION_MANAGER.create(cwd, requested_shell)
        except Exception as error:
            self._send_json(500, {"error": {"message": f"session start failed: {error}"}})
            return

        time.sleep(0.12)
        self._send_json(200, session.snapshot())

    def _handle_session_input(self, payload: Dict[str, Any]) -> None:
        session = self._require_session(payload.get("sessionId"))
        if not session:
            return

        input_text = str(payload.get("input", ""))
        append_newline = bool(payload.get("appendNewline", True))
        try:
            session.send_input(input_text, append_newline=append_newline)
        except Exception as error:
            self._send_json(500, {"error": {"message": f"session input failed: {error}"}})
            return

        wait_ms = max(0, min(int(payload.get("waitMs", 60)), 250))
        if wait_ms > 0:
            time.sleep(wait_ms / 1000)
        self._send_json(200, session.snapshot())

    def _handle_session_signal(self, payload: Dict[str, Any]) -> None:
        session = self._require_session(payload.get("sessionId"))
        if not session:
            return

        signal_name = str(payload.get("signal", "interrupt")).strip()
        try:
            session.send_signal(signal_name)
        except ValueError as error:
            self._send_json(400, {"error": {"message": str(error)}})
            return
        except Exception as error:
            self._send_json(500, {"error": {"message": f"session signal failed: {error}"}})
            return

        time.sleep(0.08)
        self._send_json(200, session.snapshot())

    def _handle_session_stop(self, payload: Dict[str, Any]) -> None:
        session_id = str(payload.get("sessionId", "")).strip()
        if not session_id:
            self._send_json(400, {"error": {"message": "sessionId is required"}})
            return

        session = SESSION_MANAGER.remove(session_id)
        if not session:
            self._send_json(404, {"error": {"message": "session not found"}})
            return

        try:
            self._send_json(200, session.stop())
        except Exception as error:
            self._send_json(500, {"error": {"message": f"session stop failed: {error}"}})

    def _handle_session_poll(self, parsed) -> None:
        query = parse_qs(parsed.query)
        session_id = (
            query.get("sessionId", [""])[0]
            or query.get("session_id", [""])[0]
            or query.get("id", [""])[0]
        ).strip()

        session = self._require_session(session_id)
        if not session:
            return
        self._send_json(200, session.snapshot())

    def _require_session(self, raw_session_id: Any) -> PtyShellSession | None:
        session_id = str(raw_session_id or "").strip()
        if not session_id:
            self._send_json(400, {"error": {"message": "sessionId is required"}})
            return None

        session = SESSION_MANAGER.get(session_id)
        if not session:
            self._send_json(404, {"error": {"message": "session not found"}})
            return None
        return session

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {self.address_string()} {fmt % args}")

    def _send_json(self, status: int, payload: Dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


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
