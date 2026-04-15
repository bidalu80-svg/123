interface Env {
  DB: D1Database;
  AUTH_PEPPER: string;
  SMS_PROVIDER?: string;
  TWILIO_ACCOUNT_SID?: string;
  TWILIO_AUTH_TOKEN?: string;
  TWILIO_FROM_NUMBER?: string;
}

const encoder = new TextEncoder();
const ACCOUNT_REGEX = /^[^\s]{2,64}$/;
const PASSWORD_REGEX = /^.{6,64}$/;

const ADMIN_USERNAME = "blank";
const ADMIN_PASSWORD = "888888";

const LOGIN_FAIL_LOCK_WINDOW_MS = 15 * 60 * 1000;
const LOGIN_FAIL_LIMIT = 5;
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const PASSWORD_PBKDF2_ITERATIONS = 100_000;

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type,authorization",
    },
  });
}

function errorResponse(message: string, status = 400): Response {
  return json({ ok: false, message }, status);
}

function ok(data: Record<string, unknown> = {}): Response {
  return json({ ok: true, ...data });
}

function nowISO(): string {
  return new Date().toISOString();
}

function addMillisISO(ms: number): string {
  return new Date(Date.now() + ms).toISOString();
}

function normalizeAccount(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function isAccountValid(value: string): boolean {
  return ACCOUNT_REGEX.test(value);
}

function isPasswordValid(value: string): boolean {
  return PASSWORD_REGEX.test(value);
}

function randomToken(bytes = 32): string {
  const raw = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(raw)
    .map((x) => x.toString(16).padStart(2, "0"))
    .join("");
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return Array.from(new Uint8Array(digest))
    .map((x) => x.toString(16).padStart(2, "0"))
    .join("");
}

async function pbkdf2Hex(password: string, salt: string, iterations = PASSWORD_PBKDF2_ITERATIONS): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    {
      name: "PBKDF2",
      hash: "SHA-256",
      iterations,
      salt: encoder.encode(salt),
    },
    key,
    256
  );

  return Array.from(new Uint8Array(bits))
    .map((x) => x.toString(16).padStart(2, "0"))
    .join("");
}

async function parseJSON(request: Request): Promise<Record<string, unknown>> {
  try {
    const value = await request.json();
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return value as Record<string, unknown>;
    }
    return {};
  } catch {
    return {};
  }
}

function getClientIP(request: Request): string {
  return request.headers.get("CF-Connecting-IP")?.trim() || "unknown";
}

function extractBearerToken(request: Request): string {
  const value = request.headers.get("Authorization") || "";
  const [scheme, token] = value.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token) return "";
  return token.trim();
}

async function createSession(
  env: Env,
  user: { id: string; account: string }
): Promise<{ token: string; expiresAt: string; user: { id: string; phone: string; createdAt: string | null } }> {
  const token = randomToken(48);
  const tokenHash = await sha256Hex(`${token}:${env.AUTH_PEPPER}`);
  const id = crypto.randomUUID();
  const createdAt = nowISO();
  const expiresAt = addMillisISO(SESSION_TTL_MS);

  await env.DB.prepare(
    `INSERT INTO auth_sessions (id, user_id, token_hash, created_at, expires_at, revoked_at)
     VALUES (?, ?, ?, ?, ?, NULL)`
  )
    .bind(id, user.id, tokenHash, createdAt, expiresAt)
    .run();

  return {
    token,
    expiresAt,
    user: {
      id: user.id,
      phone: user.account,
      createdAt: null,
    },
  };
}

async function recordLoginAttempt(env: Env, account: string, ip: string, success: boolean): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO auth_attempts (id, phone, action, ip, success, created_at)
     VALUES (?, ?, 'login', ?, ?, ?)`
  )
    .bind(crypto.randomUUID(), account, ip, success ? 1 : 0, nowISO())
    .run();
}

async function isLoginLocked(env: Env, account: string): Promise<boolean> {
  const since = new Date(Date.now() - LOGIN_FAIL_LOCK_WINDOW_MS).toISOString();
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS total
     FROM auth_attempts
     WHERE phone = ?
       AND action = 'login'
       AND success = 0
       AND created_at >= ?`
  )
    .bind(account, since)
    .first<{ total: number | string }>();

  const total = Number(row?.total || 0);
  return total >= LOGIN_FAIL_LIMIT;
}

