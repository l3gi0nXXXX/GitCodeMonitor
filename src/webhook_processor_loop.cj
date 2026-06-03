package gitcodemonitor

import std.sync.*
import std.time.*

public class WebhookProcessorLoopSnapshot {
    public let processorStatus: String
    public let lastBatchAtMs: Int64
    public let lastBatchClaimed: Int64
    public let lastBatchProcessed: Int64
    public let lastBatchIgnored: Int64
    public let lastBatchRetried: Int64
    public let lastBatchDeadLettered: Int64
    public let emptyTickCount: Int64
    public let lastStateSaveStatus: String
    public let lastStateSaveSkipped: Bool
    public let lastStateSaveDurationMs: Int64
    public let lastStateSaveBytes: Int64
    public let lastError: String

    public init(
        status: String,
        lastBatchAtMs!: Int64 = 0,
        lastBatchClaimed!: Int64 = 0,
        lastBatchProcessed!: Int64 = 0,
        lastBatchIgnored!: Int64 = 0,
        lastBatchRetried!: Int64 = 0,
        lastBatchDeadLettered!: Int64 = 0,
        emptyTickCount!: Int64 = 0,
        lastStateSaveStatus!: String = "not_started",
        lastStateSaveSkipped!: Bool = false,
        lastStateSaveDurationMs!: Int64 = 0,
        lastStateSaveBytes!: Int64 = 0,
        lastError!: String = ""
    ) {
        this.processorStatus = status.trimAscii()
        this.lastBatchAtMs = lastBatchAtMs
        this.lastBatchClaimed = lastBatchClaimed
        this.lastBatchProcessed = lastBatchProcessed
        this.lastBatchIgnored = lastBatchIgnored
        this.lastBatchRetried = lastBatchRetried
        this.lastBatchDeadLettered = lastBatchDeadLettered
        this.emptyTickCount = emptyTickCount
        this.lastStateSaveStatus = lastStateSaveStatus.trimAscii()
        this.lastStateSaveSkipped = lastStateSaveSkipped
        this.lastStateSaveDurationMs = lastStateSaveDurationMs
        this.lastStateSaveBytes = lastStateSaveBytes
        this.lastError = lastError.trimAscii()
    }
}

public class WebhookProcessorLoopTickResult {
    public let result: WebhookBatchResult
    public let sleepMs: Int64

    public init(result: WebhookBatchResult, sleepMs: Int64) {
        this.result = result
        this.sleepMs = sleepMs
    }
}

public class WebhookProcessorLoopRuntime {
    private let config: MonitorConfig
    private let runtime: RuntimeContainer
    private let state: MonitorState
    private let queue: WebhookQueue
    private let idleSleepMs: Int64
    private let failureSleepMs: Int64
    private let lock = Mutex()
    private let stopRequested = AtomicBool(false)
    private var worker: Option<Future<Unit>> = None
    private var processorStatus: String = "not_started"
    private var lastBatchAtMs: Int64 = 0
    private var lastBatchClaimed: Int64 = 0
    private var lastBatchProcessed: Int64 = 0
    private var lastBatchIgnored: Int64 = 0
    private var lastBatchRetried: Int64 = 0
    private var lastBatchDeadLettered: Int64 = 0
    private var emptyTickCount: Int64 = 0
    private var lastStateSaveStatus: String = "not_started"
    private var lastStateSaveSkipped: Bool = false
    private var lastStateSaveDurationMs: Int64 = 0
    private var lastStateSaveBytes: Int64 = 0
    private var lastError: String = ""

    public init(
        config: MonitorConfig,
        runtime: RuntimeContainer,
        state: MonitorState,
        queue: WebhookQueue,
        idleSleepMs!: Int64 = 1000,
        failureSleepMs!: Int64 = 5000
    ) {
        this.config = config
        this.runtime = runtime
        this.state = state
        this.queue = queue
        this.idleSleepMs = if (idleSleepMs < 0) { 0 } else { idleSleepMs }
        this.failureSleepMs = if (failureSleepMs < 0) { 0 } else { failureSleepMs }
    }

