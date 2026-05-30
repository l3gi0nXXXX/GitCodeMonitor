package gitcodemonitor

import std.collection.ArrayList
import std.fs.{Directory, File, remove, Path, exists}
import std.time.DateTime
import std.unittest.testmacro.*

private class FakeNativeRawTransport <: NativeRawHttpTransport {
    public let requests = ArrayList<HttpRequestSpec>()
    public var nextResponse: HttpResponseSpec = HttpResponseSpec(200, body: "{\"ok\":true}")
    public var throwNext: Bool = false

    public init() {}

    public func send(request: HttpRequestSpec, timeoutSeconds: Int64): HttpResponseSpec {
        if (throwNext) {
            throw Exception("Authorization: Bearer secret")
        }
        requests.add(request)
        nextResponse
    }
}

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
        @Expect(config.gitCodeBaseUrl, "https://api.gitcode.com/api/v5")
        @Expect(configuredHttpTransport(config), "native")
        @Expect(validateConfig(config), "ok")
    }

    @TestCase
    public func loadConfigUsesInjectablePathAndRedactsSecrets(): Unit {
        let dir = Path("/tmp/gcm-config-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(dir, recursive: true)
        let path = dir.join("metis.json")
        File.writeTo(path, ("{" +
            "\"gitcode\":{\"baseUrl\":\"https://gitcode.example/api/v5\",\"authMode\":\"Authorization\",\"token\":\"gitcode-secret\",\"cookie\":\"sid=cookie-secret\",\"username\":\"bot\",\"password\":\"password-secret\"}," +
            "\"metis\":{\"mcpEndpoint\":\"http://127.0.0.1:8787/mcp\",\"mcpServiceToken\":\"mcp-secret\"}," +
            "\"feishu\":{\"webhook\":\"https://open.feishu.cn/hook/feishu-secret\"}," +
            "\"telegram\":{\"botToken\":\"123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef\",\"chatId\":\"chat\"}," +
            "\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"autoReply\":false,\"notifyNetworkEnabled\":false,\"repoAllowlist\":[\"cangjie/compiler\"]}" +
            "}").toArray())
        let config = loadConfig(path: path.toString())
        @Expect(config.gitCodeBaseUrl, "https://gitcode.example/api/v5")
        @Expect(config.gitCodeAuthMode, "Authorization")
        @Expect(config.mcpEndpoint, "http://127.0.0.1:8787/mcp")
        @Expect(config.telegramChatId, "chat")
        @Expect(config.repoAllowlist[0], "cangjie/compiler")
        let summary = configSummary(config)
        let doctor = doctorReport(config, MonitorState(), FakeMcpClient())
        @Expect(summary.contains("gitcode-secret"), false)
        @Expect(summary.contains("cookie-secret"), false)
        @Expect(summary.contains("mcp-secret"), false)
        @Expect(summary.contains("transport=native"), true)
        @Expect(summary.contains("present"), true)
        @Expect(doctor.contains("gitCodeAuth=present"), true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
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
    public func gitCodeHttpTransportParsesReposIssuesPrsCommentsAndRateLimit(): Unit {
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(200, body: "{\"repos\":[{\"path\":\"compiler\",\"public\":true,\"private\":false,\"internal\":false,\"default_branch\":\"main\"},{\"full_name\":\"cangjie/runtime\",\"visibility\":\"public\"}]}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"data\":[{\"number\":11,\"title\":\"bug\",\"body\":\"details\",\"user\":{\"login\":\"alice\",\"html_url\":\"https://gitcode.com/alice\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/11\"}]}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"comments\":[{\"id\":99,\"body\":\"comment\",\"user\":{\"login\":\"bob\"}}]}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"items\":[{\"id\":7,\"title\":\"pr\",\"description\":\"change\",\"author\":{\"username\":\"carol\"}}]}"))
        sender.enqueue(HttpResponseSpec(200, body: "[]"))
        let transport = GitCodeHttpTransport(GitCodeApiClient(token: "secret"), sender: sender, pageSize: 50)
        let repos = transport.listReposPage("cangjie", 1)
        @Expect(repos.repos.size, 2)
        @Expect(repos.repos[0].fullName(), "cangjie/compiler")
        @Expect(repos.repos[0].defaultBranch, "main")
        let state = MonitorState()
        let events = collectRepoEventsHttp(GitCodeRepo("cangjie", "compiler"), transport, state)
        @Expect(events.size, 3)
        @Expect(events[0].id, "cangjie/compiler:issue:11")
        @Expect(events[1].id, "cangjie/compiler:issue:11:comment:99")
        @Expect(events[2].itemKind, "pr")

        let limitedSender = FakeHttpSender()
        limitedSender.nextResponse = HttpResponseSpec(429, headers: [("Retry-After", "2")])
        let limited = GitCodeHttpTransport(GitCodeApiClient(), sender: limitedSender)
        let limitedResult = limited.listReposPage("cangjie", 1)
        @Expect(limitedResult.errorKind, "rate_limited")
        @Expect(limitedResult.retryAfterMs, 2000)
    }

    @TestCase
    public func realGitCodeRequestBuilderSupportsAuthModesAndRedaction(): Unit {
        let privateClient = GitCodeApiClient(token: "private-secret")
        let privateReq = privateClient.listReposRequest("cang jie", 2, 150)
        @Expect(privateClient.baseUrl, "https://api.gitcode.com/api/v5")
        @Expect(privateReq.url.contains("/orgs/cang%20jie/repos?type=public"), true)
        @Expect(privateReq.url.contains("page=2"), true)
        @Expect(privateReq.url.contains("per_page=100"), true)
        @Expect(privateReq.headers[0][0], "PRIVATE-TOKEN")
        @Expect(privateReq.redactedLogLine().contains("private-secret"), false)

        let bearerClient = GitCodeApiClient(authMode: "Authorization", token: "bearer-secret")
        let bearerReq = bearerClient.listIssuesRequest(GitCodeRepo("cangjie", "compiler"), 1, 20, since: "2026-05-21T10:20:30+08:00")
        @Expect(bearerReq.headers[0][0], "Authorization")
        @Expect(bearerReq.headers[0][1], "Bearer bearer-secret")
        @Expect(bearerReq.url.contains("/repos/cangjie/compiler/issues?state=all"), true)
        @Expect(bearerReq.url.contains("sort=updated_at"), true)
        @Expect(bearerReq.url.contains("direction=desc"), true)
        @Expect(bearerReq.url.contains("since=2026-05-21T10%3A20%3A30%2B08%3A00"), true)
        @Expect(bearerReq.redactedLogLine().contains("bearer-secret"), false)

        let queryClient = GitCodeApiClient(authMode: "access_token", token: "query-secret")
        let queryReq = queryClient.listCommentsRequest(GitCodeRepo("cangjie", "compiler"), "pr", "9", 1, 20)
        @Expect(queryReq.url.contains("/pulls/9/comments?page=1&per_page=20"), true)
        @Expect(queryReq.url.contains("access_token="), true)
        @Expect(queryReq.redactedLogLine().contains("query-secret"), false)

        let cookieClient = GitCodeApiClient(token: "token-secret", cookie: "sid=cookie-secret")
        let cookieReq = cookieClient.listReposRequest("cangjie", 1, 20)
        @Expect(cookieReq.redactedLogLine().contains("cookie-secret"), false)
    }

    @TestCase
    public func gitCodeRepoDiscoveryKeepsOnlyPublicRepos(): Unit {
        let body = "{\"data\":[" +
            "{\"path\":\"public-flag\",\"public\":true,\"private\":false,\"internal\":false,\"default_branch\":\"main\",\"html_url\":\"https://gitcode.com/cangjie/public-flag\"}," +
            "{\"path\":\"public-visibility\",\"visibility\":\"public\"}," +
            "{\"path\":\"private-flag\",\"public\":false,\"private\":true,\"internal\":false}," +
            "{\"path\":\"private-visibility\",\"visibility\":\"private\"}," +
            "{\"path\":\"internal-flag\",\"public\":false,\"private\":false,\"internal\":true}," +
            "{\"path\":\"internal-visibility\",\"visibility\":\"internal\"}," +
            "{\"path\":\"unknown\"}" +
            "]}"
        let repos = parseReposResponse(body, "cangjie")
        @Expect(repos.size, 2)
        @Expect(repos[0].name, "public-flag")
        @Expect(repos[0].isPublic, true)
        @Expect(repos[0].isPrivate, false)
        @Expect(repos[0].isInternal, false)
        @Expect(repos[0].defaultBranch, "main")
        @Expect(repos[0].htmlUrl, "https://gitcode.com/cangjie/public-flag")
        @Expect(repos[1].name, "public-visibility")
        @Expect(repoVisibilityDecision(false, false, false, ""), "visibility_unknown")
        @Expect(repoVisibilityDecision(false, true, false, "public"), "private")
        @Expect(repoVisibilityDecision(false, false, true, "public"), "internal")
    }

    @TestCase
    public func gitCodeIssuePrAndCommentRequestsUseOfficialParameters(): Unit {
        let client = GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5/")
        let repo = GitCodeRepo("cangjie", "compiler")
        let issues = client.listIssuesRequest(repo, 3, 101)
        @Expect(issues.url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/issues?state=all&sort=updated_at&direction=desc&page=3&per_page=100")
        let prs = client.listPullRequestsRequest(repo, 4, 25, updatedAfter: "2026-05-21T12:00:00+08:00")
        @Expect(prs.url.contains("/repos/cangjie/compiler/pulls?state=all"), true)
        @Expect(prs.url.contains("sort=updated"), true)
        @Expect(prs.url.contains("updated_after=2026-05-21T12%3A00%3A00%2B08%3A00"), true)
        let issueComments = client.listCommentsRequest(repo, "issue", "42", 1, 20)
        @Expect(issueComments.url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/issues/comments?page=1&per_page=20")
        let prComments = client.listCommentsRequest(repo, "pr", "7", 2, 20)
        @Expect(prComments.url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/pulls/7/comments?page=2&per_page=20")
        let issueEvent = GitCodeEvent("evt", "cangjie", "compiler", "issue", "42", "alice", "", "", "x")
        let issuePost = client.postCommentRequest(issueEvent, "hello")
        @Expect(issuePost.url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/issues/42/comments")
        @Expect(issuePost.body.contains("\"body\""), true)
        @Expect(issuePost.body.contains(SELF_MARKER), true)
        let prEvent = GitCodeEvent("evt", "cangjie", "compiler", "pr", "7", "alice", "", "", "x")
        let prPost = client.postCommentRequest(prEvent, "hello")
        @Expect(prPost.url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/pulls/7/comments")
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
    public func nativeHttpSenderUsesInjectableRawTransportAndKeepsFailuresContained(): Unit {
        let raw = FakeNativeRawTransport()
        let sender = NativeHttpSender(rawTransport: raw)
        let methods = ["GET", "POST", "PATCH", "DELETE", "PUT"]
        for (method in methods) {
            let res = sender.send(HttpRequestSpec(method, "https://api.gitcode.com/api/v5/test", headers: [("X-Test", "yes")], body: "{\"body\":true}"))
            @Expect(res.statusCode, 200)
        }
        @Expect(raw.requests.size, 5)
        @Expect(raw.requests[1].method, "POST")
        @Expect(raw.requests[1].headers[0][0], "X-Test")
        @Expect(raw.requests[1].body.contains("body"), true)

        raw.throwNext = true
        let failed = sender.send(HttpRequestSpec("GET", "https://api.gitcode.com/api/v5/test", headers: [("Authorization", "Bearer secret")]))
        @Expect(failed.statusCode, 599)
        @Expect(failed.body.contains("Bearer secret"), false)
        @Expect(failed.body.contains("transport_error"), true)
    }

    @TestCase
    public func configuredTransportDefaultsNativeAndAllowsExplicitCurlOnly(): Unit {
        let config = defaultConfig()
        @Expect(configuredHttpTransport(config), "native")
        @Expect(configSummary(config).contains("transport=native"), true)
        @Expect(doctorReport(config, MonitorState(), FakeMcpClient()).contains("transport=native"), true)
        config.httpTransport = "curl"
        @Expect(configuredHttpTransport(config), "curl")
        @Expect(configSummary(config).contains("transport=curl"), true)
        config.gitCodeToken = "gitcode-secret"
        config.gitCodeCookie = "sid=cookie-secret"
        let doctor = doctorReport(config, MonitorState(), FakeMcpClient())
        @Expect(doctor.contains("transport=curl"), true)
        @Expect(doctor.contains("gitcode-secret"), false)
        @Expect(doctor.contains("cookie-secret"), false)
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
    public func duplicateEventsDoNotRepeatNotifyMcpOrWriteback(): Unit {
        let config = defaultConfig()
        let state = MonitorState()
        let first = scanOnceOfflineFixture(config, state)
        let second = scanOnceOfflineFixture(config, state)
        @Expect(first.accepted, 1)
        @Expect(first.scannedRepos, 3)
        @Expect(first.checkedItems, 1)
        @Expect(first.newEvents, 1)
        @Expect(first.samplesNew.size, 1)
        @Expect(first.samplesNew[0].repo, "cangjie/compiler")
        @Expect(first.samplesNew[0].kind, "issue")
        @Expect(first.samplesNew[0].number, "1")
        @Expect(first.samplesNew[0].url, "https://gitcode.com/cangjie/compiler/issues/1")
        @Expect(first.notified, 2)
        @Expect(first.mcpCalls, 1)
        @Expect(second.accepted, 0)
        @Expect(second.scannedRepos, 3)
        @Expect(second.checkedItems, 1)
        @Expect(second.duplicateEvents, 1)
        @Expect(second.samplesDuplicate.size, 1)
        @Expect(second.samplesDuplicate[0].reason, "seen")
        @Expect(second.notified, 0)
        @Expect(second.mcpCalls, 0)
    }

    @TestCase
    public func scanReportCountsMultipleNewAndFilteredEvents(): Unit {
        let config = defaultConfig()
        let transport = FakeGitCodeTransport()
        transport.repos.add(GitCodeRepo("cangjie", "compiler"))
        transport.events.add(GitCodeEvent("evt-1", "cangjie", "compiler", "pr", "70", "alice", "", "https://gitcode.com/cangjie/compiler/pulls/70", "Fix parser\nbody"))
        transport.events.add(GitCodeEvent("evt-2", "cangjie", "compiler", "issue", "71", "bob", "", "https://gitcode.com/cangjie/compiler/issues/71", "Discuss docs"))
        transport.events.add(GitCodeEvent("evt-3", "cangjie", "compiler", "issue", "72", "CangjiePL", "https://gitcode.com/CangjiePL", "https://gitcode.com/cangjie/compiler/issues/72", "bot event"))

        let result = scanOnce(config, transport, MonitorState(), FakeNotifier("feishu"), FakeNotifier("telegram"), FakeMcpClient(), FakeCommentWriter())

        @Expect(result.scannedRepos, 1)
        @Expect(result.checkedItems, 3)
        @Expect(result.newEvents, 2)
        @Expect(result.filteredEvents, 1)
        @Expect(result.draftsGenerated, 2)
        @Expect(result.notificationsSent, 4)
        @Expect(result.samplesNew.size, 2)
        @Expect(result.samplesNew[0].title, "Fix parser")
        @Expect(result.samplesFiltered.size, 1)
        @Expect(result.samplesFiltered[0].reason, "CangjiePL")
    }

    @TestCase
    public func scanReportSamplesAreCappedAndRedacted(): Unit {
        let config = defaultConfig()
        let state = MonitorState()
        let transport = FakeGitCodeTransport()
        transport.repos.add(GitCodeRepo("cangjie", "compiler"))
        for (i in 0..6) {
            let id = "dup-${i}"
            state.markSeen(id)
            transport.events.add(GitCodeEvent(
                id,
                "cangjie",
                "compiler",
                "issue",
                "${i}",
                "alice",
                "",
                "https://gitcode.com/cangjie/compiler/issues/${i}?access_token=secret-token",
                "Authorization: Bearer secret-token /Users/alice/private"
            ))
        }

        let result = scanOnce(config, transport, state, FakeNotifier("feishu"), FakeNotifier("telegram"), FakeMcpClient(), FakeCommentWriter())

        @Expect(result.duplicateEvents, 6)
        @Expect(result.samplesDuplicate.size, 5)
        @Expect(result.samplesDuplicate[0].title.contains("secret-token"), false)
        @Expect(result.samplesDuplicate[0].url.contains("secret-token"), false)
        @Expect(result.samplesDuplicate[0].title.contains("/Users/alice"), false)
    }

    @TestCase
    public func scanSummaryAuditContainsCountersWithoutSecrets(): Unit {
        let config = defaultConfig()
        let state = MonitorState()
        let transport = FakeGitCodeTransport()
        transport.repos.add(GitCodeRepo("cangjie", "compiler"))
        transport.events.add(GitCodeEvent("evt-secret", "cangjie", "compiler", "issue", "1", "alice", "", "", "token=secret-value"))

        let result = scanOnce(config, transport, state, FakeNotifier("feishu"), FakeNotifier("telegram"), FakeMcpClient(), FakeCommentWriter())

        @Expect(result.checkedItems, 1)
        @Expect(state.audit[state.audit.size - 1].status, "scan_summary")
        @Expect(state.audit[state.audit.size - 1].reason.contains("checkedItems=1"), true)
        @Expect(state.audit[state.audit.size - 1].reason.contains("secret-value"), false)
    }

    @TestCase
    public func scanResultDefaultsStopReasonToCompletedAndAuditMentionsIt(): Unit {
        let state = MonitorState()
        let result = ScanResult(0, 0, 0, 0, 0)

        let finalized = finalizeScanResult(state, "scan-stop-reason", result)

        @Expect(finalized.stopReason, "completed")
        @Expect(state.audit[state.audit.size - 1].reason.contains("stopReason=completed"), true)
        @Expect(state.audit[state.audit.size - 1].reason.contains("token="), false)
        @Expect(state.audit[state.audit.size - 1].reason.contains("/Users/"), false)
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
    public func stateStoreCorruptionDoesNotCrashAndKeepsBackup(): Unit {
        let path = "/tmp/gcm-corrupt-state-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.json"
        File.writeTo(Path(path), "{not-json".toArray())
        let store = StateStore(path)
        let state = store.load()
        @Expect(store.loadDegraded, true)
        @Expect(state.audit.size, 1)
        @Expect(state.audit[0].status, "state_error")
        @Expect(exists(Path(path + ".corrupt")), true)
        if (exists(Path(path))) { remove(Path(path)) }
        if (exists(Path(path + ".corrupt"))) { remove(Path(path + ".corrupt")) }
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

        let liveSender = FakeHttpSender()
        liveSender.nextResponse = HttpResponseSpec(200, body: "{\"ok\":true}")
        let live = HttpNotifier("telegram", networkEnabled: true, webhookOrToken: "123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef", chatId: "chat", sender: liveSender)
        let delivery = live.notify(event)
        @Expect(delivery.status, "sent")
        @Expect(delivery.httpStatus, 200)
        @Expect(liveSender.requests.size, 1)
        @Expect(liveSender.requests[0].redactedLogLine().contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), false)

        let limitedSender = FakeHttpSender()
        limitedSender.nextResponse = HttpResponseSpec(429, headers: [("Retry-After", "3")])
        let limited = HttpNotifier("feishu", networkEnabled: true, webhookOrToken: "https://open.feishu.cn/webhook/abc", sender: limitedSender)
        let limitedAudit = limited.notify(event)
        @Expect(limitedAudit.status, "rate_limited")
        @Expect(limitedAudit.httpStatus, 429)
        @Expect(limitedAudit.errorKind, "rate_limited")
        @Expect(limited.backoffUntilMs, 3000)
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
        sender.enqueue(HttpResponseSpec(200, body: "{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"result\":{}}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"jsonrpc\":\"2.0\",\"id\":\"tools\",\"result\":{\"tools\":[{\"name\":\"gitcode_issue_summary\"},{\"name\":\"gitcode_issue_draft_reply\"},{\"name\":\"gitcode_pr_summary\"},{\"name\":\"gitcode_pr_draft_reply\"},{\"name\":\"gitcode_safety_review\"}]}}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"result\":{\"structuredContent\":{\"summary\":\"short\",\"draft\":\"real draft\",\"approved\":true,\"needsHumanReview\":false,\"citations\":[\"https://gitcode.com/cangjie/compiler/issues/1\"]}}}"))
        let mcp = McpHttpClient("http://127.0.0.1:8787/mcp", serviceToken: "service-secret", sender: sender)
        @Expect(mcp.initialize(), true)
        @Expect(sender.requests[0].body.contains("\"method\":\"initialize\""), true)
        @Expect(sender.requests[0].redactedLogLine().contains("service-secret"), false)
        let tools = mcp.toolsList()
        @Expect(tools.size, 5)
        let result = mcp.call(ToolInput("gitcode_issue_draft_reply", "evt", "cangjie/compiler", "body"))
        @Expect(result.ok, true)
        @Expect(result.draft, "real draft")
        @Expect(result.summary, "short")
        @Expect(result.citations.size, 1)
        @Expect(sender.requests[2].body.contains("\"method\":\"tools/call\""), true)
        @Expect(sender.requests[2].body.contains("\"repo\":\"cangjie/compiler\""), true)

        let downSender = FakeHttpSender()
        downSender.nextResponse = HttpResponseSpec(503)
        let down = McpHttpClient("http://127.0.0.1:8787/mcp", sender: downSender)
        @Expect(down.initialize(), false)
        @Expect(down.degradedReason, "server_error")
    }

    @TestCase
    public func mcpParsesRealToolListsCallsAndMalformedBodiesWithoutSyntheticSuccess(): Unit {
        let tools = parseMcpToolsResponse("{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[{\"name\":\"gitcode_issue_summary\"},{\"name\":\"gitcode_issue_draft_reply\"}]}}")
        @Expect(tools.size, 2)
        @Expect(tools[0].name, "gitcode_issue_summary")
        @Expect(parseMcpToolsResponse("").size, 0)
        @Expect(parseMcpToolsResponse("<html>bad gateway</html>").size, 0)

        let textJson = parseMcpCallResponse("{\"jsonrpc\":\"2.0\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"draft\\\":\\\"from text\\\",\\\"approved\\\":true,\\\"needsHumanReview\\\":false}\"}]}}")
        @Expect(textJson.ok, true)
        @Expect(textJson.draft, "from text")
        let rejected = parseMcpCallResponse("{\"jsonrpc\":\"2.0\",\"result\":{\"structuredContent\":{\"draft\":\"unsafe\",\"approved\":false,\"needsHumanReview\":true,\"reason\":\"secret risk\"}}}")
        @Expect(rejected.ok, true)
        @Expect(rejected.approved, false)
        @Expect(rejected.needsHumanReview, true)
        @Expect(writebackGate(defaultConfig(), MonitorState(), GitCodeEvent("evt", "cangjie", "compiler", "issue", "1", "alice", "", "", "x"), rejected).reason, "dry_run")
        @Expect(parseMcpCallResponse("").errorKind, "mcp_empty_body")
        @Expect(parseMcpCallResponse("<html>bad gateway</html>").errorKind, "mcp_parse_error")
        @Expect(parseMcpCallResponse("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"boom\"}}").errorKind, "mcp_jsonrpc_error")
        @Expect(parseMcpCallResponse("{\"jsonrpc\":\"2.0\",\"result\":{\"unexpected\":true}}").ok, false)
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
        config.repoAllowlist = ["Cangjie/Compiler"]
        @Expect(writebackGate(config, state, event, McpResult(true, draft: "Authorization: Bearer x")).reason, "secret_detected")
        @Expect(writebackGate(config, state, event, McpResult(true, draft: "/Users/name/private-index")).reason, "local_path_detected")
        @Expect(writebackGate(config, state, GitCodeEvent("filtered", "cangjie", "compiler", "issue", "1", "CangjiePL", "", "", "x"), mcp).reason, "filtered_event")
        @Expect(writebackGate(config, state, event, mcp).allowed, true)
        let writer = FakeCommentWriter()
        let url = writer.write(event, mcp.draft, state)
        @Expect(url.contains("https://gitcode.com/cangjie/compiler/comments/"), true)
        @Expect(writebackGate(config, state, event, mcp).reason, "duplicate")
        @Expect(filterEvent(GitCodeEvent("self", "cangjie", "compiler", "issue", "1", "bot", "", "", writer.written[0])).reason, "self_marker")
    }

    @TestCase
    public func serviceLifecycleStopsAfterConfiguredScansAndHonorsOverlapGuard(): Unit {
        let config = defaultConfig()
        let clock = FakeClock()
        let state = MonitorState()
        let scheduler = FullScanScheduler(config, clock)
        let summary = runServiceTicks(config, clock, scheduler, state, ServiceControl(maxScans: 2), tickMinutes: 10)
        @Expect(summary.scans, 2)
        @Expect(summary.stopped, true)
        let overlapState = MonitorState()
        let overlapScheduler = FullScanScheduler(config, FakeClock())
        @Expect(overlapScheduler.begin(FakeClock(), overlapState), true)
        @Expect(overlapScheduler.begin(FakeClock(), overlapState), false)
        @Expect(overlapState.skippedOverlappingScans, 1)
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
