from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from pathlib import Path

from gitcodemonitor.acp import ACPClient, FakeACPTransport
from gitcodemonitor.api import (
    FakeTransport,
    ForbiddenError,
    GitCodeClient,
    NotFoundError,
    RateLimitError,
    Response,
    ServerError,
    UnauthorizedError,
)
from gitcodemonitor.config import DEFAULT_ORGS, load_config
from gitcodemonitor.events import CommentEvent, IssueEvent, PullRequestEvent
from gitcodemonitor.filters import has_self_marker, is_exact_start_build, should_process
from gitcodemonitor.mapper import map_event_to_tool_call
from gitcodemonitor.mcp import FakeMCPServer, MCPClient, schema_hash
from gitcodemonitor.notifiers import FeishuNotifier, TelegramNotifier, notify_with_audit
from gitcodemonitor.refresh import refresh_repositories
from gitcodemonitor.scheduler import FakeClock, FullScanScheduler
from gitcodemonitor.secrets import SecretResolver, contains_secret, redact_text
from gitcodemonitor.state import MonitorState, StateStore
from gitcodemonitor.writeback import FakeGitCodeCommentWriter, WritebackPolicy, WritebackService


class ConfigAndSecretsTests(unittest.TestCase):
    def test_config_defaults_and_bounds(self) -> None:
        config = load_config()
        self.assertEqual(config.orgs, DEFAULT_ORGS)
        self.assertEqual(config.full_scan_interval_minutes, 10)
        self.assertLessEqual(config.jitter_seconds, 30)

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps({"fullScanIntervalMinutes": 4}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "at least 5"):
                load_config(path)

            path.write_text(json.dumps({"jitterSeconds": 31}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "between 0 and 30"):
                load_config(path)

    def test_secret_resolver_and_redaction(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            secret_path = Path(tmp) / "secret.txt"
            secret_path.write_text("file-secret\n", encoding="utf-8")
            resolver = SecretResolver({"GITCODE_TOKEN": "env-secret"})
            secrets = [
                resolver.token("token-secret"),
                resolver.cookie("cookie-secret"),
                resolver.env("GITCODE_TOKEN"),
                resolver.file(secret_path),
            ]
            text = "token-secret cookie-secret env-secret file-secret token=abc Authorization: Bearer abc.def"
            redacted = redact_text(text, secrets)
            self.assertNotIn("token-secret", redacted)
            self.assertNotIn("cookie-secret", redacted)
            self.assertNotIn("env-secret", redacted)
            self.assertNotIn("file-secret", redacted)
            self.assertTrue(contains_secret("password=hunter2"))


class APIAndRefreshTests(unittest.TestCase):
    def test_fake_transport_pagination_and_repo_refresh(self) -> None:
        transport = FakeTransport(
            [
                Response(200, {"items": [{"name": "one"}], "nextCursor": "n2"}),
                Response(200, {"items": [{"name": "two"}]}),
                Response(200, {"items": []}),
                Response(200, {"items": []}),
            ]
        )
        client = GitCodeClient(transport=transport)
        state = MonitorState()
        repos = refresh_repositories(client, DEFAULT_ORGS, state)
        self.assertEqual([repo["name"] for repo in repos], ["one", "two"])
        self.assertEqual(transport.calls[1][2], {"cursor": "n2"})
        self.assertEqual(state.cursors["repos:cangjie"], "2")
        self.assertEqual(state.audit[0]["action"], "repo_refresh")

    def test_error_mapping(self) -> None:
        cases = [
            (401, UnauthorizedError),
            (403, ForbiddenError),
            (404, NotFoundError),
            (429, RateLimitError),
            (500, ServerError),
        ]
        for status, error_type in cases:
            with self.subTest(status=status):
                client = GitCodeClient(transport=FakeTransport([Response(status, {"message": "boom"})]))
                with self.assertRaises(error_type):
                    client.request("GET", "/x")


class StateSchedulerEventTests(unittest.TestCase):
    def test_state_store_cursor_seen_backoff_audit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = StateStore(Path(tmp) / "state.json")
            state = MonitorState()
            state.cursors["repo"] = "cursor"
            self.assertTrue(state.mark_seen("event-1"))
            self.assertFalse(state.mark_seen("event-1"))
            state.backoff["repo"] = 12.5
            state.record_audit("dry_run", "ok", detail="kept")
            store.save(state)
            loaded = store.load()
            self.assertEqual(loaded.cursors["repo"], "cursor")
            self.assertIn("event-1", loaded.seen)
            self.assertEqual(loaded.backoff["repo"], 12.5)
            self.assertEqual(loaded.audit[0]["detail"], "kept")

    def test_full_scan_scheduler_fake_clock_and_overlap(self) -> None:
        calls: list[str] = []
        state = MonitorState()
        scheduler = FullScanScheduler(load_config(), state, lambda: calls.append("scan"), FakeClock())
        self.assertTrue(scheduler.run_once())
        self.assertEqual(calls, ["scan"])
        self.assertGreaterEqual(scheduler.next_due, 600)
        self.assertLessEqual(scheduler.next_due, 630)

        scheduler.running = True
        self.assertFalse(scheduler.run_once())
        self.assertEqual(state.audit[-1]["status"], "skipped_overlapping_scan")

    def test_event_models_and_filters(self) -> None:
        issue = IssueEvent(
            org="cangjie",
            repo="repo",
            number=1,
            title="",
            body="start build",
            author="alice",
            url="https://gitcode.com/cangjie/repo/issues/1",
            updated_at="2026-05-16T00:00:00Z",
        )
        pr = PullRequestEvent(
            org="cangjie-sig",
            repo="repo",
            number=2,
            title="Need review",
            body="",
            author="alice",
            url="u",
            updated_at="t",
        )
        comment = CommentEvent(
            org="cangjie",
            repo="repo",
            number=1,
            title="",
            body="Thanks\n<!-- metis-gitcode-monitor -->",
            author="bot",
            url="u",
            updated_at="t",
            comment_id=9,
        )
        maintainer = CommentEvent(
            org="cangjie",
            repo="repo",
            number=1,
            title="",
            body="Needs update",
            author="CangjiePL",
            url="https://gitcode.com/CangjiePL",
            updated_at="t",
            comment_id=10,
        )
        self.assertTrue(is_exact_start_build(issue))
        self.assertFalse(should_process(issue))
        self.assertTrue(should_process(pr))
        self.assertTrue(has_self_marker(comment))
        self.assertFalse(should_process(comment))
        self.assertFalse(should_process(maintainer))
        self.assertIn(":9:", comment.idempotency_key)


class NotificationMCPMapperTests(unittest.TestCase):
    def test_notifier_delivery_audit(self) -> None:
        state = MonitorState()
        feishu = FeishuNotifier()
        telegram = TelegramNotifier()
        notify_with_audit(feishu, state, "chat-a", "message")
        notify_with_audit(telegram, state, "chat-b", "message")
        self.assertEqual(feishu.deliveries[0].channel, "feishu")
        self.assertEqual(telegram.deliveries[0].channel, "telegram")
        self.assertEqual([item["status"] for item in state.audit], ["delivered", "delivered"])

    def test_mcp_initialize_tools_call_schema_hash_and_degraded(self) -> None:
        tools = [{"name": "gitcode_issue_draft_reply", "inputSchema": {"type": "object"}}]
        server = FakeMCPServer(tools)
        client = MCPClient(server)
        self.assertEqual(client.initialize()["protocolVersion"], "2024-11-05")
        client.list_tools()
        self.assertEqual(schema_hash(tools), client.last_schema_hash)
        self.assertFalse(client.degraded)
        server.tools = [{"name": "changed", "inputSchema": {"type": "object"}}]
        client.list_tools()
        self.assertTrue(client.degraded)
        self.assertEqual(client.call_tool("changed", {"x": 1})["content"][0]["text"], "ok")

    def test_mapper_omits_credentials_and_evidence_pack(self) -> None:
        event = IssueEvent(
            org="CangjiePL",
            repo="repo",
            number=1,
            title="start build",
            body="",
            author="alice",
            url="u",
            updated_at="t",
            evidence_pack={"token": "secret", "raw": "large"},
        )
        tool_name, arguments = map_event_to_tool_call(event)
        self.assertEqual(tool_name, "gitcode_issue_draft_reply")
        self.assertNotIn("evidence_pack", arguments)
        self.assertNotIn("token", json.dumps(arguments).lower())
        self.assertNotIn("secret", json.dumps(arguments).lower())


class WritebackAndACPTests(unittest.TestCase):
    def test_writeback_safety_gate_dry_run_allowlist_duplicate_and_secret_scan(self) -> None:
        state = MonitorState()
        writer = FakeGitCodeCommentWriter({"repo#7": ["prior\n<!-- metis-gitcode-monitor -->"]})
        disabled = WritebackService(writer, WritebackPolicy(enabled=False, allowlist=("repo",)), state)
        self.assertFalse(disabled.comment("repo", 1, "body"))
        self.assertEqual(state.audit[-1]["status"], "blocked_disabled")

        service = WritebackService(writer, WritebackPolicy(enabled=True, allowlist=("repo",)), state)
        self.assertFalse(service.comment("other", 1, "body"))
        self.assertEqual(state.audit[-1]["status"], "blocked_not_allowlisted")
        self.assertFalse(service.comment("repo", 2, "token=abc"))
        self.assertEqual(state.audit[-1]["status"], "blocked_secret_scan")
        self.assertFalse(service.comment("repo", 7, "body"))
        self.assertEqual(state.audit[-1]["status"], "skipped_duplicate_marker")
        self.assertTrue(service.comment("repo", 8, "body", dry_run=True))
        self.assertEqual(writer.writes, [])
        self.assertEqual(state.audit[-1]["status"], "dry_run")
        self.assertTrue(service.comment("repo", 9, "body"))
        self.assertEqual(writer.writes[0][0:2], ("repo", 9))
        self.assertIn("<!-- metis-gitcode-monitor -->", writer.writes[0][2])

    def test_acp_disabled_by_default_allowed_tasks_lifecycle_and_freshness_policy(self) -> None:
        async def scenario() -> None:
            transport = FakeACPTransport()
            disabled = ACPClient(transport=transport)
            with self.assertRaisesRegex(RuntimeError, "disabled"):
                await disabled.start_run("scan")

            client = ACPClient(enabled=True, allowed_tasks=("triage",), transport=transport)
            with self.assertRaises(PermissionError):
                await client.start_run("scan")
            run = await client.start_run("triage", freshnessPolicy={"maxAgeSeconds": 60})
            self.assertEqual(run.freshness_policy, {"maxAgeSeconds": 60})
            self.assertEqual((await client.status(run.run_id)).status, "running")
            self.assertEqual((await client.cancel(run.run_id)).status, "cancelled")

        asyncio.run(scenario())


if __name__ == "__main__":
    unittest.main()