    public func start(eventWriter!: ?GcmPluginStdioWriter = None<GcmPluginStdioWriter>): Unit {
        synchronized(this.lock) {
            if (this.worker.isSome()) { return }
            if (!this.config.webhook.enabled || !this.config.webhook.processor.enabled) {
                this.processorStatus = "disabled"
                return
            }
            this.processorStatus = "running"
            this.stopRequested.store(false)
            this.worker = spawn {
                this.runLoop(eventWriter)
            }
        }
    }

    public func stop(): Unit {
        this.stopRequested.store(true)
        let existing = synchronized(this.lock) {
            let current = this.worker
            this.worker = None<Future<Unit>>
            current
        }
        existing?.cancel()
        try { existing?.get() } catch (_: Exception) { () }
        synchronized(this.lock) {
            if (this.processorStatus == "running") {
                this.processorStatus = "stopped"
            }
        }
    }

    public func tick(nowMs!: Int64 = DateTime.now().toUnixTimeStamp().toMilliseconds(), eventWriter!: ?GcmPluginStdioWriter = None<GcmPluginStdioWriter>): WebhookProcessorLoopTickResult {
        let result = processWebhookBatch(this.config, this.runtime, this.state, this.queue, nowMs: nowMs, maxItems: this.config.webhook.processor.maxBatchSize, eventWriter: eventWriter)
        let didWork = result.processed > 0 || result.ignored > 0 || result.retried > 0 || result.deadLettered > 0
        let sleepMs = if (!result.ok) {
            this.failureSleepMs
        } else if (didWork) {
            0
        } else {
            this.idleSleepMs
        }
        synchronized(this.lock) {
            this.processorStatus = if (result.ok) { "running" } else { "degraded" }
            this.lastBatchAtMs = nowMs
            this.lastBatchClaimed = result.claimed
            this.lastBatchProcessed = result.processed
            this.lastBatchIgnored = result.ignored
            this.lastBatchRetried = result.retried
            this.lastBatchDeadLettered = result.deadLettered
            this.lastStateSaveStatus = result.stateSaveStatus
            this.lastStateSaveSkipped = result.stateSaveSkipped
            this.lastStateSaveDurationMs = result.stateSaveDurationMs
            this.lastStateSaveBytes = result.stateSaveBytes
            if (!didWork) { this.emptyTickCount++ }
            this.lastError = if (result.ok) { "" } else { result.status }
        }
        WebhookProcessorLoopTickResult(result, sleepMs)
    }

    public func snapshot(): WebhookProcessorLoopSnapshot {
        synchronized(this.lock) {
            WebhookProcessorLoopSnapshot(
                this.processorStatus,
                lastBatchAtMs: this.lastBatchAtMs,
                lastBatchClaimed: this.lastBatchClaimed,
                lastBatchProcessed: this.lastBatchProcessed,
                lastBatchIgnored: this.lastBatchIgnored,
                lastBatchRetried: this.lastBatchRetried,
                lastBatchDeadLettered: this.lastBatchDeadLettered,
                emptyTickCount: this.emptyTickCount,
                lastStateSaveStatus: this.lastStateSaveStatus,
                lastStateSaveSkipped: this.lastStateSaveSkipped,
                lastStateSaveDurationMs: this.lastStateSaveDurationMs,
                lastStateSaveBytes: this.lastStateSaveBytes,
                lastError: this.lastError
            )
        }
    }

    private func runLoop(eventWriter: ?GcmPluginStdioWriter): Unit {
        while (!this.stopRequested.load() && !Thread.currentThread.hasPendingCancellation) {
            let ticked = this.tick(eventWriter: eventWriter)
            if (ticked.sleepMs > 0) {
                sleep(Duration.millisecond * ticked.sleepMs)
            }
        }
    }
}
