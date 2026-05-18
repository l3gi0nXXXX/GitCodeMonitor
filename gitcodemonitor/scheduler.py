from __future__ import annotations

import random
import time
from dataclasses import dataclass
from typing import Callable, Optional, Union

from .config import MonitorConfig
from .state import MonitorState


class SystemClock:
    def now(self) -> float:
        return time.time()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


@dataclass
class FakeClock:
    current: float = 0.0

    def now(self) -> float:
        return self.current

    def sleep(self, seconds: float) -> None:
        self.current += seconds


class FullScanScheduler:
    def __init__(
        self,
        config: MonitorConfig,
        state: MonitorState,
        scan: Callable[[], None],
        clock: Optional[Union[SystemClock, FakeClock]] = None,
        rng: Optional[random.Random] = None,
    ):
        self.config = config
        self.state = state
        self.scan = scan
        self.clock = clock or SystemClock()
        self.rng = rng or random.Random()
        self.running = False
        self.next_due = self.clock.now()

    def due(self) -> bool:
        return self.clock.now() >= self.next_due

    def run_once(self) -> bool:
        if self.running:
            self.state.record_audit("full_scan", "skipped_overlapping_scan")
            return False
        if not self.due():
            return False
        self.running = True
        try:
            self.scan()
            self.state.record_audit("full_scan", "ok")
            return True
        finally:
            self.running = False
            jitter = self.rng.randint(0, self.config.jitter_seconds)
            self.next_due = self.clock.now() + self.config.full_scan_interval_minutes * 60 + jitter
