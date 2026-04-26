import base64
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field


MAX_FILES = 180
MAX_SINGLE_FILE_BYTES = 1_200_000
MAX_TOTAL_BYTES = 7_500_000
MAX_TIMEOUT_SECONDS = 900

app = FastAPI(title="ChatApp Remote Python Runner", version="1.0.0")


class PayloadFile(BaseModel):
    path: str
    content_base64: str = Field(alias="content_base64")


class ExecuteRequest(BaseModel):
    mode: Literal["run_file", "unit_tests", "compile_all"]
    entry_path: str | None = None
    stdin: str | None = None
    timeout: int = 180
    files: list[PayloadFile]


def _normalize_token(value: str | None) -> str:
    return (value or "").strip()


def _require_auth(
    authorization: str | None,
    x_api_key: str | None,
    api_key: str | None,
) -> None:
    expected = _normalize_token(os.environ.get("REMOTE_PYTHON_API_KEY"))
    if not expected:
        return

    bearer = ""
    if authorization and authorization.lower().startswith("bearer "):
        bearer = authorization[7:].strip()

    provided = bearer or _normalize_token(x_api_key) or _normalize_token(api_key)
    if provided != expected:
        raise HTTPException(status_code=401, detail="Unauthorized")


def _safe_relative_path(raw: str) -> Path:
    normalized = raw.replace("\\", "/").strip().lstrip("/")
    path = Path(normalized)
    if not normalized or ".." in path.parts:
        raise HTTPException(status_code=400, detail=f"Invalid file path: {raw}")
    return path


def _write_project_files(root: Path, files: list[PayloadFile]) -> None:
    if not files:
        raise HTTPException(status_code=400, detail="No files provided")
    if len(files) > MAX_FILES:
        raise HTTPException(status_code=400, detail=f"Too many files: {len(files)}")

    total_bytes = 0
    for payload_file in files:
        relative_path = _safe_relative_path(payload_file.path)
        try:
            content = base64.b64decode(payload_file.content_base64.encode("utf-8"), validate=True)
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status_code=400, detail=f"Invalid base64 for {payload_file.path}") from exc

        if len(content) > MAX_SINGLE_FILE_BYTES:
            raise HTTPException(status_code=400, detail=f"File too large: {payload_file.path}")

        total_bytes += len(content)
        if total_bytes > MAX_TOTAL_BYTES:
            raise HTTPException(status_code=400, detail="Project payload too large")

        target = root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


def _venv_python(workspace: Path) -> Path:
    return workspace / ".venv" / "bin" / "python"


def _run_command(
    command: list[str],
    cwd: Path,
    timeout_seconds: int,
    stdin_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=str(cwd),
        input=stdin_text or "",
        text=True,
        capture_output=True,
        timeout=timeout_seconds,
        check=False,
    )


def _detect_install_command(workspace: Path) -> list[str] | None:
    if (workspace / "requirements.txt").is_file():
        return [str(_venv_python(workspace)), "-m", "pip", "install", "-r", "requirements.txt"]
    if (workspace / "pyproject.toml").is_file() or (workspace / "setup.py").is_file():
        return [str(_venv_python(workspace)), "-m", "pip", "install", "-e", "."]
    return None


def _prepare_environment(workspace: Path, timeout_seconds: int) -> str:
    install_log: list[str] = []

    create_venv = _run_command([sys.executable, "-m", "venv", ".venv"], cwd=workspace, timeout_seconds=timeout_seconds)
    if create_venv.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to create virtualenv:\n{create_venv.stdout}\n{create_venv.stderr}",
        )

    pip_upgrade = _run_command(
        [str(_venv_python(workspace)), "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"],
        cwd=workspace,
        timeout_seconds=timeout_seconds,
    )
    install_log.append(pip_upgrade.stdout + pip_upgrade.stderr)
    if pip_upgrade.returncode != 0:
        raise HTTPException(status_code=500, detail=f"Failed to bootstrap pip:\n{pip_upgrade.stdout}\n{pip_upgrade.stderr}")

    install_command = _detect_install_command(workspace)
    if install_command:
        install_result = _run_command(install_command, cwd=workspace, timeout_seconds=timeout_seconds)
        install_log.append(install_result.stdout + install_result.stderr)
        if install_result.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail=f"Dependency install failed:\n{install_result.stdout}\n{install_result.stderr}",
            )

    return "\n".join(part.strip() for part in install_log if part.strip())


def _execute_mode(request: ExecuteRequest, workspace: Path) -> tuple[list[str], str | None]:
    python = str(_venv_python(workspace))

    if request.mode == "run_file":
        if not request.entry_path:
            raise HTTPException(status_code=400, detail="entry_path is required for run_file")
        entry = _safe_relative_path(request.entry_path)
        if not (workspace / entry).is_file():
            raise HTTPException(status_code=400, detail=f"Entry file not found: {request.entry_path}")
        return [python, str(entry)], request.stdin

    if request.mode == "unit_tests":
        if (workspace / "pytest.ini").exists() or (workspace / "conftest.py").exists() or (workspace / "tests").exists():
            return [python, "-m", "pytest", "-q"], None
        return [python, "-m", "unittest", "discover", "-v"], None

    return [python, "-m", "compileall", "."], None


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "python_version": sys.version,
        "runner": "huggingface-space",
    }


@app.post("/v1/python/execute")
def execute_python(
    request: ExecuteRequest,
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None),
    api_key: str | None = Header(default=None, alias="api-key"),
) -> dict:
    _require_auth(authorization, x_api_key, api_key)

    timeout_seconds = max(10, min(request.timeout, MAX_TIMEOUT_SECONDS))
    temp_root = Path(tempfile.mkdtemp(prefix="chatapp-remote-python-"))
    workspace = temp_root / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)

    try:
        _write_project_files(workspace, request.files)
        install_log = _prepare_environment(workspace, timeout_seconds)
        command, stdin_text = _execute_mode(request, workspace)
        result = _run_command(command, cwd=workspace, timeout_seconds=timeout_seconds, stdin_text=stdin_text)

        combined_output = "\n".join(
            part for part in [result.stdout.strip(), result.stderr.strip()] if part
        ).strip()

        return {
            "ok": result.returncode == 0,
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "combined_output": combined_output or "执行完成（无输出）",
            "install_log": install_log,
            "used_remote": True,
        }
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=504, detail=f"Execution timed out after {timeout_seconds}s") from exc
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)
