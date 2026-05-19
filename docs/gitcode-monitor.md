# GitCodeMonitor Runtime Notes

GitCodeMonitor owns GitCode API access, scan state, notification audit, MCP client calls, and GitCode comment writeback. Metis is only called through MCP and never receives GitCode credentials.

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
- `scan-once`: runs the offline fake scan baseline.
- `serve`: runs the single-loop serve baseline.
- `probe-gitcode`: prints the redacted GitCode request that would be used for repo probing.
- `probe-mcp`: prints a redacted MCP initialize request.
- `config summary`: prints sanitized configuration.

## State

State is written to the configured data path, defaulting to `data/gitcodemonitor-state.json`. Tests use `/tmp` paths and never write real user home files.
