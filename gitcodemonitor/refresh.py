from __future__ import annotations

from .api import GitCodeClient
from .state import MonitorState


def refresh_repositories(client: GitCodeClient, orgs: tuple[str, ...], state: MonitorState) -> list[dict]:
    repos: list[dict] = []
    for org in orgs:
        org_repos = client.list_repositories(org)
        repos.extend({"org": org, **repo} for repo in org_repos)
        state.cursors[f"repos:{org}"] = str(len(org_repos))
        state.record_audit("repo_refresh", "ok", org=org, count=len(org_repos))
    return repos

