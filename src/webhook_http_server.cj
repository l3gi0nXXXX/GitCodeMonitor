package gitcodemonitor

import std.collection.*
import std.convert.Parsable
import std.sync.*
import std.time.*
import stdx.net.http.*

public class WebhookHttpServerSnapshot {
    public let listenerStatus: String
    public let bind: String
    public let startedAtMs: Int64
    public let lastRequestAtMs: Int64
    public let lastError: String
    public let acceptedCount: Int64
    public let rejectedCount: Int64
    public let lastResponseStatus: Int64
    public let lastRequestDurationMs: Int64
    public let healthzCount: Int64
    public let activeRequestCount: Int64

    public init(
        status: String,
        bind!: String = "",
        startedAtMs!: Int64 = 0,
        lastRequestAtMs!: Int64 = 0,
        lastError!: String = "",
        acceptedCount!: Int64 = 0,
        rejectedCount!: Int64 = 0,
        lastResponseStatus!: Int64 = 0,
        lastRequestDurationMs!: Int64 = 0,
        healthzCount!: Int64 = 0,
        activeRequestCount!: Int64 = 0
    ) {
        this.listenerStatus = status.trimAscii()
        this.bind = bind.trimAscii()
        this.startedAtMs = startedAtMs
        this.lastRequestAtMs = lastRequestAtMs
        this.lastError = lastError.trimAscii()
        this.acceptedCount = acceptedCount
        this.rejectedCount = rejectedCount
        this.lastResponseStatus = lastResponseStatus
        this.lastRequestDurationMs = lastRequestDurationMs
        this.healthzCount = healthzCount
        this.activeRequestCount = activeRequestCount
    }
}

public class WebhookHttpServerStartResult {
    public let ok: Bool
    public let status: String
    public let snapshot: WebhookHttpServerSnapshot

    public init(ok: Bool, status: String, snapshot!: WebhookHttpServerSnapshot = WebhookHttpServerSnapshot("not_started")) {
        this.ok = ok
        this.status = status.trimAscii()
        this.snapshot = snapshot
    }
}

public class WebhookBodyReadResult {
    public let ok: Bool
    public let status: String
    public let body: Array<Byte>

    public init(ok: Bool, status: String, body!: Array<Byte> = []) {
        this.ok = ok
        this.status = status
        this.body = body
    }
}

public class WebhookHttpServerRuntime {
    private let config: MonitorConfig
    private let queue: WebhookQueue
    private let lock = Mutex()
    private var server: Option<Server> = None
    private var listenerStatus: String = "not_started"
    private var startedAtMs: Int64 = 0
    private var lastRequestAtMs: Int64 = 0
    private var lastError: String = ""
    private var acceptedCount: Int64 = 0
    private var rejectedCount: Int64 = 0
    private var lastResponseStatus: Int64 = 0
    private var lastRequestDurationMs: Int64 = 0
    private var healthzCount: Int64 = 0
    private var activeRequestCount: Int64 = 0

    public init(config: MonitorConfig, queue: WebhookQueue) {
        this.config = config
        this.queue = queue
    }

