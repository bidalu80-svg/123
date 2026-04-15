interface Env {
  DB: D1Database;
  AUTH_PEPPER: string;
  SMS_PROVIDER?: string;
  TWILIO_ACCOUNT_SID?: string;
  TWILIO_AUTH_TOKEN?: string;
  TWILIO_FROM_NUMBER?: string;
}

const encoder = new TextEncoder();
const PHONE_REGEX = /^\+?[1-9]\d{7,14}$/;
const CODE_REGEX = /^\d{4,8}$/;
const PASSWORD_REGEX = /^(?=.*[A-Za-z])(?=.*\d).{8,64}$/;

const CODE_TTL_MS = 10 * 60 * 1000;
const CODE_COOLDOWN_MS = 60 * 1000;
const CODE_MAX_PER_DAY = 10;
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

function normalizePhone(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const trimmed = raw.trim();
  if (trimmed.startsWith("+")) {
    const suffix = trimmed.slice(1).replace(/\D/g, "");
    return `+${suffix}`;
  }
  return trimmed.replace(/\D/g, "");
}

function isPhoneValid(phone: string): boolean {
  return PHONE_REGEX.test(phone);
}

function nowISO(): string {
  return new Date().toISOString();
}

function addMillisISO(ms: number): string {
  return new Date(Date.now() + ms).toISOString();
}

function randomDigits(length: number): string {
  const chars = "0123456789";
  let out = "";
  for (let i = 0; i < length; i++) {
    const idx = crypto.getRandomValues(new Uint8Array(1))[0] % chars.length;
    out += chars[idx];
  }
  return out;
}

