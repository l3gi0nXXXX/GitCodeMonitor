package gitcodemonitor

import std.convert.Parsable
import std.env.{exit, getProcessId, getVariable}
import std.process.executeWithOutput
import std.sync.*
import std.time.*

public class GcmPluginWatchdogContext {
    public let leasePath: String
    public let lease: GcmPluginLease
    public let parentSnapshot: GcmPluginOwnerSnapshot
    public let forceOrphan: Bool

    public init(leasePath: String, lease: GcmPluginLease, parentSnapshot: GcmPluginOwnerSnapshot, forceOrphan!: Bool = false) {
        this.leasePath = leasePath.trimAscii()
        this.lease = lease
        this.parentSnapshot = parentSnapshot
        this.forceOrphan = forceOrphan
    }
}

public class GcmPluginWatchdogTickResult {
    public let orphanDetected: Bool
    public let status: String
    public let reason: String

    public init(orphanDetected: Bool, status: String, reason!: String = "") {
        this.orphanDetected = orphanDetected
        this.status = status.trimAscii()
        this.reason = reason.trimAscii()
    }
}

public class GcmPluginWatchdogRuntime {
    private let leasePath: String
    private let baseLease: GcmPluginLease
    private let writer: GcmPluginStdioWriter
    private let listener: WebhookHttpServerRuntime
    private let processorLoop: WebhookProcessorLoopRuntime
    private let intervalMs: Int64
    private let forceOrphan: Bool
    private let stopRequested = AtomicBool(false)
    private let lock = Mutex()
    private var worker: Option<Future<Unit>> = None

    public init(
        leasePath: String,
        lease: GcmPluginLease,
        writer: GcmPluginStdioWriter,
        listener: WebhookHttpServerRuntime,
        processorLoop: WebhookProcessorLoopRuntime,
        intervalMs!: Int64 = 1000,
        forceOrphan!: Bool = false
    ) {
        this.leasePath = leasePath.trimAscii()
        this.baseLease = lease
        this.writer = writer
        this.listener = listener
        this.processorLoop = processorLoop
        this.intervalMs = if (intervalMs <= 0) { 1000 } else { intervalMs }
        this.forceOrphan = forceOrphan
    }

