from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Union


@dataclass
class MonitorState:
    cursors: dict[str, str] = field(default_factory=dict)
    seen: set[str] = field(default_factory=set)
    backoff: dict[str, float] = field(default_factory=dict)
    audit: list[dict[str, Any]] = field(default_factory=list)

    def mark_seen(self, key: str) -> bool:
        if key in self.seen:
            return False
        self.seen.add(key)
        return True

    def record_audit(self, action: str, status: str, **details: Any) -> None:
        self.audit.append(
            {
                "ts": details.pop("ts", time.time()),
                "action": action,
                "status": status,
                **details,
            }
        )


class StateStore:
    def __init__(self, path: Union[str, Path]):
        self.path = Path(path)

    def load(self) -> MonitorState:
        if not self.path.exists():
            return MonitorState()
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        return MonitorState(
            cursors=dict(raw.get("cursors", {})),
            seen=set(raw.get("seen", [])),
            backoff=dict(raw.get("backoff", {})),
            audit=list(raw.get("audit", [])),
        )

    def save(self, state: MonitorState) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "cursors": state.cursors,
            "seen": sorted(state.seen),
            "backoff": state.backoff,
            "audit": state.audit,
        }
        self.path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
