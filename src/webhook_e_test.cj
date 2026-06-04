package gitcodemonitor

import std.fs.{Directory, File, Path, exists, remove}
import std.time.*
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

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

    private func issuePayload(): String {
        "{" +
            "\"object_kind\":\"issue\"," +
            "\"project\":{\"path_with_namespace\":\"cangjie/compiler\"}," +
            "\"object_attributes\":{\"iid\":72,\"action\":\"open\",\"title\":\"Fix docs\",\"description\":\"please document\",\"url\":\"https://gitcode.com/cangjie/compiler/issues/72\"}," +
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

    private func fixtureLine(name: String): String {
        let candidates = [
            "test/fixtures/service_plugin/gcm_webhook/${name}",
            "../test/fixtures/service_plugin/gcm_webhook/${name}",
            "fixtures/service_plugin/gcm_webhook/${name}"
        ]
        for (path in candidates) {
            if (exists(Path(path))) {
                return String.fromUtf8(File.readFrom(Path(path))).trimAscii()
            }
        }
        ""
    }

    private func payloadHasField(payload: String, field: String): Bool {
        let root = JsonValue.fromStr(payload).asObject()
        match (root.get(field)) {
            case Some(_) => true
            case None => false
        }
    }

    private func payloadString(payload: String, field: String): String {
        let root = JsonValue.fromStr(payload).asObject()
        firstJsonString(root, [field])
    }

    private func stateFileSize(path: String): Int64 {
        if (!exists(Path(path))) { return 0 }
        File.readFrom(Path(path)).size
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
    public func httpServerRequestConversionAndHandlerKeepReceiverSemantics(): Unit {
        let dir = tempDir("gcm-webhook-http-server")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let converted = convertWebhookHttpRequest(
            "POST",
            "/webhooks/gitcode/main",
            [("Content-Type", "application/json"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook"), ("X-GitCode-Delivery", "delivery-http-1")],
            mrPayload().toArray(),
            "198.51.100.11"
        )
        @Expect(converted.method, "POST")
        @Expect(converted.path, "/webhooks/gitcode/main")
        @Expect(webhookHeader(converted.headers, ["Content-Type"]), "application/json")
        @Expect(String.fromUtf8(converted.body).contains("\"merge_request\""), true)
        @Expect(converted.remoteAddr, "198.51.100.11")

        let ok = handleWebhookHttpServerRequest(config, queue, converted)
        @Expect(ok.statusCode, 202)
        @Expect(queue.countByStatus("pending"), 1)
        let duplicate = handleWebhookHttpServerRequest(config, queue, converted)
        @Expect(duplicate.statusCode, 202)
        @Expect(duplicate.body.contains("duplicate accepted"), true)
        @Expect(queue.countByStatus("pending"), 1)

        @Expect(handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest("GET", "/webhooks/gitcode/main", converted.headers, Array<Byte>(), "198.51.100.12")).statusCode, 405)
        @Expect(handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest("POST", "/wrong", converted.headers, mrPayload().toArray(), "198.51.100.13")).statusCode, 404)
        @Expect(handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest("POST", "/webhooks/gitcode/main", [("Content-Type", "application/json"), ("X-GitCode-Token", "wrong"), ("X-GitCode-Event", "Merge Request Hook")], mrPayload().toArray(), "198.51.100.14")).statusCode, 401)
        @Expect(handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest("POST", "/webhooks/gitcode/main", [("Content-Type", "text/plain"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook")], mrPayload().toArray(), "198.51.100.15")).statusCode, 415)
        @Expect(handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest("POST", "/webhooks/gitcode/main", [("Content-Type", "application/json"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook")], "{".toArray(), "198.51.100.16")).statusCode, 400)
        @Expect(handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest("POST", "/webhooks/gitcode/main", [("Content-Type", "application/json"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook")], Array<Byte>(4097, repeat: 120), "198.51.100.17")).statusCode, 413)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1Neg01OversizedWebhookBodyReturnsPayloadTooLargeWithoutQueueMutation(): Unit {
        let dir = tempDir("gcm-webhook-p1-oversized")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let beforePending = queue.countByStatus("pending")

        let response = handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest(
            "POST",
            "/webhooks/gitcode/main",
            [("Content-Type", "application/json"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook"), ("Content-Length", "4097")],
            Array<Byte>(4097, repeat: 120),
            "198.51.100.18"
        ))

        @Expect(response.statusCode, 413)
        @Expect(response.body, "payload_too_large")
        @Expect(queue.countByStatus("pending"), beforePending)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1Neg02MalformedAndEmptyWebhookBodiesReturnExplicitBadRequestWithoutQueueMutation(): Unit {
        let dir = tempDir("gcm-webhook-p1-malformed")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let headers = [("Content-Type", "application/json"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook")]

        let malformed = handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest("POST", "/webhooks/gitcode/main", headers, "{".toArray(), "198.51.100.19"))
        let empty = handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest("POST", "/webhooks/gitcode/main", headers, Array<Byte>(), "198.51.100.20"))

        @Expect(malformed.statusCode, 400)
        @Expect(malformed.body, "malformed_json")
        @Expect(empty.statusCode, 400)
        @Expect(empty.body, "empty_body")
        @Expect(queue.countByStatus("pending"), 0)
        @Expect(queue.countByStatus("processed"), 0)
        @Expect(queue.countByStatus("dead-letter"), 0)
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
    public func p1Ut01DuplicateRuntimeEventDoesNotAdvanceStateVersionOrAudit(): Unit {
        let config = defaultConfig()
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = MonitorState()
        let event = GitCodeEvent("gitcode:cangjie/compiler:pr:71", "cangjie", "compiler", "pr", "71", "alice", "", "https://gitcode.com/cangjie/compiler/pulls/71", "Fix parser")
        state.markSeen(event.id)
        let versionBefore = state.version()
        let auditCountBefore = state.audit.size

        let result = processRuntimeEvent(config, state, event, runtime.feishu, runtime.telegram, runtime.mcp, runtime.writer, baselineMode: false)

        @Expect(result.duplicateEvents, 1)
        @Expect(state.version(), versionBefore)
        @Expect(state.audit.size, auditCountBefore)
    }

    @TestCase
    public func p0Ut03DuplicateWebhookDoesNotForceFullStateSaveEveryTime(): Unit {
        let dir = tempDir("gcm-webhook-p0-duplicate-save")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = MonitorState()
        @Expect(queue.enqueue(GitCodeWebhookDelivery("dup-first", "main", "Merge Request Hook", 1000, "payload-1", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)
        let first = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1)
        @Expect(first.stateSaved, true)
        @Expect(first.stateSaveStatus, "saved")
        let versionBeforeDuplicate = state.version()
        @Expect(queue.enqueue(GitCodeWebhookDelivery("dup-second", "main", "Merge Request Hook", 3000, "payload-2", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)

        let second = processWebhookBatch(config, runtime, state, queue, nowMs: 4000, maxItems: 1)

        @Expect(second.duplicates, 1)
        @Expect(second.stateSaved, false)
        @Expect(second.stateSaveSkipped, true)
        @Expect(second.stateSaveStatus, "skipped_duplicate_only")
        @Expect(state.version(), versionBeforeDuplicate)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1Ut02DuplicateOnlyBatchSkipsStateSaveAndKeepsStateFileStable(): Unit {
        let dir = tempDir("gcm-webhook-p1-duplicate-only")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = MonitorState()
        @Expect(queue.enqueue(GitCodeWebhookDelivery("p1-first", "main", "Merge Request Hook", 1000, "payload-1", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)
        let first = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1)
        @Expect(first.processed, 1)
        @Expect(first.stateSaved, true)
        let stateTextBefore = String.fromUtf8(File.readFrom(Path(config.statePath)))
        @Expect(queue.enqueue(GitCodeWebhookDelivery("p1-second", "main", "Merge Request Hook", 3000, "payload-2", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)

        let duplicate = processWebhookBatch(config, runtime, state, queue, nowMs: 4000, maxItems: 1)

        @Expect(duplicate.claimed, 1)
        @Expect(duplicate.processed, 1)
        @Expect(duplicate.duplicates, 1)
        @Expect(duplicate.stateSaved, false)
        @Expect(duplicate.stateSaveSkipped, true)
        @Expect(duplicate.stateSaveStatus, "skipped_duplicate_only")
        @Expect(String.fromUtf8(File.readFrom(Path(config.statePath))), stateTextBefore)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func processorEmptyQueueDoesNotPersistState(): Unit {
        let dir = tempDir("gcm-webhook-empty-queue-no-save")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = MonitorState()

        let result = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 20)

        @Expect(result.ok, true)
        @Expect(result.claimed, 0)
        @Expect(result.processed, 0)
        @Expect(result.stateSaved, false)
        @Expect(result.stateSaveSkipped, true)
        @Expect(result.stateSaveStatus, "skipped_unchanged")
        @Expect(runtime.store.lastSaveStatus, "skipped_unchanged")
        @Expect(runtime.store.lastSaveSkippedReason, "empty_queue")
        @Expect(exists(Path(config.statePath)), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1Ut03StateStoreSaveIfChangedReportsDuplicateOnlySkip(): Unit {
        let dir = tempDir("gcm-webhook-p1-state-store-duplicate")
        let store = StateStore(dir.join("state.json").toString())
        let state = MonitorState()

        let result = store.saveIfChanged(state, state.version(), reason: "duplicate_only")

        @Expect(result.saved, false)
        @Expect(result.skipped, true)
        @Expect(result.status, "skipped_duplicate_only")
        @Expect(result.durationMs, 0)
        @Expect(result.bytes, 0)
        @Expect(store.lastSaveStatus, "skipped_duplicate_only")
        @Expect(store.lastSaveSkippedReason, "duplicate_only")
        @Expect(exists(store.path), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func monitorStateVersionAndStateStoreSaveOnlyWhenDirty(): Unit {
        let dir = tempDir("gcm-webhook-state-dirty-save")
        let store = StateStore(dir.join("state.json").toString())
        let state = MonitorState()
        let version0 = state.version()

        let clean = store.saveIfChanged(state, version0)
        @Expect(clean.saved, false)
        @Expect(clean.skipped, true)
        @Expect(clean.status, "skipped_unchanged")
        @Expect(exists(store.path), false)

        state.markSeen("gitcode:cangjie/compiler:issue:1")
        let version1 = state.version()
        @Expect(version1 > version0, true)
        state.markSeen("gitcode:cangjie/compiler:issue:1")
        @Expect(state.version(), version1)

        let dirty = store.saveIfChanged(state, version0)
        @Expect(dirty.saved, true)
        @Expect(dirty.skipped, false)
        @Expect(dirty.status, "saved")
        @Expect(dirty.bytes > 0, true)
        @Expect(exists(store.path), true)
        @Expect(store.lastSaveStatus, "saved")

        let unchanged = store.saveIfChanged(state, state.version())
        @Expect(unchanged.saved, false)
        @Expect(unchanged.skipped, true)
        @Expect(unchanged.status, "skipped_unchanged")
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1Bnd01DuplicateWebhookFloodDoesNotGrowStateFileOrPersistAudit(): Unit {
        let dir = tempDir("gcm-webhook-p1-duplicate-boundary")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = MonitorState()
        @Expect(queue.enqueue(GitCodeWebhookDelivery("flood-first", "main", "Merge Request Hook", 1000, "payload-1", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)
        let first = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1)
        @Expect(first.stateSaved, true)
        let sizeBefore = stateFileSize(config.statePath)
        let auditBefore = state.audit.size
        var duplicateCount: Int64 = 0
        var skippedCount: Int64 = 0
        for (i in 0..1000) {
            @Expect(queue.enqueue(GitCodeWebhookDelivery("flood-${i}", "main", "Merge Request Hook", 3000 + i, "payload-${i}", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)
            let ticked = processWebhookBatch(config, runtime, state, queue, nowMs: 5000 + i, maxItems: 1)
            duplicateCount += ticked.duplicates
            if (ticked.stateSaveStatus == "skipped_duplicate_only") { skippedCount++ }
        }

        @Expect(stateFileSize(config.statePath), sizeBefore)
        @Expect(state.audit.size, auditBefore)
        @Expect(skippedCount, 1000)
        @Expect(duplicateCount, 1000)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func monitorStateAuditIsCappedWhenPersistedAndLoaded(): Unit {
        let dir = tempDir("gcm-webhook-audit-cap")
        let store = StateStore(dir.join("state.json").toString())
        let state = MonitorState()
        for (i in 0..(DEFAULT_MAX_AUDIT_RECORDS + 5)) {
            state.addAudit(AuditRecord("audit-${i}", status: "accepted"))
        }

        @Expect(state.audit.size, DEFAULT_MAX_AUDIT_RECORDS)
        @Expect(state.audit[0].eventId, "audit-5")
        @Expect(store.save(state), true)
        let loaded = store.load()
        @Expect(loaded.audit.size, DEFAULT_MAX_AUDIT_RECORDS)
        @Expect(loaded.audit[0].eventId, "audit-5")
        @Expect(loaded.audit[loaded.audit.size - 1].eventId, "audit-${DEFAULT_MAX_AUDIT_RECORDS + 4}")
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func wrongWebhookTokenDoesNotEnqueueOrPersistState(): Unit {
        let dir = tempDir("gcm-webhook-bad-token-no-side-effects")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let response = handleGitCodeWebhookRequest(config, WebhookHttpRequest(
            "POST",
            "/webhooks/gitcode/main",
            [("Content-Type", "application/json"), ("X-GitCode-Token", "wrong"), ("X-GitCode-Event", "Merge Request Hook")],
            mrPayload().toArray(),
            "203.0.113.22"
        ), queue)

        @Expect(response.statusCode, 401)
        @Expect(queue.countByStatus("pending"), 0)
        @Expect(queue.countByStatus("processing"), 0)
        @Expect(queue.countByStatus("processed"), 0)
        @Expect(exists(Path(config.statePath)), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func healthzResponseIsIndependentFromWebhookTokenBodyAndQueue(): Unit {
        let healthz = handleWebhookHealthzRequest()
        @Expect(healthz.statusCode, 200)
        @Expect(healthz.body, "ok")
        @Expect(healthz.headers[0][0].toAsciiLower(), "content-type")
        @Expect(healthz.body.contains("token"), false)
        @Expect(healthz.body.contains("{"), false)
    }

    @TestCase
    public func processorEmitsAcceptedServiceEventWhenWriterIsConfigured(): Unit {
        let dir = tempDir("gcm-webhook-processor-event-writer")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let delivery = GitCodeWebhookDelivery("d-event", "main", "Merge Request Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash")
        @Expect(queue.enqueue(delivery, mrPayload().toArray()).ok, true)
        let sender = FakeHttpSender()
        sender.nextResponse = HttpResponseSpec(200, body: "{\"approved\":true,\"draft\":\"thanks\"}")
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = MonitorState()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        let result = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))
        @Expect(result.processed, 1)
        @Expect(sink.lines.size, 1)
        let decoded = decodeServiceFrame(sink.lines[0])
        @Expect(decoded.ok, true)
        @Expect(decoded.frame.capabilityId, "gitcode.event.accepted")
        @Expect(decoded.frame.payload.contains("webhook-d-event"), true)
        @Expect(decoded.frame.payload.contains("https://gitcode.com/cangjie/compiler/pulls/71"), true)
        @Expect(decoded.frame.payload.contains("token-secret"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1Pos01NewWebhookBatchSavesStateAndEmitsAcceptedFrame(): Unit {
        let dir = tempDir("gcm-webhook-p1-positive")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("p1-pos", "main", "Merge Request Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = MonitorState()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)

        let result = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))

        @Expect(result.claimed, 1)
        @Expect(result.processed, 1)
        @Expect(result.duplicates, 0)
        @Expect(result.stateSaved, true)
        @Expect(result.stateSaveStatus, "saved")
        @Expect(sink.lines.size, 1)
        let decoded = decodeServiceFrame(sink.lines[0])
        @Expect(decoded.frame.frameType, "event")
        @Expect(decoded.frame.capabilityId, "gitcode.event.accepted")
        @Expect(state.hasSeen("gitcode:cangjie/compiler:pr:71"), true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func processorLoopTickConsumesPendingAndIdleTickSleeps(): Unit {
        let dir = tempDir("gcm-webhook-processor-loop")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let delivery = GitCodeWebhookDelivery("loop-d1", "main", "Merge Request Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash")
        @Expect(queue.enqueue(delivery, mrPayload().toArray()).ok, true)
        let sender = FakeHttpSender()
        sender.nextResponse = HttpResponseSpec(200, body: "{\"approved\":true,\"draft\":\"thanks\"}")
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = MonitorState()
        let loop = WebhookProcessorLoopRuntime(config, runtime, state, queue, idleSleepMs: 250, failureSleepMs: 1000)
        let processed = loop.tick(nowMs: 2000)
        @Expect(processed.result.claimed, 1)
        @Expect(processed.result.processed, 1)
        @Expect(processed.result.stateSaved, true)
        @Expect(processed.result.stateSaveStatus, "saved")
        @Expect(processed.sleepMs, 0)
        @Expect(loop.snapshot().processorStatus, "running")
        @Expect(loop.snapshot().lastBatchClaimed, 1)
        @Expect(loop.snapshot().lastBatchProcessed, 1)
        @Expect(loop.snapshot().lastStateSaveStatus, "saved")
        let idle = loop.tick(nowMs: 3000)
        @Expect(idle.result.claimed, 0)
        @Expect(idle.result.processed, 0)
        @Expect(idle.result.stateSaved, false)
        @Expect(idle.result.stateSaveSkipped, true)
        @Expect(idle.result.stateSaveStatus, "skipped_unchanged")
        @Expect(idle.sleepMs, 250)
        @Expect(loop.snapshot().emptyTickCount >= 1, true)
        @Expect(loop.snapshot().lastStateSaveStatus, "skipped_unchanged")
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1Stress01DuplicateProcessorLoadYieldsAndHealthzRemainsFastInFakeRuntime(): Unit {
        let dir = tempDir("gcm-webhook-p1-stress")
        let config = enabledConfig(dir.join("queue").toString())
        let port = 19000 + (DateTime.now().toUnixTimeStamp().toNanoseconds() % 1000)
        config.webhook = WebhookReceiverConfig(
            enabled: true,
            bindHost: config.webhook.bindHost,
            port: port,
            publicBaseUrl: config.webhook.publicBaseUrl,
            maxBodyBytes: config.webhook.maxBodyBytes,
            queueDir: config.webhook.queueDir,
            endpoints: config.webhook.endpoints,
            processor: WebhookProcessorConfig(maxBatchSize: 1)
        )
        let queue = WebhookQueue(config.webhook.queueDir)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = MonitorState()
        let server = WebhookHttpServerRuntime(config, queue)
        let started = server.start()
        @Expect(started.ok, true)
        sleep(Duration.millisecond * 20)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("stress-first", "main", "Merge Request Hook", 1000, "payload-1", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)
        let loop = WebhookProcessorLoopRuntime(config, runtime, state, queue, idleSleepMs: 250, failureSleepMs: 1000, maxConsecutiveWorkBatchesBeforeYield: 10, workYieldMs: 1)
        let first = loop.tick(nowMs: 2000)
        @Expect(first.result.processed, 1)
        for (i in 0..500) {
            @Expect(queue.enqueue(GitCodeWebhookDelivery("stress-${i}", "main", "Merge Request Hook", 3000 + i, "payload-${i}", "", "pending", 0, "", 0, "ip-hash"), mrPayload().toArray()).ok, true)
        }
        var healthzOk: Int64 = 0
        var yielded: Bool = false
        var duplicates: Int64 = 0
        let curl = CurlHttpSender()
        for (i in 0..500) {
            let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let healthz = curl.send(HttpRequestSpec("GET", "http://127.0.0.1:${port}/healthz"))
            let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
            if (healthz.statusCode == 200 && healthz.body.trimAscii() == "ok" && ended - started < 1000) { healthzOk++ }
            let ticked = loop.tick(nowMs: 4000 + i)
            duplicates += ticked.result.duplicates
            if (ticked.sleepMs == 1) { yielded = true }
        }

        @Expect(healthzOk, 500)
        @Expect(duplicates, 500)
        @Expect(yielded, true)
        @Expect(loop.snapshot().processorStatus, "running")
        @Expect(queue.countByStatus("dead-letter"), 0)
        server.stop()
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p8E2e02FakeHttpPostQueuesProcessesAndEmitsAcceptedFrame(): Unit {
        let dir = tempDir("gcm-webhook-p8-e2e")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let response = handleWebhookHttpServerRequest(config, queue, convertWebhookHttpRequest(
            "POST",
            "/webhooks/gitcode/main",
            [("Content-Type", "application/json"), ("X-GitCode-Token", "token-secret"), ("X-GitCode-Event", "Merge Request Hook"), ("X-GitCode-Delivery", "p8-e2e")],
            mrPayload().toArray(),
            "198.51.100.21"
        ))
        @Expect(response.statusCode, 202)
        @Expect(queue.countByStatus("pending"), 1)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = MonitorState()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)

        let processed = processWebhookBatch(config, runtime, state, queue, nowMs: 3000, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))

        @Expect(processed.processed, 1)
        @Expect(queue.countByStatus("pending"), 0)
        @Expect(queue.countByStatus("processed"), 1)
        @Expect(sink.lines.size, 1)
        @Expect(decodeServiceFrame(sink.lines[0]).frame.capabilityId, "gitcode.event.accepted")
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func statusReconcileAndPluginCapabilitiesReturnStructuredSafePayloads(): Unit {
        let dir = tempDir("gcm-webhook-status")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("dlq-1", "main", "Issue Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash"), "{}".toArray()).ok, true)
        let status = renderWebhookStatus(config, queue)
        @Expect(status.contains("receiver=degraded"), true)
        @Expect(status.contains("listener=not_started"), true)
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
        @Expect(handled.frame.payload.contains("\"receiver\":\"degraded\""), true)
        @Expect(handled.frame.payload.contains("\"listenerStatus\":\"not_started\""), true)
        @Expect(handled.frame.payload.contains("\"lastError\":\"\""), true)
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

    @TestCase
    public func webhookStatusReflectsDisabledRunningAndDegradedRuntimeSemantics(): Unit {
        let disabledDir = tempDir("gcm-webhook-status-disabled")
        let disabled = defaultConfig()
        disabled.webhook = WebhookReceiverConfig(enabled: false, queueDir: disabledDir.join("queue").toString())
        let disabledQueue = WebhookQueue(disabled.webhook.queueDir)
        let disabledPayload = webhookStatusPayload(disabled, disabledQueue)
        @Expect(disabledPayload.contains("\"receiver\":\"disabled\""), true)
        @Expect(disabledPayload.contains("\"pending\":0"), true)

        let runningDir = tempDir("gcm-webhook-status-running")
        let running = enabledConfig(runningDir.join("queue").toString())
        let runningQueue = WebhookQueue(running.webhook.queueDir)
        @Expect(runningQueue.enqueue(GitCodeWebhookDelivery("pending-1", "main", "Issue Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash"), "{}".toArray()).ok, true)
        let runningPayload = webhookStatusPayload(
            running,
            runningQueue,
            listenerSnapshot: Some<WebhookHttpServerSnapshot>(WebhookHttpServerSnapshot("listening", bind: "127.0.0.1:18080", lastResponseStatus: 202, lastRequestDurationMs: 3, healthzCount: 2, activeRequestCount: 0)),
            processorSnapshot: Some<WebhookProcessorLoopSnapshot>(WebhookProcessorLoopSnapshot("running", lastBatchClaimed: 1, lastStateSaveStatus: "saved", lastStateSaveDurationMs: 4, lastStateSaveBytes: 512))
        )
        @Expect(runningPayload.contains("\"receiver\":\"running\""), true)
        @Expect(runningPayload.contains("\"listenerStatus\":\"listening\""), true)
        @Expect(runningPayload.contains("\"listenerLastStatus\":202"), true)
        @Expect(runningPayload.contains("\"listenerLastDurationMs\":3"), true)
        @Expect(runningPayload.contains("\"healthzCount\":2"), true)
        @Expect(runningPayload.contains("\"activeRequestCount\":0"), true)
        @Expect(runningPayload.contains("\"processorStatus\":\"running\""), true)
        @Expect(runningPayload.contains("\"lastBatchClaimed\":1"), true)
        @Expect(runningPayload.contains("\"stateSaveStatus\":\"saved\""), true)
        @Expect(runningPayload.contains("\"stateSaveDurationMs\":4"), true)
        @Expect(runningPayload.contains("\"stateSaveBytes\":512"), true)
        @Expect(runningPayload.contains("\"receiverHealth\""), true)
        @Expect(runningPayload.contains("\"stateSave\""), true)
        @Expect(runningPayload.contains("\"processor\""), true)
        @Expect(runningPayload.contains("\"queue\""), true)
        @Expect(runningPayload.contains("\"pending\":1"), true)
        @Expect(runningPayload.contains("token-secret"), false)

        let notStartedPayload = webhookStatusPayload(running, runningQueue)
        @Expect(notStartedPayload.contains("\"receiver\":\"degraded\""), true)
        @Expect(notStartedPayload.contains("\"listenerStatus\":\"not_started\""), true)
        @Expect(notStartedPayload.contains("listener_not_started"), true)

        let degradedDir = tempDir("gcm-webhook-status-degraded")
        let degraded = enabledConfig(degradedDir.join("queue").toString())
        degraded.webhook = WebhookReceiverConfig(
            enabled: true,
            bindHost: "127.0.0.1",
            port: 18080,
            queueDir: degraded.webhook.queueDir,
            endpoints: [WebhookEndpointConfig("main", "/webhooks/gitcode/main")]
        )
        let degradedPayload = webhookStatusPayload(degraded, WebhookQueue(degraded.webhook.queueDir))
        @Expect(degradedPayload.contains("\"receiver\":\"degraded\""), true)
        @Expect(degradedPayload.contains("missing_endpoint_secret"), true)

        try { remove(disabledDir, recursive: true) } catch (_: Exception) { () }
        try { remove(runningDir, recursive: true) } catch (_: Exception) { () }
        try { remove(degradedDir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p6GcmStatusPayloadExposesReceiverQueueProcessorAndStateSaveSnapshots(): Unit {
        let dir = tempDir("gcm-webhook-p6-status")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("p6-pending", "main", "Issue Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash"), "{}".toArray()).ok, true)

        let payload = webhookStatusPayload(
            config,
            queue,
            listenerSnapshot: Some<WebhookHttpServerSnapshot>(WebhookHttpServerSnapshot("listening", bind: "127.0.0.1:18080", lastResponseStatus: 202, lastRequestDurationMs: 5, healthzCount: 3, activeRequestCount: 1)),
            processorSnapshot: Some<WebhookProcessorLoopSnapshot>(WebhookProcessorLoopSnapshot("running", lastBatchClaimed: 2, lastBatchProcessed: 1, lastStateSaveStatus: "skipped_duplicate_only", lastStateSaveSkipped: true, lastStateSaveDurationMs: 0, lastStateSaveBytes: 0))
        )

        @Expect(payload.contains("\"receiverHealth\""), true)
        @Expect(payload.contains("\"healthzCount\":3"), true)
        @Expect(payload.contains("\"activeRequestCount\":1"), true)
        @Expect(payload.contains("\"queue\""), true)
        @Expect(payload.contains("\"processor\""), true)
        @Expect(payload.contains("\"lastBatchClaimed\":2"), true)
        @Expect(payload.contains("\"stateSave\""), true)
        @Expect(payload.contains("\"stateSaveStatus\":\"skipped_duplicate_only\""), true)
        @Expect(payload.contains("token-secret"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p7Ut01GcmWebhookAcceptedPrFixtureContainsRequiredProducerFields(): Unit {
        let decoded = decodeServiceFrame(fixtureLine("gitcode_event_accepted_pr.jsonl"))

        @Expect(decoded.ok, true)
        @Expect(decoded.frame.frameType, "event")
        @Expect(decoded.frame.serviceId, GCM_SERVICE_PLUGIN_ID)
        @Expect(decoded.frame.capabilityId, "gitcode.event.accepted")
        for (field in ["jobId", "eventId", "repo", "kind", "number", "url", "title"]) {
            @Expect(payloadHasField(decoded.frame.payload, field), true)
        }
    }

    @TestCase
    public func p7Pos01GcmWebhookAcceptedFixturesCoverPrIssueAndCommentWithoutSensitiveRawData(): Unit {
        let fixtures = [
            ("gitcode_event_accepted_pr.jsonl", "pr", "/pulls/71"),
            ("gitcode_event_accepted_issue.jsonl", "issue", "/issues/72"),
            ("gitcode_event_accepted_comment.jsonl", "comment", "#comment-9001")
        ]
        for ((name, kind, urlPart) in fixtures) {
            let decoded = decodeServiceFrame(fixtureLine(name))
            @Expect(decoded.ok, true)
            @Expect(decoded.frame.capabilityId, "gitcode.event.accepted")
            @Expect(payloadString(decoded.frame.payload, "kind"), kind)
            @Expect(payloadString(decoded.frame.payload, "url").contains(urlPart), true)
            @Expect(decoded.frame.payload.contains("Authorization"), false)
            @Expect(decoded.frame.payload.contains("Bearer secret"), false)
            @Expect(decoded.frame.payload.contains("X-GitCode-Token"), false)
            @Expect(decoded.frame.payload.contains("rawBody"), false)
        }
    }

    @TestCase
    public func p7GcmProducerTruncatesLongAcceptedContentAndFlagsRedaction(): Unit {
        let longContent = "Authorization: Bearer secret token=abc " + String(Array<Rune>(5000, repeat: r'x'))
        let event = GitCodeEvent("gitcode:cangjie/compiler:pr:80", "cangjie", "compiler", "pr", "80", "alice", "", "https://gitcode.com/cangjie/compiler/pulls/80", longContent)
        let frame = gcmAcceptedScanEventFrame("webhook-long", event)

        @Expect(frame.payload.contains("Authorization"), false)
        @Expect(frame.payload.contains("Bearer secret"), false)
        @Expect(frame.payload.contains("token=abc"), false)
        @Expect(frame.payload.contains("\"contentRedacted\":true"), true)
        @Expect(frame.payload.contains("\"truncated\":true"), true)
        @Expect(payloadString(frame.payload, "content").toRuneArray().size <= 4096, true)
    }

    @TestCase
    public func webhookRuntimeStatusDegradesWhenQueueDirCannotBeInitialized(): Unit {
        let dir = tempDir("gcm-webhook-status-queue-unavailable")
        let queuePath = dir.join("queue-file")
        File.writeTo(queuePath, "not-a-directory".toArray())
        let config = enabledConfig(queuePath.toString())
        let runtime = evaluateWebhookReceiverRuntime(config)
        @Expect(runtime.status, "degraded")
        @Expect(runtime.lastError, "queue_unavailable")
        let payload = webhookStatusPayload(config, WebhookQueue(config.webhook.queueDir))
        @Expect(payload.contains("\"receiver\":\"degraded\""), true)
        @Expect(payload.contains("queue_unavailable"), true)
        @Expect(payload.contains("token-secret"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }
}
