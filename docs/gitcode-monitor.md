# GitCodeMonitor Runtime Notes

GitCodeMonitor owns GitCode API access, scan state, dry-run/writeback audit, and GitCode comment writeback execution. Metis integrates with it only through service-plugin mode and never receives GitCode credentials.

## Review Contract

GCM to Metis review events are governed by these contract documents:

- [gcm-metis-gitcode-review-contract-v1.md](gcm-metis-gitcode-review-contract-v1.md)
- [gcm-gitcode-review-domain-model-v1.md](gcm-gitcode-review-domain-model-v1.md)
- [gcm-gitcode-review-footer-format-v1.md](gcm-gitcode-review-footer-format-v1.md)

`gitcode.event.accepted` keeps legacy top-level fields and adds `contractVersion` plus `reviewRequest`.

For field-by-field configuration guidance, especially `gitcode.token`,
`monitor.writebackScope`, and staged dry-run to writeback rollout, see
[configuration.zh.md](configuration.zh.md).

## Safety Defaults

- `dryRun` defaults to `true`.
- `autoReply` defaults to `false`.
- Writeback is disabled by default because `dryRun=true` and `autoReply=false`.
- Writeback requires `dryRun=false`, `autoReply=true`, a writeback scope match, Metis safety approval, no human review flag, no detected secret or local path, and no duplicate reply audit.
- GitCode comments written by the monitor include `<!-- gitcodemonitor:auto-reply:v1 -->` so later scans can ignore self-generated comments.

## CLI

Use `cjpm run --name gitcodemonitor --run-args <command>`.

Commands:

- `doctor`: prints runtime switch and audit summary without credentials.
- `plugin-stdio`: starts the Metis service-plugin protocol entrypoint.
- `scan-once`, `webhook-http`, and `serve`: return service-plugin-only unsupported diagnostics.
- `probe-gitcode`: prints the redacted GitCode request that would be used for repo probing.
- `probe-mcp`: returns a diagnostic that the MCP client path is unsupported.
- `config summary`: prints sanitized configuration.

Pass `--config <path>` before the command to load an injected config path for tests or local dry-runs. Without it, the monitor reads `$HOME/.metis/metis.json`.

## Configuration

`~/.metis/metis.json` may contain the GitCode and monitor sections below. Tests must use injected temporary paths and must not read real user files.

```json
{
  "gitcode": {
    "baseUrl": "https://api.gitcode.com/api/v5",
    "authMode": "PRIVATE-TOKEN",
    "token": "redacted",
    "cookie": "redacted",
    "transport": "native"
  },
  "monitor": {
    "fullScanIntervalMinutes": 10,
    "jitterSeconds": 30,
    "dryRun": true,
    "autoReply": false,
    "writebackScope": {
      "allowedOrgs": ["cangjie", "cangjie-sig", "cangjie-tpc"],
      "allowedRepos": [],
      "deniedRepos": []
    },
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

The GitCode response parser accepts common array and envelope shapes for organization repositories, issues, pull requests, comments, and comment writeback responses. HTTP status codes map to monitor error kinds such as `unauthorized`, `forbidden`, `not_found`, `rate_limited`, and `server_error`; `Retry-After` drives backoff where available.

## State

State is written to the configured data path, defaulting to
`.gitcodemonitor/state.json`. Tests use temporary paths and never write real
user home files.
