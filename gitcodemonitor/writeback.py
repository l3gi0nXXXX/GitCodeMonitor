from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from .secrets import contains_secret
from .state import MonitorState


DEFAULT_MARKER = "<!-- metis-gitcode-monitor -->"


@dataclass(frozen=True)
class WritebackPolicy:
    enabled: bool = False
    allowlist: tuple[str, ...] = ()
    marker: str = DEFAULT_MARKER


class FakeGitCodeCommentWriter:
    def __init__(self, existing_comments: Optional[dict[str, list[str]]] = None):
        self.existing_comments = existing_comments or {}
        self.writes: list[tuple[str, int, str]] = []

    def comments_for(self, repo: str, number: int) -> list[str]:
        return self.existing_comments.get(f"{repo}#{number}", [])

    def create_comment(self, repo: str, number: int, body: str) -> None:
        self.writes.append((repo, number, body))


class WritebackService:
    def __init__(self, writer: FakeGitCodeCommentWriter, policy: WritebackPolicy, state: MonitorState):
        self.writer = writer
        self.policy = policy
        self.state = state

    def comment(self, repo: str, number: int, body: str, dry_run: bool = False) -> bool:
        if not self.policy.enabled:
            self.state.record_audit("writeback", "blocked_disabled", repo=repo, number=number)
            return False
        if repo not in self.policy.allowlist:
            self.state.record_audit("writeback", "blocked_not_allowlisted", repo=repo, number=number)
            return False
        if contains_secret(body):
            self.state.record_audit("writeback", "blocked_secret_scan", repo=repo, number=number)
            return False
        if any(self.policy.marker in comment for comment in self.writer.comments_for(repo, number)):
            self.state.record_audit("writeback", "skipped_duplicate_marker", repo=repo, number=number)
            return False
        marked_body = f"{body.rstrip()}\n\n{self.policy.marker}"
        if dry_run:
            self.state.record_audit("writeback", "dry_run", repo=repo, number=number)
            return True
        self.writer.create_comment(repo, number, marked_body)
        self.state.record_audit("writeback", "delivered", repo=repo, number=number)
        return True
