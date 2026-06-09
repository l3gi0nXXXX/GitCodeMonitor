# GitCodeMonitor

## Project Introduction

GitCodeMonitor is an independent Cangjie `cjpm` project for GitCode community
activity monitoring. It watches public repositories under the configured
Cangjie organizations, normalizes new issues, pull requests, and comments,
applies local filters, emits service-plugin events to Metis, and accepts
service-plugin writeback decisions.

GitCode credentials, scan cursors, dry-run audit, and final GitCode writeback
execution stay inside this project. Metis receives only contract-shaped events
and decides whether to ask GCM to write a GitCode comment through
`gitcode.writeback.apply_result`.

The current baseline is intentionally offline-testable. It provides
configuration loading from an injectable Metis config path, secret redaction,
fake and HTTP-backed GitCode transport surfaces, scheduler/service lifecycle,
state store, filters, service-plugin protocol handling, writeback guards, and
optional ACP client primitives without using real network calls in tests.

## Usage

Requirements:

- Cangjie SDK 1.0.0.
- `cjpm` available in `PATH`.

Useful commands:

```bash
cjpm build -i
cjpm test
(cd test && cjpm test)
cjpm run --name gitcodemonitor --run-args doctor
cjpm run --name gitcodemonitor --run-args plugin-stdio
cjpm run --name gitcodemonitor --run-args "--config .gitcodemonitor/gcm-live.json doctor"
```

Default behavior:

- Monitored organizations: `cangjie`, `cangjie-sig`, `cangjie-tpc`.
- Full scan interval: 10 minutes.
- Minimum production scan interval: 5 minutes.
- Scheduler jitter upper bound: 30 seconds.
- Dry-run is enabled by default.
- Automatic writeback is disabled by default.
- Optional ACP support is disabled by default.

## Quick Start

```bash
cd <GitCodeMonitor repo>
cjpm clean
cjpm build -i
cjpm test
(cd test && cjpm clean && cjpm test)
cjpm run --name gitcodemonitor --run-args doctor
```

Do not put real GitCode tokens, bot tokens, cookies, or passwords in test
fixtures or logs.

Runtime configuration defaults to `$HOME/.metis/metis.json`. Tests and local
automation should pass `--config <path>` and use temporary files.

For a Chinese field-by-field configuration guide, including what to put in
`gitcode.token`, `monitor.writebackScope`, and the service-plugin runtime
switches, see
[docs/configuration.zh.md](docs/configuration.zh.md).

## How to Contribute

1. Keep GitCodeMonitor independent from Metis and CangjieCommunityKnowledgeBase.
2. Do not add Metis model-provider calls, MCP clients, or IM bot senders here;
   the production path is Metis service-plugin mode only.
3. Do not build or carry Cangjie knowledge indexes here; that belongs to
   CangjieCommunityKnowledgeBase.
4. Keep real network calls behind injectable transports so unit tests stay
   offline.
5. Add or update tests for config, scanning, filtering, service-plugin
   protocol handling, writeback gates, and credential redaction.
6. Run validation before committing:

```bash
cjpm clean && cjpm build -i && cjpm test
(cd test && cjpm clean && cjpm test)
```
