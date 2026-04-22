# Remote Terminal Runner (Server Side)

This service executes shell commands on your server for the iOS app.

## 1) Features

- Command execution via HTTP API
- Per-job timeout
- Per-stream output cap (`stdout` / `stderr`)
- Concurrent job limit
- Job polling
- Job cancellation
- Token auth

## 2) API

1. `GET /api/terminal/health`
2. `POST /api/terminal/start`
3. `GET /api/terminal/jobs/<job_id>`
4. `POST /api/terminal/jobs/<job_id>/cancel`

Auth headers:

- `X-Terminal-Token: <token>` or
- `Authorization: Bearer <token>`

## 3) Run

```bash
export TERMINAL_RUNNER_HOST=127.0.0.1
export TERMINAL_RUNNER_PORT=8765
export TERMINAL_RUNNER_TOKEN='replace-with-strong-token'
export TERMINAL_RUNNER_MAX_CONCURRENT=2
export TERMINAL_RUNNER_DEFAULT_TIMEOUT=45
export TERMINAL_RUNNER_MAX_TIMEOUT=180
export TERMINAL_RUNNER_DEFAULT_MAX_OUTPUT=120000
export TERMINAL_RUNNER_MAX_OUTPUT_HARD=500000
python3 terminal_runner_server.py
```

## 4) Nginx reverse proxy (recommended)

Example (`/etc/nginx/conf.d/chatapp-terminal.conf`):

```nginx
server {
    listen 80;
    server_name _;

    location /terminal/ {
        proxy_pass http://127.0.0.1:8765/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Then your app can use base URL like:

`http://<your-server-ip>/terminal`

## 5) Quick test with curl

Start:

```bash
curl -s -X POST "http://127.0.0.1:8765/api/terminal/start" \
  -H "Content-Type: application/json" \
  -H "X-Terminal-Token: replace-with-strong-token" \
  -d '{"command":"python3 --version","timeout_seconds":20,"max_output_bytes":120000}'
```

Fetch:

```bash
curl -s "http://127.0.0.1:8765/api/terminal/jobs/<job_id>" \
  -H "X-Terminal-Token: replace-with-strong-token"
```

Cancel:

```bash
curl -s -X POST "http://127.0.0.1:8765/api/terminal/jobs/<job_id>/cancel" \
  -H "X-Terminal-Token: replace-with-strong-token"
```

## 6) Security notes

- Do not expose this service without token auth.
- Prefer binding to `127.0.0.1` and exposing only through Nginx.
- Consider running in a dedicated low-privilege user and/or container.
- Keep `MAX_CONCURRENT` low on shared servers.

