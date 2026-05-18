from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional, Union


DEFAULT_ORGS = ("cangjie", "cangjie-sig", "cangjie-tpc")
DEFAULT_FULL_SCAN_INTERVAL_MINUTES = 10
MIN_FULL_SCAN_INTERVAL_MINUTES = 5
MAX_JITTER_SECONDS = 30


@dataclass(frozen=True)
class MonitorConfig:
    orgs: tuple[str, ...] = DEFAULT_ORGS
    full_scan_interval_minutes: int = DEFAULT_FULL_SCAN_INTERVAL_MINUTES
    jitter_seconds: int = MAX_JITTER_SECONDS
    gitcode_base_url: str = "https://gitcode.com/api/v5"
    state_path: str = ".gitcodemonitor/state.json"
    self_marker: str = "<!-- metis-gitcode-monitor -->"
    dry_run: bool = True
    writeback_enabled: bool = False
    writeback_allowlist: tuple[str, ...] = field(default_factory=tuple)
    acp_enabled: bool = False
    acp_allowed_tasks: tuple[str, ...] = field(default_factory=tuple)

    def validate(self) -> "MonitorConfig":
        if len(self.orgs) != 3:
            raise ValueError("config must contain exactly three default organizations")
        if self.full_scan_interval_minutes < MIN_FULL_SCAN_INTERVAL_MINUTES:
            raise ValueError("fullScanIntervalMinutes must be at least 5")
        if self.jitter_seconds < 0 or self.jitter_seconds > MAX_JITTER_SECONDS:
            raise ValueError("jitterSeconds must be between 0 and 30")
        return self


def _tuple(value: Any, default: tuple[str, ...]) -> tuple[str, ...]:
    if value is None:
        return default
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError("expected a list of strings")
    return tuple(value)


def load_config(path: Optional[Union[str, Path]] = None) -> MonitorConfig:
    data: dict[str, Any] = {}
    if path is not None:
        config_path = Path(path)
        if config_path.exists():
            with config_path.open("r", encoding="utf-8") as handle:
                data = json.load(handle)

    config = MonitorConfig(
        orgs=_tuple(data.get("orgs"), DEFAULT_ORGS),
        full_scan_interval_minutes=int(
            data.get("fullScanIntervalMinutes", DEFAULT_FULL_SCAN_INTERVAL_MINUTES)
        ),
        jitter_seconds=int(data.get("jitterSeconds", MAX_JITTER_SECONDS)),
        gitcode_base_url=str(data.get("gitcodeBaseUrl", "https://gitcode.com/api/v5")),
        state_path=str(data.get("statePath", ".gitcodemonitor/state.json")),
        self_marker=str(data.get("selfMarker", "<!-- metis-gitcode-monitor -->")),
        dry_run=bool(data.get("dryRun", True)),
        writeback_enabled=bool(data.get("writebackEnabled", False)),
        writeback_allowlist=_tuple(data.get("writebackAllowlist"), ()),
        acp_enabled=bool(data.get("acpEnabled", False)),
        acp_allowed_tasks=_tuple(data.get("acpAllowedTasks"), ()),
    )
    return config.validate()
