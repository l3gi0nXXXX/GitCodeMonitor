# GitCodeMonitor 配置说明

本文档说明 GitCodeMonitor 配置文件中每一项应该填写什么、从哪里获取，以及在 Metis service-plugin 模式下开启真实 GitCode 写回时的安全边界。

## 配置文件位置

GitCodeMonitor 默认读取：

```text
$HOME/.metis/metis.json
```

本地调试建议不要直接改默认文件，而是使用项目内被 `.gitignore` 忽略的配置目录：

```text
.gitcodemonitor/gcm-live.json
```

运行时通过 `--config` 显式指定：

```bash
cjpm run --name gitcodemonitor --run-args "--config .gitcodemonitor/gcm-live.json doctor"
```

注意：

- 不要把真实 token、cookie、bot token、webhook、service token 写进 README、docs、测试用例或提交记录。
- `.gitcodemonitor/` 已被忽略，适合存放本机真实配置和状态文件。
- 删除 `monitor.statePath` 指向的状态文件会导致已处理事件重新进入 service-plugin 事件处理和写回审计流程。

## 最小安全配置

这是只验证 GitCode 配置、不开写回的最小配置：

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>"
  },
  "monitor": {
    "statePath": ".gitcodemonitor/state.json",
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": true,
    "autoReply": false,
    "transport": "native"
  }
}
```

## GitCode 配置

| 字段 | 是否建议填写 | 应该填什么 |
| --- | --- | --- |
| `gitcode.baseUrl` | 必填或使用默认值 | GitCode API 根地址。当前实现默认值是 `https://api.gitcode.com/api/v5`。 |
| `gitcode.authMode` | 建议填写 | 认证头模式。常用值是 `PRIVATE-TOKEN`。如果你的 token 要作为 Bearer token 发送，可填 `Authorization`、`Bearer` 或 `bearer`。如果 API 要求 query token，可填 `access_token` 或 `query`。 |
| `gitcode.token` | 真实扫描建议填写 | GitCode/AtomGit API 访问 token。它不是飞书 webhook，不是 Telegram bot token，也不是 Metis service token。 |
| `gitcode.cookie` | 不推荐，必要时才填 | GitCode 登录后的 Cookie 原始字符串。只有 token 不可用且你明确需要 Cookie 模式时才使用。 |
| `gitcode.username` / `gitcode.password` | 当前不要使用 | 当前代码能读取这两个字段并把它们识别为“有认证信息”，但真实 HTTP 客户端没有实现账号密码自动登录。正式运行请使用 `token` 或 `cookie`。 |
| `gitcode.transport` | 通常不填 | HTTP 传输方式。默认是 `native`。只有明确排查兼容问题时才填 `curl`。 |

当前实现会用这些 GitCode API 形态：

- 组织公开仓库：`GET /orgs/{org}/repos?type=public&page=...&per_page=...`
- Issue 列表：`GET /repos/{owner}/{repo}/issues?...`
- PR 列表：`GET /repos/{owner}/{repo}/pulls?...`
- 维护者 team leader：`GET /repos/Cangjie/community/contents/team%2Frepo_list.md?ref=main`
- CODEOWNERS：`GET /repos/{owner}/{repo}/contents/.gitcode%2FCODEOWNERS?ref=...`
- PR changed files：`GET /repos/{owner}/{repo}/pulls/{number}/files`
- Issue 评论：`GET /repos/{owner}/{repo}/issues/comments?...`
- PR 评论：`GET /repos/{owner}/{repo}/pulls/{number}/comments?...`
- 自动回复写回：`POST /repos/{owner}/{repo}/issues/{number}/comments` 或 `POST /repos/{owner}/{repo}/pulls/{number}/comments`

## 维护者邮件通知配置

维护者 lookup、footer 和邮件通知都属于 GCM。Metis 不读取 `team/repo_list.md`，不读取 `.gitcode/CODEOWNERS`，也不发送维护者邮件。

邮件通知默认关闭。启用后，GCM 只会在 GitCode 评论写回成功后发送邮件；gate 失败、dry-run、`autoReply=false`、GitCode writer 失败、draft 含 secret 或本机路径时都不会发送邮件。测试必须使用 fake sender 或 fake SMTP transport，不得连接真实 SMTP 服务。

示例：