    public func start(): WebhookHttpServerStartResult {
        synchronized(this.lock) {
            if (!this.config.webhook.enabled) {
                this.listenerStatus = "disabled"
                return WebhookHttpServerStartResult(false, "disabled", snapshot: this.snapshotLocked())
            }
            let validation = validateWebhookReceiverConfig(this.config.webhook)
            if (!validation.ok) {
                this.listenerStatus = "degraded"
                this.lastError = validation.status
                return WebhookHttpServerStartResult(false, validation.status, snapshot: this.snapshotLocked())
            }
            if (this.server.isSome()) {
                return WebhookHttpServerStartResult(true, "already_started", snapshot: this.snapshotLocked())
            }
            try {
                let s = ServerBuilder()
                    .addr(this.config.webhook.bindHost)
                    .port(UInt16(this.config.webhook.port))
                    .build()
                for (endpoint in this.config.webhook.endpoints) {
                    if (!endpoint.enabled) { continue }
                    s.distributor.register(endpoint.path, { ctx =>
                        this.handleHttpContext(ctx, endpoint.path)
                    })
                }
                s.distributor.register("/healthz", { ctx =>
                    this.handleHealthzContext(ctx)
                })
                this.server = Some<Server>(s)
                this.listenerStatus = "listening"
                this.startedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                this.lastError = ""
                spawn {
                    try {
                        s.serve()
                    } catch (e: Exception) {
                        synchronized(this.lock) {
                            this.listenerStatus = "degraded"
                            this.lastError = redactServicePayload(e.message).rawHash
                            this.server = None<Server>
                        }
                    }
                }
                WebhookHttpServerStartResult(true, "listening", snapshot: this.snapshotLocked())
            } catch (e: Exception) {
                this.listenerStatus = "degraded"
                this.lastError = redactServicePayload(e.message).rawHash
                WebhookHttpServerStartResult(false, "bind_failed", snapshot: this.snapshotLocked())
            }
        }
    }

    public func stop(): Unit {
        let current = synchronized(this.lock) {
            let s = this.server
            this.server = None<Server>
            if (this.listenerStatus == "listening") { this.listenerStatus = "stopped" }
            s
        }
        try { current?.close() } catch (_: Exception) { () }
    }

    public func snapshot(): WebhookHttpServerSnapshot {
        synchronized(this.lock) {
            this.snapshotLocked()
        }
    }

    private func handleHealthzContext(ctx: HttpContext): Unit {
        let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
        synchronized(this.lock) {
            this.activeRequestCount++
        }
        let response = handleWebhookHealthzRequest()
        let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
        synchronized(this.lock) {
            this.lastRequestAtMs = ended
            this.lastResponseStatus = response.statusCode
            this.lastRequestDurationMs = if (ended >= started) { ended - started } else { 0 }
            this.healthzCount++
            if (this.activeRequestCount > 0) { this.activeRequestCount-- }
        }
        ctx.responseBuilder.status(UInt16(response.statusCode))
        for ((key, value) in response.headers) {
            ctx.responseBuilder.header(key, value)
        }
        ctx.responseBuilder.body(response.body)
    }

    private func handleHttpContext(ctx: HttpContext, routePath: String): Unit {
        let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
        synchronized(this.lock) {
            this.activeRequestCount++
        }
        let read = readWebhookRequestBody(ctx, this.config.webhook.maxBodyBytes + 1)
        let response = if (read.ok) {
            handleWebhookHttpServerRequest(
                this.config,
                this.queue,
                convertWebhookHttpRequest(
                    ctx.request.method,
                    routePath,
                    collectWebhookHeaders(ctx),
                    read.body,
                    webhookRequestRemoteAddress(ctx)
                )
            )
        } else {
            WebhookHttpResponse(if (read.status == "payload_too_large") { 413 } else { 408 }, read.status)
        }
        let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
        synchronized(this.lock) {
            this.lastRequestAtMs = ended
            this.lastResponseStatus = response.statusCode
            this.lastRequestDurationMs = if (ended >= started) { ended - started } else { 0 }
            if (response.statusCode >= 200 && response.statusCode < 300) {
                this.acceptedCount++
            } else {
                this.rejectedCount++
            }
            if (this.activeRequestCount > 0) { this.activeRequestCount-- }
        }
        ctx.responseBuilder.status(UInt16(response.statusCode))
        for ((key, value) in response.headers) {
            ctx.responseBuilder.header(key, value)
        }
        ctx.responseBuilder.body(response.body)
    }

