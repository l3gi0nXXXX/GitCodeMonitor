package gitcodemonitor

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@Test
public class GitCodeWebhookETest {
    private func tempDir(name: String): Path {
        let dir = Path("/tmp").join("${name}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(dir, recursive: true)
        dir
    }

    private func writeConfig(dir: Path, text: String): String {
        let path = dir.join("gcm.json")
        File.writeTo(path, text.toArray())
        path.toString()
    }

    private func enabledConfig(queueDir: String): MonitorConfig {
        let config = defaultConfig()
        config.statePath = Path(queueDir).parent.join("state.json").toString()
        config.webhook = WebhookReceiverConfig(
            enabled: true,
            bindHost: "127.0.0.1",
            port: 18080,
            publicBaseUrl: "https://gcm.example.com",
            maxBodyBytes: 4096,
            queueDir: queueDir,
            endpoints: [
                WebhookEndpointConfig(
                    "main",
                    "/webhooks/gitcode/main",
                    token: "token-secret",
                    signatureSecret: "",
                    allowedEvents: ["Merge Request Hook", "Issue Hook", "Note Hook"],
                    enabled: true
                )
            ]
        )
        config
    }

    private func mrPayload(): String {
        "{" +
            "\"object_kind\":\"merge_request\"," +
            "\"project\":{\"path_with_namespace\":\"cangjie/compiler\"}," +
            "\"object_attributes\":{\"iid\":71,\"action\":\"open\",\"title\":\"Fix parser\",\"description\":\"please review\",\"url\":\"https://gitcode.com/cangjie/compiler/pulls/71\"}," +
            "\"user\":{\"name\":\"alice\",\"username\":\"alice\"}" +
        "}"
    }

    private func notePayload(noteableType: String): String {
        "{" +
            "\"object_kind\":\"note\"," +
            "\"project\":{\"path_with_namespace\":\"cangjie/compiler\"}," +
            "\"merge_request\":{\"iid\":71,\"title\":\"Fix parser\",\"url\":\"https://gitcode.com/cangjie/compiler/pulls/71\"}," +
            "\"object_attributes\":{\"id\":9001,\"note\":\"Looks good token=secret /Users/alice/.metis\",\"noteable_type\":\"${noteableType}\",\"url\":\"https://gitcode.com/cangjie/compiler/pulls/71#note_9001\"}," +
            "\"user\":{\"name\":\"bob\"}" +
        "}"
    }

    @TestCase
    public func configParsesTopLevelAndGitCodeWebhookWithoutLeakingSecrets(): Unit {
        let dir = tempDir("gcm-webhook-config")
        let queueDir = dir.join("queue").toString()
        let configPath = writeConfig(dir, "{" +
            "\"monitor\":{\"statePath\":\"${dir.join("state.json").toString()}\"}," +
            "\"gitcode\":{\"token\":\"gitcode-secret\",\"webhook\":{\"enabled\":true,\"bindHost\":\"0.0.0.0\",\"port\":18081,\"publicBaseUrl\":\"https://gcm.example.com/\",\"queueDir\":\"${queueDir}\",\"maxBodyBytes\":2048,\"endpoints\":[{\"id\":\"main\",\"path\":\"/webhooks/gitcode/main\",\"token\":\"receiver-token\",\"signatureSecret\":\"signature-secret\",\"allowedEvents\":[\"Merge Request Hook\",\"Issue Hook\"]}]}}" +
        "}")
        let config = loadConfig(path: configPath)
        @Expect(config.webhook.enabled, true)
        @Expect(config.webhook.port, 18081)
        @Expect(config.webhook.endpoints.size, 1)
        @Expect(config.webhook.endpoints[0].allowedEvents.size, 2)
        @Expect(validateWebhookReceiverConfig(config.webhook).ok, true)
        let summary = configSummary(config)
        @Expect(summary.contains("webhook=enabled"), true)
        @Expect(summary.contains("receiver-token"), false)
        @Expect(summary.contains("signature-secret"), false)
        @Expect(summary.contains("gitcode-secret"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func receiverValidatesRequestAuthAndFastAcksAfterQueueEnqueue(): Unit {
        let dir = tempDir("gcm-webhook-receiver")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let ok = handleGitCodeWebhookRequest(config, WebhookHttpRequest(
            "POST",
            "/webhooks/gitcode/main",
            [("Content-Type", "application/json"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook"), ("X-GitCode-Delivery", "delivery/../71")],
            mrPayload().toArray(),
            "203.0.113.1"
        ), queue)
        @Expect(ok.statusCode, 202)
        @Expect(ok.body.contains("accepted"), true)
        @Expect(queue.countByStatus("pending"), 1)
        @Expect(queue.countByStatus("processing"), 0)

        let badToken = handleGitCodeWebhookRequest(config, WebhookHttpRequest(
            "POST",
            "/webhooks/gitcode/main",
            [("Content-Type", "application/json"), ("X-GitCode-Token", "wrong"), ("X-GitCode-Event", "Merge Request Hook")],
            mrPayload().toArray(),
            "203.0.113.2"
        ), queue)
        @Expect(badToken.statusCode, 401)
        @Expect(queue.countByStatus("pending"), 1)

        let tooLarge = handleGitCodeWebhookRequest(config, WebhookHttpRequest(
            "POST",
            "/webhooks/gitcode/main",
            [("Content-Type", "application/json"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook")],
            Array<Byte>(4097, repeat: 120),
            "203.0.113.3"
        ), queue)
        @Expect(tooLarge.statusCode, 413)
        @Expect(tooLarge.body.contains("{\""), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func queueClaimsRetriesDeadLettersReplaysAndCancelsSafely(): Unit {
        let dir = tempDir("gcm-webhook-queue")
        let queue = WebhookQueue(dir.join("queue").toString())
        let delivery = GitCodeWebhookDelivery("delivery/../A", "main", "Issue Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash")
        @Expect(queue.enqueue(delivery, "{\"ok\":true}".toArray()).status, "enqueued")
        @Expect(queue.enqueue(delivery, "{\"ok\":false}".toArray()).status, "already_exists")
        let claimed = queue.claim(2000, 1)
        @Expect(claimed.size, 1)
        @Expect(claimed[0].deliveryId, "delivery/../A")
        @Expect(exists(Path(queue.statusPath("pending", delivery.deliveryId))), false)
        @Expect(queue.markRetry(claimed[0].deliveryId, "metis_unavailable", 3000).status, "retry_scheduled")
        @Expect(queue.countByStatus("pending"), 1)
        let claimedAgain = queue.claim(4000, 1)
        @Expect(queue.markDeadLetter(claimedAgain[0].deliveryId, "missing_repo").status, "dead_lettered")
        @Expect(queue.countByStatus("dead-letter"), 1)
        @Expect(replayWebhookDelivery(queue, claimedAgain[0].deliveryId).status, "replay_accepted")
        @Expect(queue.countByStatus("pending"), 1)
        let pending = queue.claim(5000, 1)
        @Expect(cancelWebhookDelivery(queue, pending[0].deliveryId).status, "cancelled")
        @Expect(queue.countByStatus("cancelled"), 1)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func parserNormalizesSupportedPayloadsAndRedactsDiagnostics(): Unit {
        let mr = parseGitCodeWebhookPayload("Merge Request Hook", mrPayload())
        @Expect(mr.ok, true)
        @Expect(mr.event.id, "gitcode:cangjie/compiler:pr:71")
        @Expect(mr.event.itemKind, "pr")
        let note = parseGitCodeWebhookPayload("Note Hook", notePayload("MergeRequest"))
        @Expect(note.ok, true)
        @Expect(note.event.id, "gitcode:cangjie/compiler:pr:71:comment:9001")
        @Expect(note.event.content.contains("token=secret"), false)
        @Expect(note.event.content.contains("/Users/"), false)
        let ignored = parseGitCodeWebhookPayload("Note Hook", notePayload("Commit"))
        @Expect(ignored.ignored, true)
        @Expect(ignored.ignoreReason, "unsupported_noteable_type")
        let missing = parseGitCodeWebhookPayload("Issue Hook", "{\"object_attributes\":{\"action\":\"open\"}}")
        @Expect(missing.ok, false)
        @Expect(missing.errorKind, "missing_repo")
        @Expect(missing.diagnostic.contains("{\"object_attributes\""), false)
    }

    @TestCase
    public func processorReusesRuntimeEventPathWithoutBaselineSeed(): Unit {
        let dir = tempDir("gcm-webhook-processor")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let delivery = GitCodeWebhookDelivery("d1", "main", "Merge Request Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash")
        @Expect(queue.enqueue(delivery, mrPayload().toArray()).ok, true)
        let sender = FakeHttpSender()
        sender.nextResponse = HttpResponseSpec(200, body: "{\"approved\":true,\"draft\":\"thanks\"}")
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = MonitorState()
        let result = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1)
        @Expect(result.processed, 1)
        @Expect(state.hasSeen("gitcode:cangjie/compiler:pr:71"), true)
        @Expect(queue.countByStatus("processed"), 1)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func statusReconcileAndPluginCapabilitiesReturnStructuredSafePayloads(): Unit {
        let dir = tempDir("gcm-webhook-status")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("dlq-1", "main", "Issue Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash"), "{}".toArray()).ok, true)
        let status = renderWebhookStatus(config, queue)
        @Expect(status.contains("pending=1"), true)
        @Expect(status.contains("token-secret"), false)
        let client = GitCodeApiClient(token: "gitcode-token")
        let hookReq = client.createRepoWebhookRequest(GitCodeRepo("cangjie", "compiler"), "https://gcm.example.com/webhooks/gitcode/main", "receiver-token", ["Merge Request Hook"])
        @Expect(hookReq.method, "POST")
        @Expect(hookReq.redactedLogLine().contains("gitcode-token"), false)
        let reconcile = reconcileWebhookHooksDryRun(config, [GitCodeRepo("cangjie", "compiler")])
        @Expect(reconcile.results[0].status, "missing")

        let caps = requiredGitCodeMonitorCapabilityIds()
        @Expect(arrayContains(caps, "gitcode.webhook.status"), true)
        @Expect(arrayContains(caps, "gitcode.webhook.reconcile_events"), true)
        let runtime = RuntimeContainer(config)
        let state = MonitorState()
        let frame = ServiceFrame("request", "webhook-status-1", GCM_SERVICE_PLUGIN_ID, method: "invokeCapability", capabilityId: "gitcode.webhook.status", correlationId: "corr-webhook-status", payload: "{}")
        let handled = handleGcmPluginInputLine(encodeServiceFrame(frame).trimAscii(), config, runtime, state)
        @Expect(handled.ok, true)
        @Expect(handled.frame.payload.contains("\"summary\""), true)
        @Expect(handled.frame.payload.contains("token-secret"), false)
        let reconcilePayload = "{" +
            "\"mode\":\"async\"," +
            "\"jobId\":\"gcm-reconcile-1\"," +
            "\"idempotencyKey\":\"idem-1\"," +
            "\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"bot\",\"peerId\":\"chat\"}," +
            "\"limits\":{\"maxRepos\":1,\"maxItems\":2}," +
            "\"options\":{\"dryRun\":true}" +
        "}"
        let reconcileFrame = ServiceFrame("request", "webhook-reconcile-1", GCM_SERVICE_PLUGIN_ID, method: "invokeCapability", capabilityId: "gitcode.webhook.reconcile_events", correlationId: "corr-webhook-reconcile", payload: reconcilePayload)
        let reconcileHandled = handleGcmPluginInputLine(encodeServiceFrame(reconcileFrame).trimAscii(), config, runtime, state)
        @Expect(reconcileHandled.ok, true)
        @Expect(reconcileHandled.asyncJobId, "gcm-reconcile-1")
        @Expect(reconcileHandled.frame.payload.contains("gcm-reconcile-1"), true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }
}