```json
{
  "gitcode": {
    "maintainerNotification": {
      "email": {
        "enabled": false,
        "transport": "smtp",
        "smtp": {
          "host": "smtp.example.com",
          "port": 465,
          "security": "ssl",
          "username": "bot@example.com",
          "passwordEnv": "GCM_MAINTAINER_SMTP_PASSWORD"
        },
        "from": "bot@example.com",
        "replyTo": "bot@example.com",
        "allowedDomains": ["example.com"],
        "addressBook": {
          "@alice": ["alice@example.com"],
          "bob": ["bob@example.com"]
        }
      }
    }
  }
}
```

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `gitcode.maintainerNotification.email.enabled` | `false` | 是否启用维护者邮件。默认关闭。 |
| `transport` | `smtp` | 当前只支持 `smtp`。 |
| `smtp.host` / `smtp.port` | 空 / `0` | SMTP 服务器地址和端口。启用时必须填写。 |
| `smtp.security` | `ssl` | 支持 `ssl`、`starttls`、`none`。`none` 只允许 fake/local test transport，不允许生产配置。 |
| `smtp.username` | 空 | SMTP 登录用户名，通常是完整邮箱地址。 |
| `smtp.passwordEnv` | 空 | 保存 SMTP 密码或客户端授权码的环境变量名。配置文件中只写变量名，不写真实值。 |
| `from` / `replyTo` | 空 | 邮件头里的发件人与回复地址。启用时 `from` 必须是合法 email；不填时可用 `smtp.username`。 |
| `allowedDomains` | `[]` | 可选收件人域名白名单。非空时，addressBook 中不在白名单内的地址会被配置校验拒绝。 |
| `addressBook` | `{}` | mention/login 到 email 的映射。GCM 不根据 login 猜邮箱。 |

安全要求：

- 不要把真实 SMTP 密码、授权码、token、cookie 或 webhook secret 写入配置文件、测试、日志或文档。
- `passwordEnv` 对应的真实值只应存在于运行环境变量中，GCM response 和 config summary 不会输出该真实值。
- GCM response 只返回 `emailNotificationStatus`、计数和 retryable，不返回收件人明文或邮件正文。
- 没有合法 email 时，GitCode 评论仍可写回并追加维护者 mention，邮件状态为 `email_unavailable`。

## GitCode Author Policy 配置

`gitcode.authorPolicy` 用于配置哪些作者只记录、不进入 Metis/LLM/IM/writeback 链路。这个策略属于 GCM 的 GitCode 事件过滤边界；Metis 不应该根据原始 webhook payload 再做企业作者过滤。

默认值必须是空列表：不配置 `gitcode.authorPolicy`、不配置 `recordOnlyEmailDomains`、或显式配置 `recordOnlyEmailDomains: []` 时，GCM 不过滤任何作者。也就是说，默认情况下 `@huawei.com`、`@h-partners.com` 或任何其他域名都不会被自动 record-only。

不启用任何作者过滤时，可以不写该段配置，也可以显式写成：

```json
{
  "gitcode": {
    "authorPolicy": {
      "recordOnlyEmailDomains": []
    }
  }
}
```

如果你希望某些企业邮箱作者只记录事件、不触发后续处理，需要显式配置域名：

```json
{
  "gitcode": {
    "authorPolicy": {
      "recordOnlyEnabled": true,
      "recordOnlyEmailDomains": [
        "@huawei.com",
        "@h-partners.com"
      ],
      "unknownEmailDecision": "process"
    }
  }
}
```

| 字段 | 默认值 | 应该填什么 |
| --- | --- | --- |
| `gitcode.authorPolicy.recordOnlyEnabled` | `true` | 可选开关。只有当该值为 `true` 且 `recordOnlyEmailDomains` 非空时，record-only 过滤才会实际生效。设为 `false` 时，即使配置了域名也不会过滤作者。 |
| `gitcode.authorPolicy.recordOnlyEmailDomains` | `[]` | 需要 record-only 的 email 后缀列表。默认空数组，不过滤任何作者。可写 `huawei.com` 或 `@huawei.com`，解析时统一为 `@huawei.com`。 |
| `gitcode.authorPolicy.unknownEmailDecision` | `process` | email 解析失败或没有 email 时的处理方式。当前只允许 `process`，避免把未知作者误判为需要 record-only 的作者。 |

