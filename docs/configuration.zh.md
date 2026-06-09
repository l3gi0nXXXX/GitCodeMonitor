# GitCodeMonitor 配置说明

本文档说明 GitCodeMonitor 配置文件中每一项应该填写什么、从哪里获取，以及开启真实网络、通知、MCP 调用和自动写回时的安全边界。

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
- 删除 `monitor.statePath` 指向的状态文件会导致已处理事件重新被扫描、通知和调用 MCP。

## 最小安全配置

这是只验证 GitCode 配置、不开通知、不开写回的最小配置：

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
    "notifyNetworkEnabled": false,
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
- Issue 评论：`GET /repos/{owner}/{repo}/issues/comments?...`
- PR 评论：`GET /repos/{owner}/{repo}/pulls/{number}/comments?...`
- 自动回复写回：`POST /repos/{owner}/{repo}/issues/{number}/comments` 或 `POST /repos/{owner}/{repo}/pulls/{number}/comments`

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
5. GCM 不调用 LLM、不通知 TG/Feishu bot、不执行 GitCode 写回。

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

## Metis MCP 配置

| 字段 | 是否建议填写 | 应该填什么 |
| --- | --- | --- |
| `metis.mcpEndpoint` | 需要大模型总结/回复时必填 | Metis 暴露的 MCP HTTP 入口，例如 `http://127.0.0.1:8787/mcp`。GitCodeMonitor 只把已过滤后的 PR/Issue 上下文发给 Metis，不把 GitCode 凭证发给 Metis。 |
| `metis.mcpServiceToken` | 按 Metis 服务端要求填写 | 如果 Metis MCP 入口要求服务 token，就填对应 Bearer token；如果 Metis 不要求鉴权，留空。 |

没有配置 `metis.mcpEndpoint` 时，GitCodeMonitor 仍可做扫描和通知，但不能从 Metis 获取总结、回复草稿和安全审查结果。

## 飞书通知配置

| 字段 | 是否建议填写 | 应该填什么 |
| --- | --- | --- |
| `feishu.webhook` | 需要飞书通知时必填 | 飞书群自定义机器人的 Incoming Webhook URL，形如 `https://open.feishu.cn/open-apis/bot/v2/hook/<webhook-id>`。海外租户可能是 `https://open.larksuite.com/open-apis/bot/v2/hook/<webhook-id>`。 |

`feishu.webhook` 不是飞书 App ID、App Secret、tenant token，也不是 GitCode token。它是你在飞书群里添加“自定义机器人”后复制出来的完整 webhook 地址。

只有满足以下条件时才会真实发送飞书通知：

- `monitor.notifyNetworkEnabled=true`
- `feishu.webhook` 不为空
- 扫描到的事件没有被过滤规则忽略

`monitor.dryRun=true` 不会阻止飞书通知。`dryRun` 只阻止 GitCode 自动写回。

## Telegram 通知配置

| 字段 | 是否建议填写 | 应该填什么 |
| --- | --- | --- |
| `telegram.botToken` | 需要 Telegram 通知时必填 | BotFather 创建 bot 后给出的 token，形如 `<digits>:<secret>`。 |
| `telegram.chatId` | 需要 Telegram 通知时必填 | 目标私聊、群或频道的 chat id。私聊通常是正数，群或超级群通常是负数。建议作为字符串填写。 |

获取 `telegram.chatId` 的常用方法：

1. 在 Telegram 中通过 BotFather 创建 bot，拿到 `telegram.botToken`。
2. 给 bot 发一条消息，或者把 bot 加入目标群并在群里发一条消息。
3. 访问 `https://api.telegram.org/bot<telegram.botToken>/getUpdates`。
4. 在返回 JSON 中找到 `message.chat.id`，把这个值填入 `telegram.chatId`。

发送通知时，GitCodeMonitor 会调用：

```text
POST https://api.telegram.org/bot<telegram.botToken>/sendMessage
```

