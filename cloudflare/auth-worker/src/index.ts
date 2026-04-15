interface Env {
  DB: D1Database;
  AUTH_PEPPER: string;
  REGISTRATION_ENABLED?: string;
  REGISTRATION_INVITE_CODE?: string;
  GOOGLE_CLIENT_ID?: string;
  APPLE_ALLOWED_AUDIENCES?: string;
  SMS_PROVIDER?: string;
  TWILIO_ACCOUNT_SID?: string;
  TWILIO_AUTH_TOKEN?: string;
  TWILIO_FROM_NUMBER?: string;
}

const encoder = new TextEncoder();
const ACCOUNT_REGEX = /^[A-Za-z0-9_.+\-@]{2,64}$/;
const PASSWORD_REGEX = /^.{6,64}$/;

const ADMIN_USERNAME = "blank";
const ADMIN_PASSWORD = "888888";

const LOGIN_FAIL_LOCK_WINDOW_MS = 15 * 60 * 1000;
const LOGIN_FAIL_LIMIT = 5;
const REGISTER_ATTEMPT_WINDOW_MS = 60 * 60 * 1000;
const REGISTER_ATTEMPT_IP_LIMIT = 8;
const REGISTER_ATTEMPT_ACCOUNT_LIMIT = 5;
const REGISTER_SUCCESS_WINDOW_MS = 24 * 60 * 60 * 1000;
const REGISTER_SUCCESS_IP_LIMIT = 3;
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const PASSWORD_PBKDF2_ITERATIONS = 100_000;
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";

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
  return typeof raw === "string" ? raw.trim().toLowerCase() : "";
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

