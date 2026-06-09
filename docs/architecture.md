# GitCodeMonitor Cangjie Baseline

This repository is an independent Cangjie `cjpm` project. It owns GitCode
scanning, event filtering, state, dry-run audit, and the final GitCode
writeback executor. Metis integration is service-plugin-only; tests use fake
transports and do not perform real network calls.

Implemented baseline areas:

- `test/` is a separate `cjpm` unittest package. It keeps test code under
  `test/src` and carries a test-package copy of the offline core so Cangjie
  unittest can compile the tests from the required test tree.
- Config defaults for the three Cangjie organizations, 10 minute full scan
  cadence, 30 second jitter, dry-run enabled, auto reply disabled, and ACP
  disabled.
- Secret detection and redaction helpers for token, cookie, password,
  Authorization, and Telegram bot token patterns.
- GitCode event model and filters for `CangjiePL`, exact `start build`, and
  the self marker.
- Fake-clock friendly full scan scheduler with overlap guard and in-memory
  state for seen events, legacy diagnostic MCP markers, replies, and audit
  records.
- Fake GitCode transport for repo refresh, pagination, event scan, and stable
  error mapping.
- Service-plugin protocol handling for accepted events, status, scan jobs, and
  `gitcode.writeback.apply_result`.
- Writeback gate for dry-run, autoReply, writeback scope including allowed orgs,
  allowed repos, denied repos, safety result, duplicate reply, local secret
  detection, and self marker checks.
- Optional ACP run lifecycle structures, task allowlist, and freshness policy
  fields. ACP is disabled by default and its result is audit/human-review
  material only.
