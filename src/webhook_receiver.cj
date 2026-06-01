package gitcodemonitor

import std.time.DateTime
import stdx.encoding.json.JsonValue

public class WebhookHttpRequest {
    public let method: String
    public let path: String
    public let headers: Array<(String, String)>
    public let body: Array<Byte>
    public let remoteAddr: String
    public init(method: String, path: String, headers: Array<(String, String)>, body: Array<Byte>, remoteAddr: String) {
        this.method = method
        this.path = path
        this.headers = headers
        this.body = body
        this.remoteAddr = remoteAddr
    }
}

public class WebhookHttpResponse {
    public let statusCode: Int64
    public let body: String
    public let headers: Array<(String, String)>
    public init(statusCode: Int64, body: String, headers!: Array<(String, String)> = [("Content-Type", "text/plain; charset=utf-8")]) {
        this.statusCode = statusCode
        this.body = body
        this.headers = headers
    }
}

public func handleGitCodeWebhookRequest(config: MonitorConfig, request: WebhookHttpRequest, queue: WebhookQueue): WebhookHttpResponse {
    if (!config.webhook.enabled) { return WebhookHttpResponse(503, "webhook disabled") }
    if (request.method.toAsciiUpper() != "POST") { return WebhookHttpResponse(405, "method not allowed") }
    let endpoint = findWebhookEndpoint(config.webhook, request.path)
    match (endpoint) {
        case None => return WebhookHttpResponse(404, "webhook endpoint not found")
        case Some(ep) =>
            let contentType = webhookHeader(request.headers, ["Content-Type"])
            if (!contentType.toAsciiLower().contains("application/json")) { return WebhookHttpResponse(415, "unsupported content type") }
            if (request.body.size > config.webhook.maxBodyBytes) { return WebhookHttpResponse(413, "payload too large") }
            let eventName = webhookHeader(request.headers, ["X-GitCode-Event", "X-Gitlab-Event", "X-Gitee-Event"])
            if (!arrayContains(ep.allowedEvents, eventName)) { return WebhookHttpResponse(400, "rejected unknown event") }
            let auth = verifyGitCodeWebhookAuth(ep, request.headers, request.body)
            if (!auth.ok) { return WebhookHttpResponse(401, "unauthorized ${auth.status}") }
            let bodyText = try {
                String.fromUtf8(request.body)
            } catch (_: Exception) {
                return WebhookHttpResponse(400, "payload is not utf8 json")
            }
            try {
                let _ = JsonValue.fromStr(bodyText).asObject()
            } catch (_: Exception) {
                return WebhookHttpResponse(400, "payload must be json object")
            }
            let deliveryId = deriveWebhookDeliveryId(eventName, request.headers, bodyText)
            let delivery = GitCodeWebhookDelivery(
                deliveryId,
                ep.id,
                eventName,
                DateTime.now().toUnixTimeStamp().toMilliseconds(),
                hashRawPayload(bodyText),
                "",
                "pending",
                0,
                "",
                0,
                hashRawPayload(request.remoteAddr)
            )
            let enqueued = queue.enqueue(delivery, request.body)
            if (!enqueued.ok) { return WebhookHttpResponse(503, "queue unavailable ${enqueued.status}") }
            WebhookHttpResponse(202, if (enqueued.status == "already_exists") { "duplicate accepted deliveryId=${sanitizeDeliveryIdForPath(deliveryId)}" } else { "accepted deliveryId=${sanitizeDeliveryIdForPath(deliveryId)} status=queued" })
    }
}

public func findWebhookEndpoint(config: WebhookReceiverConfig, path: String): ?WebhookEndpointConfig {
    for (endpoint in config.endpoints) {
        if (endpoint.enabled && endpoint.path == path) { return Some<WebhookEndpointConfig>(endpoint) }
    }
    None<WebhookEndpointConfig>
}

public func deriveWebhookDeliveryId(eventName: String, headers: Array<(String, String)>, body: String): String {
    let headerId = webhookHeader(headers, ["X-GitCode-Delivery", "X-Gitlab-Delivery", "X-Gitee-Delivery", "X-Request-Id"])
    if (!headerId.isEmpty()) { return headerId }
    "${eventName}-${hashRawPayload(body)}"
}
