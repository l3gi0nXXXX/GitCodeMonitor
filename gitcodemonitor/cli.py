from __future__ import annotations

import argparse
import subprocess
import sys
from typing import Optional

from .api import GitCodeClient
from .config import load_config
from .refresh import refresh_repositories
from .state import StateStore


def doctor_main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="gitcodemonitor-doctor")
    parser.add_argument("--config")
    args = parser.parse_args(argv)
    config = load_config(args.config)
    print("GitCodeMonitor doctor ok")
    print(f"orgs={','.join(config.orgs)}")
    print(f"fullScanIntervalMinutes={config.full_scan_interval_minutes}")
    print(f"jitterSeconds={config.jitter_seconds}")
    return 0


def scan_once_main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="gitcodemonitor-scan-once")
    parser.add_argument("--config")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    config = load_config(args.config)
    store = StateStore(config.state_path)
    state = store.load()
    if args.dry_run or config.dry_run:
        state.record_audit("scan_once", "dry_run")
        store.save(state)
        print("scan-once dry-run complete")
        return 0
    repos = refresh_repositories(GitCodeClient(config.gitcode_base_url), config.orgs, state)
    store.save(state)
    print(f"scan-once complete repos={len(repos)}")
    return 0


def tests_main(argv: Optional[list[str]] = None) -> int:
    command = [sys.executable, "-m", "unittest", "discover", "-s", "tests"]
    if argv:
        command.extend(argv)
    return subprocess.call(command)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m gitcodemonitor")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor")
    subparsers.add_parser("scan-once")
    subparsers.add_parser("tests")
    args, rest = parser.parse_known_args(argv)
    if args.command == "doctor":
        return doctor_main(rest)
    if args.command == "scan-once":
        return scan_once_main(rest)
    return tests_main(rest)


if __name__ == "__main__":
    raise SystemExit(main())