匹配规则：

- 只做大小写不敏感的 email 后缀匹配，不支持正则、通配符或 URL。
- `dev@huawei.com` 会命中 `@huawei.com`。
- `dev@sub.huawei.com` 不会命中 `@huawei.com`；如果需要过滤子域名，必须显式配置 `@sub.huawei.com`。
- 无 email、email 获取失败或 email 格式不合法时，按 `unknownEmailDecision=process` 继续处理事件。

record-only 命中后的运行行为：

1. GCM 标记该事件已见过，避免重复处理。
2. GCM 写入审计记录，原因是 `record_only/corporate_author`。
3. GCM 标记 webhook delivery 已处理。
4. GCM 不发送 `gitcode.event.accepted` 给 Metis。
5. GCM 不执行 GitCode 写回。

## GitCode Webhook 配置

GitCodeMonitor 可以作为 GitCode webhook receiver 接收 GitCode 官方推送的 Issue、PR 和评论事件。这个能力由 GCM 消费，Metis 不直接读取 GitCode 原始 webhook payload；Metis 只接收 GCM 解析、过滤和契约化后的 service plugin event。

配置位置是 `gitcode.webhook`。本地 macOS 调试时，通常把 GCM listener 绑定到 `127.0.0.1:18080`，再用 cloudflared 或 ngrok 把临时公网 HTTPS URL 转发到这个本地端口。

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>",
    "webhook": {
      "enabled": true,
      "bindHost": "127.0.0.1",
      "port": 18080,
      "publicBaseUrl": "https://<cloudflared-or-ngrok-domain>",
      "queueDir": ".gitcodemonitor/webhook-queue",
      "ackMode": "fast",
      "endpoints": [
        {
          "id": "main",
          "path": "/webhooks/gitcode/main",
          "token": "<GCM webhook endpoint token>",
          "allowedEvents": [
            "Issue Hook",
            "Merge Request Hook",
            "Note Hook"
          ]
        }
      ]
    }
  }
}
```

| 字段 | 是否建议填写 | 应该填什么 |
| --- | --- | --- |
| `gitcode.webhook.enabled` | 需要 webhook-first 模式时必填 | `true` 表示启动 GCM webhook listener。 |
| `gitcode.webhook.bindHost` | 本地调试建议填写 | 本地 cloudflared/ngrok 转发场景建议 `127.0.0.1`。如果直接部署到公网服务器，可按部署边界选择监听地址。 |
| `gitcode.webhook.port` | 必填或使用默认值 | GCM webhook listener 端口。本地联调建议 `18080`。 |
| `gitcode.webhook.publicBaseUrl` | GitCode 真实投递时必填 | GitCode 后台能访问到的公网 HTTPS 根地址，不包含 endpoint path，例如 `https://example.trycloudflare.com`。 |
| `gitcode.webhook.queueDir` | 建议填写 | webhook 持久化队列目录。建议使用被 `.gitignore` 忽略的 `.gitcodemonitor/webhook-queue`。 |
| `gitcode.webhook.ackMode` | 通常填写 `fast` | 当前实现只接受 `fast`。GCM 收到合法请求后快速返回 `202`，后续由 processor 异步处理。 |
| `gitcode.webhook.endpoints[].id` | 必填 | endpoint 标识，例如 `main`。 |
| `gitcode.webhook.endpoints[].path` | 必填 | GitCode webhook URL path，例如 `/webhooks/gitcode/main`。GitCode 后台最终 URL 应为 `publicBaseUrl + path`。 |
| `gitcode.webhook.endpoints[].token` | 必填，除非使用签名密钥 | GCM endpoint token。它不是 GitCode API token，也不是 Metis token。GitCode 后台 webhook 密码/Secret Token 必须填写同一个值。 |
| `gitcode.webhook.endpoints[].signatureSecret` | 可选 | 预留签名密钥字段。当前常用配置是填写 `token`。 |
| `gitcode.webhook.endpoints[].allowedEvents` | 建议显式填写 | GCM 接收事件白名单，当前只能填写 `Issue Hook`、`Merge Request Hook`、`Note Hook`。 |
| `gitcode.webhook.endpoints[].enabled` | 可选 | 不填时默认为 `true`。 |

