package gitcodemonitor

import std.collection.*
import std.fs.{File, Path}
import std.time.DateTime

public class WebhookBatchResult {
    public let ok: Bool
    public let status: String
    public let claimed: Int64
    public let processed: Int64
    public let ignored: Int64
    public let retried: Int64
    public let deadLettered: Int64
    public let stateSaved: Bool
    public let stateSaveSkipped: Bool
    public let stateSaveStatus: String
    public let stateSaveDurationMs: Int64
    public let stateSaveBytes: Int64
    public let diagnostic: String

    public init(
        ok: Bool,
        status: String,
        claimed!: Int64 = 0,
        processed!: Int64 = 0,
        ignored!: Int64 = 0,
        retried!: Int64 = 0,
        deadLettered!: Int64 = 0,
        stateSaved!: Bool = false,
        stateSaveSkipped!: Bool = false,
        stateSaveStatus!: String = "",
        stateSaveDurationMs!: Int64 = 0,
        stateSaveBytes!: Int64 = 0,
        diagnostic!: String = ""
    ) {
        this.ok = ok
        this.status = status
        this.claimed = claimed
        this.processed = processed
        this.ignored = ignored
        this.retried = retried
        this.deadLettered = deadLettered
        this.stateSaved = stateSaved
        this.stateSaveSkipped = stateSaveSkipped
        this.stateSaveStatus = stateSaveStatus.trimAscii()
        this.stateSaveDurationMs = stateSaveDurationMs
        this.stateSaveBytes = stateSaveBytes
        this.diagnostic = diagnostic
    }
}

public class WebhookHookReconcileRow {
    public let repo: GitCodeRepo
    public let status: String
    public let action: String
    public init(repo: GitCodeRepo, status: String, action!: String = "") {
        this.repo = repo
        this.status = status
        this.action = action
    }
}

public class WebhookHookReconcileResult {
    public let ok: Bool
    public let status: String
    public let results: Array<WebhookHookReconcileRow>
    public init(ok: Bool, status: String, results!: Array<WebhookHookReconcileRow> = []) {
        this.ok = ok
        this.status = status
        this.results = results
    }
}

public func processWebhookBatch(
    config: MonitorConfig,
    runtime: RuntimeContainer,
    state: MonitorState,
    queue: WebhookQueue,
    nowMs!: Int64 = DateTime.now().toUnixTimeStamp().toMilliseconds(),
    maxItems!: Int64 = 20,
    eventWriter!: ?GcmPluginStdioWriter = None<GcmPluginStdioWriter>
): WebhookBatchResult {
    if (!config.webhook.processor.enabled) {
        return WebhookBatchResult(true, "processor_disabled")
    }
    let limit = if (maxItems <= 0) { config.webhook.processor.maxBatchSize } else { maxItems }
    let beforeVersion = state.version()
    let claimed = queue.claim(nowMs, limit)
    if (claimed.size == 0) {
        let skipped = runtime.store.markSaveSkipped("skipped_empty_queue", "empty_queue")
        return WebhookBatchResult(
            true,
            "ok",
            claimed: 0,
            stateSaved: skipped.saved,
            stateSaveSkipped: skipped.skipped,
            stateSaveStatus: skipped.status,
            stateSaveDurationMs: skipped.durationMs,
            stateSaveBytes: skipped.bytes
        )
    }
    var processed: Int64 = 0
    var ignored: Int64 = 0
    var retried: Int64 = 0
    var dead: Int64 = 0
    for (delivery in claimed) {
        let payload = queue.loadPayload(delivery)
        if (!payload.ok) {
            let _ = queue.markDeadLetter(delivery.deliveryId, payload.status)
            dead++
            continue
        }
        let parsed = parseGitCodeWebhookPayload(delivery.eventName, payload.payload)
        if (!parsed.ok) {
            let _ = queue.markDeadLetter(delivery.deliveryId, parsed.errorKind)
            dead++
            continue
        }
        if (parsed.ignored) {
            state.addAudit(AuditRecord(delivery.deliveryId, status: "webhook_ignored", reason: parsed.ignoreReason))
            let _ = queue.markProcessed(delivery.deliveryId, "")
            ignored++
            continue
        }
        let result = processRuntimeEvent(config, state, parsed.event, runtime.feishu, runtime.telegram, runtime.mcp, runtime.writer, baselineMode: false)
        if (result.failedEvents > 0) {
            let _ = queue.markRetry(delivery.deliveryId, "runtime_failed", nowMs + 60000)
            retried++
        } else {
            if (result.newEvents > 0) {
                match (eventWriter) {
                    case Some(writer) => emitGcmAcceptedScanEvent("webhook-${sanitizeDeliveryIdForPath(delivery.deliveryId)}", parsed.event, writer)
                    case None => ()
                }
            }
            let _ = queue.markProcessed(delivery.deliveryId, parsed.event.id)
            processed++
        }
    }
    let saved = runtime.store.saveIfChanged(state, beforeVersion)
    let ok = saved.saved || saved.skipped
    WebhookBatchResult(
        ok,
        if (ok) { "ok" } else { saved.status },
        claimed: claimed.size,
        processed: processed,
        ignored: ignored,
        retried: retried,
        deadLettered: dead,
        stateSaved: saved.saved,
        stateSaveSkipped: saved.skipped,
        stateSaveStatus: saved.status,
        stateSaveDurationMs: saved.durationMs,
        stateSaveBytes: saved.bytes,
        diagnostic: saved.diagnostic
    )
}

