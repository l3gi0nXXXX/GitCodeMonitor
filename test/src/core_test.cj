package gitcodemonitor

import std.fs.{remove, Path, exists}
import std.time.DateTime
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
    public func realGitCodeRequestBuilderSupportsAuthModesAndRedaction(): Unit {
        let privateClient = GitCodeApiClient(token: "private-secret")
        let privateReq = privateClient.listReposRequest("cangjie", 2, 50)
        @Expect(privateReq.url.contains("page=2"), true)
        @Expect(privateReq.headers[0][0], "PRIVATE-TOKEN")
        @Expect(privateReq.redactedLogLine().contains("private-secret"), false)

        let bearerClient = GitCodeApiClient(authMode: "Authorization", token: "bearer-secret")
        let bearerReq = bearerClient.listIssuesRequest(GitCodeRepo("cangjie", "compiler"), 1, 20)
        @Expect(bearerReq.headers[0][0], "Authorization")
        @Expect(bearerReq.headers[0][1], "Bearer bearer-secret")
        @Expect(bearerReq.redactedLogLine().contains("bearer-secret"), false)

        let queryClient = GitCodeApiClient(authMode: "access_token", token: "query-secret")
        let queryReq = queryClient.listCommentsRequest(GitCodeRepo("cangjie", "compiler"), "pr", "9", 1, 20)
        @Expect(queryReq.url.contains("access_token="), true)
        @Expect(queryReq.redactedLogLine().contains("query-secret"), false)
    }

    @TestCase
    public func curlHttpSenderBuildsRealHttpArgsWithoutLoggingSecrets(): Unit {
        let req = HttpRequestSpec("POST", "https://api.telegram.org/bot123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef/sendMessage", headers: [("Authorization", "Bearer secret")], body: "{\"ok\":true}")
        let sender = CurlHttpSender()
        let args = sender.curlArgs(req)
        @Expect(args[0], "-sS")
        @Expect(args.contains("--data"), true)
        let redacted = joinStrings(sender.redactedCurlArgs(req), " ")
        @Expect(redacted.contains("Bearer secret"), false)
        @Expect(redacted.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), false)
    }

    @TestCase
    public func commentPostRequestAddsSelfMarkerAndJsonBody(): Unit {
        let event = GitCodeEvent("evt", "cangjie", "compiler", "issue", "42", "alice", "", "", "x")
        let req = GitCodeApiClient(token: "secret").postCommentRequest(event, "hello")
        @Expect(req.method, "POST")
        @Expect(req.url.contains("/issues/42/comments"), true)
        @Expect(req.body.contains(SELF_MARKER), true)
        @Expect(req.redactedLogLine().contains("secret"), false)
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
    public func stateStorePersistsSeenAuditReplyAndBackoff(): Unit {
        let path = "/tmp/gcm-state-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.json"
        let store = StateStore(path)
        let state = MonitorState()
        state.markSeen("evt")
        state.markMcpCall("evt")
        state.markReply("evt")
        state.setBackoff("cangjie/compiler", 1234)
        let audit = AuditRecord("evt", status: "drafted", reason: "dry_run")
        audit.draft = "draft"
        audit.writeDecision = "dry_run"
        state.addAudit(audit)
        @Expect(store.save(state), true)
        let loaded = store.load()
        @Expect(loaded.hasSeen("evt"), true)
        @Expect(loaded.hasMcpCall("evt"), true)
        @Expect(loaded.hasReply("evt"), true)
        @Expect(loaded.backoffUntil("cangjie/compiler"), 1234)
        @Expect(loaded.audit.size, 1)
        if (exists(Path(path))) { remove(Path(path)) }
    }

    @TestCase
    public func notifierPayloadBuildersAreDryRunByDefaultAndRedactContent(): Unit {
        let event = GitCodeEvent("evt", "cangjie", "compiler", "issue", "1", "alice", "", "https://gitcode.com/cangjie/compiler/issues/1", "Authorization: Bearer secret")
        let feishu = buildFeishuPayload("https://open.feishu.cn/webhook/abc", event)
        @Expect(feishu.request.body.contains("[REDACTED]"), true)
        let telegram = buildTelegramPayload("123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef", "chat", event)
        @Expect(telegram.request.url.contains("sendMessage"), true)
        @Expect(telegram.request.redactedLogLine().contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), false)
        let sender = FakeHttpSender()
        let notifier = HttpNotifier("feishu", sender: sender)
        let audit = notifier.notify(event)
        @Expect(audit.status, "dry_run")
        @Expect(sender.requests.size, 0)
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
    public func mcpHttpClientBuildsJsonRpcRequestsAndDegradesCleanly(): Unit {
        let sender = FakeHttpSender()
        let mcp = McpHttpClient("http://127.0.0.1:8787/mcp", serviceToken: "service-secret", sender: sender)
        @Expect(mcp.initialize(), true)
        @Expect(sender.requests[0].body.contains("\"method\":\"initialize\""), true)
        @Expect(sender.requests[0].redactedLogLine().contains("service-secret"), false)
        let tools = mcp.toolsList()
        @Expect(tools.size, 5)
        let result = mcp.call(ToolInput("gitcode_issue_draft_reply", "evt", "cangjie/compiler", "body"))
        @Expect(result.ok, true)
        @Expect(sender.requests[2].body.contains("\"method\":\"tools/call\""), true)

        let downSender = FakeHttpSender()
        downSender.nextResponse = HttpResponseSpec(503)
        let down = McpHttpClient("http://127.0.0.1:8787/mcp", sender: downSender)
        @Expect(down.initialize(), false)
        @Expect(down.degradedReason, "server_error")
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
        @Expect(writebackGate(config, state, event, McpResult(true, draft: "/Users/name/private-index")).reason, "local_path_detected")
        @Expect(writebackGate(config, state, event, mcp).allowed, true)
        let writer = FakeCommentWriter()
        let url = writer.write(event, mcp.draft, state)
        @Expect(url.contains("https://gitcode.com/cangjie/compiler/comments/"), true)
        @Expect(writebackGate(config, state, event, mcp).reason, "duplicate")
        @Expect(filterEvent(GitCodeEvent("self", "cangjie", "compiler", "issue", "1", "bot", "", "", writer.written[0])).reason, "self_marker")
    }

    @TestCase
    public func realWritebackWriterPostsOnlyAfterGates(): Unit {
        let config = defaultConfig()
        config.dryRun = false
        config.autoReply = true
        config.repoAllowlist = ["cangjie/compiler"]
        let event = GitCodeEvent("evt", "cangjie", "compiler", "pr", "7", "alice", "", "", "need help")
        let sender = FakeHttpSender()
        let writer = GitCodeCommentWriter(GitCodeApiClient(token: "secret"), sender: sender)
        let decision = writer.writeIfAllowed(config, MonitorState(), event, McpResult(true, draft: "safe", approved: true))
        @Expect(decision.reason, "posted")
        @Expect(sender.requests.size, 1)
        @Expect(sender.requests[0].url.contains("/pulls/7/comments"), true)
        @Expect(sender.requests[0].body.contains(SELF_MARKER), true)
    }

    @TestCase
    public func cliReportsDoNotLeakCredentials(): Unit {
        let config = defaultConfig()
        config.gitCodeToken = "gitcode-secret"
        config.mcpServiceToken = "mcp-secret"
        config.mcpEndpoint = "http://127.0.0.1:8787/mcp"
        let summary = configSummary(config)
        @Expect(summary.contains("gitcode-secret"), false)
        @Expect(summary.contains("mcp-secret"), false)
        @Expect(probeGitCode(config).contains("gitcode-secret"), false)
        @Expect(probeMcp(config).contains("mcp-secret"), false)
        @Expect(cliHelp().contains("probe-gitcode"), true)
        @Expect(serveOnceBaseline(config).contains("serve baseline"), true)
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
