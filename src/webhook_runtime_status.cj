package gitcodemonitor

import std.fs.{Directory, File, Path, exists, remove}

public class WebhookReceiverRuntimeStatus {
    public let status: String
    public let bind: String
    public let endpointCount: Int64
    public let queueDir: String
    public let lastError: String

    public init(status: String, bind!: String = "", endpointCount!: Int64 = 0, queueDir!: String = "", lastError!: String = "") {
        this.status = status.trimAscii()
        this.bind = bind.trimAscii()
        this.endpointCount = endpointCount
        this.queueDir = queueDir.trimAscii()
        this.lastError = lastError.trimAscii()
    }
}

public func evaluateWebhookReceiverRuntime(config: MonitorConfig): WebhookReceiverRuntimeStatus {
    let webhook = config.webhook
    let bind = "${webhook.bindHost}:${webhook.port}"
    let endpointCount = enabledWebhookEndpointCount(webhook)
    if (!webhook.enabled) {
        return WebhookReceiverRuntimeStatus("disabled", bind: bind, endpointCount: endpointCount, queueDir: webhook.queueDir)
    }
    let validation = validateWebhookReceiverConfig(webhook)
    if (!validation.ok) {
        return WebhookReceiverRuntimeStatus("degraded", bind: bind, endpointCount: endpointCount, queueDir: webhook.queueDir, lastError: validation.status)
    }
    let queue = ensureWebhookQueueAvailable(webhook.queueDir)
    if (!queue.ok) {
        return WebhookReceiverRuntimeStatus("degraded", bind: bind, endpointCount: endpointCount, queueDir: webhook.queueDir, lastError: queue.status)
    }
    WebhookReceiverRuntimeStatus("running", bind: bind, endpointCount: endpointCount, queueDir: webhook.queueDir)
}

public func webhookReceiverRuntimeDiagnostic(runtime: WebhookReceiverRuntimeStatus): String {
    "webhookReceiver.status=${runtime.status} webhookBind=${runtime.bind} webhookEndpointCount=${runtime.endpointCount} webhookQueueDir=${redactServicePayload(runtime.queueDir).text} lastError=${runtime.lastError}"
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