public func replayWebhookDelivery(queue: WebhookQueue, deliveryId: String): WebhookQueueResult {
    match (queue.loadDelivery(deliveryId)) {
        case Some(delivery) =>
            if (delivery.status != "dead-letter" && delivery.status != "cancelled" && delivery.status != "processed") {
                return WebhookQueueResult(false, "delivery_not_replayable")
            }
            let replayed = delivery.withStatus("pending", attempts: 0, lastError: "", nextAttemptAtMs: 0)
            try {
                let path = queue.statusPath("pending", deliveryId)
                File.writeTo(Path(path), webhookDeliveryToJson(replayed).toJsonString().toArray())
                WebhookQueueResult(true, "replay_accepted")
            } catch (_: Exception) {
                WebhookQueueResult(false, "queue_unavailable")
            }
        case None => WebhookQueueResult(false, "delivery_not_found")
    }
}

public func cancelWebhookDelivery(queue: WebhookQueue, deliveryId: String): WebhookQueueResult {
    match (queue.loadDelivery(deliveryId)) {
        case Some(delivery) =>
            if (delivery.status == "processed") { return WebhookQueueResult(false, "delivery_already_processed") }
            let cancelled = delivery.withStatus("cancelled")
            try {
                let path = queue.statusPath("cancelled", deliveryId)
                File.writeTo(Path(path), webhookDeliveryToJson(cancelled).toJsonString().toArray())
                WebhookQueueResult(true, "cancelled")
            } catch (_: Exception) {
                WebhookQueueResult(false, "queue_unavailable")
            }
        case None => WebhookQueueResult(false, "delivery_not_found")
    }
}

public func renderWebhookStatus(
    config: MonitorConfig,
    queue: WebhookQueue,
    listenerSnapshot!: ?WebhookHttpServerSnapshot = None<WebhookHttpServerSnapshot>,
    processorSnapshot!: ?WebhookProcessorLoopSnapshot = None<WebhookProcessorLoopSnapshot>
): String {
    let receiver = evaluateWebhookReceiverRuntime(config, listenerSnapshot: listenerSnapshot, processorSnapshot: processorSnapshot)
    let errorPart = if (receiver.lastError.isEmpty()) { "" } else { " lastError=${receiver.lastError}" }
    let processorPart = match (processorSnapshot) {
        case Some(snapshot) => " lastClaimed=${snapshot.lastBatchClaimed} stateSave=${snapshot.lastStateSaveStatus} stateSaveDurationMs=${snapshot.lastStateSaveDurationMs}"
        case None => ""
    }
    "GitCode Webhook receiver=${receiver.status} listener=${receiver.listenerStatus} processor=${receiver.processorStatus} pending=${queue.countByStatus("pending")} processing=${queue.countByStatus("processing")} processed=${queue.countByStatus("processed")} deadLetter=${queue.countByStatus("dead-letter")} cancelled=${queue.countByStatus("cancelled")}${processorPart}${errorPart}"
}