function randomToken(bytes = 32): string {
  const raw = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(raw).map((x) => x.toString(16).padStart(2, "0")).join("");
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

async function sendSMS(env: Env, phone: string, message: string): Promise<{ provider: string; debugCode?: string }> {
  const provider = (env.SMS_PROVIDER || "mock").toLowerCase();

  if (provider === "twilio") {
    const sid = env.TWILIO_ACCOUNT_SID || "";
    const token = env.TWILIO_AUTH_TOKEN || "";
    const from = env.TWILIO_FROM_NUMBER || "";
    if (!sid || !token || !from) {
      throw new Error("Twilio 未配置完整。");
    }

    const body = new URLSearchParams({
      To: phone,
      From: from,
      Body: message,
    });

    const auth = btoa(`${sid}:${token}`);
    const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
      method: "POST",
      headers: {
        Authorization: `Basic ${auth}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: body.toString(),
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(`Twilio 发送失败: ${text}`);
    }
    return { provider: "twilio" };
  }

  return { provider: "mock" };
}

async function createSession(env: Env, user: { id: string; phone: string }): Promise<{ token: string; expiresAt: string; user: { id: string; phone: string; createdAt: string | null } }> {
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
      phone: user.phone,
      createdAt: null,
    },
  };
}

async function recordLoginAttempt(env: Env, phone: string, ip: string, success: boolean): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO auth_attempts (id, phone, action, ip, success, created_at)
     VALUES (?, ?, 'login', ?, ?, ?)`
  )
    .bind(crypto.randomUUID(), phone, ip, success ? 1 : 0, nowISO())
    .run();
}

async function isLoginLocked(env: Env, phone: string): Promise<boolean> {
  const since = new Date(Date.now() - LOGIN_FAIL_LOCK_WINDOW_MS).toISOString();
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS total
     FROM auth_attempts
     WHERE phone = ?
       AND action = 'login'
       AND success = 0
       AND created_at >= ?`
  )
    .bind(phone, since)
    .first<{ total: number | string }>();

  const total = Number(row?.total || 0);
  return total >= LOGIN_FAIL_LIMIT;
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
            smsProvider: (env.SMS_PROVIDER || "mock").toLowerCase(),
            passwordIterations: PASSWORD_PBKDF2_ITERATIONS,
          },
        });
      }

      if (request.method === "POST" && path === "/auth/send-code") {
        const body = await parseJSON(request);
        const phone = normalizePhone(body.phone);
        const purpose = (typeof body.purpose === "string" ? body.purpose : "register").trim().toLowerCase();
        const ip = getClientIP(request);

        if (!isPhoneValid(phone)) {
          return errorResponse("手机号格式无效。");
        }
        if (purpose !== "register") {
          return errorResponse("仅支持注册验证码。");
        }

        const userExists = await env.DB.prepare("SELECT id FROM users WHERE phone = ? LIMIT 1").bind(phone).first();
        if (userExists) {
          return errorResponse("该手机号已注册，请直接登录。");
        }

        const latest = await env.DB.prepare(
          `SELECT created_at
           FROM verification_codes
           WHERE phone = ? AND purpose = ?
           ORDER BY created_at DESC
           LIMIT 1`
        )
          .bind(phone, purpose)
          .first<{ created_at: string }>();

        if (latest?.created_at) {
          const elapsed = Date.now() - new Date(latest.created_at).getTime();
          if (elapsed < CODE_COOLDOWN_MS) {
            const remain = Math.ceil((CODE_COOLDOWN_MS - elapsed) / 1000);
            return json({ ok: false, message: `请求过于频繁，请 ${remain}s 后重试。`, cooldownSeconds: remain }, 429);
          }
        }

        const dayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
        const dailyCountRow = await env.DB.prepare(
          `SELECT COUNT(*) AS total
           FROM verification_codes
           WHERE phone = ? AND created_at >= ?`
        )
          .bind(phone, dayAgo)
          .first<{ total: number | string }>();
        const dailyCount = Number(dailyCountRow?.total || 0);
        if (dailyCount >= CODE_MAX_PER_DAY) {
          return errorResponse("今日验证码请求次数已达上限，请明天再试。", 429);
        }

        const code = randomDigits(6);
        const salt = randomToken(12);
        const codeHash = await sha256Hex(`${code}:${salt}:${env.AUTH_PEPPER}`);
        const createdAt = nowISO();
        const expiresAt = addMillisISO(CODE_TTL_MS);

        await env.DB.prepare(
          `INSERT INTO verification_codes (id, phone, purpose, code_hash, salt, expires_at, used_at, created_at, request_ip)
           VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)`
        )
          .bind(crypto.randomUUID(), phone, purpose, codeHash, salt, expiresAt, createdAt, ip)
          .run();

        await sendSMS(env, phone, `IEXA 验证码：${code}，10 分钟内有效。`);
        const provider = (env.SMS_PROVIDER || "mock").toLowerCase();
        return ok({
          message: "验证码已发送，请查收短信。",
          cooldownSeconds: 60,
          ...(provider === "mock" ? { debugCode: code } : {}),
        });
      }

      if (request.method === "POST" && path === "/auth/register") {
        const body = await parseJSON(request);
        const phone = normalizePhone(body.phone);
        const password = typeof body.password === "string" ? body.password : "";
        const code = typeof body.code === "string" ? body.code.trim() : "";

        if (!isPhoneValid(phone)) return errorResponse("手机号格式无效。");
        if (!PASSWORD_REGEX.test(password)) return errorResponse("密码至少 8 位，且需包含字母和数字。");
        if (!CODE_REGEX.test(code)) return errorResponse("验证码格式无效。");

        const userExists = await env.DB.prepare("SELECT id FROM users WHERE phone = ? LIMIT 1").bind(phone).first();
        if (userExists) {
          return errorResponse("该手机号已注册，请直接登录。");
        }

        const row = await env.DB.prepare(
          `SELECT id, code_hash, salt, expires_at, used_at
           FROM verification_codes
           WHERE phone = ? AND purpose = 'register'
           ORDER BY created_at DESC
           LIMIT 1`
        )
          .bind(phone)
          .first<{ id: string; code_hash: string; salt: string; expires_at: string; used_at: string | null }>();

        if (!row) return errorResponse("请先获取验证码。");
        if (row.used_at) return errorResponse("验证码已使用，请重新获取。");
        if (new Date(row.expires_at).getTime() < Date.now()) return errorResponse("验证码已过期，请重新获取。");

        const inputHash = await sha256Hex(`${code}:${row.salt}:${env.AUTH_PEPPER}`);
        if (inputHash !== row.code_hash) {
          return errorResponse("验证码错误。");
        }

        const userId = crypto.randomUUID();
        const passwordSalt = randomToken(16);
        const passwordHash = await pbkdf2Hex(password, passwordSalt, PASSWORD_PBKDF2_ITERATIONS);
        const createdAt = nowISO();

        await env.DB.prepare(
          `INSERT INTO users (id, phone, password_hash, password_salt, password_iterations, created_at)
           VALUES (?, ?, ?, ?, ?, ?)`
        )
          .bind(userId, phone, passwordHash, passwordSalt, PASSWORD_PBKDF2_ITERATIONS, createdAt)
          .run();

        await env.DB.prepare("UPDATE verification_codes SET used_at = ? WHERE id = ?")
          .bind(nowISO(), row.id)
          .run();

        const session = await createSession(env, { id: userId, phone });
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
        const phone = normalizePhone(body.phone);
        const password = typeof body.password === "string" ? body.password : "";
        const ip = getClientIP(request);

        if (!isPhoneValid(phone)) return errorResponse("手机号格式无效。");
        if (!PASSWORD_REGEX.test(password)) return errorResponse("密码格式无效。");

        if (await isLoginLocked(env, phone)) {
          return errorResponse("登录失败次数过多，请稍后再试。", 429);
        }

        const user = await env.DB.prepare(
          `SELECT id, phone, password_hash, password_salt, password_iterations, created_at
           FROM users
           WHERE phone = ?
           LIMIT 1`
        )
          .bind(phone)
          .first<{
            id: string;
            phone: string;
            password_hash: string;
            password_salt: string;
            password_iterations: number;
            created_at: string;
          }>();

        if (!user) {
          await recordLoginAttempt(env, phone, ip, false);
          return errorResponse("手机号或密码错误。", 401);
        }

        const hash = await pbkdf2Hex(password, user.password_salt, user.password_iterations || PASSWORD_PBKDF2_ITERATIONS);
        if (hash !== user.password_hash) {
          await recordLoginAttempt(env, phone, ip, false);
          return errorResponse("手机号或密码错误。", 401);
        }

        await recordLoginAttempt(env, phone, ip, true);
        const session = await createSession(env, { id: user.id, phone: user.phone });
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