async function ensureAdminUser(env: Env): Promise<{ id: string; createdAt: string }> {
  const existing = await env.DB.prepare(
    `SELECT id, created_at
     FROM users
     WHERE phone = ?
     LIMIT 1`
  )
    .bind(ADMIN_USERNAME)
    .first<{ id: string; created_at: string }>();

  if (existing) {
    return {
      id: existing.id,
      createdAt: existing.created_at,
    };
  }

  const userId = "admin-blank";
  const createdAt = nowISO();
  const salt = randomToken(16);
  const hash = await pbkdf2Hex(ADMIN_PASSWORD, salt, PASSWORD_PBKDF2_ITERATIONS);

  await env.DB.prepare(
    `INSERT INTO users (id, phone, password_hash, password_salt, password_iterations, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`
  )
    .bind(userId, ADMIN_USERNAME, hash, salt, PASSWORD_PBKDF2_ITERATIONS, createdAt)
    .run();

  return { id: userId, createdAt };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET,POST,OPTIONS",
          "access-control-allow-headers": "content-type,authorization",
        },
      });
    }

    if (!env.AUTH_PEPPER) {
      return errorResponse("服务端缺少 AUTH_PEPPER 配置。", 500);
    }

    const url = new URL(request.url);
    const path = url.pathname;

    try {
      if (request.method === "GET" && path === "/auth/health") {
        return ok({
          message: "auth worker is healthy",
          config: {
            smsEnabled: false,
            passwordIterations: PASSWORD_PBKDF2_ITERATIONS,
            adminAccount: ADMIN_USERNAME,
          },
        });
      }

      if (request.method === "POST" && path === "/auth/send-code") {
        return errorResponse("当前版本已关闭短信验证码注册。", 410);
      }

      if (request.method === "POST" && path === "/auth/register") {
        const body = await parseJSON(request);
        const account = normalizeAccount(body.phone ?? body.account);
        const password = typeof body.password === "string" ? body.password : "";

        if (!isAccountValid(account)) return errorResponse("账号格式无效。");
        if (!isPasswordValid(password)) return errorResponse("密码至少 6 位。");
        if (account === ADMIN_USERNAME) return errorResponse("该账号为管理员预留账号。");

        const userExists = await env.DB.prepare("SELECT id FROM users WHERE phone = ? LIMIT 1")
          .bind(account)
          .first();
        if (userExists) {
          return errorResponse("该账号已注册，请直接登录。");
        }

        const userId = crypto.randomUUID();
        const createdAt = nowISO();
        const passwordSalt = randomToken(16);
        const passwordHash = await pbkdf2Hex(password, passwordSalt, PASSWORD_PBKDF2_ITERATIONS);

        await env.DB.prepare(
          `INSERT INTO users (id, phone, password_hash, password_salt, password_iterations, created_at)
           VALUES (?, ?, ?, ?, ?, ?)`
        )
          .bind(userId, account, passwordHash, passwordSalt, PASSWORD_PBKDF2_ITERATIONS, createdAt)
          .run();

        const session = await createSession(env, { id: userId, account });
        return ok({
          message: "注册成功",
          data: {
            ...session,
            user: {
              ...session.user,
              createdAt,
            },
          },
        });
      }

      if (request.method === "POST" && path === "/auth/login") {
        const body = await parseJSON(request);
        const account = normalizeAccount(body.phone ?? body.account);
        const password = typeof body.password === "string" ? body.password : "";
        const ip = getClientIP(request);

        if (!isAccountValid(account)) return errorResponse("账号格式无效。");
        if (!isPasswordValid(password)) return errorResponse("密码至少 6 位。");

        if (account === ADMIN_USERNAME && password === ADMIN_PASSWORD) {
          const admin = await ensureAdminUser(env);
          await recordLoginAttempt(env, account, ip, true);
          const session = await createSession(env, { id: admin.id, account });
          return ok({
            message: "管理员登录成功",
            data: {
              ...session,
              user: {
                ...session.user,
                createdAt: admin.createdAt,
              },
            },
          });
        }

        if (await isLoginLocked(env, account)) {
          return errorResponse("登录失败次数过多，请稍后再试。", 429);
        }

        const user = await env.DB.prepare(
          `SELECT id, phone, password_hash, password_salt, password_iterations, created_at
           FROM users
           WHERE phone = ?
           LIMIT 1`
        )
          .bind(account)
          .first<{
            id: string;
            phone: string;
            password_hash: string;
            password_salt: string;
            password_iterations: number;
            created_at: string;
          }>();

        if (!user) {
          await recordLoginAttempt(env, account, ip, false);
          return errorResponse("账号或密码错误。", 401);
        }

        const hash = await pbkdf2Hex(password, user.password_salt, user.password_iterations || PASSWORD_PBKDF2_ITERATIONS);
        if (hash !== user.password_hash) {
          await recordLoginAttempt(env, account, ip, false);
          return errorResponse("账号或密码错误。", 401);
        }

        await recordLoginAttempt(env, account, ip, true);
        const session = await createSession(env, { id: user.id, account: user.phone });
        return ok({
          message: "登录成功",
          data: {
            ...session,
            user: {
              ...session.user,
              createdAt: user.created_at,
            },
          },
        });
      }

      if (request.method === "POST" && path === "/auth/logout") {
        const token = extractBearerToken(request);
        if (!token) return errorResponse("缺少登录凭证。", 401);

        const tokenHash = await sha256Hex(`${token}:${env.AUTH_PEPPER}`);
        await env.DB.prepare(
          `UPDATE auth_sessions
           SET revoked_at = ?
           WHERE token_hash = ? AND revoked_at IS NULL`
        )
          .bind(nowISO(), tokenHash)
          .run();

        return ok({ message: "已退出登录" });
      }

      return errorResponse("Not Found", 404);
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown error";
      return errorResponse(`服务端异常：${message}`, 500);
    }
  },
};