public func webhookStatusPayload(
    config: MonitorConfig,
    queue: WebhookQueue,
    listenerSnapshot!: ?WebhookHttpServerSnapshot = None<WebhookHttpServerSnapshot>,
    processorSnapshot!: ?WebhookProcessorLoopSnapshot = None<WebhookProcessorLoopSnapshot>,
    state!: ?MonitorState = None<MonitorState>
): String {
    let receiver = evaluateWebhookReceiverRuntime(config, listenerSnapshot: listenerSnapshot, processorSnapshot: processorSnapshot)
    let auditCount = match (state) {
        case Some(value) => value.audit.size
        case None => 0
    }
    let processorDetails = match (processorSnapshot) {
        case Some(snapshot) =>
            "\"lastBatchAtMs\":${snapshot.lastBatchAtMs},\"lastBatchClaimed\":${snapshot.lastBatchClaimed},\"lastBatchProcessed\":${snapshot.lastBatchProcessed},\"lastBatchIgnored\":${snapshot.lastBatchIgnored},\"lastBatchRetried\":${snapshot.lastBatchRetried},\"lastBatchDeadLettered\":${snapshot.lastBatchDeadLettered},\"emptyTickCount\":${snapshot.emptyTickCount},\"stateSaveStatus\":\"${jsonEscape(snapshot.lastStateSaveStatus)}\",\"stateSaveSkipped\":${snapshot.lastStateSaveSkipped},\"stateSaveDurationMs\":${snapshot.lastStateSaveDurationMs},\"stateSaveBytes\":${snapshot.lastStateSaveBytes},"
        case None =>
            "\"lastBatchAtMs\":0,\"lastBatchClaimed\":0,\"lastBatchProcessed\":0,\"lastBatchIgnored\":0,\"lastBatchRetried\":0,\"lastBatchDeadLettered\":0,\"emptyTickCount\":0,\"stateSaveStatus\":\"not_started\",\"stateSaveSkipped\":false,\"stateSaveDurationMs\":0,\"stateSaveBytes\":0,"
    }
    let listenerDetails = match (listenerSnapshot) {
        case Some(snapshot) =>
            "\"listenerLastStatus\":${snapshot.lastResponseStatus},\"listenerLastDurationMs\":${snapshot.lastRequestDurationMs},\"healthzCount\":${snapshot.healthzCount},\"activeRequestCount\":${snapshot.activeRequestCount},"
        case None =>
            "\"listenerLastStatus\":0,\"listenerLastDurationMs\":0,\"healthzCount\":0,\"activeRequestCount\":0,"
    }
    "{\"ok\":true,\"status\":\"ok\",\"receiver\":\"${jsonEscape(receiver.status)}\",\"webhookReceiverStatus\":\"${jsonEscape(receiver.status)}\",\"configStatus\":\"${jsonEscape(receiver.configStatus)}\",\"queueStatus\":\"${jsonEscape(receiver.queueStatus)}\",\"listenerStatus\":\"${jsonEscape(receiver.listenerStatus)}\",\"processorStatus\":\"${jsonEscape(receiver.processorStatus)}\",\"webhookBind\":\"${jsonEscape(receiver.bind)}\",\"webhookEndpointCount\":${receiver.endpointCount},\"webhookQueueDir\":\"${jsonEscape(redactServicePayload(receiver.queueDir).text)}\",\"publicBaseUrlConfigured\":${!config.webhook.publicBaseUrl.isEmpty()},\"diagnostic\":\"${jsonEscape(receiver.diagnostic)}\",\"lastError\":\"${jsonEscape(receiver.lastError)}\",${listenerDetails}${processorDetails}\"queue\":{\"pending\":${queue.countByStatus("pending")},\"processing\":${queue.countByStatus("processing")},\"processed\":${queue.countByStatus("processed")},\"deadLetter\":${queue.countByStatus("dead-letter")},\"cancelled\":${queue.countByStatus("cancelled")}},\"pending\":${queue.countByStatus("pending")},\"processing\":${queue.countByStatus("processing")},\"processed\":${queue.countByStatus("processed")},\"deadLetter\":${queue.countByStatus("dead-letter")},\"cancelled\":${queue.countByStatus("cancelled")},\"auditCount\":${auditCount},\"auditMax\":${DEFAULT_MAX_AUDIT_RECORDS},\"summary\":\"${jsonEscape(renderWebhookStatus(config, queue, listenerSnapshot: listenerSnapshot, processorSnapshot: processorSnapshot))}\"}"
}