如果群里看不到 `getUpdates` 返回，通常是 bot 没收到群消息、没有被加入目标群，或者 BotFather 的 group privacy 设置影响了可见消息。

## Monitor 配置

| 字段 | 默认值 | 应该填什么 |
| --- | --- | --- |
| `monitor.orgs` | `["cangjie", "cangjie-sig", "cangjie-tpc"]` | 需要扫描的 GitCode 组织列表。当前目标就是这三个组织。这个字段只控制扫描范围，不控制自动写回范围。 |
| `monitor.statePath` | `data/gitcodemonitor-state.json` | 扫描游标、通知审计、写回审计的本地状态文件。建议填 `.gitcodemonitor/state.json`。 |
| `monitor.fullScanIntervalMinutes` | `10` | 全量扫描间隔，单位分钟。生产配置不能低于 5。当前方案建议 10 分钟。 |
| `monitor.jitterSeconds` | `30` | 扫描抖动秒数，用于避免固定时间点集中请求。当前校验要求不超过 30。 |
| `monitor.dryRun` | `true` | 是否禁止 GitCode 自动写回。`true` 表示不写回 GitCode；`false` 才允许进入写回门禁。 |
| `monitor.autoReply` | `false` | 是否启用自动回复。即使设为 `true`，仍需 `dryRun=false`、MCP 安全通过、writebackScope 命中、无重复写回、无敏感信息和本地路径，才会真正写回。 |
| `monitor.notifyNetworkEnabled` | `false` | 是否启用真实飞书/Telegram 发送。`false` 时只记录 dry-run audit，不发网络请求。 |
| `monitor.writebackScope.allowedOrgs` | `[]` | 允许自动写回的组织列表，格式是 GitCode owner 名，例如 `["cangjie", "cangjie-sig", "cangjie-tpc"]`。只控制写回范围，不扩大或缩小 `monitor.orgs` 扫描范围。 |
| `monitor.writebackScope.allowedRepos` | `[]` | 允许自动写回的仓库列表，格式是 `owner/repo`，例如 `["Cangjie/community"]`。用于补充组织外或少量精确仓库授权。 |
| `monitor.writebackScope.deniedRepos` | `[]` | 禁止自动写回的仓库列表，格式是 `owner/repo`。优先级最高，即使命中 `allowedOrgs` 或 `allowedRepos` 也不会写回。 |
| `monitor.repoAllowlist` | `[]` | 兼容字段，旧配置入口。格式是 `owner/repo`，语义等价于合并进 `monitor.writebackScope.allowedRepos`；新配置建议使用 `writebackScope`。 |
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

### 阶段 1：GitCode 扫描 dry-run

用于确认 GitCode token、组织仓库扫描、状态文件是否正常：

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
    "notifyNetworkEnabled": false,
    "transport": "native"
  }
}
```

验证命令：

```bash
cjpm run --name gitcodemonitor --run-args "--config .gitcodemonitor/gcm-live.json doctor"
cjpm run --name gitcodemonitor --run-args "--config .gitcodemonitor/gcm-live.json probe-gitcode"
cjpm run --name gitcodemonitor --run-args "--config .gitcodemonitor/gcm-live.json scan-once"
```

验收标准：

- `doctor` 中 `gitCodeAuth=present`。
- 输出不包含真实 token、cookie、webhook、bot token。
- `scan-once` 能完成，不写 GitCode 评论，不发送飞书/Telegram。

### 阶段 2：开启飞书和 Telegram 通知

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>"
  },
  "feishu": {
    "webhook": "https://open.feishu.cn/open-apis/bot/v2/hook/<webhook-id>"
  },
  "telegram": {
    "botToken": "<Telegram bot token>",
    "chatId": "<Telegram chat id>"
  },
  "monitor": {
    "statePath": ".gitcodemonitor/state.json",
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": true,
    "autoReply": false,
    "notifyNetworkEnabled": true,
    "transport": "native"
  }
}
```