    private func snapshotLocked(): WebhookHttpServerSnapshot {
        WebhookHttpServerSnapshot(
            this.listenerStatus,
            bind: "${this.config.webhook.bindHost}:${this.config.webhook.port}",
            startedAtMs: this.startedAtMs,
            lastRequestAtMs: this.lastRequestAtMs,
            lastError: this.lastError,
            acceptedCount: this.acceptedCount,
            rejectedCount: this.rejectedCount,
            lastResponseStatus: this.lastResponseStatus,
            lastRequestDurationMs: this.lastRequestDurationMs,
            healthzCount: this.healthzCount,
            activeRequestCount: this.activeRequestCount
        )
    }
}

public func convertWebhookHttpRequest(method: String, path: String, headers: Array<(String, String)>, body: Array<Byte>, remoteAddr: String): WebhookHttpRequest {
    WebhookHttpRequest(method.trimAscii(), path.trimAscii(), headers, body, remoteAddr.trimAscii())
}

public func handleWebhookHttpServerRequest(config: MonitorConfig, queue: WebhookQueue, request: WebhookHttpRequest): WebhookHttpResponse {
    handleGitCodeWebhookRequest(config, request, queue)
}

public func handleWebhookHealthzRequest(): WebhookHttpResponse {
    WebhookHttpResponse(200, "ok")
}

public func collectWebhookHeaders(ctx: HttpContext): Array<(String, String)> {
    let names = [
        "Content-Type",
        "content-type",
        "X-GitCode-Token",
        "x-gitcode-token",
        "X-GitCode-Event",
        "x-gitcode-event",
        "X-GitCode-Delivery",
        "x-gitcode-delivery",
        "X-Gitlab-Event",
        "x-gitlab-event",
        "X-Gitlab-Delivery",
        "x-gitlab-delivery",
        "X-Gitee-Event",
        "x-gitee-event",
        "X-Gitee-Delivery",
        "x-gitee-delivery",
        "X-Request-Id",
        "x-request-id",
        "X-Forwarded-For",
        "x-forwarded-for",
        "X-Real-IP",
        "x-real-ip",
        "Content-Length",
        "content-length"
    ]
    let headers = ArrayList<(String, String)>()
    for (name in names) {
        let value = ctx.request.headers.getFirst(name) ?? ""
        if (!value.isEmpty()) {
            headers.add((name, value))
        }
    }
    headers.toArray()
}

public func webhookRequestRemoteAddress(ctx: HttpContext): String {
    (ctx.request.headers.getFirst("X-Forwarded-For") ??
        ctx.request.headers.getFirst("x-forwarded-for") ??
        ctx.request.headers.getFirst("X-Real-IP") ??
        ctx.request.headers.getFirst("x-real-ip") ??
        "").trimAscii()
}

public func readWebhookRequestBody(ctx: HttpContext, maxBytes: Int64): WebhookBodyReadResult {
    try {
        let contentLength = ctx.request.headers.getFirst("Content-Length") ?? ctx.request.headers.getFirst("content-length") ?? ""
        if (!contentLength.trimAscii().isEmpty()) {
            let declared = try {
                Int64.parse(contentLength.trimAscii())
            } catch (_: Exception) {
                return WebhookBodyReadResult(false, "malformed_content_length")
            }
            if (maxBytes > 0 && declared > maxBytes) {
                return WebhookBodyReadResult(false, "payload_too_large")
            }
        }
        let output = ArrayList<Byte>()
        let buffer = Array<Byte>(8192, repeat: 0)
        var chunks: Int64 = 0
        let maxChunks = if (maxBytes <= 0) { 4096 } else { (maxBytes / 8192) + 2 }
        while (true) {
            let n = ctx.request.body.read(buffer)
            if (n <= 0) { break }
            chunks++
            if (chunks > maxChunks) {
                return WebhookBodyReadResult(false, "body_read_chunk_limit")
            }
            if (maxBytes > 0 && Int64(output.size) + Int64(n) > maxBytes) {
                return WebhookBodyReadResult(false, "payload_too_large")
            }
            output.add(all: buffer[..n])
        }
        WebhookBodyReadResult(true, "ok", body: output.toArray())
    } catch (_: Exception) {
        WebhookBodyReadResult(false, "body_read_failed")
    }
}