    public func start(): Unit {
        synchronized(this.lock) {
            if (this.worker.isSome()) { return }
            this.stopRequested.store(false)
            this.worker = spawn {
                this.runLoop()
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
    }

    private func runLoop(): Unit {
        while (!this.stopRequested.load() && !Thread.currentThread.hasPendingCancellation) {
            let parentSnapshot = GcmPluginOwnerSnapshot(gcmProcessExists(this.baseLease.parentPid), false, 0, observedParentPid: gcmCurrentParentPid())
            let ticked = gcmPluginWatchdogTick(
                GcmPluginWatchdogContext(this.leasePath, this.baseLease, parentSnapshot, forceOrphan: this.forceOrphan),
                nowMs: DateTime.now().toUnixTimeStamp().toMilliseconds()
            )
            if (ticked.orphanDetected) {
                let loaded = readGcmPluginLease(this.leasePath)
                if (loaded.ok) {
                    this.writer.writeFrame(gcmPluginOrphanDetectedFrame(loaded.lease))
                }
                this.processorLoop.stop()
                this.listener.stop()
                exit(0)
            }
            sleep(Duration.millisecond * this.intervalMs)
        }
    }
}

public func gcmPluginWatchdogTick(context: GcmPluginWatchdogContext, nowMs!: Int64 = DateTime.now().toUnixTimeStamp().toMilliseconds()): GcmPluginWatchdogTickResult {
    if (context.forceOrphan) {
        let _ = markGcmPluginLeaseOrphan(context.leasePath, "test_injected_orphan", nowMs: nowMs)
        return GcmPluginWatchdogTickResult(true, "orphan_detected", reason: "test_injected_orphan")
    }
    if (context.parentSnapshot.observedParentPid > 0 && context.parentSnapshot.observedParentPid != context.lease.parentPid && !context.parentSnapshot.pidExists) {
        let _ = markGcmPluginLeaseOrphan(context.leasePath, "parent_mismatch_unreachable", nowMs: nowMs)
        return GcmPluginWatchdogTickResult(true, "orphan_detected", reason: "parent_mismatch_unreachable")
    }
    if (!context.parentSnapshot.pidExists) {
        let _ = markGcmPluginLeaseOrphan(context.leasePath, "parent_lost", nowMs: nowMs)
        return GcmPluginWatchdogTickResult(true, "orphan_detected", reason: "parent_lost")
    }
    let heartbeat = context.lease.withHeartbeat(nowMs)
    let written = writeGcmPluginLease(context.leasePath, heartbeat)
    if (!written.ok) {
        return GcmPluginWatchdogTickResult(false, written.status)
    }
    GcmPluginWatchdogTickResult(false, "heartbeat")
}

public func gcmPluginOrphanDetectedFrame(lease: GcmPluginLease): ServiceFrame {
    ServiceFrame(
        "event",
        "orphan-${lease.sessionId}-${lease.lastHeartbeatMs}",
        GCM_SERVICE_PLUGIN_ID,
        method: "emitCapabilityEvent",
        capabilityId: "gitcode.monitor.orphan_detected",
        payload: gcmPluginOrphanDetectedPayload(lease)
    )
}

public func gcmPluginOrphanDetectedPayload(lease: GcmPluginLease): String {
    "{" +
        "\"ok\":true," +
        "\"status\":\"orphan_detected\"," +
        "\"pluginId\":\"${jsonEscape(lease.pluginId)}\"," +
        "\"sessionId\":\"${jsonEscape(lease.sessionId)}\"," +
        "\"pid\":${lease.pid}," +
        "\"parentPid\":${lease.parentPid}," +
        "\"bindHost\":\"${jsonEscape(lease.bindHost)}\"," +
        "\"port\":${lease.port}," +
        "\"startedAtMs\":${lease.startedAtMs}," +
        "\"lastHeartbeatMs\":${lease.lastHeartbeatMs}," +
        "\"orphanReason\":\"${jsonEscape(lease.orphanReason)}\"" +
        "}"
}

public func buildGcmPluginLeaseFromEnv(config: MonitorConfig, startedAtMs: Int64): Option<(String, GcmPluginLease, Bool)> {
    let sessionId = gcmPluginEnv("METIS_SERVICE_PLUGIN_SESSION_ID")
    let leasePath = gcmPluginEnv("METIS_SERVICE_PLUGIN_LEASE_PATH")
    let parentPidText = gcmPluginEnv("METIS_SERVICE_PLUGIN_PARENT_PID")
    if (sessionId.isEmpty() || leasePath.isEmpty() || parentPidText.isEmpty()) {
        return None<(String, GcmPluginLease, Bool)>
    }
    let parentPid = try { Int64.parse(parentPidText) } catch (_: Exception) { 0 }
    if (parentPid <= 0) {
        return None<(String, GcmPluginLease, Bool)>
    }
    let lease = GcmPluginLease(
        GCM_SERVICE_PLUGIN_ID,
        sessionId,
        getProcessId(),
        parentPid,
        config.webhook.bindHost,
        config.webhook.port,
        startedAtMs,
        startedAtMs,
        "running",
        ""
    )
    Some<(String, GcmPluginLease, Bool)>((leasePath, lease, gcmPluginForceOrphanEnv()))
}

public func gcmProcessExists(pid: Int64): Bool {
    if (pid <= 0) { return false }
    try {
        let (exitCode, _, _) = executeWithOutput("kill", ["-0", "${pid}"])
        exitCode == 0
    } catch (_: Exception) {
        false
    }
}

public func gcmCurrentParentPid(): Int64 {
    try {
        let (exitCode, stdoutBytes, _) = executeWithOutput("ps", ["-o", "ppid=", "-p", "${getProcessId()}"])
        if (exitCode != 0) { return 0 }
        Int64.parse(String.fromUtf8(stdoutBytes).trimAscii())
    } catch (_: Exception) {
        0
    }
}

func gcmPluginEnv(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value.trimAscii()
        case None => ""
    }
}

func gcmPluginForceOrphanEnv(): Bool {
    let value = gcmPluginEnv("METIS_SERVICE_PLUGIN_FORCE_ORPHAN").toAsciiLower()
    value == "1" || value == "true" || value == "yes"
}