`allowedEvents` 是大小写敏感的精确字符串，必须按 GitCode webhook 请求头 `X-GitCode-Event` 的事件名填写。当前实现只接受以下三个值：

| 事件名 | 含义 |
| --- | --- |
| `Issue Hook` | Issue 新建、更新等事件。GCM 后续只对需要回复的新 Issue 动作继续处理。 |
| `Merge Request Hook` | PR 新建、更新等事件。GCM 后续只对需要回复的新 PR 动作继续处理。 |
| `Note Hook` | 评论事件。GCM 后续只处理 Issue/PR 评论，忽略 commit note 等非目标评论。 |

不要写成小写或下划线形式，例如 `issue_hook`、`merge_request_hook`、`note_hook`。这些值不会通过当前 GCM 配置校验或 webhook 接收白名单校验。

字段名也可以写成 `events`，GCM 会按同样规则解析；但用户配置建议统一使用 `allowedEvents`，避免和 GitCode 后台页面里的事件勾选项混淆。

GCM 对这个字段的消费路径如下：

1. 启动时从 `gitcode.webhook.endpoints[]` 读取 `allowedEvents`。
2. 配置校验阶段确认事件名只包含 `Issue Hook`、`Merge Request Hook`、`Note Hook`。
3. HTTP webhook 请求进入 GCM listener 后，读取请求头 `X-GitCode-Event`。
4. 如果请求头事件名不在 endpoint 的 `allowedEvents` 中，GCM 返回 `400 rejected unknown event`。
5. 事件通过白名单、token、content-type、body size、JSON 校验后写入 GCM webhook queue。

配置后可以用以下命令验证原始配置是否显式包含事件白名单：

```bash
jq '.gitcode.webhook | {
  enabled,
  bindHost,
  port,
  publicBaseUrl,
  queueDir,
  endpointCount: (.endpoints | length),
  endpoints: [.endpoints[] | {id, path, allowedEvents}]
}' .gitcodemonitor/gcm-live.json
```

预期 `endpoints[0].allowedEvents` 输出为：

```json
[
  "Issue Hook",
  "Merge Request Hook",
  "Note Hook"
]
```

也可以用 GCM 自己的解析结果确认运行时生效配置：

```bash
cjpm run --skip-build --name gitcodemonitor --run-args "--config .gitcodemonitor/gcm-live.json config summary"
```

预期输出中包含：

```text
webhookEndpoints=main:/webhooks/gitcode/main:Issue Hook|Merge Request Hook|Note Hook
```

GitCode 后台 webhook 配置时：

- URL 填 `publicBaseUrl + endpoints[0].path`，例如 `https://example.trycloudflare.com/webhooks/gitcode/main`。
- 密码/Secret Token 填 `endpoints[0].token` 的值。
- 事件只勾选 Issue、Pull Request/Merge Request、评论/Note 相关事件。

## Metis service-plugin 边界

GitCodeMonitor 当前生产运行形态只有 Metis service-plugin 模式：

- GCM 通过 `plugin-stdio` 被 Metis service-plugin host 启动。
- GCM 发出 `gitcode.event.accepted` 等契约化事件，不直接调用 Metis MCP。
- Metis 负责 LLM、回复生成、安全判断、飞书/Telegram 等 IM 通知。
- Metis 需要写回 GitCode 时，调用 GCM 的 `gitcode.writeback.apply_result` capability。
- GCM 在 `apply_result` 中执行最终写回门禁和 GitCode API 评论写入。

因此，GCM 配置中不再需要 `monitor.notifyNetworkEnabled`，也不再需要 `feishu.webhook`、`telegram.botToken`、`telegram.chatId` 作为 GCM 通知配置。旧配置字段会被忽略或只作为脱敏兼容输入处理，不能触发 GCM 自己发送 IM 通知。

如果需要配置飞书或 Telegram，请在 Metis Gateway / channel 配置中完成，不要放到 GCM 配置里。

## Monitor 配置

