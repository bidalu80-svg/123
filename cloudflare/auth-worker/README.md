# ChatApp Auth Worker (Cloudflare D1)

这个目录提供了一个可直接部署到 Cloudflare 的认证后端：

- 账号/手机号 + 密码登录
- 账号/手机号 + 密码注册（无短信验证码）
- Google 账号一键注册/登录（首次登录自动建号）
- Apple ID 一键注册/登录（首次登录自动建号）
- 管理员保留账号直接登录：`blank / 888888`
- 登录失败次数限制（防爆破）
- 注册频率限制（防无限刷号）
- 设备限制：1 台设备仅允许注册 1 个账号；账号首次登录后会绑定设备
- 会话签发与注销

当前已部署可用地址（开发环境）：

`https://chatapp-auth-worker-v2.bidalu9.workers.dev`

## 1) 在 Cloudflare Dashboard 创建 D1 数据库

1. 打开 `https://dash.cloudflare.com`  
2. 进入 `Workers & Pages` -> `D1 SQL Database`
3. 创建数据库，名称建议：`chatapp-auth`
4. 记录 `database_id`

## 2) 配置 Worker

编辑 `wrangler.toml`：

- `name` 改成你自己的 worker 名称
- `database_id` 改成 D1 实际 ID

## 3) 初始化数据库表

在本目录执行：

```bash
wrangler d1 execute chatapp-auth --file=./schema.sql
```

## 4) 配置密钥（必填）

```bash
wrangler secret put AUTH_PEPPER
```

说明：`AUTH_PEPPER` 用于密码与 token 哈希增强，建议高强度随机字符串（32+ 字节）。

### 可选配置（推荐）

1. 开关公开注册（默认开启）：

```bash
wrangler secret put REGISTRATION_ENABLED
```

填 `false` 可关闭公开注册（仅已有账号可登录；Google/Apple 首次建号也会被禁止）。

2. 邀请码注册（启用后注册必须携带邀请码）：

```bash
wrangler secret put REGISTRATION_INVITE_CODE
```

3. Google 登录校验（建议必配）：

```bash
wrangler secret put GOOGLE_CLIENT_ID
```

填写你的 Google OAuth Client ID，用于校验 Google `id_token` 的 `aud`。

4. Apple 登录受众校验（建议配置）：

```bash
wrangler secret put APPLE_ALLOWED_AUDIENCES
```

填写允许的 `aud`（逗号分隔），通常是 iOS 包名或 Service ID。  
示例：`com.chatapp.ios,com.yourcompany.yourapp`

## 5) 部署 Worker

```bash
wrangler deploy
```

部署成功后会得到 URL，例如：

`https://chatapp-auth-worker.your-subdomain.workers.dev`

## 6) 在 iOS 端使用

打开 App 的登录页，将“认证服务地址（Cloudflare Worker）”设置为上面的 Worker URL，然后：

1. 新用户：输入账号和密码，直接注册
2. 已有用户：输入账号和密码直接登录
3. 管理员：使用 `blank / 888888` 可直接登录

## API 概览

- `POST /auth/send-code`
- `POST /auth/register`
- `POST /auth/google`
- `POST /auth/apple`
- `POST /auth/login`
- `POST /auth/logout`

备注：`/auth/send-code` 在当前版本会返回 `410`（已禁用）。

## Google 登录请求体

`POST /auth/google`

```json
{
  "idToken": "GOOGLE_ID_TOKEN"
}
```

服务端会校验 token，首次登录自动创建账号（`google:<sub>`），随后签发与普通登录一致的会话 token。

## Apple 登录请求体

`POST /auth/apple`

```json
{
  "idToken": "APPLE_ID_TOKEN"
}
```

服务端会校验 Apple 签名和声明，首次登录自动创建账号（`apple:<sub>`），随后签发与普通登录一致的会话 token。

请求/响应格式已经与 iOS 端 `AuthService.swift` 对齐。

## 设备绑定规则

- 客户端在登录/注册请求中会携带 `X-Device-Install-ID`。  
- 注册：同一设备仅允许成功注册 1 次。  
- 登录：账号首次成功登录后绑定当前设备，后续仅允许在同一设备登录。  