function isRegistrationOpen(env: Env): boolean {
  const value = (env.REGISTRATION_ENABLED || "").trim().toLowerCase();
  if (!value) return true;
  return !["0", "false", "off", "no"].includes(value);
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

async function recordAuthAttempt(
  env: Env,
  account: string,
  ip: string,
  action: "login" | "register" | "google_login" | "apple_login",
  success: boolean
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO auth_attempts (id, phone, action, ip, success, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`
  )
    .bind(crypto.randomUUID(), account, action, ip, success ? 1 : 0, nowISO())
    .run();
}

async function countAuthAttempts(
  env: Env,
  options: {
    action: "login" | "register" | "google_login" | "apple_login";
    sinceISO: string;
    account?: string;
    ip?: string;
    success?: boolean;
  }
): Promise<number> {
  let sql = `SELECT COUNT(*) AS total FROM auth_attempts WHERE action = ? AND created_at >= ?`;
  const binds: Array<string | number> = [options.action, options.sinceISO];

  if (options.account) {
    sql += " AND phone = ?";
    binds.push(options.account);
  }
  if (options.ip) {
    sql += " AND ip = ?";
    binds.push(options.ip);
  }
  if (typeof options.success === "boolean") {
    sql += " AND success = ?";
    binds.push(options.success ? 1 : 0);
  }

  const row = await env.DB.prepare(
    sql
  )
    .bind(...binds)
    .first<{ total: number | string }>();

  return Number(row?.total || 0);
}

async function recordLoginAttempt(env: Env, account: string, ip: string, success: boolean): Promise<void> {
  await recordAuthAttempt(env, account, ip, "login", success);
}

async function recordRegisterAttempt(env: Env, account: string, ip: string, success: boolean): Promise<void> {
  await recordAuthAttempt(env, account, ip, "register", success);
}

async function recordGoogleLoginAttempt(env: Env, account: string, ip: string, success: boolean): Promise<void> {
  await recordAuthAttempt(env, account, ip, "google_login", success);
}

async function recordAppleLoginAttempt(env: Env, account: string, ip: string, success: boolean): Promise<void> {
  await recordAuthAttempt(env, account, ip, "apple_login", success);
}

async function isLoginLocked(env: Env, account: string): Promise<boolean> {
  const since = new Date(Date.now() - LOGIN_FAIL_LOCK_WINDOW_MS).toISOString();
  const total = await countAuthAttempts(env, {
    action: "login",
    sinceISO: since,
    account,
    success: false,
  });
  return total >= LOGIN_FAIL_LIMIT;
}

async function getRegisterThrottleMessage(env: Env, account: string, ip: string): Promise<string | null> {
  const attemptsSince = new Date(Date.now() - REGISTER_ATTEMPT_WINDOW_MS).toISOString();
  const successSince = new Date(Date.now() - REGISTER_SUCCESS_WINDOW_MS).toISOString();

  const attemptsByIP = await countAuthAttempts(env, {
    action: "register",
    sinceISO: attemptsSince,
    ip,
  });
  if (attemptsByIP >= REGISTER_ATTEMPT_IP_LIMIT) {
    return "当前网络注册过于频繁，请稍后再试。";
  }

  const attemptsByAccount = await countAuthAttempts(env, {
    action: "register",
    sinceISO: attemptsSince,
    account,
  });
  if (attemptsByAccount >= REGISTER_ATTEMPT_ACCOUNT_LIMIT) {
    return "该账号注册尝试次数过多，请稍后再试。";
  }

  const successByIP = await countAuthAttempts(env, {
    action: "register",
    sinceISO: successSince,
    ip,
    success: true,
  });
  if (successByIP >= REGISTER_SUCCESS_IP_LIMIT) {
    return "当前网络当日新注册数量已达上限。";
  }

  return null;
}

function isUniqueConstraintError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error ?? "");
  const lowered = message.toLowerCase();
  return lowered.includes("unique") || lowered.includes("constraint");
}

interface GoogleTokenInfo {
  iss?: string;
  aud?: string;
  sub?: string;
  email?: string;
  email_verified?: string;
  exp?: string;
  name?: string;
}

interface AppleTokenHeader {
  alg?: string;
  kid?: string;
}

interface AppleTokenPayload {
  iss?: string;
  aud?: string;
  exp?: number | string;
  iat?: number | string;
  sub?: string;
  email?: string;
  email_verified?: boolean | string;
}

interface AppleJWKSResponse {
  keys?: JsonWebKey[];
}

let appleKeyCache: { keys: JsonWebKey[]; expiresAtMs: number } | null = null;

function parseMaxAgeSeconds(cacheControlHeader: string | null): number {
  if (!cacheControlHeader) return 900;
  const match = cacheControlHeader.match(/max-age=(\d+)/i);
  if (!match) return 900;
  const value = Number(match[1]);
  return Number.isFinite(value) && value > 0 ? value : 900;
}

function base64URLToUint8Array(input: string): Uint8Array {
  const normalized = input
    .replace(/-/g, "+")
    .replace(/_/g, "/")
    .padEnd(Math.ceil(input.length / 4) * 4, "=");
  const binary = atob(normalized);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function decodeJWTPart<T>(part: string): T {
  const bytes = base64URLToUint8Array(part);
  const text = new TextDecoder().decode(bytes);
  return JSON.parse(text) as T;
}

function parseAppleAllowedAudiences(env: Env): string[] {
  const raw = (env.APPLE_ALLOWED_AUDIENCES || "").trim();
  if (!raw) return [];
  return raw
    .split(",")
    .map((item) => item.trim())
    .filter((item) => !!item);
}

async function loadApplePublicKeys(): Promise<JsonWebKey[]> {
  if (appleKeyCache && Date.now() < appleKeyCache.expiresAtMs && appleKeyCache.keys.length > 0) {
    return appleKeyCache.keys;
  }

  const response = await fetch(APPLE_JWKS_URL, { method: "GET" });
  if (!response.ok) {
    throw new Error("Apple 公钥获取失败。");
  }

  const payload = (await response.json()) as AppleJWKSResponse;
  const keys = Array.isArray(payload.keys) ? payload.keys.filter((item) => item && item.kty === "RSA") : [];
  if (!keys.length) {
    throw new Error("Apple 公钥为空。");
  }

  const ttlSeconds = parseMaxAgeSeconds(response.headers.get("cache-control"));
  appleKeyCache = {
    keys,
    expiresAtMs: Date.now() + ttlSeconds * 1000,
  };
  return keys;
}

async function verifyAppleIDToken(env: Env, idToken: string): Promise<AppleTokenPayload> {
  const parts = idToken.split(".");
  if (parts.length !== 3) {
    throw new Error("Apple 登录凭证格式无效。");
  }

  const [headerPart, payloadPart, signaturePart] = parts;
  const header = decodeJWTPart<AppleTokenHeader>(headerPart);
  const payload = decodeJWTPart<AppleTokenPayload>(payloadPart);
  const signingInput = `${headerPart}.${payloadPart}`;
  const signature = base64URLToUint8Array(signaturePart);

  if (header.alg !== "RS256") {
    throw new Error("Apple 登录凭证算法无效。");
  }

  const issuer = (payload.iss || "").trim();
  if (issuer !== "https://appleid.apple.com") {
    throw new Error("Apple 登录凭证签发方无效。");
  }

  const subject = (payload.sub || "").trim();
  if (!subject) {
    throw new Error("Apple 登录凭证缺少 sub。");
  }

  const exp = Number(payload.exp || 0);
  if (!Number.isFinite(exp) || exp * 1000 <= Date.now()) {
    throw new Error("Apple 登录凭证已过期。");
  }

  const tokenAudience = (payload.aud || "").trim();
  const allowedAudiences = parseAppleAllowedAudiences(env);
  if (allowedAudiences.length > 0) {
    if (!allowedAudiences.includes(tokenAudience)) {
      throw new Error("Apple 登录凭证受众不匹配。");
    }
  } else if (!tokenAudience) {
    throw new Error("Apple 登录凭证缺少受众。");
  }

  const keys = await loadApplePublicKeys();
  const candidateKeys = header.kid
    ? keys.filter((item) => item.kid === header.kid)
    : keys;
  if (!candidateKeys.length) {
    throw new Error("Apple 登录凭证缺少匹配公钥。");
  }

  const data = encoder.encode(signingInput);
  let verified = false;
  for (const key of candidateKeys) {
    try {
      const publicKey = await crypto.subtle.importKey(
        "jwk",
        key,
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["verify"]
      );
      verified = await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        publicKey,
        signature,
        data
      );
      if (verified) break;
    } catch {
      // Try next key.
    }
  }

  if (!verified) {
    throw new Error("Apple 登录凭证签名验证失败。");
  }

  return payload;
}

async function verifyGoogleIDToken(env: Env, idToken: string): Promise<GoogleTokenInfo> {
  const url = new URL("https://oauth2.googleapis.com/tokeninfo");
  url.searchParams.set("id_token", idToken);

  const response = await fetch(url.toString(), { method: "GET" });
  if (!response.ok) {
    throw new Error("Google 令牌校验失败。");
  }

  const payload = (await response.json()) as GoogleTokenInfo;
  const issuer = (payload.iss || "").trim();
  const audience = (payload.aud || "").trim();
  const subject = (payload.sub || "").trim();
  const email = (payload.email || "").trim().toLowerCase();
  const emailVerified = String(payload.email_verified || "").toLowerCase() === "true";

  if (!subject) {
    throw new Error("Google 令牌缺少 sub。");
  }
  if (!email || !emailVerified) {
    throw new Error("Google 邮箱未验证。");
  }

  if (issuer !== "accounts.google.com" && issuer !== "https://accounts.google.com") {
    throw new Error("Google 令牌签发方无效。");
  }

  const expectedAudience = (env.GOOGLE_CLIENT_ID || "").trim();
  if (expectedAudience && audience !== expectedAudience) {
    throw new Error("Google 令牌受众不匹配。");
  }

  return payload;
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
            registrationOpen: isRegistrationOpen(env),
            googleLoginEnabled: !!(env.GOOGLE_CLIENT_ID || "").trim(),
            appleLoginEnabled: true,
            appleAudienceEnforced: parseAppleAllowedAudiences(env).length > 0,
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
        const ip = getClientIP(request);

        if (!isRegistrationOpen(env)) {
          await recordRegisterAttempt(env, account || "unknown", ip, false);
          return errorResponse("当前已关闭公开注册。", 403);
        }

        if (!isAccountValid(account)) {
          await recordRegisterAttempt(env, account || "unknown", ip, false);
          return errorResponse("账号格式无效。");
        }
        if (!isPasswordValid(password)) {
          await recordRegisterAttempt(env, account, ip, false);
          return errorResponse("密码至少 6 位。");
        }
        if (account === ADMIN_USERNAME) {
          await recordRegisterAttempt(env, account, ip, false);
          return errorResponse("该账号为管理员预留账号。");
        }

        const inviteCodeRequired = (env.REGISTRATION_INVITE_CODE || "").trim();
        if (inviteCodeRequired) {
          const inviteCode = typeof body.inviteCode === "string" ? body.inviteCode.trim() : "";
          if (inviteCode !== inviteCodeRequired) {
            await recordRegisterAttempt(env, account, ip, false);
            return errorResponse("邀请码无效。", 403);
          }
        }

        const registerThrottleMessage = await getRegisterThrottleMessage(env, account, ip);
        if (registerThrottleMessage) {
          await recordRegisterAttempt(env, account, ip, false);
          return errorResponse(registerThrottleMessage, 429);
        }

        const userExists = await env.DB.prepare("SELECT id FROM users WHERE phone = ? LIMIT 1")
          .bind(account)
          .first();
        if (userExists) {
          await recordRegisterAttempt(env, account, ip, false);
          return errorResponse("该账号已注册，请直接登录。");
        }

        const userId = crypto.randomUUID();
        const createdAt = nowISO();
        const passwordSalt = randomToken(16);
        const passwordHash = await pbkdf2Hex(password, passwordSalt, PASSWORD_PBKDF2_ITERATIONS);

        try {
          await env.DB.prepare(
            `INSERT INTO users (id, phone, password_hash, password_salt, password_iterations, created_at)
             VALUES (?, ?, ?, ?, ?, ?)`
          )
            .bind(userId, account, passwordHash, passwordSalt, PASSWORD_PBKDF2_ITERATIONS, createdAt)
            .run();
        } catch (error) {
          if (isUniqueConstraintError(error)) {
            await recordRegisterAttempt(env, account, ip, false);
            return errorResponse("该账号已注册，请直接登录。");
          }
          throw error;
        }

        await recordRegisterAttempt(env, account, ip, true);
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

      if (request.method === "POST" && path === "/auth/google") {
        const body = await parseJSON(request);
        const idToken = typeof body.idToken === "string" ? body.idToken.trim() : "";
        const ip = getClientIP(request);

        if (!idToken || idToken.length > 4096) {
          await recordGoogleLoginAttempt(env, "google:unknown", ip, false);
          return errorResponse("缺少有效的 Google idToken。", 400);
        }

        let tokenInfo: GoogleTokenInfo;
        try {
          tokenInfo = await verifyGoogleIDToken(env, idToken);
        } catch (error) {
          await recordGoogleLoginAttempt(env, "google:unknown", ip, false);
          const message = error instanceof Error ? error.message : "Google 登录失败。";
          return errorResponse(message, 401);
        }

        const subject = (tokenInfo.sub || "").trim();
        const email = (tokenInfo.email || "").trim().toLowerCase();
        const account = `google:${subject}`;
        const createdAt = nowISO();

        let user = await env.DB.prepare(
          `SELECT id, created_at
           FROM users
           WHERE phone = ?
           LIMIT 1`
        )
          .bind(account)
          .first<{ id: string; created_at: string }>();

        if (!user) {
          if (!isRegistrationOpen(env)) {
            await recordGoogleLoginAttempt(env, account, ip, false);
            return errorResponse("当前已关闭公开注册。", 403);
          }

          const registerThrottleMessage = await getRegisterThrottleMessage(env, account, ip);
          if (registerThrottleMessage) {
            await recordGoogleLoginAttempt(env, account, ip, false);
            return errorResponse(registerThrottleMessage, 429);
          }

          const userId = crypto.randomUUID();
          const passwordSalt = randomToken(16);
          const randomPassword = randomToken(32);
          const passwordHash = await pbkdf2Hex(randomPassword, passwordSalt, PASSWORD_PBKDF2_ITERATIONS);

          try {
            await env.DB.prepare(
              `INSERT INTO users (id, phone, password_hash, password_salt, password_iterations, created_at)
               VALUES (?, ?, ?, ?, ?, ?)`
            )
              .bind(userId, account, passwordHash, passwordSalt, PASSWORD_PBKDF2_ITERATIONS, createdAt)
              .run();
            await recordRegisterAttempt(env, account, ip, true);
            user = { id: userId, created_at: createdAt };
          } catch (error) {
            if (isUniqueConstraintError(error)) {
              user = await env.DB.prepare(
                `SELECT id, created_at
                 FROM users
                 WHERE phone = ?
                 LIMIT 1`
              )
                .bind(account)
                .first<{ id: string; created_at: string }>();
            } else {
              throw error;
            }
          }
        }

        if (!user) {
          await recordGoogleLoginAttempt(env, account, ip, false);
          return errorResponse("Google 账号绑定失败，请稍后重试。", 500);
        }

        await recordGoogleLoginAttempt(env, account, ip, true);
        const session = await createSession(env, { id: user.id, account });
        return ok({
          message: "Google 登录成功",
          data: {
            ...session,
            user: {
              ...session.user,
              phone: email || session.user.phone,
              createdAt: user.created_at,
            },
          },
        });
      }

      if (request.method === "POST" && path === "/auth/apple") {
        const body = await parseJSON(request);
        const idToken = typeof body.idToken === "string" ? body.idToken.trim() : "";
        const ip = getClientIP(request);

        if (!idToken || idToken.length > 4096) {
          await recordAppleLoginAttempt(env, "apple:unknown", ip, false);
          return errorResponse("缺少有效的 Apple idToken。", 400);
        }

        let tokenInfo: AppleTokenPayload;
        try {
          tokenInfo = await verifyAppleIDToken(env, idToken);
        } catch (error) {
          await recordAppleLoginAttempt(env, "apple:unknown", ip, false);
          const message = error instanceof Error ? error.message : "Apple 登录失败。";
          return errorResponse(message, 401);
        }

        const subject = (tokenInfo.sub || "").trim();
        const account = `apple:${subject}`;
        const createdAt = nowISO();
        const tokenEmail = (tokenInfo.email || "").trim().toLowerCase();

        let user = await env.DB.prepare(
          `SELECT id, created_at
           FROM users
           WHERE phone = ?
           LIMIT 1`
        )
          .bind(account)
          .first<{ id: string; created_at: string }>();

        if (!user) {
          if (!isRegistrationOpen(env)) {
            await recordAppleLoginAttempt(env, account, ip, false);
            return errorResponse("当前已关闭公开注册。", 403);
          }

          const registerThrottleMessage = await getRegisterThrottleMessage(env, account, ip);
          if (registerThrottleMessage) {
            await recordAppleLoginAttempt(env, account, ip, false);
            return errorResponse(registerThrottleMessage, 429);
          }

          const userId = crypto.randomUUID();
          const passwordSalt = randomToken(16);
          const randomPassword = randomToken(32);
          const passwordHash = await pbkdf2Hex(randomPassword, passwordSalt, PASSWORD_PBKDF2_ITERATIONS);

          try {
            await env.DB.prepare(
              `INSERT INTO users (id, phone, password_hash, password_salt, password_iterations, created_at)
               VALUES (?, ?, ?, ?, ?, ?)`
            )
              .bind(userId, account, passwordHash, passwordSalt, PASSWORD_PBKDF2_ITERATIONS, createdAt)
              .run();
            await recordRegisterAttempt(env, account, ip, true);
            user = { id: userId, created_at: createdAt };
          } catch (error) {
            if (isUniqueConstraintError(error)) {
              user = await env.DB.prepare(
                `SELECT id, created_at
                 FROM users
                 WHERE phone = ?
                 LIMIT 1`
              )
                .bind(account)
                .first<{ id: string; created_at: string }>();
            } else {
              throw error;
            }
          }
        }

        if (!user) {
          await recordAppleLoginAttempt(env, account, ip, false);
          return errorResponse("Apple 账号绑定失败，请稍后重试。", 500);
        }

        await recordAppleLoginAttempt(env, account, ip, true);
        const session = await createSession(env, { id: user.id, account });
        return ok({
          message: "Apple 登录成功",
          data: {
            ...session,
            user: {
              ...session.user,
              phone: tokenEmail || session.user.phone,
              createdAt: user.created_at,
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
