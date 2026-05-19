package gitcodemonitor

import std.unittest.testmacro.*

@Test
public class GitCodeMonitorCoreTest {
    @TestCase
    public func defaultsMatchRequestedBaseline(): Unit {
        let config = defaultConfig()
        @Expect(config.orgs.size, 3)
        @Expect(config.orgs[0], "cangjie")
        @Expect(config.orgs[1], "cangjie-sig")
        @Expect(config.orgs[2], "cangjie-tpc")
        @Expect(config.fullScanIntervalMinutes, 10)
        @Expect(config.minProduction, 5)
        @Expect(config.jitterSeconds, 30)
        @Expect(config.dryRun, true)
        @Expect(config.autoReply, false)
        @Expect(config.acpEnabled, false)
        @Expect(validateConfig(config), "ok")
    }

    @TestCase
    public func secretDetectionCoversRequiredKinds(): Unit {
        @Expect(containsSecret("Authorization: Bearer abcdef"), true)
        @Expect(containsSecret("cookie=sessionid=abc"), true)
        @Expect(containsSecret("password=secret"), true)
        @Expect(containsSecret("token=secret"), true)
        @Expect(containsSecret("123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"), true)
        @Expect(containsSecret("https://gitcode.com/cangjie/compiler"), false)
    }

    @TestCase
    public func filtersIgnoreCangjiePlStartBuildAndSelfMarker(): Unit {
        let byActor = GitCodeEvent("a", "cangjie", "compiler", "issue", "1", "CangjiePL", "https://gitcode.com/CangjiePL", "", "hello")
        let build = GitCodeEvent("b", "cangjie", "compiler", "issue", "1", "alice", "", "", "  start build  ")
        let self = GitCodeEvent("c", "cangjie", "compiler", "issue", "1", "bot", "", "", "reply\n${SELF_MARKER}")
        let normal = GitCodeEvent("d", "cangjie", "compiler", "issue", "1", "alice", "", "", "start build please")
        @Expect(filterEvent(byActor).reason, "CangjiePL")
        @Expect(filterEvent(build).reason, "start_build")
        @Expect(filterEvent(self).reason, "self_marker")
        @Expect(filterEvent(normal).ignored, false)
    }

    @TestCase
    public func schedulerUsesFakeClockCadenceAndOverlapGuard(): Unit {
        let config = defaultConfig()
        let clock = FakeClock()
        let state = MonitorState()
        let scheduler = FullScanScheduler(config, clock)
        @Expect(scheduler.begin(clock, state), true)
        @Expect(scheduler.begin(clock, state), false)
        @Expect(state.skippedOverlappingScans, 1)
        scheduler.finish()
        clock.advanceMinutes(10)
        @Expect(scheduler.due(clock), false)
        clock.nowMs += 30 * 1000
        @Expect(scheduler.begin(clock, state), true)
    }

    @TestCase
    public func fakeGitCodeRefreshPaginatesAndMapsErrors(): Unit {
        let config = defaultConfig()
        let transport = FakeGitCodeTransport()
        transport.seedDefaultRepos()
        transport.repos.add(GitCodeRepo("cangjie", "runtime"))
        let result = refreshRepos(config, transport)
        @Expect(result.repoCount, 4)
        @Expect(mapGitCodeError(401), "unauthorized")
        @Expect(mapGitCodeError(403), "forbidden")
        @Expect(mapGitCodeError(404), "not_found")
        @Expect(mapGitCodeError(429), "rate_limited")
        @Expect(mapGitCodeError(503), "server_error")
    }

    @TestCase
    public func acceptedEventsNotifyBothChannelsAndMcpDownDoesNotBlock(): Unit {
        let config = defaultConfig()
        let transport = FakeGitCodeTransport()
        transport.repos.add(GitCodeRepo("cangjie", "compiler"))
        transport.events.add(GitCodeEvent("evt", "cangjie", "compiler", "issue", "1", "alice", "", "", "need help"))
        let mcp = FakeMcpClient()
        mcp.available = false
        let result = scanOnce(config, transport, MonitorState(), FakeNotifier("feishu"), FakeNotifier("telegram"), mcp, FakeCommentWriter())
        @Expect(result.accepted, 1)
        @Expect(result.notified, 2)
        @Expect(result.mcpCalls, 0)
        @Expect(result.writes, 0)
    }

    @TestCase
    public func mcpSchemaCacheAndMapperUseGitCodeTools(): Unit {
        let mcp = FakeMcpClient()
        @Expect(mcp.initialize(), true)
        @Expect(mcp.toolsList().size, 5)
        let input = eventToToolInput(GitCodeEvent("evt", "cangjie", "compiler", "pr", "2", "alice", "", "", "review please"))
        @Expect(input.toolName, "gitcode_pr_draft_reply")
        @Expect(input.repo, "cangjie/compiler")
        @Expect(containsSecret(input.body), false)
    }

    @TestCase
    public func writebackGateRequiresAllLocalSafetySwitches(): Unit {
        let config = defaultConfig()
        let state = MonitorState()
        let event = GitCodeEvent("evt", "cangjie", "compiler", "issue", "1", "alice", "", "", "need help")
        let mcp = McpResult(true, draft: "safe reply", approved: true, needsHumanReview: false)
        @Expect(writebackGate(config, state, event, mcp).reason, "dry_run")
        config.dryRun = false
        @Expect(writebackGate(config, state, event, mcp).reason, "auto_reply_disabled")
        config.autoReply = true
        @Expect(writebackGate(config, state, event, mcp).reason, "repo_not_allowlisted")
        config.repoAllowlist = ["cangjie/compiler"]
        @Expect(writebackGate(config, state, event, McpResult(true, draft: "Authorization: Bearer x")).reason, "secret_detected")
        @Expect(writebackGate(config, state, event, mcp).allowed, true)
        let writer = FakeCommentWriter()
        let url = writer.write(event, mcp.draft, state)
        @Expect(url.contains("https://gitcode.com/cangjie/compiler/comments/"), true)
        @Expect(writebackGate(config, state, event, mcp).reason, "duplicate")
        @Expect(filterEvent(GitCodeEvent("self", "cangjie", "compiler", "issue", "1", "bot", "", "", writer.written[0])).reason, "self_marker")
    }

    @TestCase
    public func acpIsDisabledByDefaultAndResultsAreAuditOnly(): Unit {
        let config = defaultConfig()
        let acp = FakeAcpClient()
        let request = AcpTaskRequest("deep_pr_analysis", freshnessPolicy: "ensure_recent")
        @Expect(acp.allowed(config, request), false)
        config.acpEnabled = true
        config.acpEndpoint = "https://metis.example/mcp/acp"
        config.acpServiceToken = "service-token"
        config.acpAllowedTasks = ["deep_pr_analysis", "batch_triage_report", "weekly_report", "history_retrospective", "human_review_draft"]
        @Expect(validateConfig(config), "ok")
        let run = acp.createRun(config, request)
        @Expect(run.status, "pending")
        let done = acp.poll(run)
        @Expect(done.status, "succeeded")
        @Expect(done.resultSource, "acp")
        @Expect(writebackGate(config, MonitorState(), GitCodeEvent("evt", "cangjie", "compiler", "issue", "1", "alice", "", "", "x"), McpResult(true, draft: done.finalDraft)).reason, "dry_run")
        @Expect(acp.allowed(config, AcpTaskRequest("gitcode_issue_draft_reply")), false)
    }
}