public func deadLetterListPayload(queue: WebhookQueue): String {
    "{\"ok\":true,\"status\":\"ok\",\"count\":${queue.countByStatus("dead-letter")}}"
}

public func deadLetterInspectPayload(queue: WebhookQueue, deliveryId: String): String {
    match (queue.loadDelivery(deliveryId)) {
        case Some(delivery) =>
            "{\"ok\":true,\"status\":\"${jsonEscape(delivery.status)}\",\"deliveryId\":\"${jsonEscape(sanitizeDeliveryIdForPath(delivery.deliveryId))}\",\"eventName\":\"${jsonEscape(delivery.eventName)}\",\"attempts\":${delivery.attempts},\"errorKind\":\"${jsonEscape(delivery.lastError)}\"}"
        case None =>
            "{\"ok\":false,\"status\":\"delivery_not_found\",\"deliveryId\":\"${jsonEscape(sanitizeDeliveryIdForPath(deliveryId))}\"}"
    }
}

public func reconcileWebhookHooksDryRun(config: MonitorConfig, repos: Array<GitCodeRepo>): WebhookHookReconcileResult {
    let rows = ArrayList<WebhookHookReconcileRow>()
    let configured = config.webhook.enabled && config.webhook.endpoints.size > 0 && !config.webhook.publicBaseUrl.isEmpty()
    for (repo in repos) {
        rows.add(WebhookHookReconcileRow(repo, if (configured) { "missing" } else { "receiver_not_configured" }, action: if (configured) { "create" } else { "skip" }))
    }
    WebhookHookReconcileResult(true, "dry_run", results: rows.toArray())
}

public func hookReconcilePayload(config: MonitorConfig, apply: Bool): String {
    if (apply && config.webhook.publicBaseUrl.trimAscii().isEmpty()) {
        return "{\"ok\":false,\"status\":\"apply_rejected\",\"apply\":true,\"applyRejected\":true,\"rejectReason\":\"publicBaseUrl missing\",\"aligned\":0,\"missing\":0,\"wrong_url\":0,\"wrong_events\":0,\"auth_failed\":0,\"failed\":0,\"summary\":\"GitCode webhook hook reconcile apply rejected\"}"
    }
    let status = if (apply) { "apply_unavailable" } else { "dry_run" }
    "{\"ok\":true,\"status\":\"${status}\",\"apply\":${apply},\"aligned\":0,\"missing\":0,\"wrong_url\":0,\"wrong_events\":0,\"auth_failed\":0,\"failed\":0,\"updated\":0,\"summary\":\"GitCode webhook hook reconcile ${status}\"}"
}

public func eventReconcilePayload(config: MonitorConfig): String {
    "{\"ok\":true,\"status\":\"accepted\",\"mode\":\"async\",\"lookbackHours\":${config.webhook.reconcile.lookbackHours},\"repos\":0,\"candidates\":0,\"newEvents\":0,\"drafts\":0,\"notifications\":0,\"writes\":0,\"summary\":\"GitCode webhook reconcile accepted\"}"
}
