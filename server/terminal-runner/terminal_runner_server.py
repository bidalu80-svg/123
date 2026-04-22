#!/usr/bin/env python3
"""
Minimal remote terminal runner with safety guardrails.

API:
  GET  /api/terminal/health
  POST /api/terminal/start
  GET  /api/terminal/jobs/<job_id>
  POST /api/terminal/jobs/<job_id>/cancel

Auth:
  - Header "X-Terminal-Token: <token>" OR
  - Header "Authorization: Bearer <token>"
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
import time
import traceback
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, Optional
from urllib.parse import urlparse


HOST = os.environ.get("TERMINAL_RUNNER_HOST", "127.0.0.1")
PORT = int(os.environ.get("TERMINAL_RUNNER_PORT", "8765"))
API_TOKEN = os.environ.get("TERMINAL_RUNNER_TOKEN", "").strip()
MAX_CONCURRENT_JOBS = max(1, int(os.environ.get("TERMINAL_RUNNER_MAX_CONCURRENT", "2")))
DEFAULT_TIMEOUT_SECONDS = max(1, int(os.environ.get("TERMINAL_RUNNER_DEFAULT_TIMEOUT", "45")))
MAX_TIMEOUT_SECONDS = max(DEFAULT_TIMEOUT_SECONDS, int(os.environ.get("TERMINAL_RUNNER_MAX_TIMEOUT", "180")))
DEFAULT_MAX_OUTPUT_BYTES = max(4_096, int(os.environ.get("TERMINAL_RUNNER_DEFAULT_MAX_OUTPUT", "120000")))
MAX_OUTPUT_BYTES_HARD = max(DEFAULT_MAX_OUTPUT_BYTES, int(os.environ.get("TERMINAL_RUNNER_MAX_OUTPUT_HARD", "500000")))
JOB_TTL_SECONDS = max(60, int(os.environ.get("TERMINAL_RUNNER_JOB_TTL_SECONDS", "1800")))


def _now() -> float:
    return time.time()


def _decode_bytes(raw: bytes) -> str:
    return raw.decode("utf-8", errors="replace")


@dataclass
class JobState:
    id: str
    command: str
    cwd: Optional[str]
    timeout_seconds: int
    max_output_bytes: int
    created_at: float = field(default_factory=_now)
    status: str = "queued"
    stdout: str = ""
    stderr: str = ""
    truncated_stdout: bool = False
    truncated_stderr: bool = False
    timed_out: bool = False
    exit_code: Optional[int] = None
    error: Optional[str] = None
    duration_ms: Optional[int] = None
    _lock: threading.Lock = field(default_factory=threading.Lock)
    _cancel_requested: bool = False
    _process: Optional[subprocess.Popen] = None

    def append_stdout(self, chunk: bytes) -> None:
        text = _decode_bytes(chunk)
        with self._lock:
            remain = self.max_output_bytes - len(self.stdout.encode("utf-8"))
            if remain <= 0:
                self.truncated_stdout = True
                return
            encoded = text.encode("utf-8")
            if len(encoded) > remain:
                self.stdout += _decode_bytes(encoded[:remain])
                self.truncated_stdout = True
            else:
                self.stdout += text

    def append_stderr(self, chunk: bytes) -> None:
        text = _decode_bytes(chunk)
        with self._lock:
            remain = self.max_output_bytes - len(self.stderr.encode("utf-8"))
            if remain <= 0:
                self.truncated_stderr = True
                return
            encoded = text.encode("utf-8")
            if len(encoded) > remain:
                self.stderr += _decode_bytes(encoded[:remain])
                self.truncated_stderr = True
            else:
                self.stderr += text

    def mark_running(self, process: subprocess.Popen) -> None:
        with self._lock:
            self._process = process
            self.status = "running"

    def request_cancel(self) -> bool:
        with self._lock:
            self._cancel_requested = True
            process = self._process
        if process is None:
            return False
        _kill_process_tree(process)
        return True

    def should_cancel(self) -> bool:
        with self._lock:
            return self._cancel_requested

    def snapshot(self) -> Dict[str, object]:
        with self._lock:
            return {
                "ok": True,
                "id": self.id,
                "status": self.status,
                "command": self.command,
                "cwd": self.cwd,
                "created_at": self.created_at,
                "stdout": self.stdout,
                "stderr": self.stderr,
                "truncated_stdout": self.truncated_stdout,
                "truncated_stderr": self.truncated_stderr,
                "timed_out": self.timed_out,
                "exit_code": self.exit_code,
                "error": self.error,
                "duration_ms": self.duration_ms,
            }


jobs: Dict[str, JobState] = {}
jobs_lock = threading.Lock()
job_slots = threading.BoundedSemaphore(MAX_CONCURRENT_JOBS)


def _kill_process_tree(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        else:
            os.killpg(process.pid, signal.SIGKILL)
    except Exception:
        try:
            process.kill()
        except Exception:
            pass


def _command_for_platform(raw_command: str) -> list[str]:
    if os.name == "nt":
        return [
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            raw_command,
        ]
    if os.path.exists("/bin/bash"):
        return ["/bin/bash", "-lc", raw_command]
    return ["/bin/sh", "-lc", raw_command]


def _stream_reader(pipe, append_fn) -> None:
    try:
        while True:
            chunk = pipe.read(4096)
            if not chunk:
                break
            append_fn(chunk)
    except Exception:
        pass


def _run_job(job: JobState) -> None:
    started_at = _now()
    try:
        popen_kwargs = {
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "cwd": job.cwd or None,
            "text": False,
        }
        if os.name != "nt":
            popen_kwargs["start_new_session"] = True

        process = subprocess.Popen(_command_for_platform(job.command), **popen_kwargs)
        job.mark_running(process)

        stdout_thread = threading.Thread(target=_stream_reader, args=(process.stdout, job.append_stdout), daemon=True)
        stderr_thread = threading.Thread(target=_stream_reader, args=(process.stderr, job.append_stderr), daemon=True)
        stdout_thread.start()
        stderr_thread.start()

        deadline = _now() + job.timeout_seconds
        cancelled = False
        while True:
            if process.poll() is not None:
                break
            if job.should_cancel():
                cancelled = True
                _kill_process_tree(process)
                break
            if _now() >= deadline:
                job.timed_out = True
                _kill_process_tree(process)
                break
            time.sleep(0.08)

        stdout_thread.join(timeout=1.0)
        stderr_thread.join(timeout=1.0)
        try:
            process.wait(timeout=1.0)
        except Exception:
            pass

        job.exit_code = process.returncode
        if cancelled:
            job.status = "cancelled"
        elif job.timed_out:
            job.status = "timed_out"
        else:
            job.status = "completed"
    except Exception as exc:
        job.status = "failed"
        job.error = str(exc)
        job.append_stderr(traceback.format_exc().encode("utf-8"))
    finally:
        job.duration_ms = int((_now() - started_at) * 1000)
        job_slots.release()


def _prune_jobs() -> None:
    now = _now()
    with jobs_lock:
        stale = [
            key
            for key, job in jobs.items()
            if job.status != "running" and now - job.created_at > JOB_TTL_SECONDS
        ]
        for key in stale:
            jobs.pop(key, None)


class TerminalRunnerHandler(BaseHTTPRequestHandler):
    server_version = "TerminalRunner/1.0"

    def log_message(self, format: str, *args) -> None:
        # Keep default-style logs; no-op to reduce noisy output.
        return

    def _write_json(self, status_code: int, payload: Dict[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _unauthorized(self) -> None:
        self._write_json(401, {"ok": False, "error": "unauthorized"})

    def _bad_request(self, message: str) -> None:
        self._write_json(400, {"ok": False, "error": message})

    def _not_found(self) -> None:
        self._write_json(404, {"ok": False, "error": "not_found"})

    def _is_authorized(self) -> bool:
        if not API_TOKEN:
            return True
        token = self.headers.get("X-Terminal-Token", "").strip()
        if token == API_TOKEN:
            return True
        auth = self.headers.get("Authorization", "").strip()
        if auth.lower().startswith("bearer "):
            return auth[7:].strip() == API_TOKEN
        return False

    def _parse_json_body(self) -> Dict[str, object]:
        raw_length = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_length)
        except ValueError:
            raise ValueError("invalid_content_length")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid_json: {exc}") from exc
        if not isinstance(payload, dict):
            raise ValueError("json_body_must_be_object")
        return payload

    def do_GET(self) -> None:
        _prune_jobs()
        path = urlparse(self.path).path
        if path == "/api/terminal/health":
            if not self._is_authorized():
                return self._unauthorized()
            with jobs_lock:
                running = sum(1 for job in jobs.values() if job.status == "running")
                queued = sum(1 for job in jobs.values() if job.status == "queued")
                total = len(jobs)
            return self._write_json(
                200,
                {
                    "ok": True,
                    "status": "up",
                    "running_jobs": running,
                    "queued_jobs": queued,
                    "known_jobs": total,
                    "max_concurrent_jobs": MAX_CONCURRENT_JOBS,
                    "default_timeout_seconds": DEFAULT_TIMEOUT_SECONDS,
                },
            )

        if path.startswith("/api/terminal/jobs/"):
            if not self._is_authorized():
                return self._unauthorized()
            parts = [segment for segment in path.split("/") if segment]
            if len(parts) != 4:
                return self._not_found()
            job_id = parts[-1]
            with jobs_lock:
                job = jobs.get(job_id)
            if job is None:
                return self._not_found()
            return self._write_json(200, job.snapshot())

        return self._not_found()

    def do_POST(self) -> None:
        _prune_jobs()
        path = urlparse(self.path).path

        if path == "/api/terminal/start":
            if not self._is_authorized():
                return self._unauthorized()
            try:
                payload = self._parse_json_body()
            except ValueError as exc:
                return self._bad_request(str(exc))

            command = str(payload.get("command", "")).strip()
            if not command:
                return self._bad_request("command_required")

            cwd_raw = str(payload.get("cwd", "")).strip()
            cwd: Optional[str] = cwd_raw if cwd_raw else None
            if cwd and not os.path.isdir(cwd):
                return self._bad_request("cwd_not_found")

            try:
                timeout_seconds = int(payload.get("timeout_seconds", DEFAULT_TIMEOUT_SECONDS))
            except Exception:
                return self._bad_request("invalid_timeout_seconds")
            timeout_seconds = max(1, min(timeout_seconds, MAX_TIMEOUT_SECONDS))

            try:
                max_output_bytes = int(payload.get("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES))
            except Exception:
                return self._bad_request("invalid_max_output_bytes")
            max_output_bytes = max(4_096, min(max_output_bytes, MAX_OUTPUT_BYTES_HARD))

            acquired = job_slots.acquire(blocking=False)
            if not acquired:
                return self._write_json(
                    429,
                    {
                        "ok": False,
                        "error": "too_many_running_jobs",
                        "max_concurrent_jobs": MAX_CONCURRENT_JOBS,
                    },
                )

            job_id = str(uuid.uuid4())
            job = JobState(
                id=job_id,
                command=command,
                cwd=cwd,
                timeout_seconds=timeout_seconds,
                max_output_bytes=max_output_bytes,
            )
            with jobs_lock:
                jobs[job_id] = job

            thread = threading.Thread(target=_run_job, args=(job,), daemon=True)
            thread.start()

            return self._write_json(
                200,
                {
                    "ok": True,
                    "job_id": job_id,
                    "status": job.status,
                },
            )

        if path.startswith("/api/terminal/jobs/") and path.endswith("/cancel"):
            if not self._is_authorized():
                return self._unauthorized()
            parts = [segment for segment in path.split("/") if segment]
            if len(parts) != 5:
                return self._not_found()
            job_id = parts[-2]
            with jobs_lock:
                job = jobs.get(job_id)
            if job is None:
                return self._not_found()

            cancelled = job.request_cancel()
            return self._write_json(
                200,
                {
                    "ok": True,
                    "cancel_requested": True,
                    "signal_sent": cancelled,
                    "job_id": job_id,
                },
            )

        return self._not_found()


def main() -> None:
    if not API_TOKEN:
        print("WARN: TERMINAL_RUNNER_TOKEN is empty. Service is currently open.", flush=True)
    print(
        f"Terminal runner listening on {HOST}:{PORT} | max_concurrent={MAX_CONCURRENT_JOBS} "
        f"| default_timeout={DEFAULT_TIMEOUT_SECONDS}s",
        flush=True,
    )
    httpd = ThreadingHTTPServer((HOST, PORT), TerminalRunnerHandler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
