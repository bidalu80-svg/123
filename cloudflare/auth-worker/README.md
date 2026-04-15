# ChatApp Auth Worker (Cloudflare D1)

这个目录提供了一个可直接部署到 Cloudflare 的认证后端：

- 手机号 + 密码登录
- 手机号 + 短信验证码注册
- 验证码频率限制（防止恶意刷号）
- 登录失败次数限制（防爆破）
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

## 5) 配置短信通道

### 开发调试（默认）

`SMS_PROVIDER=mock`，接口会返回 `debugCode` 便于联调，不会真实发短信。

### 生产（Twilio）

1. 修改 `wrangler.toml` 的 `SMS_PROVIDER = "twilio"`
2. 设置 secrets：

```bash
wrangler secret put TWILIO_ACCOUNT_SID
wrangler secret put TWILIO_AUTH_TOKEN
wrangler secret put TWILIO_FROM_NUMBER
```

## 6) 部署 Worker

```bash
wrangler deploy
```

部署成功后会得到 URL，例如：

`https://chatapp-auth-worker.your-subdomain.workers.dev`

## 7) 在 iOS 端使用

打开 App 的登录页，将“认证服务地址（Cloudflare Worker）”设置为上面的 Worker URL，然后：

1. 注册时先发送验证码
2. 输入验证码并注册
3. 注册后自动登录

## API 概览

- `POST /auth/send-code`
- `POST /auth/register`
- `POST /auth/login`
- `POST /auth/logout`

请求/响应格式已经与 iOS 端 `AuthService.swift` 对齐。
