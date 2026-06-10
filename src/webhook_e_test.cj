package gitcodemonitor

import std.collection.ArrayList
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

        let result = processRuntimeEvent(config, state, event, baselineMode: false)

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
    public func gcmListenerU001StopReportsBoundedServeWorkerShutdown(): Unit {
        // GCM-LISTENER-U-001
        let dir = tempDir("gcm-listener-u001")
        let config = enabledConfig(dir.join("queue").toString())
        let port = 19200 + (DateTime.now().toUnixTimeStamp().toNanoseconds() % 1000)
        config.webhook = WebhookReceiverConfig(
            enabled: true,
            bindHost: config.webhook.bindHost,
            port: port,
            publicBaseUrl: config.webhook.publicBaseUrl,
            maxBodyBytes: config.webhook.maxBodyBytes,
            queueDir: config.webhook.queueDir,
            endpoints: config.webhook.endpoints,
            processor: config.webhook.processor
        )
        let server = WebhookHttpServerRuntime(config, WebhookQueue(config.webhook.queueDir))

        @Expect(server.start().ok, true)
        sleep(Duration.millisecond * 20)
        server.stop()
        let stopped = server.snapshot()

        @Expect(stopped.listenerStatus == "stopped" || stopped.listenerStatus == "disabled" || stopped.listenerStatus == "not_started", true)
        @Expect(stopped.serveWorkerDone, true)
        @Expect(stopped.stopBounded, true)
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

    private func reviewFactsIssuePayload(email!: String = "alice@example.com", action!: String = "open", body!: String = "details"): String {
        "{" +
            "\"object_kind\":\"issue\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/cangjie_tools\"}," +
            "\"object_attributes\":{\"iid\":71,\"action\":\"${action}\",\"title\":\"[Bug]: parser\",\"description\":\"${body}\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/71\"}," +
            "\"user\":{\"name\":\"Alice\",\"username\":\"alice\",\"email\":\"${email}\",\"html_url\":\"https://gitcode.com/alice\"}" +
        "}"
    }

    private func reviewFactsIssuePayloadWithoutEmail(): String {
        "{" +
            "\"object_kind\":\"issue\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/cangjie_tools\"}," +
            "\"object_attributes\":{\"iid\":71,\"action\":\"open\",\"title\":\"[Bug]: parser\",\"description\":\"details\",\"url\":\"https://gitcode.com/Cangjie/cangjie_tools/issues/71\"}," +
            "\"user\":{\"name\":\"Alice\",\"username\":\"alice\",\"html_url\":\"https://gitcode.com/alice\"}" +
        "}"
    }

    private func auditContains(state: MonitorState, status: String, reason!: String = ""): Bool {
        for (audit in state.audit) {
            if (audit.status == status && (reason.isEmpty() || audit.reason == reason)) {
                return true
            }
        }
        false
    }

    private func scopedIssuePayload(authorId: String, authorUsername: String, authorEmail: String, actorId!: String = "900000", actorUsername!: String = "reviewer", actorEmail!: String = "reviewer@example.com"): String {
        "{" +
            "\"object_kind\":\"issue\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/community\"}," +
            "\"object_attributes\":{\"iid\":4,\"action\":\"open\",\"title\":\"Need help\",\"description\":\"please check\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4\",\"author\":{\"id\":${authorId},\"username\":\"${authorUsername}\",\"email\":\"${authorEmail}\",\"web_url\":\"https://gitcode.com/${authorUsername}\"}}," +
            "\"user\":{\"id\":${actorId},\"username\":\"${actorUsername}\",\"email\":\"${actorEmail}\",\"web_url\":\"https://gitcode.com/${actorUsername}\"}" +
        "}"
    }

    private func scopedPrPayload(targetId: String, targetUsername: String, targetEmail: String, actorId!: String = "856442", actorUsername!: String = "l3gi0n", actorEmail!: String = "huxiaoming6@huawei.com"): String {
        "{" +
            "\"object_kind\":\"merge_request\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/community\"}," +
            "\"merge_request\":{\"iid\":8,\"author_id\":${targetId},\"author\":{\"id\":${targetId},\"username\":\"${targetUsername}\",\"email\":\"${targetEmail}\"},\"title\":\"PR title\",\"url\":\"https://gitcode.com/Cangjie/community/pulls/8\"}," +
            "\"object_attributes\":{\"iid\":8,\"action\":\"open\",\"author_id\":${targetId},\"author\":{\"id\":${targetId},\"username\":\"${targetUsername}\",\"email\":\"${targetEmail}\"},\"title\":\"PR title\",\"description\":\"body\",\"url\":\"https://gitcode.com/Cangjie/community/pulls/8\"}," +
            "\"user\":{\"id\":${actorId},\"username\":\"${actorUsername}\",\"email\":\"${actorEmail}\"}" +
        "}"
    }

    private func scopedIssuePayloadMissingTarget(actorId!: String = "856442", actorUsername!: String = "l3gi0n", actorEmail!: String = "huxiaoming6@huawei.com"): String {
        "{" +
            "\"object_kind\":\"issue\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/community\"}," +
            "\"object_attributes\":{\"iid\":5,\"action\":\"open\",\"title\":\"Need help\",\"description\":\"please check\",\"url\":\"https://gitcode.com/Cangjie/community/issues/5\"}," +
            "\"user\":{\"id\":${actorId},\"username\":\"${actorUsername}\",\"email\":\"${actorEmail}\",\"web_url\":\"https://gitcode.com/${actorUsername}\"}" +
        "}"
    }

    private func scopedPrPayloadMissingTarget(actorId!: String = "856442", actorUsername!: String = "l3gi0n", actorEmail!: String = "huxiaoming6@huawei.com"): String {
        "{" +
            "\"object_kind\":\"merge_request\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/community\"}," +
            "\"merge_request\":{\"iid\":9,\"title\":\"PR title\",\"url\":\"https://gitcode.com/Cangjie/community/pulls/9\"}," +
            "\"object_attributes\":{\"iid\":9,\"action\":\"open\",\"title\":\"PR title\",\"description\":\"body\",\"url\":\"https://gitcode.com/Cangjie/community/pulls/9\"}," +
            "\"user\":{\"id\":${actorId},\"username\":\"${actorUsername}\",\"email\":\"${actorEmail}\"}" +
        "}"
    }

    private func issue4NotePayload(commentId!: String = "9001", note!: String = "natural comment"): String {
        "{" +
            "\"object_kind\":\"note\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/community\"}," +
            "\"issue\":{\"iid\":4,\"author_id\":707874,\"author\":{\"id\":707874,\"username\":\"Leporide\",\"email\":\"leporide@example.com\"},\"title\":\"Issue 4\",\"description\":\"body\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4\"}," +
            "\"object_attributes\":{\"id\":${commentId},\"author_id\":856442,\"note\":\"${note}\",\"noteable_type\":\"Issue\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4#note_${commentId}\"}," +
            "\"user\":{\"id\":856442,\"username\":\"l3gi0n\",\"email\":\"huxiaoming6@huawei.com\",\"web_url\":\"https://gitcode.com/l3gi0n\"}" +
        "}"
    }

    private func issue4NotePayloadMissingTarget(commentId!: String = "9010", note!: String = "natural comment"): String {
        "{" +
            "\"object_kind\":\"note\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/community\"}," +
            "\"issue\":{\"iid\":4,\"title\":\"Issue 4\",\"description\":\"body\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4\"}," +
            "\"object_attributes\":{\"id\":${commentId},\"author_id\":856442,\"note\":\"${note}\",\"noteable_type\":\"Issue\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4#note_${commentId}\"}," +
            "\"user\":{\"id\":856442,\"username\":\"l3gi0n\",\"email\":\"huxiaoming6@huawei.com\",\"web_url\":\"https://gitcode.com/l3gi0n\"}" +
        "}"
    }

    private func issue4NotePayloadWithoutUrl(commentId!: String = "9020", note!: String = "natural comment"): String {
        "{" +
            "\"object_kind\":\"note\"," +
            "\"project\":{\"path_with_namespace\":\"Cangjie/community\"}," +
            "\"issue\":{\"iid\":4,\"author_id\":707874,\"author\":{\"id\":707874,\"username\":\"Leporide\",\"email\":\"leporide@example.com\"},\"title\":\"Issue 4\",\"description\":\"body\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4\"}," +
            "\"object_attributes\":{\"id\":${commentId},\"author_id\":999999,\"note\":\"${note}\",\"noteable_type\":\"Issue\"}," +
            "\"user\":{\"id\":999999,\"username\":\"external\",\"email\":\"external@example.com\",\"web_url\":\"https://gitcode.com/external\"}" +
        "}"
    }

    private func processOnePayload(config: MonitorConfig, payload: String, eventName: String): (MonitorState, GcmMemoryLineSink, WebhookBatchResult) {
        let queue = WebhookQueue(config.webhook.queueDir)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("delivery-${hashRawPayload(payload)}", "main", eventName, 1000, hashRawPayload(payload), "", "pending", 0, "", 0, "ip"), payload.toArray()).ok, true)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = runtime.store.load()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        let result = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))
        (state, sink, result)
    }

    @TestCase
    public func p1SubjectsExtractByScopeAndClassifyWithoutScopeBleed(): Unit {
        // T-P1-P-001, T-P1-P-002, T-P1-N-001, T-P3-B-001
        let issueSubjects = extractWebhookSubjectSet(JsonValue.fromStr(scopedIssuePayload("856442", "l3gi0n", "huxiaoming6@huawei.com")).asObject())
        @Expect(issueSubjects.targetAuthor.isSome(), true)
        @Expect(issueSubjects.eventActor.isSome(), true)
        @Expect(issueSubjects.commentAuthor.isNone(), true)
        match (issueSubjects.targetAuthor) {
            case Some(author) =>
                @Expect(author.id, "856442")
                @Expect(author.login, "l3gi0n")
                @Expect(author.emails[0], "huxiaoming6@huawei.com")
            case None => @Expect(true, false)
        }

        let prSubjects = extractWebhookSubjectSet(JsonValue.fromStr(scopedPrPayload("707874", "target", "target@example.com")).asObject())
        let prPolicy = AuthorPolicyConfig()
        prPolicy.recordOnlyEnabled = true
        prPolicy.targetAuthorRule.emails = ["target@example.com"]
        let prDecision = classifyRecordOnlySubjects(prSubjects, prPolicy)
        @Expect(prDecision.decision, "record_only")
        @Expect(prDecision.reason, "record_only_target_author_email")

        let noteSubjects = extractWebhookSubjectSet(JsonValue.fromStr(issue4NotePayload()).asObject())
        match (noteSubjects.commentAuthor) {
            case Some(author) =>
                @Expect(author.id, "856442")
                @Expect(author.login, "l3gi0n")
            case None => @Expect(true, false)
        }
        match (noteSubjects.targetAuthor) {
            case Some(author) =>
                @Expect(author.id, "707874")
                @Expect(author.login.toAsciiLower(), "leporide")
            case None => @Expect(true, false)
        }
        let targetOnly = AuthorPolicyConfig()
        targetOnly.recordOnlyEnabled = true
        targetOnly.targetAuthorRule.ids = ["856442"]
        @Expect(classifyRecordOnlySubjects(noteSubjects, targetOnly).decision, "process")
        @Expect(classifyRecordOnlySubjects(noteSubjects, targetOnly).missingDiagnostics.contains("target_subject_missing"), false)

        let missingTargetSubjects = extractWebhookSubjectSet(JsonValue.fromStr(issue4NotePayloadMissingTarget()).asObject())
        @Expect(missingTargetSubjects.targetAuthor.isNone(), true)
        @Expect(missingTargetSubjects.commentAuthor.isSome(), true)
        let missingPolicy = AuthorPolicyConfig()
        missingPolicy.recordOnlyEnabled = true
        missingPolicy.commentAuthorRule.ids = ["856442"]
        missingPolicy.targetAuthorRule.ids = ["707874"]
        let missingDecision = classifyRecordOnlySubjects(missingTargetSubjects, missingPolicy)
        @Expect(missingDecision.decision, "record_only")
        @Expect(missingDecision.reason, "record_only_comment_author_id")
        @Expect(missingDecision.missingDiagnostics.contains("target_subject_missing"), true)

        let missingIssueSubjects = extractWebhookSubjectSet(JsonValue.fromStr(scopedIssuePayloadMissingTarget()).asObject())
        @Expect(missingIssueSubjects.targetAuthor.isNone(), true)
        @Expect(missingIssueSubjects.eventActor.isSome(), true)
        let issueTargetPolicy = AuthorPolicyConfig()
        issueTargetPolicy.recordOnlyEnabled = true
        issueTargetPolicy.targetAuthorRule.ids = ["856442"]
        let missingIssueDecision = classifyRecordOnlySubjects(missingIssueSubjects, issueTargetPolicy)
        @Expect(missingIssueDecision.decision, "process")
        @Expect(missingIssueDecision.missingDiagnostics.contains("target_subject_missing"), true)

        let missingPrSubjects = extractWebhookSubjectSet(JsonValue.fromStr(scopedPrPayloadMissingTarget()).asObject())
        @Expect(missingPrSubjects.targetAuthor.isNone(), true)
        @Expect(missingPrSubjects.eventActor.isSome(), true)
        let missingPrDecision = classifyRecordOnlySubjects(missingPrSubjects, issueTargetPolicy)
        @Expect(missingPrDecision.decision, "process")
        @Expect(missingPrDecision.missingDiagnostics.contains("target_subject_missing"), true)
    }

    @TestCase
    public func p0p1p3p7ScopedRecordOnlyProcessorAcceptsOnlyWhenRulesDoNotMatch(): Unit {
        // T-P0-P-001, T-P0-N-001, T-P1-P-003, T-P1-P-004, T-P1-N-002, T-P3-U-001, T-P3-N-001, T-P7-E2E-001, T-P7-E2E-002, T-P7-E2E-005
        let commentIdConfigDir = tempDir("gcm-p1-comment-id-record-only")
        let commentIdConfig = enabledConfig(commentIdConfigDir.join("queue").toString())
        commentIdConfig.authorPolicy.recordOnlyEnabled = true
        commentIdConfig.authorPolicy.commentAuthorRule.ids = ["856442"]
        let (commentState, commentSink, commentResult) = processOnePayload(commentIdConfig, issue4NotePayload(), "Note Hook")
        @Expect(commentResult.processed, 1)
        @Expect(commentSink.lines.size, 0)
        @Expect(auditContains(commentState, "record_only", reason: "record_only_comment_author_id"), true)
        @Expect(commentState.audit[0].reason.contains("huxiaoming6@huawei.com"), false)
        @Expect(webhookStatusPayload(commentIdConfig, WebhookQueue(commentIdConfig.webhook.queueDir), state: Some<MonitorState>(commentState)).contains("\"recordOnlyCommentAuthorCount\":1"), true)
        try { remove(commentIdConfigDir, recursive: true) } catch (_: Exception) { () }

        let issueMissingDir = tempDir("gcm-p1-issue-target-missing")
        let issueMissingConfig = enabledConfig(issueMissingDir.join("queue").toString())
        issueMissingConfig.authorPolicy.recordOnlyEnabled = true
        issueMissingConfig.authorPolicy.targetAuthorRule.ids = ["856442"]
        let (issueMissingState, issueMissingSink, _) = processOnePayload(issueMissingConfig, scopedIssuePayloadMissingTarget(), "Issue Hook")
        @Expect(issueMissingSink.lines.size, 1)
        @Expect(auditContains(issueMissingState, "record_only"), false)
        try { remove(issueMissingDir, recursive: true) } catch (_: Exception) { () }

        let legacyNoteDir = tempDir("gcm-legacy-domain-note-comment")
        let legacyNoteConfig = enabledConfig(legacyNoteDir.join("queue").toString())
        legacyNoteConfig.authorPolicy.recordOnlyEnabled = true
        legacyNoteConfig.authorPolicy.recordOnlyEmailDomains = ["@huawei.com"]
        legacyNoteConfig.authorPolicy.targetAuthorRule.emailDomains = ["@huawei.com"]
        let (legacyNoteState, legacyNoteSink, _) = processOnePayload(legacyNoteConfig, issue4NotePayload(commentId: "9011"), "Note Hook")
        @Expect(legacyNoteSink.lines.size, 1)
        @Expect(auditContains(legacyNoteState, "record_only"), false)
        try { remove(legacyNoteDir, recursive: true) } catch (_: Exception) { () }

        let missingTargetDir = tempDir("gcm-p3-missing-target-record-only")
        let missingTargetConfig = enabledConfig(missingTargetDir.join("queue").toString())
        missingTargetConfig.authorPolicy.recordOnlyEnabled = true
        missingTargetConfig.authorPolicy.commentAuthorRule.ids = ["856442"]
        missingTargetConfig.authorPolicy.targetAuthorRule.ids = ["707874"]
        let (missingTargetState, missingTargetSink, missingTargetResult) = processOnePayload(missingTargetConfig, issue4NotePayloadMissingTarget(), "Note Hook")
        @Expect(missingTargetResult.processed, 1)
        @Expect(missingTargetSink.lines.size, 0)
        @Expect(auditContains(missingTargetState, "record_only", reason: "record_only_comment_author_id"), true)
        @Expect(missingTargetState.audit[0].requestId.contains("target_subject_missing"), true)
        @Expect(missingTargetState.audit[0].requestId.contains("huxiaoming6@huawei.com"), false)
        try { remove(missingTargetDir, recursive: true) } catch (_: Exception) { () }

        let commentEmailDir = tempDir("gcm-p1-comment-email-record-only")
        let commentEmailConfig = enabledConfig(commentEmailDir.join("queue").toString())
        commentEmailConfig.authorPolicy.recordOnlyEnabled = true
        commentEmailConfig.authorPolicy.commentAuthorRule.emails = ["huxiaoming6@huawei.com"]
        let (emailState, emailSink, _) = processOnePayload(commentEmailConfig, issue4NotePayload(commentId: "9002"), "Note Hook")
        @Expect(emailSink.lines.size, 0)
        @Expect(auditContains(emailState, "record_only", reason: "record_only_comment_author_email"), true)
        @Expect(emailState.audit[0].requestId.contains("huxiaoming6@huawei.com"), false)
        try { remove(commentEmailDir, recursive: true) } catch (_: Exception) { () }

        let targetEmailDir = tempDir("gcm-p1-target-email-record-only")
        let targetEmailConfig = enabledConfig(targetEmailDir.join("queue").toString())
        targetEmailConfig.authorPolicy.recordOnlyEnabled = true
        targetEmailConfig.authorPolicy.targetAuthorRule.emails = ["target@example.com"]
        let (targetState, targetSink, _) = processOnePayload(targetEmailConfig, scopedPrPayload("707874", "target", "target@example.com"), "Merge Request Hook")
        @Expect(targetSink.lines.size, 0)
        @Expect(auditContains(targetState, "record_only", reason: "record_only_target_author_email"), true)
        try { remove(targetEmailDir, recursive: true) } catch (_: Exception) { () }

        let domainCounterDir = tempDir("gcm-p3-domain-counters")
        let targetDomainConfig = enabledConfig(domainCounterDir.join("target").toString())
        targetDomainConfig.authorPolicy.recordOnlyEnabled = true
        targetDomainConfig.authorPolicy.targetAuthorRule.emailDomains = ["@example.com"]
        let (targetDomainState, _, _) = processOnePayload(targetDomainConfig, scopedPrPayload("707874", "target", "target@example.com"), "Merge Request Hook")
        let targetDomainStatus = webhookStatusPayload(targetDomainConfig, WebhookQueue(targetDomainConfig.webhook.queueDir), state: Some<MonitorState>(targetDomainState))
        @Expect(auditContains(targetDomainState, "record_only", reason: "record_only_target_author_email_domain"), true)
        @Expect(targetDomainStatus.contains("\"recordOnlyTargetAuthorCount\":1"), true)

        let commentDomainConfig = enabledConfig(domainCounterDir.join("comment").toString())
        commentDomainConfig.authorPolicy.recordOnlyEnabled = true
        commentDomainConfig.authorPolicy.commentAuthorRule.emailDomains = ["@huawei.com"]
        let (commentDomainState, _, _) = processOnePayload(commentDomainConfig, issue4NotePayload(commentId: "9012"), "Note Hook")
        let commentDomainStatus = webhookStatusPayload(commentDomainConfig, WebhookQueue(commentDomainConfig.webhook.queueDir), state: Some<MonitorState>(commentDomainState))
        @Expect(auditContains(commentDomainState, "record_only", reason: "record_only_comment_author_email_domain"), true)
        @Expect(commentDomainStatus.contains("\"recordOnlyCommentAuthorCount\":1"), true)
        try { remove(domainCounterDir, recursive: true) } catch (_: Exception) { () }

        let acceptedDir = tempDir("gcm-p1-accepted-no-match")
        let acceptedConfig = enabledConfig(acceptedDir.join("queue").toString())
        acceptedConfig.authorPolicy.recordOnlyEnabled = true
        acceptedConfig.authorPolicy.commentAuthorRule.ids = ["999999"]
        let (acceptedState, acceptedSink, acceptedResult) = processOnePayload(acceptedConfig, issue4NotePayload(commentId: "9003"), "Note Hook")
        @Expect(acceptedResult.processed, 1)
        @Expect(acceptedSink.lines.size, 1)
        @Expect(decodeServiceFrame(acceptedSink.lines[0]).frame.capabilityId, "gitcode.event.accepted")
        @Expect(auditContains(acceptedState, "record_only"), false)
        @Expect(webhookStatusPayload(acceptedConfig, WebhookQueue(acceptedConfig.webhook.queueDir), state: Some<MonitorState>(acceptedState)).contains("\"selfEchoIgnoredCount\":0"), true)
        try { remove(acceptedDir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p2p3p7WritebackLedgerSuppressesSelfEchoWithoutBodyLeakOrFalsePositive(): Unit {
        // T-P2-U-001, T-P2-B-001, T-P2-P-001, T-P2-N-001, T-P3-P-001, T-P7-E2E-004
        let dir = tempDir("gcm-p2-ledger")
        let config = enabledConfig(dir.join("queue").toString())
        let ledgerPath = writebackLedgerPathForConfig(config)
        let body = "natural comment"
        let recorded = recordWriteback(ledgerPath, "Cangjie/community", "issue", "4", "https://gitcode.com/Cangjie/community/issues/4#note_9004", body, "source-event-1", nowMs: 1000)
        @Expect(recorded.ok, true)
        let ledgerText = String.fromUtf8(File.readFrom(Path(ledgerPath)))
        @Expect(ledgerText.contains(body), false)
        @Expect(ledgerText.contains("token"), false)
        @Expect(ledgerText.contains("note_9004"), true)

        @Expect(recordWriteback(ledgerPath, "Cangjie/community", "issue", "4", "https://gitcode.com/Cangjie/community/issues/4#note_9010", body, "https://audit.local/events/1?token=gitcode-token", nowMs: 1000).ok, true)
        @Expect(recordWriteback(ledgerPath, "Cangjie/community", "issue", "4", "https://gitcode.com/Cangjie/community/issues/4#note_9011", body, "/Users/alice/.metis/source-event", nowMs: 1000).ok, true)
        let safeLedgerText = String.fromUtf8(File.readFrom(Path(ledgerPath)))
        @Expect(safeLedgerText.contains("gitcode-token"), false)
        @Expect(safeLedgerText.contains("token="), false)
        @Expect(safeLedgerText.contains("/Users/alice"), false)
        let safeSourceMatch = matchWebhookComment(ledgerPath, "Cangjie/community", "issue", "4", "", "note_9010", body, nowMs: 2000)
        @Expect(safeSourceMatch.matched, true)
        @Expect(safeSourceMatch.sourceEventId.contains("gitcode-token"), false)
        @Expect(safeSourceMatch.sourceEventId.contains("token="), false)
        let localPathSourceMatch = matchWebhookComment(ledgerPath, "Cangjie/community", "issue", "4", "", "note_9011", body, nowMs: 2000)
        @Expect(localPathSourceMatch.matched, true)
        @Expect(localPathSourceMatch.sourceEventId.contains("/Users/alice"), false)

        let echo = issue4NotePayload(commentId: "9004", note: body)
        let (state, sink, result) = processOnePayload(config, echo, "Note Hook")
        @Expect(result.processed, 1)
        @Expect(sink.lines.size, 0)
        @Expect(auditContains(state, "self_echo_ignored"), true)
        @Expect(webhookStatusPayload(config, WebhookQueue(config.webhook.queueDir), state: Some<MonitorState>(state)).contains("\"selfEchoIgnoredCount\":1"), true)

        let mismatchDir = tempDir("gcm-p2-ledger-mismatch")
        let mismatchConfig = enabledConfig(mismatchDir.join("queue").toString())
        @Expect(recordWriteback(writebackLedgerPathForConfig(mismatchConfig), "Other/community", "issue", "4", "https://gitcode.com/Other/community/issues/4#note_9005", body, "source-event-2", nowMs: 1000).ok, true)
        let (mismatchState, mismatchSink, _) = processOnePayload(mismatchConfig, issue4NotePayload(commentId: "9005", note: body), "Note Hook")
        @Expect(mismatchSink.lines.size, 1)
        @Expect(auditContains(mismatchState, "self_echo_ignored"), false)

        let expired = matchWebhookComment(ledgerPath, "Cangjie/community", "issue", "4", "", "note_missing", body, nowMs: 1000 + WRITEBACK_LEDGER_TTL_MS + 1)
        @Expect(expired.matched, false)
        let expiredUrl = matchWebhookComment(ledgerPath, "Cangjie/community", "issue", "4", "https://gitcode.com/Cangjie/community/issues/4#note_9004", "", body, nowMs: 1000 + WRITEBACK_LEDGER_TTL_MS + 1)
        @Expect(expiredUrl.matched, false)
        let expiredAnchor = matchWebhookComment(ledgerPath, "Cangjie/community", "issue", "4", "", "note_9004", body, nowMs: 1000 + WRITEBACK_LEDGER_TTL_MS + 1)
        @Expect(expiredAnchor.matched, false)

        let bodyOnlyDir = tempDir("gcm-p2-ledger-bodyhash-untrusted")
        let bodyOnlyConfig = enabledConfig(bodyOnlyDir.join("queue").toString())
        @Expect(recordWriteback(writebackLedgerPathForConfig(bodyOnlyConfig), "Cangjie/community", "issue", "4", "", body, "source-event-body", nowMs: 1000).ok, true)
        let bodyHashOnly = matchWebhookComment(writebackLedgerPathForConfig(bodyOnlyConfig), "Cangjie/community", "issue", "4", "", "", body, nowMs: 2000)
        @Expect(bodyHashOnly.matched, false)
        @Expect(bodyHashOnly.status, "body_hash_untrusted")
        let (bodyOnlyState, bodyOnlySink, _) = processOnePayload(bodyOnlyConfig, issue4NotePayloadWithoutUrl(note: body), "Note Hook")
        @Expect(bodyOnlySink.lines.size, 1)
        @Expect(auditContains(bodyOnlyState, "self_echo_ignored"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
        try { remove(mismatchDir, recursive: true) } catch (_: Exception) { () }
        try { remove(bodyOnlyDir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func reviewContractValidationCoversRequiredAndUnsafePayloads(): Unit {
        // T-CONTRACT-001, T-CONTRACT-002, T-CONTRACT-003, T-CONTRACT-004, T-CONTRACT-005, T-CONTRACT-009
        let event = GitCodeEvent("gitcode:cangjie/compiler:issue:1", "cangjie", "compiler", "issue", "1", "alice", "", "https://gitcode.com/cangjie/compiler/issues/1", "bug body")
        let payload = renderReviewRequestJson("job-contract", event, issueKind: "bug")
        let ok = validateReviewRequestForTest(payload)
        @Expect(ok.ok, true)
        @Expect(ok.contractVersion, "gcm-metis-gitcode-review-v1")
        @Expect(validateReviewRequestForTest("{\"reviewRequest\":{\"repo\":\"cangjie/compiler\"}}").status, "contract_version_missing")
        @Expect(validateReviewRequestForTest("{\"contractVersion\":\"unknown\",\"reviewRequest\":{\"repo\":\"cangjie/compiler\"}}").status, "contract_version_unsupported")
        let secret = validateReviewRequestForTest("{\"contractVersion\":\"gcm-metis-gitcode-review-v1\",\"reviewRequest\":{\"repo\":\"cangjie/compiler\",\"body\":\"Authorization: Bearer x\"}}")
        @Expect(secret.status, "payload_contains_secret")
        @Expect(secret.diagnostic.contains("Bearer x"), false)
        let localPath = validateReviewRequestForTest("{\"contractVersion\":\"gcm-metis-gitcode-review-v1\",\"reviewRequest\":{\"repo\":\"cangjie/compiler\",\"body\":\"/Users/alice/private\"}}")
        @Expect(localPath.status, "payload_contains_local_path")
        @Expect(localPath.diagnostic.contains("/Users/alice"), false)
        @Expect(validateReviewRequestForTest("{\"contractVersion\":\"gcm-metis-gitcode-review-v1\",\"reviewRequest\":{\"repo\":\"\"}}").status, "repo_missing")
    }

    @TestCase
    public func ctxP2U001U002AndP4U001ReviewContractRendersContextAndKeepsLegacyCompatibility(): Unit {
        // CTX-P2-U-001, CTX-P2-U-002, CTX-P4-U-001
        let event = GitCodeEvent("gitcode:cangjie/compiler:issue:4:comment:9003", "cangjie", "compiler", "issue", "4", "bob", "", "https://gitcode.com/cangjie/compiler/issues/4#note_9003", "trigger body")
        let context = GitCodeDiscussionContext(
            status: "resolved",
            repo: "cangjie/compiler",
            kind: "issue",
            number: "4",
            commentId: "9003",
            parent: GitCodeDiscussionParent(kind: "issue", number: "4", title: "Issue 4", body: "Parent issue body", url: "https://gitcode.com/cangjie/compiler/issues/4", author: "alice"),
            triggerComment: GitCodeDiscussionComment(id: "9003", body: "trigger body", author: "bob"),
            previousComments: [GitCodeDiscussionComment(id: "9001", body: "previous comment body", author: "carol")],
            previousCommentsTotal: 1,
            previousCommentsIncluded: 1
        )

        let payload = renderReviewRequestJson("job-context", event, discussionContext: Some<GitCodeDiscussionContext>(context))
        let root = JsonValue.fromStr(payload).asObject()
        let request = nestedObject(root, ["reviewRequest"])
        let contextJson = nestedObject(request, ["context"])
        let parent = nestedObject(contextJson, ["parent"])
        let previous = contextJson.get("previousComments").getOrThrow().asArray().getItems()
        let previous0 = previous[0].asObject()
        let oldPayload = renderReviewRequestJson("job-legacy", event)

        @Expect(firstJsonString(parent, ["body"]), "Parent issue body")
        @Expect(firstJsonString(previous0, ["body"]), "previous comment body")
        @Expect(payloadHasField(payload, "kind"), true)
        @Expect(validateReviewRequestForTest(payload).ok, true)
        @Expect(validateReviewRequestForTest(oldPayload).ok, true)
        @Expect(oldPayload.contains("\"context\""), false)

        let unsafeContext = GitCodeDiscussionContext(
            status: "resolved",
            repo: "cangjie/compiler",
            kind: "issue",
            number: "4",
            commentId: "9004",
            parent: GitCodeDiscussionParent(kind: "issue", number: "4", body: "gitcode_token=fake-secret /Users/example/private"),
            triggerComment: GitCodeDiscussionComment(id: "9004", body: "safe"),
            previousComments: []
        )
        let safeRendered = renderReviewRequestJson("job-safe-context", event, discussionContext: Some<GitCodeDiscussionContext>(unsafeContext))
        @Expect(validateReviewRequestForTest(safeRendered).ok, true)
        @Expect(safeRendered.contains("fake-secret"), false)
        @Expect(safeRendered.contains("/Users/example"), false)
        let rawUnsafe = "{\"contractVersion\":\"gcm-metis-gitcode-review-v1\",\"reviewRequest\":{\"repo\":\"cangjie/compiler\",\"context\":{\"parent\":{\"body\":\"gitcode_token=fake-secret /Users/example/private\"}}}}"
        @Expect(validateReviewRequestForTest(rawUnsafe).ok, false)
    }

    @TestCase
    public func ctxP2B001ReviewContractTruncatesLongContextAndValidates(): Unit {
        // CTX-P2-B-001
        let event = GitCodeEvent("gitcode:cangjie/compiler:issue:5:comment:9010", "cangjie", "compiler", "issue", "5", "bob", "", "https://gitcode.com/cangjie/compiler/issues/5#note_9010", "trigger body")
        let comments = ArrayList<GitCodeDiscussionComment>()
        for (i in 1..=20) {
            comments.add(GitCodeDiscussionComment(id: "${i}", body: "previous-${i}-" + String(Array<Rune>(900, repeat: r'x')), author: "user${i}", createdAtMs: i * 1000))
        }
        let context = GitCodeDiscussionContext(
            status: "resolved",
            repo: "cangjie/compiler",
            kind: "issue",
            number: "5",
            commentId: "9010",
            parent: GitCodeDiscussionParent(kind: "issue", number: "5", body: String(Array<Rune>(9000, repeat: r'p'))),
            triggerComment: GitCodeDiscussionComment(id: "9010", body: "trigger body"),
            previousComments: comments.toArray(),
            previousCommentsTotal: comments.size,
            previousCommentsIncluded: comments.size
        )

        let payload = renderReviewRequestJson("job-long-context", event, discussionContext: Some<GitCodeDiscussionContext>(context))

        @Expect(payload.contains("\"context\""), true)
        @Expect(payload.contains("\"truncated\":true"), true)
        @Expect(validateReviewRequestForTest(payload).ok, true)
    }

    @TestCase
    public func ctxP2P001WebhookNoteAcceptedFrameIncludesDiscussionContext(): Unit {
        // CTX-P2-P-001
        let dir = tempDir("gcm-ctx-p2-p001")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("ctx-p2-p001", "main", "Note Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash"), issue4NotePayload(commentId: "9003", note: "trigger context").toArray()).ok, true)
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(200, body: "{\"iid\":4,\"title\":\"Issue 4\",\"description\":\"API parent issue body\",\"html_url\":\"https://gitcode.com/Cangjie/community/issues/4\"}"))
        sender.enqueue(HttpResponseSpec(200, body: "{\"comments\":[" +
            "{\"id\":9001,\"body\":\"previous context A\",\"created_at_ms\":1000}," +
            "{\"id\":9002,\"body\":\"previous context B\",\"created_at_ms\":2000}," +
            "{\"id\":9003,\"body\":\"trigger context\",\"created_at_ms\":3000}" +
        "]}"))
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = MonitorState()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)

        let result = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))

        @Expect(result.processed, 1)
        @Expect(sink.lines.size, 1)
        @Expect(sender.requests.size, 2)
        let decoded = decodeServiceFrame(sink.lines[0])
        @Expect(decoded.frame.payload.contains("\"context\""), true)
        @Expect(decoded.frame.payload.contains("API parent issue body"), true)
        @Expect(decoded.frame.payload.contains("previous context A"), true)
        @Expect(decoded.frame.payload.contains("trigger context"), true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func ctxP2N001ContextFetchFailureStillEmitsDegradedAcceptedFrame(): Unit {
        // CTX-P2-N-001
        let dir = tempDir("gcm-ctx-p2-n001")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("ctx-p2-n001", "main", "Note Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash"), issue4NotePayload(commentId: "9006", note: "trigger degraded").toArray()).ok, true)
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(500, body: "{\"message\":\"temporary\"}"))
        sender.enqueue(HttpResponseSpec(500, body: "{\"message\":\"temporary\"}"))
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = MonitorState()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)

        let result = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))

        @Expect(result.processed, 1)
        @Expect(sink.lines.size, 1)
        let payload = decodeServiceFrame(sink.lines[0]).frame.payload
        let context = nestedObject(nestedObject(JsonValue.fromStr(payload).asObject(), ["reviewRequest"]), ["context"])
        @Expect(payload.contains("\"context\""), true)
        @Expect(firstJsonString(context, ["status"]), "degraded")
        @Expect(payload.contains("detail_fetch_failed:server_error"), true)
        @Expect(payload.contains("comments_fetch_failed:server_error"), true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func ctxP2N002RecordOnlyCommentAuthorDoesNotFetchContextOrEmitAccepted(): Unit {
        // CTX-P2-N-002
        let dir = tempDir("gcm-ctx-p2-n002")
        let config = enabledConfig(dir.join("queue").toString())
        config.authorPolicy.commentAuthorRule.ids = ["856442"]
        let queue = WebhookQueue(config.webhook.queueDir)
        @Expect(queue.enqueue(GitCodeWebhookDelivery("ctx-p2-n002", "main", "Note Hook", 1000, "payload-hash", "", "pending", 0, "", 0, "ip-hash"), issue4NotePayload(commentId: "9007", note: "record only").toArray()).ok, true)
        let sender = FakeHttpSender()
        sender.enqueue(HttpResponseSpec(200, body: "{\"iid\":4,\"title\":\"should not fetch\"}"))
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = MonitorState()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)

        let result = processWebhookBatch(config, runtime, state, queue, nowMs: 2000, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))

        @Expect(result.processed, 1)
        @Expect(sink.lines.size, 0)
        @Expect(sender.requests.size, 0)
        @Expect(auditContains(state, "record_only", reason: "record_only_comment_author_id"), true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func reviewIdentityExtractsEmailsClassifiesCorporateAndDegrades(): Unit {
        // T-IDENTITY-001, T-IDENTITY-002, T-IDENTITY-003, T-IDENTITY-004, T-IDENTITY-005, T-IDENTITY-006, T-IDENTITY-007, T-IDENTITY-008, T-IDENTITY-010
        let corporate = JsonValue.fromStr(reviewFactsIssuePayload(email: "A@HUAWEI.COM")).asObject()
        let corporateIdentity = classifyCorporateAuthor(resolveAuthorEmails(corporate, GitCodeApiClient()), ["@huawei.com", "@h-partners.com"])
        @Expect(corporateIdentity.decision, "record_only")
        @Expect(corporateIdentity.corporateDomain, "@huawei.com")
        let partner = JsonValue.fromStr("{\"user\":{\"username\":\"u\",\"emails\":[\"a@example.com\",\"b@h-partners.com\"]}}").asObject()
        @Expect(classifyCorporateAuthor(resolveAuthorEmails(partner, GitCodeApiClient()), ["@huawei.com", "@h-partners.com"]).decision, "record_only")
        let external = JsonValue.fromStr(reviewFactsIssuePayload(email: "user@example.com")).asObject()
        @Expect(classifyCorporateAuthor(resolveAuthorEmails(external, GitCodeApiClient()), ["@huawei.com", "@h-partners.com"]).decision, "process")
        let missing = JsonValue.fromStr("{\"user\":{\"username\":\"unknown\"}}").asObject()
        let missingIdentity = classifyCorporateAuthor(resolveAuthorEmails(missing, GitCodeApiClient()), ["@huawei.com"])
        @Expect(missingIdentity.emailResolveStatus, "email_unavailable")
        @Expect(missingIdentity.decision, "process")
        let malformed = JsonValue.fromStr("{\"user\":{\"username\":\"bad\",\"email\":\"not-mail\"}}").asObject()
        @Expect(resolveAuthorEmails(malformed, GitCodeApiClient()).diagnostics[0].code, "invalid_email")
        let mrAuthor = JsonValue.fromStr("{\"merge_request\":{\"author\":{\"username\":\"carol\",\"name\":\"Carol\"}}}").asObject()
        @Expect(extractAuthorIdentityFromWebhook(mrAuthor).login, "carol")
        @Expect(extractAuthorIdentityFromWebhook(mrAuthor).displayName, "Carol")
        let objectAuthor = JsonValue.fromStr("{\"object_attributes\":{\"author\":{\"username\":\"dan\",\"name\":\"Dan\"}}}").asObject()
        @Expect(extractAuthorIdentityFromWebhook(objectAuthor).login, "dan")
        let timeout = JsonValue.fromStr("{\"user\":{\"username\":\"erin\"},\"emailResolveStatus\":\"timeout\"}").asObject()
        @Expect(resolveAuthorEmails(timeout, GitCodeApiClient()).emailResolveStatus, "timeout")
    }

    @TestCase
    public func reviewMaintainersParseResolveAndRenderContract(): Unit {
        // T-MAINT-001, T-MAINT-002, T-MAINT-004, T-MAINT-005, T-MAINT-006, T-MAINT-007, T-MAINT-008
        let text = "<table><tr><th>Team</th><th>Team Leader</th><th>org</th><th>repo_name</th></tr>" +
            "<tr><td>Tools Team</td><td><a href=\"https://atomgit.com/l3gi0n\">@l3gi0n</a> / <a href=\"https://gitcode.com/zjdd\">@zjdd</a></td><td>Cangjie</td><td>cangjie_tools</td></tr>" +
            "<tr><td>Empty Team</td><td></td><td>Cangjie</td><td>empty</td></tr></table>"
        let parsed = parseRepoListMd(text)
        @Expect(parsed.rows.size, 2)
        let resolved = resolveTeamLeaders("cangjie/CANGJIE_TOOLS", rows: parsed.rows)
        @Expect(resolved.teamLeaderStatus, "resolved")
        @Expect(resolved.team, "Tools Team")
        @Expect(resolved.teamLeaders[0].mention, "@l3gi0n")
        @Expect(resolved.teamLeaders[0].url, "https://atomgit.com/l3gi0n")
        @Expect(resolveTeamLeaders("Cangjie/empty", rows: parsed.rows).teamLeaderStatus, "not_found")
        @Expect(resolveTeamLeaders("Cangjie/missing", rows: parsed.rows).teamLeaderStatus, "not_found")
        @Expect(parseRepoListMd(String(Array<Rune>(210000, repeat: r'x'))).status, "truncated_catalog")
        let event = GitCodeEvent("gitcode:cangjie/cangjie_tools:issue:1", "cangjie", "cangjie_tools", "issue", "1", "alice", "", "", "body")
        let contract = renderReviewRequestJson("job-maint", event, maintainer: resolved)
        @Expect(contract.contains("\"teamLeaders\""), true)
        @Expect(contract.contains("@l3gi0n"), true)
    }

    @TestCase
    public func reviewCodeownersParseMatchOverrideAndRenderStatuses(): Unit {
        // T-CODEOWNERS-001, T-CODEOWNERS-002, T-CODEOWNERS-003, T-CODEOWNERS-004, T-CODEOWNERS-007, T-CODEOWNERS-008, T-CODEOWNERS-009, T-CODEOWNERS-010
        let parsed = parseCodeowners("# comment\n/.gitcode/ @jyf219 bad-owner\n/cjpm/ @old\n/cjpm/main.cj @new\n")
        @Expect(parsed.rules.size, 3)
        @Expect(parsed.diagnostics[0].code, "invalid_owner")
        @Expect(resolveCodeownersForPaths(parsed.rules, [".gitcode/config.yml"]).owners[0].mention, "@jyf219")
        let overridden = resolveCodeownersForPaths(parsed.rules, ["cjpm/main.cj"])
        @Expect(overridden.owners[0].mention, "@new")
        @Expect(resolveCodeownersForPaths(parseCodeowners("").rules, ["a.cj"]).codeownerStatus, "empty")
        let many = ArrayList<String>()
        for (i in 0..110) { many.add("cjpm/file${i}.cj") }
        @Expect(resolveCodeownersForPaths(parsed.rules, many.toArray()).changedFilesTruncated, true)
        let prEvent = GitCodeEvent("gitcode:cangjie/cangjie_tools:pr:9", "cangjie", "cangjie_tools", "pr", "9", "alice", "", "", "pr")
        @Expect(renderReviewRequestJson("job-codeowners", prEvent, codeowners: overridden).contains("\"codeownerStatus\":\"resolved\""), true)
        let issueEvent = GitCodeEvent("gitcode:cangjie/cangjie_tools:issue:9", "cangjie", "cangjie_tools", "issue", "9", "alice", "", "", "issue")
        @Expect(renderReviewRequestJson("job-codeowners-issue", issueEvent).contains("\"codeownerStatus\":\"not_applicable\""), true)
    }

    @TestCase
    public func reviewTemplatesClassifyExtractAndRedact(): Unit {
        // T-TEMPLATE-001, T-TEMPLATE-002, T-TEMPLATE-003, T-TEMPLATE-004, T-TEMPLATE-005, T-TEMPLATE-006, T-TEMPLATE-007, T-TEMPLATE-008, T-TEMPLATE-009, T-TEMPLATE-010, T-TEMPLATE-011, T-TEMPLATE-012
        let bugBody = "### cjc版本信息 | cjc version information\n0.53.4\n### 分支版本信息 | Branch version information\n- [x] main\n- [ ] dev\nAuthorization: Bearer secret\n/Users/alice/private\n"
        let bugFields = extractIssueFields(bugBody, "bug", [])
        @Expect(bugFields.cjcVersion, "0.53.4")
        @Expect(bugFields.branchVersions[0], "main")
        @Expect(bugFields.description.contains("Bearer secret"), false)
        @Expect(bugFields.description.contains("/Users/alice"), false)
        @Expect(classifyIssueKind("[Feature]: add cache", [], "", []), "feature-request")
        @Expect(classifyIssueKind("need help", ["question"], "", []), "question")
        @Expect(classifyIssueKind("broken yaml", [], "name: [", []), "unknown")
        let prEn = extractPrFields("## Change Type\n- [x] Bugfix\n## Related Issue\nhttps://gitcode.com/cangjie/compiler/issues/1", [])
        @Expect(prEn.changeTypes[0], "Bugfix")
        @Expect(prEn.relatedIssues[0], "https://gitcode.com/cangjie/compiler/issues/1")
        @Expect(extractPrFields("## 变更类型\n- [x] 问题修复\n## 关联 Issue\n无", []).changeTypes[0], "问题修复")
    }

    @TestCase
    public func reviewWebhookEnvelopeAndDefaultCorporateAuthorProcessesNormally(): Unit {
        // T-CONTRACT-007, T-TEMPLATE-013, T-TEMPLATE-014, T-IDENTITY-009, T-AP-PROCESSOR-001, T-AP-E2E-001
        let parsed = parseGitCodeWebhookPayload("Note Hook", "{" +
            "\"project\":{\"path_with_namespace\":\"cangjie/compiler\"}," +
            "\"issue\":{\"iid\":12,\"title\":\"question\",\"description\":\"issue body\"}," +
            "\"object_attributes\":{\"id\":9001,\"action\":\"create\",\"note\":\"comment body\",\"noteable_type\":\"Issue\",\"url\":\"https://gitcode.com/cangjie/compiler/issues/12#note_9001\"}," +
            "\"user\":{\"username\":\"alice\",\"email\":\"alice@example.com\"}" +
        "}")
        @Expect(parsed.ok, true)
        @Expect(parsed.envelope.isSome(), true)
        @Expect(parsed.envelope.getOrThrow().eventType, "comment")
        @Expect(parsed.envelope.getOrThrow().commentBody, "comment body")
        @Expect(parsed.envelope.getOrThrow().body, "issue body")
        let missingComment = parseGitCodeWebhookPayload("Note Hook", "{\"project\":{\"path_with_namespace\":\"cangjie/compiler\"},\"issue\":{\"iid\":12},\"object_attributes\":{\"note\":\"x\",\"noteable_type\":\"Issue\"}}")
        @Expect(missingComment.ok, false)
        @Expect(missingComment.errorKind, "missing_comment_id")
        let dir = tempDir("gcm-record-only")
        let config = enabledConfig(dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let delivery = GitCodeWebhookDelivery("delivery-corporate", "main", "Issue Hook", 1000, hashRawPayload("payload"), "", "pending", 0, "", 0, "ip")
        @Expect(queue.enqueue(delivery, reviewFactsIssuePayload(email: "dev@huawei.com").toArray()).ok, true)
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
        let state = runtime.store.load()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        let result = processWebhookBatch(config, runtime, state, queue, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))
        @Expect(result.processed, 1)
        @Expect(state.hasSeen("gitcode:cangjie/cangjie_tools:issue:71"), true)
        @Expect(auditContains(state, "record_only", reason: "corporate_author"), false)
        @Expect(sink.lines.size, 1)
        @Expect(decodeServiceFrame(sink.lines[0]).frame.capabilityId, "gitcode.event.accepted")
        let statusPayload = webhookStatusPayload(config, queue, state: Some<MonitorState>(state))
        @Expect(statusPayload.contains("\"recordOnly\":0"), true)
        @Expect(statusPayload.contains("token-secret"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func authorPolicyConfiguredDomainsDriveWebhookRecordOnlyDecisions(): Unit {
        // T-AP-PROCESSOR-002, T-AP-PROCESSOR-003, T-AP-PROCESSOR-004, T-AP-PROCESSOR-005, T-AP-PROCESSOR-006, T-AP-PROCESSOR-007, T-AP-DIAG-001, T-AP-DIAG-002, T-AP-DIAG-003, T-AP-E2E-002, T-AP-E2E-003
        let cases = [
            ("configured-huawei", ["@huawei.com", "@h-partners.com"], true, scopedIssuePayload("707874", "dev", "dev@huawei.com"), true),
            ("configured-example", ["@example.com"], true, scopedIssuePayload("707874", "dev", "dev@example.com"), true),
            ("disabled-huawei", ["@huawei.com"], false, scopedIssuePayload("707874", "dev", "dev@huawei.com"), false),
            ("subdomain-not-matched", ["@huawei.com"], true, scopedIssuePayload("707874", "dev", "dev@sub.huawei.com"), false),
            ("missing-email", ["@huawei.com"], true, reviewFactsIssuePayloadWithoutEmail(), false),
            ("custom-does-not-imply-huawei", ["@example.com"], true, scopedIssuePayload("707874", "dev", "dev@huawei.com"), false)
        ]
        for ((name, domains, enabled, payload, expectRecordOnly) in cases) {
            let dir = tempDir("gcm-author-policy-${name}")
            let config = enabledConfig(dir.join("queue").toString())
            config.authorPolicy.recordOnlyEnabled = enabled
            config.authorPolicy.recordOnlyEmailDomains = domains
            let queue = WebhookQueue(config.webhook.queueDir)
            let delivery = GitCodeWebhookDelivery("delivery-${name}", "main", "Issue Hook", 1000, hashRawPayload(payload), "", "pending", 0, "", 0, "ip")
            @Expect(queue.enqueue(delivery, payload.toArray()).ok, true)
            let runtime = RuntimeContainer(config, sender: Some<HttpSender>(FakeHttpSender()))
            let state = runtime.store.load()
            let sink = GcmMemoryLineSink()
            let writer = GcmPluginStdioWriter(sink)
            let result = processWebhookBatch(config, runtime, state, queue, maxItems: 1, eventWriter: Some<GcmPluginStdioWriter>(writer))
            @Expect(result.processed, 1)
            @Expect(queue.countByStatus("processed"), 1)
            if (expectRecordOnly) {
                @Expect(auditContains(state, "record_only", reason: "record_only_target_author_email_domain"), true)
                @Expect(sink.lines.size, 0)
            } else {
                @Expect(auditContains(state, "record_only", reason: "record_only_target_author_email_domain"), false)
                @Expect(sink.lines.size, 1)
                @Expect(decodeServiceFrame(sink.lines[0]).frame.capabilityId, "gitcode.event.accepted")
            }
            let statusPayload = webhookStatusPayload(config, queue, state: Some<MonitorState>(state))
            @Expect(statusPayload.contains("\"recordOnlyEnabled\":${enabled}"), true)
            @Expect(statusPayload.contains("\"recordOnlyDomainCount\":${domains.size}"), true)
            @Expect(statusPayload.contains("\"recordOnlyEffective\":${enabled && domains.size > 0}"), true)
            @Expect(statusPayload.contains("dev@"), false)
            @Expect(statusPayload.contains("token-secret"), false)
            try { remove(dir, recursive: true) } catch (_: Exception) { () }
        }
    }

    @TestCase
    public func reviewGitCodeRequestBuildersCoverContentsAndPullRequestFiles(): Unit {
        // T-MAINT-003, T-CODEOWNERS-005, T-CODEOWNERS-006, T-TEMPLATE-006
        let client = GitCodeApiClient(baseUrl: "https://mock.gitcode.test/api/v5/", token: "secret")
        let contents = client.contentsRequest(GitCodeRepo("Cangjie", "community"), "team/repo_list.md", "main")
        @Expect(contents.method, "GET")
        @Expect(contents.url, "https://mock.gitcode.test/api/v5/repos/Cangjie/community/contents/team%2Frepo_list.md?ref=main")
        @Expect(contents.redactedLogLine().contains("secret"), false)
        @Expect(fetchRepoListMd(client).status, "fetch_failed")
        @Expect(fetchCodeowners(client, GitCodeRepo("Cangjie", "cangjie_tools"), "main").status, "missing")
        @Expect(fetchIssueTemplateCatalog(client, GitCodeRepo("Cangjie", "cangjie_tools"), "main").status, "missing")
        @Expect(fetchPrTemplateCatalog(client, GitCodeRepo("Cangjie", "cangjie_tools"), "main").status, "missing")
        @Expect(client.pullRequestFilesRequest(GitCodeRepo("Cangjie", "cangjie_tools"), 9).url, "https://mock.gitcode.test/api/v5/repos/Cangjie/cangjie_tools/pulls/9/files")
    }
}
