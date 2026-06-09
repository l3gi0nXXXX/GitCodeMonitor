package gitcodemonitor

import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@Test
public class GitCodeMonitorCoreServicePluginOnlyTest {
    private func tempDir(name: String): Path {
        let dir = Path("/tmp").join("${name}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(dir, recursive: true)
        dir
    }

    private func loadConfigJsonForTest(name: String, body: String): MonitorConfig {
        let dir = tempDir(name)
        let path = dir.join("metis.json")
        File.writeTo(path, body.toArray())
        let config = loadConfig(path: path.toString())
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
        config
    }

    @TestCase
    public func pluginOnlyConfigSummarySuppressesLegacyNotifierFields(): Unit {
        // T-NOTIFY-001, T-NOTIFY-003, T-SUITE-001
        let config = loadConfigJsonForTest(
            "gcm-plugin-only-legacy-notify",
            "{" +
                "\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"notifyNetworkEnabled\":true,\"statePath\":\".gitcodemonitor/state.json\"}," +
                "\"feishu\":{\"webhook\":\"https://open.feishu.cn/open-apis/bot/v2/hook/secret\"}," +
                "\"telegram\":{\"botToken\":\"123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef\",\"chatId\":\"chat-secret\"}" +
            "}"
        )

        let summary = configSummary(config) + "\n" + summarizeGcmPluginModeConfig(config).text

        @Expect(summary.contains("notifyNetworkEnabled"), false)
        @Expect(summary.contains("legacyNotify"), false)
        @Expect(summary.contains("notificationAuth"), false)
        @Expect(summary.contains("feishu"), false)
        @Expect(summary.contains("telegram"), false)
        @Expect(summary.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), false)
        @Expect(summary.contains("open.feishu.cn"), false)
    }

    @TestCase
    public func legacyRepoAllowlistDoesNotAuthorizeWritebackScope(): Unit {
        // T-PLUGIN-ONLY-005, T-SUITE-004
        let config = defaultConfig()
        config.dryRun = false
        config.autoReply = true
        config.repoAllowlist = ["Cangjie/community"]

        let decision = evaluateWritebackScope(config, "Cangjie/community")

        @Expect(decision.allowed, false)
        @Expect(decision.reason, "repo_not_allowlisted")

        let loaded = loadConfigJsonForTest(
            "gcm-plugin-only-legacy-allowlist",
            "{\"monitor\":{\"dryRun\":false,\"autoReply\":true,\"repoAllowlist\":[\"Cangjie/community\"]}}"
        )
        @Expect(loaded.repoAllowlist.size, 1)
        @Expect(loaded.writebackScope.allowedRepos.size, 0)
        @Expect(validateConfig(loaded).contains("writebackScope has no allowed orgs or repos"), true)
    }

    @TestCase
    public func gitCodeCommentWriterPostsIssueAndPrWithJsonBody(): Unit {
        // T-ROOT-004, T-WRITER-001, T-WRITER-002, T-WRITER-005
        let sender = FakeHttpSender()
        sender.nextResponse = HttpResponseSpec(201, body: "{\"html_url\":\"https://gitcode.com/Cangjie/community/issues/3#note_9\"}")
        let writer = GitCodeCommentWriter(GitCodeApiClient(baseUrl: "https://gitcode.example/api/v5", token: "secret-token"), sender: sender)
        let state = MonitorState()
        let issue = GitCodeEvent("issue-e1", "Cangjie", "community", "issue", "3", "alice", "", "https://gitcode.com/Cangjie/community/issues/3", "body")

        let issueUrl = writer.write(issue, "line one\nline two \"quoted\" @alice", state)

        @Expect(issueUrl.startsWith("error:"), false)
        @Expect(state.hasReply("issue-e1"), true)
        @Expect(sender.requests.size, 1)
        @Expect(sender.requests[0].method, "POST")
        @Expect(sender.requests[0].url, "https://gitcode.example/api/v5/repos/Cangjie/community/issues/3/comments")
        @Expect(sender.requests[0].body.contains("\\n"), true)
        @Expect(sender.requests[0].body.contains("\\\"quoted\\\""), true)
        @Expect(sender.requests[0].body.contains("auto-reply"), false)
        @Expect(sender.requests[0].body.contains("gitcodemonitor"), false)
        @Expect(sender.requests[0].body.contains("secret-token"), false)

        sender.nextResponse = HttpResponseSpec(201, body: "{\"html_url\":\"https://gitcode.com/Cangjie/community/pulls/8#note_10\"}")
        let pr = GitCodeEvent("pr-e1", "Cangjie", "community", "pr", "8", "alice", "", "https://gitcode.com/Cangjie/community/pulls/8", "body")
        let prUrl = writer.write(pr, "safe pr draft", state)

        @Expect(prUrl.startsWith("error:"), false)
        @Expect(state.hasReply("pr-e1"), true)
        @Expect(sender.requests.size, 2)
        @Expect(sender.requests[1].url, "https://gitcode.example/api/v5/repos/Cangjie/community/pulls/8/comments")
    }

    @TestCase
    public func gitCodeCommentWriterMapsFailuresWithoutMarkingReply(): Unit {
        // T-WRITER-003, T-WRITER-004
        let sender = FakeHttpSender()
        let writer = GitCodeCommentWriter(GitCodeApiClient(baseUrl: "https://gitcode.example/api/v5"), sender: sender)
        let event = GitCodeEvent("issue-e2", "Cangjie", "community", "issue", "3", "alice", "", "", "body")

        sender.nextResponse = HttpResponseSpec(403)
        let forbidden = writer.write(event, "safe draft", MonitorState())
        @Expect(forbidden, "error:gitcode_api_forbidden")

        let state = MonitorState()
        sender.nextResponse = HttpResponseSpec(500)
        let server = writer.write(event, "safe draft", state)
        @Expect(server, "error:server_error")
        @Expect(state.hasReply("issue-e2"), false)
    }
}
