# GitCodeMonitor

## Project Introduction

GitCodeMonitor is an independent long-running monitor service for GitCode
community activity. It watches public repositories under the configured Cangjie
organizations, normalizes new issues, pull requests, and comments, applies local
filters, sends notifications, and calls Metis through MCP for structured
summaries, reply drafts, and safety review.

GitCode credentials, scan cursors, notification delivery state, dry-run audit,
and final GitCode writeback decisions stay inside this project. Metis does not
receive GitCode credentials and does not write GitCode comments.

The current baseline is intentionally offline-testable. It provides
configuration, secret resolution, fake GitCode transport, scheduler, state
store, filters, notifiers, MCP client primitives, writeback guards, and optional
ACP client primitives without using real network calls in tests.

## Usage

Requirements:

- Python 3.9 or newer.
- No third-party runtime dependency is required for the current baseline.

Useful commands:

```bash
python3 -m gitcodemonitor doctor
python3 -m gitcodemonitor scan-once --dry-run
python3 -m gitcodemonitor tests
python3 -m unittest discover -s tests -v
```

Installed console scripts, when installed as a package:

```bash
gitcodemonitor-doctor
gitcodemonitor-scan-once --dry-run
gitcodemonitor-tests
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
cd /Users/l3gi0n/work/workspace_cangjie/GitCodeMonitor
python3 -m compileall -q gitcodemonitor tests
python3 -m unittest discover -s tests -v
python3 -m gitcodemonitor doctor
python3 -m gitcodemonitor scan-once --dry-run
```

For local configuration, create a JSON file and pass it with `--config`:

```json
{
  "orgs": ["cangjie", "cangjie-sig", "cangjie-tpc"],
  "fullScanIntervalMinutes": 10,
  "dryRun": true,
  "writebackEnabled": false
}
```

Then run:

```bash
python3 -m gitcodemonitor doctor --config ./metis-gitcode-monitor.json
python3 -m gitcodemonitor scan-once --config ./metis-gitcode-monitor.json --dry-run
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
python3 -m compileall -q gitcodemonitor tests
python3 -m unittest discover -s tests -v
```
