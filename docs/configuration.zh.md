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
| `monitor.orgs` | `["cangjie", "cangjie-sig", "cangjie-tpc"]` | 需要扫描的 GitCode 组织列表。当前目标就是这三个组织。 |
| `monitor.statePath` | `data/gitcodemonitor-state.json` | 扫描游标、通知审计、写回审计的本地状态文件。建议填 `.gitcodemonitor/state.json`。 |
| `monitor.fullScanIntervalMinutes` | `10` | 全量扫描间隔，单位分钟。生产配置不能低于 5。当前方案建议 10 分钟。 |
| `monitor.jitterSeconds` | `30` | 扫描抖动秒数，用于避免固定时间点集中请求。当前校验要求不超过 30。 |
| `monitor.dryRun` | `true` | 是否禁止 GitCode 自动写回。`true` 表示不写回 GitCode；`false` 才允许进入写回门禁。 |
| `monitor.autoReply` | `false` | 是否启用自动回复。即使设为 `true`，仍需 `dryRun=false`、MCP 安全通过、repo allowlist 命中、无重复写回、无敏感信息和本地路径，才会真正写回。 |
| `monitor.notifyNetworkEnabled` | `false` | 是否启用真实飞书/Telegram 发送。`false` 时只记录 dry-run audit，不发网络请求。 |
| `monitor.repoAllowlist` | `[]` | 允许自动写回的仓库白名单，格式是 `owner/repo`，例如 `["Cangjie/community"]`。大小写按当前代码做兼容处理。 |
| `monitor.transport` | `native` | HTTP 传输方式。默认 `native`。`curl` 只作为显式回退。 |

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
    "repoAllowlist": ["Cangjie/community"],
    "transport": "native"
  }
}
```

验收标准：

- 只有 `repoAllowlist` 中的仓库允许自动写回。
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
- `repoAllowlist` 只控制自动写回范围，不控制扫描范围。扫描范围由 `monitor.orgs` 和 GitCode 公开仓库发现逻辑控制。

## 依据

- 本项目配置解析与默认值：`src/core.cj` 中 `MonitorConfig`、`applyGitCodeSection`、`applyFeishuSection`、`applyTelegramSection`、`applyMetisSection`、`applyMonitorSection`。
- 本项目通知构造：`src/core.cj` 中 `buildFeishuPayload`、`buildTelegramPayload`。
- 本项目 GitCode API 请求构造：`src/core.cj` 中 `GitCodeApiClient`。
- GitCode/AtomGit API 文档：<https://docs.atomgit.com/docs/apis/>。
- Telegram Bot API：<https://core.telegram.org/bots/api>，`sendMessage` 使用 `chat_id` 和 `text` 参数，`getUpdates` 可获取 bot 收到的更新。
- 飞书开放平台自定义机器人文档：<https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot>，自定义机器人通过 webhook 接收消息。
