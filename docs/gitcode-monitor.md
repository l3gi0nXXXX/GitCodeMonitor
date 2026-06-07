# GitCodeMonitor Runtime Notes

GitCodeMonitor owns GitCode API access, scan state, notification audit, MCP client calls, and GitCode comment writeback. Metis is only called through MCP and never receives GitCode credentials.

## Review Contract

GCM to Metis review events are governed by these contract documents:

- [gcm-metis-gitcode-review-contract-v1.md](gcm-metis-gitcode-review-contract-v1.md)
- [gcm-gitcode-review-domain-model-v1.md](gcm-gitcode-review-domain-model-v1.md)
- [gcm-gitcode-review-footer-format-v1.md](gcm-gitcode-review-footer-format-v1.md)

`gitcode.event.accepted` keeps legacy top-level fields and adds `contractVersion` plus `reviewRequest`.

For field-by-field configuration guidance, especially `feishu.webhook`,
`telegram.botToken`, `telegram.chatId`, `gitcode.token`, and staged dry-run to
writeback rollout, see [configuration.zh.md](configuration.zh.md).

## Safety Defaults

- `dryRun` defaults to `true`.
- `autoReply` defaults to `false`.
- Feishu and Telegram HTTP sending is disabled unless `notifyNetworkEnabled=true`.
- Writeback requires `dryRun=false`, `autoReply=true`, a repo allowlist match, MCP safety approval, no human review flag, no detected secret or local path, and no duplicate reply audit.
- GitCode comments written by the monitor include `<!-- gitcodemonitor:auto-reply:v1 -->` so later scans can ignore self-generated comments.

## CLI

Use `cjpm run --name gitcodemonitor --run-args <command>`.

Commands:

- `doctor`: prints runtime switch and audit summary without credentials.
- `scan-once`: runs one scan using the configured runtime surfaces.
- `scan-once --offline-fixture`: runs the offline fake scan baseline.
- `serve`: starts the monitor lifecycle path with the configured full-scan cadence and overlap guard.
- `probe-gitcode`: prints the redacted GitCode request that would be used for repo probing.
- `probe-mcp`: prints a redacted MCP initialize request.
- `config summary`: prints sanitized configuration.

Pass `--config <path>` before the command to load an injected config path for tests or local dry-runs. Without it, the monitor reads `$HOME/.metis/metis.json`.

## Configuration

`~/.metis/metis.json` may contain the GitCode, notification, Metis MCP, and monitor sections below. Tests must use injected temporary paths and must not read real user files.

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "redacted",
    "cookie": "redacted",
    "transport": "native"
  },
  "metis": {
    "mcpEndpoint": "http://127.0.0.1:8787/mcp",
    "mcpServiceToken": "redacted"
  },
  "feishu": {
    "webhook": "redacted"
  },
  "telegram": {
    "botToken": "redacted",
    "chatId": "redacted"
  },
  "monitor": {
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": true,
    "autoReply": false,
    "notifyNetworkEnabled": false,
    "repoAllowlist": ["cangjie/compiler"],
    "statePath": ".gitcodemonitor/state.json",
    "transport": "native"
  }
}
```

Doctor, probe, summary, and request log helpers report credential presence only and redact tokens, cookies, authorization headers, bot tokens, and access-token query parameters.

## Real HTTP Surfaces

GitCode API requests are built by `GitCodeApiClient` and executed through
injectable senders. Unit tests use `FakeHttpSender`; production defaults to the
native Cangjie HTTP sender. `curl` remains available only as an explicit
diagnostic fallback via `transport=curl`.

The GitCode response parser accepts common array and envelope shapes for organization repositories, issues, pull requests, and comments. HTTP status codes map to monitor error kinds such as `unauthorized`, `forbidden`, `not_found`, `rate_limited`, and `server_error`; `Retry-After` drives backoff where available.

## State

State is written to the configured data path, defaulting to
`data/gitcodemonitor-state.json`. Local live runs should use an ignored path such
as `.gitcodemonitor/state.json`. Tests use temporary paths and never write real
user home files.
