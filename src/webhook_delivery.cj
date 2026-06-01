package gitcodemonitor

import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

public class GitCodeWebhookDelivery {
    public let deliveryId: String
    public let endpointId: String
    public let eventName: String
    public let receivedAtMs: Int64
    public let bodyHash: String
    public let payloadPath: String
    public let status: String
    public let attempts: Int64
    public let lastError: String
    public let nextAttemptAtMs: Int64
    public let sourceIpHash: String
    public let processedEventId: String

    public init(
        deliveryId: String,
        endpointId: String,
        eventName: String,
        receivedAtMs: Int64,
        bodyHash: String,
        payloadPath: String,
        status: String,
        attempts: Int64,
        lastError: String,
        nextAttemptAtMs: Int64,
        sourceIpHash: String,
        processedEventId!: String = ""
    ) {
        this.deliveryId = deliveryId
        this.endpointId = endpointId
        this.eventName = eventName
        this.receivedAtMs = receivedAtMs
        this.bodyHash = bodyHash
        this.payloadPath = payloadPath
        this.status = status
        this.attempts = attempts
        this.lastError = lastError
        this.nextAttemptAtMs = nextAttemptAtMs
        this.sourceIpHash = sourceIpHash
        this.processedEventId = processedEventId
    }

    public func withStatus(status: String, attempts!: Int64 = this.attempts, lastError!: String = this.lastError, nextAttemptAtMs!: Int64 = this.nextAttemptAtMs, processedEventId!: String = this.processedEventId): GitCodeWebhookDelivery {
        GitCodeWebhookDelivery(deliveryId, endpointId, eventName, receivedAtMs, bodyHash, payloadPath, status, attempts, lastError, nextAttemptAtMs, sourceIpHash, processedEventId: processedEventId)
    }
}

public func webhookDeliveryToJson(delivery: GitCodeWebhookDelivery): JsonObject {
    let obj = JsonObject()
    obj.put("deliveryId", JsonString(delivery.deliveryId))
    obj.put("endpointId", JsonString(delivery.endpointId))
    obj.put("eventName", JsonString(delivery.eventName))
    obj.put("receivedAtMs", JsonInt(delivery.receivedAtMs))
    obj.put("bodyHash", JsonString(delivery.bodyHash))
    obj.put("payloadPath", JsonString(delivery.payloadPath))
    obj.put("status", JsonString(delivery.status))
    obj.put("attempts", JsonInt(delivery.attempts))
    obj.put("lastError", JsonString(redactSecrets(redactUrl(delivery.lastError))))
    obj.put("nextAttemptAtMs", JsonInt(delivery.nextAttemptAtMs))
    obj.put("sourceIpHash", JsonString(delivery.sourceIpHash))
    obj.put("processedEventId", JsonString(delivery.processedEventId))
    obj
}

public func webhookDeliveryFromJson(text: String): GitCodeWebhookDelivery {
    let obj = JsonValue.fromStr(text).asObject()
    GitCodeWebhookDelivery(
        readJsonString(obj, "deliveryId"),
        readJsonString(obj, "endpointId"),
        readJsonString(obj, "eventName"),
        readJsonInt(obj, "receivedAtMs"),
        readJsonString(obj, "bodyHash"),
        readJsonString(obj, "payloadPath"),
        readJsonString(obj, "status"),
        readJsonInt(obj, "attempts"),
        readJsonString(obj, "lastError"),
        readJsonInt(obj, "nextAttemptAtMs"),
        readJsonString(obj, "sourceIpHash"),
        processedEventId: readJsonString(obj, "processedEventId")
    )
}

public func sanitizeDeliveryIdForPath(deliveryId: String): String {
    var out = ""
    for (r in deliveryId.runes()) {
        let ok = (r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') || (r >= r'0' && r <= r'9') || r == r'.' || r == r'_' || r == r'-'
        out += if (ok) { String([r]) } else { "_" }
        if (out.toRuneArray().size >= 160) { break }
    }
    if (out.trimAscii().isEmpty()) { "delivery" } else { out }
}