| 字段 | 默认值 | 应该填什么 |
| --- | --- | --- |
| `monitor.orgs` | `["cangjie", "cangjie-sig", "cangjie-tpc"]` | 需要扫描的 GitCode 组织列表。当前目标就是这三个组织。这个字段只控制扫描范围，不控制自动写回范围。 |
| `monitor.statePath` | `.gitcodemonitor/state.json` | 扫描游标、写回审计的本地状态文件。建议使用 `.gitcodemonitor/` 下的路径，该目录已被 `.gitignore` 忽略。 |
| `monitor.fullScanIntervalMinutes` | `10` | 全量扫描间隔，单位分钟。生产配置不能低于 5。当前方案建议 10 分钟。 |
| `monitor.jitterSeconds` | `30` | 扫描抖动秒数，用于避免固定时间点集中请求。当前校验要求不超过 30。 |
| `monitor.dryRun` | `true` | 是否禁止 GitCode 自动写回。`true` 表示不写回 GitCode；`false` 才允许进入写回门禁。 |
| `monitor.autoReply` | `false` | 是否启用自动回复写回。即使设为 `true`，仍需 `dryRun=false`、Metis 安全通过、writebackScope 命中、无重复写回、无敏感信息和本地路径，才会真正写回。 |
| `monitor.writebackScope.allowedOrgs` | `[]` | 允许自动写回的组织列表，格式是 GitCode owner 名，例如 `["cangjie", "cangjie-sig", "cangjie-tpc"]`。只控制写回范围，不扩大或缩小 `monitor.orgs` 扫描范围。 |
| `monitor.writebackScope.allowedRepos` | `[]` | 允许自动写回的仓库列表，格式是 `owner/repo`，例如 `["Cangjie/community"]`。用于补充组织外或少量精确仓库授权。 |
| `monitor.writebackScope.deniedRepos` | `[]` | 禁止自动写回的仓库列表，格式是 `owner/repo`。优先级最高，即使命中 `allowedOrgs` 或 `allowedRepos` 也不会写回。 |
| `monitor.repoAllowlist` | `[]` | 旧配置诊断字段。格式是 `owner/repo`，只做解析和校验，不再授权写回；新配置必须使用 `writebackScope`。 |
| `monitor.transport` | `native` | HTTP 传输方式。默认 `native`。`curl` 只作为显式回退。 |

### writebackScope 优先级与匹配示例

写回 scope 只判断 GitCode 自动评论是否允许进入后续写回门禁；扫描范围仍由 `monitor.orgs` 决定。优先级公式是：

```text
deniedRepos > allowedRepos > allowedOrgs > 默认拒绝
```

完整示例：

```json
{
  "monitor": {
    "orgs": ["cangjie", "cangjie-sig", "cangjie-tpc"],
    "dryRun": false,
    "autoReply": true,
    "writebackScope": {
      "allowedOrgs": ["cangjie"],
      "allowedRepos": ["cangjie-sig/special-repo"],
      "deniedRepos": ["cangjie/community"]
    }
  }
}
```

| repo | 匹配结果 | 原因 |
| --- | --- | --- |
| `cangjie/community` | 禁止写回 | 命中 `deniedRepos`，优先级最高。 |
| `cangjie/compiler` | 允许写回 | 未命中 `deniedRepos`，命中 `allowedOrgs=["cangjie"]`。 |
| `cangjie-sig/special-repo` | 允许写回 | 未命中 `deniedRepos`，命中 `allowedRepos`。 |
| `cangjie-sig/other-repo` | 禁止写回 | 未命中 `allowedRepos`，也未命中 `allowedOrgs`。 |
| `cangjie-tpc/foo` | 禁止写回 | 未命中任何 allow scope。 |
| `other-org/foo` | 禁止写回 | 未命中任何 allow scope，按默认拒绝处理。 |

## 分阶段配置示例

### 阶段 1：GitCode 配置 dry-run

用于确认 GitCode token、组织列表、状态文件路径和脱敏输出是否正常：

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>"
  },
  "monitor": {
    "statePath": ".gitcodemonitor/state.json",
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": true,
    "autoReply": false,
    "transport": "native"
  }
}
```

验证命令：

```bash
cjpm run --name gitcodemonitor --run-args "--config .gitcodemonitor/gcm-live.json doctor"
cjpm run --name gitcodemonitor --run-args "--config .gitcodemonitor/gcm-live.json probe-gitcode"
```

验收标准：

- `doctor` 中 `gitCodeAuth=present`。
- 输出不包含真实 token、cookie、webhook、bot token。
- `dryRun=true` 且 `autoReply=false`，不会写 GitCode 评论。
- `scan-once`、`serve`、`webhook-http` 作为独立运行命令会返回 service-plugin-only 不支持提示。

### 阶段 2：接入 Metis service-plugin host

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>"
  },
  "monitor": {
    "statePath": ".gitcodemonitor/state.json",
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": true,
    "autoReply": false,
    "transport": "native"
  }
}
```

