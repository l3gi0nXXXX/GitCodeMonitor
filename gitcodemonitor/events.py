from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal


EventKind = Literal["issue", "pull_request", "comment"]


@dataclass(frozen=True)
class MonitorEvent:
    org: str
    repo: str
    number: int
    title: str
    body: str
    author: str
    url: str
    updated_at: str
    evidence_pack: dict[str, Any] = field(default_factory=dict)
    kind: EventKind = "issue"

    @property
    def idempotency_key(self) -> str:
        return f"{self.kind}:{self.org}/{self.repo}:{self.number}:{self.updated_at}"

    @property
    def text(self) -> str:
        return f"{self.title}\n{self.body}".strip()


@dataclass(frozen=True)
class IssueEvent(MonitorEvent):
    kind: EventKind = "issue"


@dataclass(frozen=True)
class PullRequestEvent(MonitorEvent):
    kind: EventKind = "pull_request"


@dataclass(frozen=True)
class CommentEvent(MonitorEvent):
    comment_id: int = 0
    kind: EventKind = "comment"

    @property
    def idempotency_key(self) -> str:
        return f"{self.kind}:{self.org}/{self.repo}:{self.number}:{self.comment_id}:{self.updated_at}"

