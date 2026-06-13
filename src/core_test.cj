package gitcodemonitor

import std.collection.*
import std.fs.{Directory, File, Path, remove}
import std.time.DateTime
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

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
    public func p0p1AuthorPolicyScopedRulesParseNormalizeValidateAndDriveEffective(): Unit {
        // T-P0-B-001, T-P1-U-001, T-P1-U-002, T-P1-U-003, T-P1-U-004, T-P1-B-001, T-P1-B-002
        let scoped = loadConfigJsonForTest("gcm-p1-author-policy-scoped", "{" +
            "\"gitcode\":{\"authorPolicy\":{\"recordOnlyEnabled\":true,\"recordOnlyEmailDomains\":[\"@Huawei.com\"],\"recordOnly\":{" +
            "\"commentAuthor\":{\"ids\":[\" 856442 \",856442],\"emails\":[\" HuXiaoMing6@Huawei.com \"],\"usernames\":[\" L3Gi0n \"],\"emailDomains\":[\"H-Partners.com\"]}," +
            "\"targetAuthor\":{\"emails\":[\" Target@Example.com \"],\"emailDomains\":[\"corp.example\"]}," +
            "\"eventActor\":{\"ids\":[\"707874\"],\"usernames\":[\" Actor \"]}" +
            "}}}}"
        )
        @Expect(scoped.authorPolicy.commentAuthorRule.ids.size, 1)
        @Expect(scoped.authorPolicy.commentAuthorRule.ids[0], "856442")
        @Expect(scoped.authorPolicy.commentAuthorRule.emails[0], "huxiaoming6@huawei.com")
        @Expect(scoped.authorPolicy.commentAuthorRule.usernames[0], "l3gi0n")
        @Expect(scoped.authorPolicy.commentAuthorRule.emailDomains[0], "@h-partners.com")
        @Expect(scoped.authorPolicy.recordOnlyEmailDomains[0], "@huawei.com")
        @Expect(scoped.authorPolicy.targetAuthorRule.emailDomains.contains("@huawei.com"), true)
        @Expect(scoped.authorPolicy.targetAuthorRule.emailDomains.contains("@corp.example"), true)
        @Expect(scoped.authorPolicy.eventActorRule.ids[0], "707874")
        @Expect(authorPolicyRecordOnlyEffective(scoped.authorPolicy), true)
        @Expect(validateConfig(scoped), "ok")

        let empty = loadConfigJsonForTest("gcm-p1-author-policy-empty", "{\"gitcode\":{\"authorPolicy\":{\"recordOnlyEnabled\":true,\"recordOnly\":{\"commentAuthor\":{},\"targetAuthor\":{},\"eventActor\":{}},\"recordOnlyEmailDomains\":[]}}}")
        @Expect(authorPolicyRecordOnlyEffective(empty.authorPolicy), false)
        let disabled = loadConfigJsonForTest("gcm-p0-author-policy-disabled", "{\"gitcode\":{\"authorPolicy\":{\"recordOnlyEnabled\":false,\"recordOnly\":{\"commentAuthor\":{\"ids\":[\"856442\"]}}}}}")
        @Expect(authorPolicyRecordOnlyEffective(disabled.authorPolicy), false)

        @Expect(validateConfig(loadConfigJsonForTest("gcm-p1-bad-id", "{\"gitcode\":{\"authorPolicy\":{\"recordOnly\":{\"commentAuthor\":{\"ids\":[\"\"]}}}}}")).contains("authorPolicy author_policy_invalid_id"), true)
        @Expect(validateConfig(loadConfigJsonForTest("gcm-p1-bad-id-alpha", "{\"gitcode\":{\"authorPolicy\":{\"recordOnly\":{\"commentAuthor\":{\"ids\":[\"abc\"]}}}}}")).contains("authorPolicy author_policy_invalid_id"), true)
        @Expect(validateConfig(loadConfigJsonForTest("gcm-p1-bad-email", "{\"gitcode\":{\"authorPolicy\":{\"recordOnly\":{\"commentAuthor\":{\"emails\":[\"localpart\"]}}}}}")).contains("authorPolicy author_policy_invalid_email"), true)
        @Expect(validateConfig(loadConfigJsonForTest("gcm-p1-bad-username", "{\"gitcode\":{\"authorPolicy\":{\"recordOnly\":{\"commentAuthor\":{\"usernames\":[\"https://gitcode.com/l3gi0n\"]}}}}}")).contains("authorPolicy author_policy_invalid_username"), true)
        @Expect(validateConfig(loadConfigJsonForTest("gcm-p1-bad-wildcard", "{\"gitcode\":{\"authorPolicy\":{\"recordOnly\":{\"commentAuthor\":{\"usernames\":[\"*\"]}}}}}")).contains("authorPolicy author_policy_invalid_username"), true)
    }

    @TestCase
    public func t3GcmUnit001002003004MaintainerEmailConfigAddressBookAndMimeAreSafe(): Unit {
        // T3-GCM-UNIT-001, T3-GCM-UNIT-002, T3-GCM-UNIT-003, T3-GCM-UNIT-004, T3-GCM-BOUND-002, T3-GCM-BOUND-003
        let defaults = defaultConfig()
        @Expect(defaults.maintainerNotificationEmail.enabled, false)
        @Expect(configSummary(defaults).contains("password"), false)
        @Expect(configSummary(defaults).contains("SMTP_SECRET_VALUE"), false)

        let valid = loadConfigJsonForTest("gcm-maintainer-email-valid", "{" +
            "\"gitcode\":{\"maintainerNotification\":{\"email\":{" +
            "\"enabled\":true,\"transport\":\"smtp\"," +
            "\"smtp\":{\"host\":\"smtp.example.com\",\"port\":465,\"security\":\"ssl\",\"username\":\"bot@example.com\",\"passwordEnv\":\"GCM_SMTP_PASSWORD\"}," +
            "\"from\":\"bot@example.com\",\"replyTo\":\"reply@example.com\",\"allowedDomains\":[\"example.com\"]," +
            "\"addressBook\":{\"@Alice\":[\"Alice@Example.com\",\"alice@example.com\"],\"bob\":[\"BOB@example.com\"]}" +
            "}}}}"
        )
        @Expect(valid.maintainerNotificationEmail.enabled, true)
        @Expect(valid.maintainerNotificationEmail.userLookup.enabled, true)
        @Expect(valid.maintainerNotificationEmail.userLookup.timeoutMs, 10000)
        @Expect(valid.maintainerNotificationEmail.userLookup.cacheTtlMs, 24 * 60 * 60 * 1000)
        @Expect(valid.maintainerNotificationEmail.userLookup.maxCacheEntries, 4096)
        @Expect(valid.maintainerNotificationEmail.userLookup.fallbackToAddressBook, true)
        @Expect(valid.maintainerNotificationEmail.smtp.passwordEnv, "GCM_SMTP_PASSWORD")
        @Expect(valid.maintainerNotificationEmail.addressBook.get("@alice").getOrThrow()[0], "alice@example.com")
        @Expect(valid.maintainerNotificationEmail.addressBook.get("@bob").getOrThrow()[0], "bob@example.com")
        @Expect(validateConfig(valid), "ok")
        @Expect(configSummary(valid).contains("GCM_SMTP_PASSWORD"), false)

        let badHost = loadConfigJsonForTest("gcm-maintainer-email-bad-host", "{\"gitcode\":{\"maintainerNotification\":{\"email\":{\"enabled\":true,\"transport\":\"smtp\",\"smtp\":{\"port\":465,\"security\":\"ssl\",\"username\":\"bot@example.com\",\"passwordEnv\":\"GCM_SMTP_PASSWORD\"},\"from\":\"bot@example.com\"}}}}")
        @Expect(validateConfig(badHost).contains("maintainerNotification.email.smtp.host"), true)
        let badPort = loadConfigJsonForTest("gcm-maintainer-email-bad-port", "{\"gitcode\":{\"maintainerNotification\":{\"email\":{\"enabled\":true,\"transport\":\"smtp\",\"smtp\":{\"host\":\"smtp.example.com\",\"port\":70000,\"security\":\"ssl\",\"username\":\"bot@example.com\",\"passwordEnv\":\"GCM_SMTP_PASSWORD\"},\"from\":\"bot@example.com\"}}}}")
        @Expect(validateConfig(badPort).contains("maintainerNotification.email.smtp.port"), true)
        let badSecurity = loadConfigJsonForTest("gcm-maintainer-email-bad-security", "{\"gitcode\":{\"maintainerNotification\":{\"email\":{\"enabled\":true,\"transport\":\"smtp\",\"smtp\":{\"host\":\"smtp.example.com\",\"port\":25,\"security\":\"none\",\"username\":\"bot@example.com\",\"passwordEnv\":\"GCM_SMTP_PASSWORD\"},\"from\":\"bot@example.com\"}}}}")
        @Expect(validateConfig(badSecurity).contains("maintainerNotification.email.smtp.security"), true)
        let badEnv = loadConfigJsonForTest("gcm-maintainer-email-bad-env", "{\"gitcode\":{\"maintainerNotification\":{\"email\":{\"enabled\":true,\"transport\":\"smtp\",\"smtp\":{\"host\":\"smtp.example.com\",\"port\":465,\"security\":\"ssl\",\"username\":\"bot@example.com\",\"passwordEnv\":\"bad env\"},\"from\":\"bot@example.com\"}}}}")
        @Expect(validateConfig(badEnv).contains("maintainerNotification.email.smtp.passwordEnv"), true)
        let badDomain = loadConfigJsonForTest("gcm-maintainer-email-bad-domain", "{\"gitcode\":{\"maintainerNotification\":{\"email\":{\"enabled\":true,\"transport\":\"smtp\",\"smtp\":{\"host\":\"smtp.example.com\",\"port\":465,\"security\":\"ssl\",\"username\":\"bot@example.com\",\"passwordEnv\":\"GCM_SMTP_PASSWORD\"},\"from\":\"bot@example.com\",\"allowedDomains\":[\"example.com\"],\"addressBook\":{\"@alice\":[\"alice@other.test\"]}}}}}")
        @Expect(validateConfig(badDomain).contains("maintainerNotification.email.addressBook"), true)

        let message = MaintainerEmailMessage(["alice@example.com"], "中文 subject", "第一行\n.第二行\nAuthorization: Bearer secret\n/Users/alice/private", repo: "Cangjie/community", kind: "pr", number: "8", url: "https://gitcode.com/Cangjie/community/pulls/8", replyUrl: "https://gitcode.com/Cangjie/community/pulls/8#note_1")
        let mime = buildSmtpMimeMessage(message, valid.maintainerNotificationEmail)
        @Expect(mime.ok, true)
        @Expect(mime.data.contains("\r\n"), true)
        @Expect(mime.data.contains("Content-Type: text/plain; charset=utf-8"), true)
        @Expect(mime.data.contains("\r\n..第二行"), true)
        @Expect(mime.data.contains("Bearer secret"), false)
        @Expect(mime.data.contains("/Users/alice"), false)
        @Expect(mime.data.contains("GCM_SMTP_PASSWORD"), false)
    }

    @TestCase
    public func e1e2MaintainerEmailUserLookupRequestParserCacheAndResolverAreSafe(): Unit {
        // E1-UNIT-001, E1-UNIT-002, E1-POS-001, E1-NEG-001, E1-NEG-002, E1-BOUND-001, E1-BOUND-002, E2-UNIT-001, E2-UNIT-002, E2-POS-001, E2-POS-002, E2-NEG-001, E2-NEG-002, E2-BOUND-001, E2-BOUND-002
        let config = loadConfigJsonForTest("gcm-maintainer-email-user-lookup", "{" +
            "\"gitcode\":{\"maintainerNotification\":{\"email\":{" +
            "\"enabled\":true,\"transport\":\"smtp\"," +
            "\"userLookup\":{\"enabled\":true,\"timeoutMs\":15000,\"cacheTtlMs\":2000,\"maxCacheEntries\":2,\"fallbackToAddressBook\":true}," +
            "\"smtp\":{\"host\":\"smtp.example.com\",\"port\":465,\"security\":\"ssl\",\"username\":\"bot@example.com\",\"passwordEnv\":\"GCM_SMTP_PASSWORD\"}," +
            "\"from\":\"bot@example.com\",\"allowedDomains\":[\"example.com\"]," +
            "\"addressBook\":{\"@fallback\":[\"fallback@example.com\"]}" +
            "}}}}"
        ).maintainerNotificationEmail
        @Expect(config.userLookup.enabled, true)
        @Expect(config.userLookup.timeoutMs, 15000)
        @Expect(config.userLookup.cacheTtlMs, 2000)
        @Expect(config.userLookup.maxCacheEntries, 2)
        @Expect(config.userLookup.fallbackToAddressBook, true)

        let client = GitCodeApiClient(baseUrl: "https://api.gitcode.com/api/v5", token: "secret-token")
        let request = client.userProfileRequest("Alice")
        @Expect(request.method, "GET")
        @Expect(request.url, "https://api.gitcode.com/api/v5/users/Alice")
        @Expect(request.redactedLogLine().contains("secret-token"), false)

        let parsed = parseGitCodeUserEmailResponse("Alice", 200, "{\"login\":\"Alice\",\"email\":\"Alice@Example.com\",\"github_account\":\"wrong@example.com\"}", allowedDomains: ["example.com"])
        @Expect(parsed.status, "resolved")
        @Expect(parsed.emails[0], "alice@example.com")
        let githubOnly = parseGitCodeUserEmailResponse("alice", 200, "{\"login\":\"alice\",\"github_account\":\"alice@example.com\"}", allowedDomains: ["example.com"])
        @Expect(githubOnly.status, "email_unavailable")
        @Expect(githubOnly.emails.size, 0)
        let filtered = parseGitCodeUserEmailResponse("alice", 200, "{\"email\":\"alice@other.test\"}", allowedDomains: ["example.com"])
        @Expect(filtered.status, "email_filtered")
        @Expect(filtered.emails.size, 0)
        @Expect(parseGitCodeUserEmailResponse("alice", 403, "{}").status, "auth_failed")
        @Expect(parseGitCodeUserEmailResponse("alice", 404, "{}").status, "user_not_found")
        @Expect(parseGitCodeUserEmailResponse("alice", 429, "{}").retryable, true)
        @Expect(parseGitCodeUserEmailResponse("alice", 500, "{}").status, "network_error")
        @Expect(parseGitCodeUserEmailResponse("alice", 200, "{").status, "invalid_content")

        @Expect(normalizeMaintainerLogin("@Alice"), "alice")
        @Expect(normalizeMaintainerLogin("Alice"), "alice")
        @Expect(normalizeMaintainerLogin("a/b"), "")
        let invalidSender = FakeHttpSender()
        let invalid = resolveGitCodeUserEmail("a/b", client, invalidSender, config, MaintainerEmailLookupCache())
        @Expect(invalid.status, "invalid_login")
        @Expect(invalidSender.requests.size, 0)

        let cache = MaintainerEmailLookupCache(maxEntries: 1, ttlMs: 1000)
        cache.put(GitCodeUserEmailLookupResult("alice", emails: ["alice@example.com"], status: "resolved"), nowMs: 1000)
        @Expect(cache.get("alice", nowMs: 1500).isSome(), true)
        @Expect(cache.get("alice", nowMs: 2501).isNone(), true)
        cache.put(GitCodeUserEmailLookupResult("alice", emails: ["alice@example.com"], status: "resolved"), nowMs: 3000)
        cache.put(GitCodeUserEmailLookupResult("bob", emails: ["bob@example.com"], status: "resolved"), nowMs: 3001)
        @Expect(cache.get("alice", nowMs: 3002).isNone(), true)
        @Expect(cache.get("bob", nowMs: 3002).isSome(), true)

        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(200, body: "{\"email\":\"Alice@Example.com\"}"))
        let lookupCache = MaintainerEmailLookupCache()
        let resolved = resolveMaintainerEmailsForMentions(["@Alice", "@alice"], client, sender, config, lookupCache)
        @Expect(resolved.status, "resolved")
        @Expect(resolved.emails.size, 1)
        @Expect(resolved.emails[0], "alice@example.com")
        @Expect(sender.requests.size, 1)
        @Expect(sender.requests[0].timeoutMs, 15000)

        let failedSender = FakeHttpSender()
        failedSender.enqueue(HttpResponseSpec(500, body: "{\"message\":\"token=secret /Users/alice/private\"}"))
        let failed = resolveMaintainerEmailsForMentions(["@missing"], client, failedSender, config, MaintainerEmailLookupCache())
        @Expect(failed.status, "network_error")
        @Expect(failed.retryable, true)
        @Expect(failed.emails.size, 0)
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

    @TestCase
    public func ctxP1U001IssueDetailAndPreviousCommentsUseTriggerBoundary(): Unit {
        // CTX-P1-U-001
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(200, body: "{\"iid\":42,\"title\":\"Issue title\",\"description\":\"Issue original body\",\"author\":{\"username\":\"alice\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/42\"}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"comments\":[" +
            "{\"id\":1,\"body\":\"previous one\",\"author\":{\"username\":\"bob\"},\"created_at_ms\":1000,\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/42#note_1\"}," +
            "{\"id\":2,\"body\":\"previous two\",\"author\":{\"username\":\"carol\"},\"created_at_ms\":2000,\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/42#note_2\"}," +
            "{\"id\":3,\"body\":\"trigger comment\",\"author\":{\"username\":\"dave\"},\"created_at_ms\":3000,\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/42#note_3\"}" +
        "]}"))
        let transport = GitCodeHttpTransport(GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5"), sender: sender, pageSize: 100)
        let event = GitCodeEvent("gitcode:cangjie/compiler:issue:42:comment:3", "cangjie", "compiler", "issue", "42", "dave", "", "https://gitcode.com/cangjie/compiler/issues/42#note_3", "trigger comment")

        let context = fetchGitCodeDiscussionContext(transport, event)

        @Expect(context.status, "resolved")
        @Expect(context.parent.kind, "issue")
        @Expect(context.parent.body, "Issue original body")
        @Expect(context.triggerComment.id, "3")
        @Expect(context.triggerComment.body, "trigger comment")
        @Expect(context.previousComments.size, 2)
        @Expect(context.previousComments[0].body, "previous one")
        @Expect(context.previousComments[1].body, "previous two")
        @Expect(context.previousCommentsTotal, 2)
        @Expect(context.previousCommentsIncluded, 2)
        @Expect(sender.requests[0].url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/issues/42")
        @Expect(sender.requests[1].url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/issues/42/comments?page=1&per_page=100")
    }

    @TestCase
    public func ctxP1U002PrDetailAndPrCommentsUsePullsEndpoint(): Unit {
        // CTX-P1-U-002
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(200, body: "{\"number\":7,\"title\":\"PR title\",\"body\":\"PR original body\",\"user\":{\"login\":\"alice\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/pulls/7\"}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"comments\":[" +
            "{\"id\":10,\"body\":\"pr previous\",\"user\":{\"login\":\"reviewer\"},\"created_at_ms\":1000,\"html_url\":\"https://gitcode.com/cangjie/compiler/pulls/7#note_10\"}," +
            "{\"id\":11,\"body\":\"pr trigger\",\"user\":{\"login\":\"dave\"},\"created_at_ms\":2000,\"html_url\":\"https://gitcode.com/cangjie/compiler/pulls/7#note_11\"}" +
        "]}"))
        let transport = GitCodeHttpTransport(GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5"), sender: sender, pageSize: 100)
        let event = GitCodeEvent("gitcode:cangjie/compiler:pr:7:comment:11", "cangjie", "compiler", "pr", "7", "dave", "", "https://gitcode.com/cangjie/compiler/pulls/7#note_11", "pr trigger")

        let context = fetchGitCodeDiscussionContext(transport, event)

        @Expect(context.status, "resolved")
        @Expect(context.parent.kind, "pr")
        @Expect(context.parent.body, "PR original body")
        @Expect(context.previousComments.size, 1)
        @Expect(context.previousComments[0].body, "pr previous")
        @Expect(sender.requests[0].url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/pulls/7")
        @Expect(sender.requests[1].url, "https://mock.gitcode.test/api/v5/repos/cangjie/compiler/pulls/7/comments?page=1&per_page=100")
    }

    @TestCase
    public func ctxP1B001AndP4B001OversizedCommentsAndParentAreTruncatedAsValidJson(): Unit {
        // CTX-P1-B-001, CTX-P4-B-001
        let sender = FakeHttpSender()
        let longParent = String(Array<Rune>(9000, repeat: r'p'))
        sender.enqueue(HttpResponseSpec(200, body: "{\"iid\":55,\"title\":\"Long issue\",\"description\":\"${longParent}\",\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/55\"}"))
        let commentItems = ArrayList<String>()
        for (i in 1..=50) {
            let body = "comment-${i}-" + String(Array<Rune>(900, repeat: r'x'))
            commentItems.add("{\"id\":${i},\"body\":\"${body}\",\"created_at_ms\":${i * 1000},\"author\":{\"username\":\"user${i}\"}}")
        }
        sender.enqueue(HttpResponseSpec(200, body: "{\"comments\":[${joinStrings(commentItems.toArray(), ",")}]}"))
        let transport = GitCodeHttpTransport(GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5"), sender: sender, pageSize: 100)
        let event = GitCodeEvent("gitcode:cangjie/compiler:issue:55:comment:50", "cangjie", "compiler", "issue", "55", "user50", "", "https://gitcode.com/cangjie/compiler/issues/55#note_50", "trigger")

        let context = fetchGitCodeDiscussionContext(transport, event)
        let json = context.toJsonString()
        let root = JsonValue.fromStr(json).asObject()

        @Expect(context.truncated, true)
        @Expect(context.previousCommentsTotal, 49)
        @Expect(context.previousCommentsIncluded < context.previousCommentsTotal, true)
        @Expect(firstJsonString(root, ["status"]), "resolved")
        @Expect(json.contains("\"previousComments\""), true)
    }

    @TestCase
    public func ctxP1B002MissingCreatedAtKeepsApiOrderAndDiagnosesOrderDegraded(): Unit {
        // CTX-P1-B-002
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(200, body: "{\"iid\":43,\"title\":\"Issue title\",\"description\":\"Issue body\"}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"comments\":[" +
            "{\"id\":1,\"body\":\"api first\"}," +
            "{\"id\":2,\"body\":\"api second\"}," +
            "{\"id\":3,\"body\":\"api trigger\"}" +
        "]}"))
        let transport = GitCodeHttpTransport(GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5"), sender: sender, pageSize: 100)
        let event = GitCodeEvent("gitcode:cangjie/compiler:issue:43:comment:3", "cangjie", "compiler", "issue", "43", "dave", "", "", "api trigger")

        let context = fetchGitCodeDiscussionContext(transport, event)

        @Expect(context.previousComments.size, 2)
        @Expect(context.previousComments[0].id, "1")
        @Expect(context.previousComments[1].id, "2")
        @Expect(context.diagnostics.contains("order_degraded"), true)
    }

    @TestCase
    public func ctxP1P001DetailFailureFallsBackToEnvelopeAndKeepsComments(): Unit {
        // CTX-P1-P-001
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(500, body: "{\"message\":\"temporary failure\"}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"comments\":[" +
            "{\"id\":1,\"body\":\"fallback previous\",\"created_at_ms\":1000}," +
            "{\"id\":2,\"body\":\"fallback trigger\",\"created_at_ms\":2000}" +
        "]}"))
        let transport = GitCodeHttpTransport(GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5"), sender: sender, pageSize: 100)
        let event = GitCodeEvent("gitcode:cangjie/compiler:issue:44:comment:2", "cangjie", "compiler", "issue", "44", "dave", "", "", "fallback trigger")
        let envelope = GitCodeWebhookEnvelope("Note Hook", "issue", itemId: "44", commentId: "2", title: "Envelope title", body: "Envelope parent body", commentBody: "fallback trigger")

        let context = fetchGitCodeDiscussionContext(transport, event, envelope: Some<GitCodeWebhookEnvelope>(envelope))

        @Expect(context.status, "degraded")
        @Expect(context.parent.body, "Envelope parent body")
        @Expect(context.parent.source, "webhook_envelope")
        @Expect(context.previousComments.size, 1)
        @Expect(context.previousComments[0].body, "fallback previous")
        @Expect(context.diagnostics.contains("detail_fetch_failed:server_error"), true)
    }

    @TestCase
    public func ctxP1N001ApiErrorsMapToDegradedDiagnosticsWithoutSecrets(): Unit {
        // CTX-P1-N-001
        for ((statusCode, expected) in [(403, "forbidden"), (429, "rate_limited"), (500, "server_error")]) {
            let sender = FakeHttpSender()
            sender.enqueue(HttpResponseSpec(statusCode, body: "{\"message\":\"PRIVATE-TOKEN fake-api-token\"}", headers: [("Retry-After", "2")]))
            sender.enqueue(HttpResponseSpec(statusCode, body: "{\"message\":\"gitcode_token=fake-api-token\"}", headers: [("Retry-After", "2")]))
            let transport = GitCodeHttpTransport(GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5", token: "fake-api-token"), sender: sender, pageSize: 100)
            let event = GitCodeEvent("gitcode:cangjie/compiler:issue:45:comment:9", "cangjie", "compiler", "issue", "45", "dave", "", "", "trigger")

            let context = fetchGitCodeDiscussionContext(transport, event)
            let json = context.toJsonString()

            @Expect(context.status, "degraded")
            @Expect(json.contains(expected), true)
            @Expect(json.contains("fake-api-token"), false)
            @Expect(json.contains("PRIVATE-TOKEN"), false)
            @Expect(json.contains("gitcode_token="), false)
        }
    }

    @TestCase
    public func ctxP1N002ContextJsonRedactsSecretsAndLocalPaths(): Unit {
        // CTX-P1-N-002
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(200, body: "{\"iid\":46,\"title\":\"Issue title\",\"description\":\"parent body\"}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"comments\":[" +
            "{\"id\":1,\"body\":\"gitcode_token=fake-secret /Users/example/private\",\"created_at_ms\":1000}," +
            "{\"id\":2,\"body\":\"trigger with /Users/example/.metis\",\"created_at_ms\":2000}" +
        "]}"))
        let transport = GitCodeHttpTransport(GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5"), sender: sender, pageSize: 100)
        let event = GitCodeEvent("gitcode:cangjie/compiler:issue:46:comment:2", "cangjie", "compiler", "issue", "46", "dave", "", "", "trigger with /Users/example/.metis")

        let context = fetchGitCodeDiscussionContext(transport, event)
        let json = context.toJsonString()

        @Expect(json.contains("fake-secret"), false)
        @Expect(json.contains("/Users/example"), false)
        @Expect(json.contains("[REDACTED"), true)
    }
}
