package gitcodemonitor

import std.collection.*
import std.fs.{Directory, File, Path, exists, remove}

public class WebhookQueueResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public init(ok: Bool, status: String, diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.diagnostic = diagnostic
    }
}

public class WebhookPayloadReadResult {
    public let ok: Bool
    public let status: String
    public let payload: String
    public init(ok: Bool, status: String, payload!: String = "") {
        this.ok = ok
        this.status = status
        this.payload = payload
    }
}

public class WebhookQueue {
    public let queueDir: String
    public init(queueDir: String) {
        this.queueDir = queueDir
    }

    public func statusPath(status: String, deliveryId: String): String {
        Path(queueDir).join(status).join("${sanitizeDeliveryIdForPath(deliveryId)}.json").toString()
    }

    public func payloadPath(deliveryId: String): String {
        Path(queueDir).join("payload").join("${sanitizeDeliveryIdForPath(deliveryId)}.body").toString()
    }

    public func enqueue(delivery: GitCodeWebhookDelivery, body: Array<Byte>): WebhookQueueResult {
        try {
            ensureDirs()
            if (findStatus(delivery.deliveryId) != "") {
                return WebhookQueueResult(true, "already_exists")
            }
            let payload = payloadPath(delivery.deliveryId)
            File.writeTo(Path(payload), body)
            let stored = GitCodeWebhookDelivery(
                delivery.deliveryId,
                delivery.endpointId,
                delivery.eventName,
                delivery.receivedAtMs,
                delivery.bodyHash,
                payload,
                "pending",
                delivery.attempts,
                "",
                delivery.nextAttemptAtMs,
                delivery.sourceIpHash
            )
            File.writeTo(Path(statusPath("pending", delivery.deliveryId)), webhookDeliveryToJson(stored).toJsonString().toArray())
            WebhookQueueResult(true, "enqueued")
        } catch (e: Exception) {
            WebhookQueueResult(false, "queue_unavailable", diagnostic: hashRawPayload(e.message))
        }
    }

    public func claim(nowMs: Int64, maxItems: Int64): Array<GitCodeWebhookDelivery> {
        let out = ArrayList<GitCodeWebhookDelivery>()
        if (maxItems <= 0) { return out.toArray() }
        ensureDirs()
        try {
            for (entry in Directory.readFrom(Path(queueDir).join("pending"))) {
                if (out.size >= maxItems) { break }
                if (!entry.isRegular() || !entry.name.endsWith(".json")) { continue }
                let delivery = webhookDeliveryFromJson(String.fromUtf8(File.readFrom(entry.path)))
                if (delivery.nextAttemptAtMs > nowMs) { continue }
                let processing = delivery.withStatus("processing")
                File.writeTo(Path(statusPath("processing", delivery.deliveryId)), webhookDeliveryToJson(processing).toJsonString().toArray())
                try { remove(entry.path) } catch (_: Exception) { () }
                out.add(processing)
            }
        } catch (_: Exception) { () }
        out.toArray()
    }

    public func markProcessed(deliveryId: String, eventId: String): WebhookQueueResult {
        moveKnown(deliveryId, "processing", "processed", lastError: "", processedEventId: eventId)
    }

    public func markRetry(deliveryId: String, errorKind: String, nextAttemptAtMs: Int64): WebhookQueueResult {
        match (loadFromStatus("processing", deliveryId)) {
            case Some(delivery) =>
                let attempts = delivery.attempts + 1
                let retry = delivery.withStatus("pending", attempts: attempts, lastError: errorKind, nextAttemptAtMs: nextAttemptAtMs)
                File.writeTo(Path(statusPath("pending", deliveryId)), webhookDeliveryToJson(retry).toJsonString().toArray())
                try { remove(Path(statusPath("processing", deliveryId))) } catch (_: Exception) { () }
                WebhookQueueResult(true, "retry_scheduled")
            case None => WebhookQueueResult(false, "delivery_not_found")
        }
    }

    public func markDeadLetter(deliveryId: String, errorKind: String): WebhookQueueResult {
        moveKnown(deliveryId, "processing", "dead-letter", lastError: errorKind)
    }

    public func loadPayload(delivery: GitCodeWebhookDelivery): WebhookPayloadReadResult {
        let path = if (delivery.payloadPath.isEmpty()) { payloadPath(delivery.deliveryId) } else { delivery.payloadPath }
        if (!exists(Path(path))) { return WebhookPayloadReadResult(false, "payload_missing") }
        try {
            WebhookPayloadReadResult(true, "ok", payload: String.fromUtf8(File.readFrom(Path(path))))
        } catch (_: Exception) {
            WebhookPayloadReadResult(false, "payload_unreadable")
        }
    }

    public func countByStatus(status: String): Int64 {
        let dir = Path(queueDir).join(status)
        if (!exists(dir)) { return 0 }
        var count: Int64 = 0
        try {
            for (entry in Directory.readFrom(dir)) {
                if (entry.isRegular() && entry.name.endsWith(".json")) { count++ }
            }
        } catch (_: Exception) { () }
        count
    }

    public func loadDelivery(deliveryId: String): ?GitCodeWebhookDelivery {
        for (status in ["pending", "processing", "processed", "dead-letter", "cancelled"]) {
            match (loadFromStatus(status, deliveryId)) {
                case Some(delivery) => return Some<GitCodeWebhookDelivery>(delivery)
                case None => ()
            }
        }
        None<GitCodeWebhookDelivery>
    }

    public func findStatus(deliveryId: String): String {
        for (status in ["pending", "processing", "processed", "dead-letter", "cancelled"]) {
            if (exists(Path(statusPath(status, deliveryId)))) { return status }
        }
        ""
    }

    private func ensureDirs(): Unit {
        for (name in ["pending", "processing", "processed", "dead-letter", "cancelled", "payload"]) {
            let dir = Path(queueDir).join(name)
            if (!exists(dir)) { Directory.create(dir, recursive: true) }
        }
    }

    private func loadFromStatus(status: String, deliveryId: String): ?GitCodeWebhookDelivery {
        let path = Path(statusPath(status, deliveryId))
        if (!exists(path)) { return None<GitCodeWebhookDelivery> }
        try {
            Some<GitCodeWebhookDelivery>(webhookDeliveryFromJson(String.fromUtf8(File.readFrom(path))))
        } catch (_: Exception) {
            None<GitCodeWebhookDelivery>
        }
    }

    private func moveKnown(deliveryId: String, fromStatus: String, toStatus: String, lastError!: String = "", processedEventId!: String = ""): WebhookQueueResult {
        match (loadFromStatus(fromStatus, deliveryId)) {
            case Some(delivery) =>
                let moved = delivery.withStatus(toStatus, lastError: lastError, processedEventId: processedEventId)
                File.writeTo(Path(statusPath(toStatus, deliveryId)), webhookDeliveryToJson(moved).toJsonString().toArray())
                try { remove(Path(statusPath(fromStatus, deliveryId))) } catch (_: Exception) { () }
                WebhookQueueResult(true, if (toStatus == "processed") { "processed" } else if (toStatus == "dead-letter") { "dead_lettered" } else { toStatus })
            case None => WebhookQueueResult(false, "delivery_not_found")
        }
    }
}
