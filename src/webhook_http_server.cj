package gitcodemonitor

import std.collection.*
import std.convert.Parsable
import std.env.{getProcessId, getVariable}
import std.fs.{Directory, File, Path, exists, OpenMode}
import std.sync.*
import std.time.*
import stdx.log.*
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
    public let serveWorkerDone: Bool
    public let stopBounded: Bool

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
        activeRequestCount!: Int64 = 0,
        serveWorkerDone!: Bool = true,
        stopBounded!: Bool = true
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
        this.serveWorkerDone = serveWorkerDone
        this.stopBounded = stopBounded
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
    private let stopRequested = AtomicBool(false)
    private var server: Option<Server> = None
    private var serveWorker: Option<Future<Unit>> = None
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
    private var serveWorkerDone: Bool = true
    private var stopBounded: Bool = true

    public init(config: MonitorConfig, queue: WebhookQueue) {
        this.config = config
        this.queue = queue
    }

    public func start(): WebhookHttpServerStartResult {
        appendGcmListenerDiagnostic("start_enter", detail: "bind=${this.config.webhook.bindHost}:${this.config.webhook.port} enabled=${this.config.webhook.enabled}")
        synchronized(this.lock) {
            if (!this.config.webhook.enabled) {
                this.listenerStatus = "disabled"
                appendGcmListenerDiagnostic("start_disabled")
                return WebhookHttpServerStartResult(false, "disabled", snapshot: this.snapshotLocked())
            }
            let validation = validateWebhookReceiverConfig(this.config.webhook)
            if (!validation.ok) {
                this.listenerStatus = "degraded"
                this.lastError = validation.status
                appendGcmListenerDiagnostic("start_config_degraded", detail: "status=${validation.status}")
                return WebhookHttpServerStartResult(false, validation.status, snapshot: this.snapshotLocked())
            }
            if (this.server.isSome()) {
                appendGcmListenerDiagnostic("start_already_started")
                return WebhookHttpServerStartResult(true, "already_started", snapshot: this.snapshotLocked())
            }
            try {
                appendGcmListenerDiagnostic("server_build_enter", detail: "bind=${this.config.webhook.bindHost}:${this.config.webhook.port}")
                let s = ServerBuilder()
                    .addr(this.config.webhook.bindHost)
                    .port(UInt16(this.config.webhook.port))
                    .build()
                s.logger.level = LogLevel.OFF
                appendGcmListenerDiagnostic("server_build_done")
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
                this.stopRequested.store(false)
                this.listenerStatus = "listening"
                this.startedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                this.lastError = ""
                this.serveWorkerDone = false
                this.stopBounded = true
                appendGcmListenerDiagnostic("serve_worker_spawn")
                let worker = spawn {
                    var failed = false
                    var diagnostic = ""
                    appendGcmListenerDiagnostic("serve_worker_enter")
                    try {
                        s.serve()
                        appendGcmListenerDiagnostic("serve_returned")
                    } catch (e: Exception) {
                        appendGcmListenerDiagnostic("serve_exception", detail: "stopRequested=${this.stopRequested.load()} errorHash=${redactServicePayload(e.message).rawHash}")
                        if (!this.stopRequested.load()) {
                            failed = true
                            diagnostic = redactServicePayload(e.message).rawHash
                        }
                    }
                    synchronized(this.lock) {
                        this.serveWorkerDone = true
                        this.serveWorker = None<Future<Unit>>
                        this.server = None<Server>
                        if (failed) {
                            this.listenerStatus = "degraded"
                            this.lastError = diagnostic
                        } else if (this.listenerStatus == "listening") {
                            this.listenerStatus = "stopped"
                        }
                    }
                    appendGcmListenerDiagnostic("serve_worker_done", detail: "failed=${failed}")
                }
                this.serveWorker = Some<Future<Unit>>(worker)
                appendGcmListenerDiagnostic("start_listening")
                WebhookHttpServerStartResult(true, "listening", snapshot: this.snapshotLocked())
            } catch (e: Exception) {
                this.listenerStatus = "degraded"
                this.lastError = redactServicePayload(e.message).rawHash
                appendGcmListenerDiagnostic("start_bind_failed", detail: "errorHash=${this.lastError}")
                WebhookHttpServerStartResult(false, "bind_failed", snapshot: this.snapshotLocked())
            }
        }
    }

    public func stop(): Unit {
        let current = synchronized(this.lock) {
            let s = this.server
            let worker = this.serveWorker
            let status = this.listenerStatus
            let serveDone = this.serveWorkerDone
            this.server = None<Server>
            this.stopRequested.store(true)
            if (this.listenerStatus == "listening") { this.listenerStatus = "stopped" }
            (s, worker, status, serveDone)
        }
        appendGcmListenerDiagnostic("stop_enter", detail: "serverPresent=${current[0].isSome()} workerPresent=${current[1].isSome()} statusBefore=${current[2]} serveWorkerDoneBefore=${current[3]}")
        let closeStarted = DateTime.now().toUnixTimeStamp().toMilliseconds()
        appendGcmListenerDiagnostic("stop_server_close_enter", detail: "serverPresent=${current[0].isSome()}")
        try {
            current[0]?.close()
            let closeEnded = DateTime.now().toUnixTimeStamp().toMilliseconds()
            appendGcmListenerDiagnostic("stop_server_close_done", detail: "durationMs=${if (closeEnded >= closeStarted) { closeEnded - closeStarted } else { 0 }}")
        } catch (e: Exception) {
            let closeEnded = DateTime.now().toUnixTimeStamp().toMilliseconds()
            appendGcmListenerDiagnostic("stop_server_close_exception", detail: "durationMs=${if (closeEnded >= closeStarted) { closeEnded - closeStarted } else { 0 }} errorHash=${redactServicePayload(e.message).rawHash}")
        }
        appendGcmListenerDiagnostic("stop_worker_cancel_enter", detail: "workerPresent=${current[1].isSome()}")
        current[1]?.cancel()
        appendGcmListenerDiagnostic("stop_worker_cancel_done")
        appendGcmListenerDiagnostic("stop_wait_worker_enter", detail: "timeoutMs=500")
        let bounded = this.waitServeWorkerDone(500)
        appendGcmListenerDiagnostic("stop_wait_worker_done", detail: "bounded=${bounded}")
        synchronized(this.lock) {
            this.stopBounded = bounded
            if (!bounded) {
                this.lastError = "serve_worker_stop_timeout"
            }
        }
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
        try {
            this.writeWebhookHttpResponse(ctx, response)
            this.finishHealthzRequest(started, response.statusCode)
        } catch (e: Exception) {
            let diagnostic = redactServicePayload(e.message).rawHash
            appendGcmListenerDiagnostic("healthz_response_exception", detail: "errorHash=${diagnostic}")
            this.finishHealthzRequest(started, 500, error: diagnostic)
        }
    }

    private func handleHttpContext(ctx: HttpContext, routePath: String): Unit {
        let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
        synchronized(this.lock) {
            this.activeRequestCount++
        }
        try {
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
            this.writeWebhookHttpResponse(ctx, response)
            this.finishWebhookRequest(started, response.statusCode)
        } catch (e: Exception) {
            let diagnostic = redactServicePayload(e.message).rawHash
            appendGcmListenerDiagnostic("webhook_response_exception", detail: "route=${routePath} errorHash=${diagnostic}")
            this.finishWebhookRequest(started, 500, error: diagnostic)
        }
    }

    private func finishHealthzRequest(started: Int64, statusCode: Int64, error!: String = ""): Unit {
        let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
        synchronized(this.lock) {
            this.lastRequestAtMs = ended
            this.lastResponseStatus = statusCode
            this.lastRequestDurationMs = if (ended >= started) { ended - started } else { 0 }
            if (!error.isEmpty()) { this.lastError = error }
            this.healthzCount++
            if (this.activeRequestCount > 0) { this.activeRequestCount-- }
        }
    }

    private func finishWebhookRequest(started: Int64, statusCode: Int64, error!: String = ""): Unit {
        let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
        synchronized(this.lock) {
            this.lastRequestAtMs = ended
            this.lastResponseStatus = statusCode
            this.lastRequestDurationMs = if (ended >= started) { ended - started } else { 0 }
            if (!error.isEmpty()) { this.lastError = error }
            if (statusCode >= 200 && statusCode < 300) {
                this.acceptedCount++
            } else {
                this.rejectedCount++
            }
            if (this.activeRequestCount > 0) { this.activeRequestCount-- }
        }
    }

    private func writeWebhookHttpResponse(ctx: HttpContext, response: WebhookHttpResponse): Unit {
        ctx.responseBuilder.status(UInt16(response.statusCode))
        for ((key, value) in webhookHttpResponseWireHeaders(response)) {
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
            activeRequestCount: this.activeRequestCount,
            serveWorkerDone: this.serveWorkerDone,
            stopBounded: this.stopBounded
        )
    }

    private func waitServeWorkerDone(timeoutMs: Int64): Bool {
        let boundedTimeout = if (timeoutMs <= 0) { 1 } else { timeoutMs }
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + boundedTimeout
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() <= deadline) {
            let done = synchronized(this.lock) {
                this.serveWorkerDone
            }
            if (done) { return true }
            sleep(Duration.millisecond * 5)
        }
        synchronized(this.lock) {
            this.serveWorkerDone
        }
    }
}

