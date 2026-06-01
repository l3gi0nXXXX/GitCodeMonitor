package gitcodemonitor

import std.collection.*
import std.fs.Path

public class WebhookEndpointConfig {
    public let id: String
    public let path: String
    public let token: String
    public let signatureSecret: String
    public let allowedEvents: Array<String>
    public let enabled: Bool

    public init(
        id: String,
        path: String,
        token!: String = "",
        signatureSecret!: String = "",
        allowedEvents!: Array<String> = ["Merge Request Hook", "Issue Hook", "Note Hook"],
        enabled!: Bool = true
    ) {
        this.id = id.trimAscii()
        this.path = path.trimAscii()
        this.token = token
        this.signatureSecret = signatureSecret
        this.allowedEvents = allowedEvents
        this.enabled = enabled
    }
}

public class WebhookProcessorConfig {
    public let enabled: Bool
    public let maxBatchSize: Int64
    public let maxAttempts: Int64
    public init(enabled!: Bool = true, maxBatchSize!: Int64 = 20, maxAttempts!: Int64 = 5) {
        this.enabled = enabled
        this.maxBatchSize = if (maxBatchSize <= 0) { 20 } else { maxBatchSize }
        this.maxAttempts = if (maxAttempts <= 0) { 5 } else { maxAttempts }
    }
}

public class WebhookReconcileConfig {
    public let lookbackHours: Int64
    public let maxRepos: Int64
    public let maxItems: Int64
    public init(lookbackHours!: Int64 = 24, maxRepos!: Int64 = 20, maxItems!: Int64 = 200) {
        this.lookbackHours = if (lookbackHours <= 0) { 24 } else { lookbackHours }
        this.maxRepos = if (maxRepos <= 0) { 20 } else { maxRepos }
        this.maxItems = if (maxItems <= 0) { 200 } else { maxItems }
    }
}

public class WebhookReceiverConfig {
    public let enabled: Bool
    public let bindHost: String
    public let port: Int64
    public let publicBaseUrl: String
    public let maxBodyBytes: Int64
    public let queueDir: String
    public let deadLetterDir: String
    public let ackMode: String
    public let endpoints: Array<WebhookEndpointConfig>
    public let processor: WebhookProcessorConfig
    public let reconcile: WebhookReconcileConfig

    public init(
        enabled!: Bool = false,
        bindHost!: String = "127.0.0.1",
        port!: Int64 = 8080,
        publicBaseUrl!: String = "",
        maxBodyBytes!: Int64 = 1048576,
        queueDir!: String = "data/webhook-queue",
        deadLetterDir!: String = "",
        ackMode!: String = "fast",
        endpoints!: Array<WebhookEndpointConfig> = [],
        processor!: WebhookProcessorConfig = WebhookProcessorConfig(),
        reconcile!: WebhookReconcileConfig = WebhookReconcileConfig()
    ) {
        this.enabled = enabled
        this.bindHost = bindHost.trimAscii()
        this.port = port
        this.publicBaseUrl = publicBaseUrl.trimAscii()
        this.maxBodyBytes = maxBodyBytes
        this.queueDir = queueDir.trimAscii()
        this.deadLetterDir = if (deadLetterDir.trimAscii().isEmpty()) { Path(this.queueDir).join("dead-letter").toString() } else { deadLetterDir.trimAscii() }
        this.ackMode = ackMode.trimAscii()
        this.endpoints = endpoints
        this.processor = processor
        this.reconcile = reconcile
    }
}

public class WebhookConfigValidationResult {
    public let ok: Bool
    public let status: String
    public let diagnostic: String
    public init(ok: Bool, status!: String = "ok", diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.diagnostic = diagnostic
    }
}

public func defaultWebhookReceiverConfigForStatePath(statePath: String): WebhookReceiverConfig {
    let parent = Path(statePath).parent
    WebhookReceiverConfig(queueDir: parent.join("webhook-queue").toString())
}

public func validateWebhookReceiverConfig(config: WebhookReceiverConfig): WebhookConfigValidationResult {
    if (!config.enabled) { return WebhookConfigValidationResult(true) }
    if (config.bindHost.isEmpty()) { return WebhookConfigValidationResult(false, status: "invalid_bind_host") }
    if (config.port < 1 || config.port > 65535) { return WebhookConfigValidationResult(false, status: "invalid_port") }
    if (config.maxBodyBytes < 1024 || config.maxBodyBytes > 10485760) { return WebhookConfigValidationResult(false, status: "invalid_max_body_bytes") }
    if (config.ackMode != "fast") { return WebhookConfigValidationResult(false, status: "invalid_ack_mode") }
    if (config.endpoints.size == 0) { return WebhookConfigValidationResult(false, status: "missing_endpoint") }
    let ids = HashSet<String>()
    for (endpoint in config.endpoints) {
        if (!endpoint.enabled) { continue }
        if (endpoint.id.isEmpty()) { return WebhookConfigValidationResult(false, status: "missing_endpoint_id") }
        if (ids.contains(endpoint.id)) { return WebhookConfigValidationResult(false, status: "duplicate_endpoint_id") }
        ids.add(endpoint.id)
        if (!isSafeWebhookPath(endpoint.path)) { return WebhookConfigValidationResult(false, status: "invalid_endpoint_path") }
        if (endpoint.token.isEmpty() && endpoint.signatureSecret.isEmpty()) { return WebhookConfigValidationResult(false, status: "missing_endpoint_secret") }
        for (eventName in endpoint.allowedEvents) {
            if (!isAllowedGitCodeWebhookEvent(eventName)) {
                return WebhookConfigValidationResult(false, status: "invalid_allowed_event", diagnostic: eventName)
            }
        }
    }
    WebhookConfigValidationResult(true)
}

public func isSafeWebhookPath(path: String): Bool {
    let p = path.trimAscii()
    !p.isEmpty() && p.startsWith("/") && !p.contains("..")
}

public func isAllowedGitCodeWebhookEvent(eventName: String): Bool {
    match (eventName.trimAscii()) {
        case "Merge Request Hook" | "Issue Hook" | "Note Hook" => true
        case _ => false
    }
}

public func webhookConfigSummary(config: WebhookReceiverConfig): String {
    let status = if (config.enabled) { "enabled" } else { "disabled" }
    let endpoints = ArrayList<String>()
    for (endpoint in config.endpoints) {
        endpoints.add("${endpoint.id}:${endpoint.path}:${joinStrings(endpoint.allowedEvents, "|")}")
    }
    "webhook=${status}\n" +
        "webhookBind=${config.bindHost}:${config.port}\n" +
        "webhookPublicBaseUrl=${config.publicBaseUrl}\n" +
        "webhookQueueDir=${config.queueDir}\n" +
        "webhookEndpoints=${joinStrings(endpoints.toArray(), ",")}"
}
