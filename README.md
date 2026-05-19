# GitCodeMonitor

## Project Introduction

GitCodeMonitor is an independent Cangjie `cjpm` project for GitCode community
activity monitoring. It watches public repositories under the configured
Cangjie organizations, normalizes new issues, pull requests, and comments,
applies local filters, sends notifications, and calls Metis through MCP for
structured summaries, reply drafts, and safety review.

GitCode credentials, scan cursors, notification delivery state, dry-run audit,
and final GitCode writeback decisions stay inside this project. Metis does not
receive GitCode credentials and does not write GitCode comments.

The current baseline is intentionally offline-testable. It provides
configuration, secret redaction, fake GitCode transport, scheduler, state store,
filters, notifiers, MCP client primitives, writeback guards, and optional ACP
client primitives without using real network calls in tests.

## Usage

Requirements:

- Cangjie SDK 1.0.0.
- `cjpm` available in `PATH`.

Useful commands:

```bash
cjpm build -i
cjpm test
(cd test && cjpm test)
cjpm run --run-args doctor
cjpm run --run-args scan-once
cjpm run --run-args tests
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
cd /Users/l3gi0n/work/worktrees/gcm-cangjie-rewrite
cjpm clean
cjpm build -i
cjpm test
(cd test && cjpm clean && cjpm test)
cjpm run --run-args doctor
cjpm run --run-args scan-once
```

Do not put real GitCode tokens, bot tokens, cookies, or passwords in test
fixtures or logs.

## How to Contribute

1. Keep GitCodeMonitor independent from Metis and CangjieCommunityKnowledgeBase.
2. Do not add Metis model-provider calls here; call Metis through MCP clients
   only.
3. Do not build or carry Cangjie knowledge indexes here; that belongs to
   CangjieCommunityKnowledgeBase.
4. Keep real network calls behind injectable transports so unit tests stay
   offline.
5. Add or update tests for config, scanning, filtering, MCP mapping, writeback
   gates, and credential redaction.
6. Run validation before committing:

```bash
cjpm clean && cjpm build -i && cjpm test
(cd test && cjpm clean && cjpm test)
```
