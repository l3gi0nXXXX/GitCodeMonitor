from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Optional


@dataclass(frozen=True)
class ACPRun:
    run_id: str
    task: str
    status: str
    freshness_policy: Optional[dict[str, Any]]


class FakeACPTransport:
    def __init__(self):
        self.runs: dict[str, ACPRun] = {}
        self.calls: list[tuple[str, dict[str, Any]]] = []

    async def start(self, payload: dict[str, Any]) -> ACPRun:
        self.calls.append(("start", payload))
        run = ACPRun(f"run-{len(self.runs) + 1}", payload["task"], "running", payload.get("freshnessPolicy"))
        self.runs[run.run_id] = run
        return run

    async def status(self, run_id: str) -> ACPRun:
        self.calls.append(("status", {"runId": run_id}))
        return self.runs[run_id]

    async def cancel(self, run_id: str) -> ACPRun:
        self.calls.append(("cancel", {"runId": run_id}))
        run = self.runs[run_id]
        cancelled = ACPRun(run.run_id, run.task, "cancelled", run.freshness_policy)
        self.runs[run_id] = cancelled
        return cancelled


class ACPClient:
    def __init__(
        self,
        enabled: bool = False,
        allowed_tasks: tuple[str, ...] = (),
        transport: Optional[FakeACPTransport] = None,
    ):
        self.enabled = enabled
        self.allowed_tasks = allowed_tasks
        self.transport = transport or FakeACPTransport()

    async def start_run(self, task: str, freshnessPolicy: Optional[dict[str, Any]] = None) -> ACPRun:
        if not self.enabled:
            raise RuntimeError("ACP client is disabled by default")
        if task not in self.allowed_tasks:
            raise PermissionError(f"ACP task is not allowed: {task}")
        return await self.transport.start({"task": task, "freshnessPolicy": freshnessPolicy})

    async def status(self, run_id: str) -> ACPRun:
        return await self.transport.status(run_id)

    async def cancel(self, run_id: str) -> ACPRun:
        return await self.transport.cancel(run_id)
