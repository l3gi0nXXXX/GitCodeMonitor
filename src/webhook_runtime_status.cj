package gitcodemonitor

import std.fs.{Directory, File, Path, exists, remove}

public class WebhookReceiverRuntimeStatus {
    public let status: String
    public let bind: String
    public let endpointCount: Int64
    public let queueDir: String
    public let lastError: String
    public let configStatus: String
    public let queueStatus: String
    public let listenerStatus: String
    public let processorStatus: String
    public let diagnostic: String

    public init(
        status: String,
        bind!: String = "",
        endpointCount!: Int64 = 0,
        queueDir!: String = "",
        lastError!: String = "",
        configStatus!: String = "unknown",
        queueStatus!: String = "unknown",
        listenerStatus!: String = "unknown",
        processorStatus!: String = "unknown",
        diagnostic!: String = ""
    ) {
        this.status = status.trimAscii()
        this.bind = bind.trimAscii()
        this.endpointCount = endpointCount
        this.queueDir = queueDir.trimAscii()
        this.lastError = lastError.trimAscii()
        this.configStatus = configStatus.trimAscii()
        this.queueStatus = queueStatus.trimAscii()
        this.listenerStatus = listenerStatus.trimAscii()
        this.processorStatus = processorStatus.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

public func evaluateWebhookReceiverRuntime(
    config: MonitorConfig,
    listenerSnapshot!: ?WebhookHttpServerSnapshot = None<WebhookHttpServerSnapshot>,
    processorSnapshot!: ?WebhookProcessorLoopSnapshot = None<WebhookProcessorLoopSnapshot>
): WebhookReceiverRuntimeStatus {
    let webhook = config.webhook
    let bind = "${webhook.bindHost}:${webhook.port}"
    let endpointCount = enabledWebhookEndpointCount(webhook)
    if (!webhook.enabled) {
        return WebhookReceiverRuntimeStatus(
            "disabled",
            bind: bind,
            endpointCount: endpointCount,
            queueDir: webhook.queueDir,
            configStatus: "disabled",
            queueStatus: "disabled",
            listenerStatus: "disabled",
            processorStatus: "disabled",
            diagnostic: "webhook_disabled"
        )
    }
    let validation = validateWebhookReceiverConfig(webhook)
    if (!validation.ok) {
        return WebhookReceiverRuntimeStatus(
            "degraded",
            bind: bind,
            endpointCount: endpointCount,
            queueDir: webhook.queueDir,
            lastError: validation.status,
            configStatus: validation.status,
            queueStatus: "unknown",
            listenerStatus: "not_started",
            processorStatus: "not_started",
            diagnostic: validation.status
        )
    }
    let queue = ensureWebhookQueueAvailable(webhook.queueDir)
    if (!queue.ok) {
        return WebhookReceiverRuntimeStatus(
            "degraded",
            bind: bind,
            endpointCount: endpointCount,
            queueDir: webhook.queueDir,
            lastError: queue.status,
            configStatus: "valid",
            queueStatus: queue.status,
            listenerStatus: "not_started",
            processorStatus: "not_started",
            diagnostic: queue.status
        )
    }
    let listenerStatus = match (listenerSnapshot) {
        case Some(snapshot) => snapshot.listenerStatus
        case None => "not_started"
    }
    let processorStatus = match (processorSnapshot) {
        case Some(snapshot) => snapshot.processorStatus
        case None => if (webhook.processor.enabled) { "not_started" } else { "disabled" }
    }
    let listenerError = match (listenerSnapshot) {
        case Some(snapshot) => snapshot.lastError
        case None => ""
    }
    let processorError = match (processorSnapshot) {
        case Some(snapshot) => snapshot.lastError
        case None => ""
    }
    let status = if (listenerStatus == "listening" && (processorStatus == "running" || processorStatus == "disabled")) {
        "running"
    } else {
        "degraded"
    }
    let diagnostic = if (listenerStatus == "not_started") {
        "listener_not_started"
    } else if (processorStatus == "not_started") {
        "processor_not_started"
    } else if (!listenerError.isEmpty()) {
        listenerError
    } else if (!processorError.isEmpty()) {
        processorError
    } else {
        ""
    }
    WebhookReceiverRuntimeStatus(
        status,
        bind: bind,
        endpointCount: endpointCount,
        queueDir: webhook.queueDir,
        lastError: if (!listenerError.isEmpty()) { listenerError } else { processorError },
        configStatus: "valid",
        queueStatus: "ready",
        listenerStatus: listenerStatus,
        processorStatus: processorStatus,
        diagnostic: diagnostic
    )
}

public func webhookReceiverRuntimeDiagnostic(runtime: WebhookReceiverRuntimeStatus): String {
    "webhookReceiver.status=${runtime.status} webhookBind=${runtime.bind} webhookEndpointCount=${runtime.endpointCount} webhookQueueDir=${redactServicePayload(runtime.queueDir).text} configStatus=${runtime.configStatus} queueStatus=${runtime.queueStatus} listenerStatus=${runtime.listenerStatus} processorStatus=${runtime.processorStatus} lastError=${runtime.lastError} diagnostic=${runtime.diagnostic}"
}

func enabledWebhookEndpointCount(config: WebhookReceiverConfig): Int64 {
    var count: Int64 = 0
    for (endpoint in config.endpoints) {
        if (endpoint.enabled) { count++ }
    }
    count
}

private func ensureWebhookQueueAvailable(queueDir: String): WebhookQueueResult {
    try {
        for (name in ["pending", "processing", "processed", "dead-letter", "cancelled", "payload"]) {
            let dir = Path(queueDir).join(name)
            if (!exists(dir)) { Directory.create(dir, recursive: true) }
        }
        let probe = Path(queueDir).join(".gcm-webhook-queue-probe")
        File.writeTo(probe, "ok".toArray())
        try { remove(probe) } catch (_: Exception) { () }
        WebhookQueueResult(true, "ok")
    } catch (_: Exception) {
        WebhookQueueResult(false, "queue_unavailable")
    }
}