验收标准：

- Metis 能以 service-plugin 模式启动 GCM 的 `plugin-stdio`。
- GCM 初始化响应不包含 GitCode token、cookie、IM bot token 或 webhook。
- 未被过滤的 GitCode 事件通过 `gitcode.event.accepted` 进入 Metis。
- Metis 侧 IM 通知由 Metis Gateway/channel 发送，GCM 不直接发送飞书或 Telegram。
- GitCode 仍不会被自动回复，因为 `dryRun=true` 且 `autoReply=false`。

### 阶段 3：Metis 生成回复，但 GCM 仍不写回

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>"
  },
  "monitor": {
    "statePath": ".gitcodemonitor/state.json",
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": true,
    "autoReply": false,
    "transport": "native"
  }
}
```

验收标准：

- Metis 能基于 `gitcode.event.accepted` 生成回复草稿和安全判断。
- Metis 调用 `gitcode.writeback.apply_result` 时，GCM 返回 `dry_run` 或 `auto_reply_disabled`，不写 GitCode 评论。
- GCM 状态文件记录 dry-run/门禁审计，状态文件位于 `.gitcodemonitor/` 或临时测试目录。

### 阶段 4：受控开启自动写回

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>"
  },
  "monitor": {
    "statePath": ".gitcodemonitor/state.json",
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": false,
    "autoReply": true,
    "writebackScope": {
      "allowedOrgs": ["cangjie", "cangjie-sig", "cangjie-tpc"],
      "allowedRepos": [],
      "deniedRepos": []
    },
    "transport": "native"
  }
}
```

验收标准：

- 只有命中 `writebackScope` 的仓库允许自动写回；`monitor.orgs` 只控制扫描范围。
- Metis 安全审查拒绝、检测到本地路径、检测到密钥、重复回复、人审要求时，都不会写回。
- 写回评论包含 `<!-- gitcodemonitor:auto-reply:v1 -->` 标记，后续扫描会忽略自生成评论。

## 当前不建议配置 ACP

当前 GitCodeMonitor 主链路是：

```text
GitCodeMonitor service-plugin -> Metis Gateway/agent runtime/model -> GitCodeMonitor apply_result
```

代码中存在 ACP client 原语，但当前 JSON 配置解析没有把 ACP 字段作为正式运行路径暴露出来。现阶段不要在 GitCodeMonitor 配置里尝试配置 ACP。后续如果要支持长流程 ACP，应单独补方案、补配置解析、补联调和测试。

## 常见误区

- `gitcode.token` 是 GitCode API token，不是飞书、Telegram 或 Metis 的 token。
- 飞书和 Telegram 配置属于 Metis Gateway/channel，不属于 GCM。
- `monitor.dryRun=true` 阻止 GCM 写回 GitCode；IM 通知是否发送由 Metis Gateway/channel 配置决定。
- `monitor.autoReply=true` 不等于一定写回，还需要满足所有写回门禁。
- `monitor.orgs` 是扫描范围，`monitor.writebackScope` 是写回范围，两者不是同一个开关。
- `repoAllowlist` 只是旧配置诊断字段，不再授权写回。新配置必须使用 `writebackScope.allowedOrgs`、`writebackScope.allowedRepos` 和 `writebackScope.deniedRepos`。

## 依据

- 本项目配置解析与默认值：`src/core.cj` 中 `MonitorConfig`、`applyGitCodeSection`、`applyMetisSection`、`applyMonitorSection`。
- 本项目 service-plugin 运行时：`src/plugin_runtime.cj` 中 `requiredGitCodeMonitorCapabilityIds`、`handleGcmPluginInputLineWithJobs`、`handleGcmWritebackApplyResult`。
- 本项目写回实现：`src/core.cj` 中 `GitCodeCommentWriter`、`GitCodeApiClient`。
- 本项目 GitCode API 请求构造：`src/core.cj` 中 `GitCodeApiClient`。
- GitCode/AtomGit API 文档：<https://docs.atomgit.com/docs/apis/>。