private func appendGcmListenerDiagnostic(phase: String, detail!: String = ""): Unit {
    let path = gcmListenerDiagnosticPath()
    if (path.isEmpty()) { return }
    let safePhase = phase.trimAscii()
    if (safePhase.isEmpty()) { return }
    let safeDetail = redactServicePayload(detail.trimAscii()).text
    let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let line = if (safeDetail.isEmpty()) {
        "${nowMs} pid=${getProcessId()} phase=${safePhase}\n"
    } else {
        "${nowMs} pid=${getProcessId()} phase=${safePhase} ${safeDetail}\n"
    }
    try {
        let target = Path(path)
        let parent = target.parent
        if (!exists(parent)) { Directory.create(parent, recursive: true) }
        try (file = File(target, OpenMode.Append)) {
            file.write(line.toArray())
        }
    } catch (_: Exception) {
        ()
    }
}

private func gcmListenerDiagnosticPath(): String {
    let leasePath = match (getVariable("METIS_SERVICE_PLUGIN_LEASE_PATH")) {
        case Some(value) => value.trimAscii()
        case None => ""
    }
    if (leasePath.isEmpty()) { return "" }
    try {
        Path(leasePath).parent.join("listener-diagnostics.log").toString()
    } catch (_: Exception) {
        ""
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

public func webhookHttpResponseWireHeaders(response: WebhookHttpResponse): Array<(String, String)> {
    let headers = ArrayList<(String, String)>()
    var hasConnection = false
    var hasContentLength = false
    for ((key, value) in response.headers) {
        let lower = key.trimAscii().toAsciiLower()
        if (lower == "connection") { hasConnection = true }
        if (lower == "content-length") { hasContentLength = true }
        headers.add((key, value))
    }
    if (!hasConnection) { headers.add(("Connection", "close")) }
    if (!hasContentLength) { headers.add(("Content-Length", "${response.body.toArray().size}")) }
    headers.toArray()
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
