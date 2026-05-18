from __future__ import annotations

from typing import Any

from .events import MonitorEvent


FORBIDDEN_KEYS = {"credential", "credentials", "token", "cookie", "authorization", "evidence_pack"}


def map_event_to_tool_call(event: MonitorEvent) -> tuple[str, dict[str, Any]]:
    arguments = {
        "kind": event.kind,
        "org": event.org,
        "repo": event.repo,
        "number": event.number,
        "title": event.title,
        "body": event.body,
        "author": event.author,
        "url": event.url,
        "updatedAt": event.updated_at,
    }
    lowered = {key.lower() for key in arguments}
    if lowered & FORBIDDEN_KEYS:
        raise AssertionError("tool mapper includes forbidden credential fields")
    if event.kind == "pull_request":
        return "gitcode_pr_draft_reply", arguments
    return "gitcode_issue_draft_reply", arguments