验收标准：

- 未被过滤的事件会同时发到飞书和 Telegram。
- GitCode 仍不会被自动回复，因为 `dryRun=true` 且 `autoReply=false`。
- 通知内容包含原始事件摘要和 PR/Issue 链接。

### 阶段 3：接入 Metis MCP，但仍不写回

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>"
  },
  "metis": {
    "mcpEndpoint": "http://127.0.0.1:8787/mcp",
    "mcpServiceToken": "<optional Metis MCP service token>"
  },
  "monitor": {
    "statePath": ".gitcodemonitor/state.json",
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": true,
    "autoReply": false,
    "notifyNetworkEnabled": false,
    "transport": "native"
  }
}
```

验收标准：

- `probe-mcp` 能生成已脱敏的 MCP initialize 请求。
- 扫描事件可以进入 MCP 总结/回复草稿链路。
- GitCode 不发生写回。

### 阶段 4：受控开启自动写回

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "<GitCode API access token>"
  },
  "metis": {
    "mcpEndpoint": "http://127.0.0.1:8787/mcp",
    "mcpServiceToken": "<optional Metis MCP service token>"
  },
  "monitor": {
    "statePath": ".gitcodemonitor/state.json",
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": false,
    "autoReply": true,
    "notifyNetworkEnabled": true,
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
- MCP 安全审查拒绝、检测到本地路径、检测到密钥、重复回复、人审要求时，都不会写回。
- 写回评论包含 `<!-- gitcodemonitor:auto-reply:v1 -->` 标记，后续扫描会忽略自生成评论。

## 当前不建议配置 ACP

当前 GitCodeMonitor 主链路是：

```text
GitCodeMonitor -> Metis MCP -> Metis agent runtime/model
```

代码中存在 ACP client 原语，但当前 JSON 配置解析没有把 ACP 字段作为正式运行路径暴露出来。现阶段不要在 GitCodeMonitor 配置里尝试配置 ACP。后续如果要支持长流程 ACP，应单独补方案、补配置解析、补联调和测试。

## 常见误区

- `gitcode.token` 是 GitCode API token，不是飞书、Telegram 或 Metis 的 token。
- `feishu.webhook` 是飞书自定义机器人 webhook 完整 URL，不是飞书应用凭证。
- `telegram.chatId` 不是 bot token，需要通过 `getUpdates` 或 Telegram 管理工具查目标会话 id。
- `monitor.dryRun=true` 只阻止 GitCode 写回，不阻止飞书/Telegram 真实通知；通知是否真实发送看 `monitor.notifyNetworkEnabled`。
- `monitor.autoReply=true` 不等于一定写回，还需要满足所有写回门禁。
- `monitor.orgs` 是扫描范围，`monitor.writebackScope` 是写回范围，两者不是同一个开关。
- `repoAllowlist` 只是旧配置兼容字段，不推荐作为几百仓库的生产配置主路径。新配置应使用 `writebackScope.allowedOrgs`、`writebackScope.allowedRepos` 和 `writebackScope.deniedRepos`。

## 依据

- 本项目配置解析与默认值：`src/core.cj` 中 `MonitorConfig`、`applyGitCodeSection`、`applyFeishuSection`、`applyTelegramSection`、`applyMetisSection`、`applyMonitorSection`。
- 本项目通知构造：`src/core.cj` 中 `buildFeishuPayload`、`buildTelegramPayload`。
- 本项目 GitCode API 请求构造：`src/core.cj` 中 `GitCodeApiClient`。
- GitCode/AtomGit API 文档：<https://docs.atomgit.com/docs/apis/>。
- Telegram Bot API：<https://core.telegram.org/bots/api>，`sendMessage` 使用 `chat_id` 和 `text` 参数，`getUpdates` 可获取 bot 收到的更新。
- 飞书开放平台自定义机器人文档：<https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot>，自定义机器人通过 webhook 接收消息。
