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
    public let parentProbeFailureCount: Int64
    public let parentProbeFailureThreshold: Int64

    public init(
        leasePath: String,
        lease: GcmPluginLease,
        parentSnapshot: GcmPluginOwnerSnapshot,
        parentProbeFailureCount!: Int64 = 0,
        parentProbeFailureThreshold!: Int64 = 3,
        forceOrphan!: Bool = false
    ) {
        this.leasePath = leasePath.trimAscii()
        this.lease = lease
        this.parentSnapshot = parentSnapshot
        this.forceOrphan = forceOrphan
        this.parentProbeFailureCount = if (parentProbeFailureCount < 0) { 0 } else { parentProbeFailureCount }
        this.parentProbeFailureThreshold = if (parentProbeFailureThreshold <= 0) { 3 } else { parentProbeFailureThreshold }
    }
}

public class GcmPluginWatchdogTickResult {
    public let orphanDetected: Bool
    public let status: String
    public let reason: String
    public let parentProbeFailureCount: Int64

    public init(orphanDetected: Bool, status: String, reason!: String = "", parentProbeFailureCount!: Int64 = 0) {
        this.orphanDetected = orphanDetected
        this.status = status.trimAscii()
        this.reason = reason.trimAscii()
        this.parentProbeFailureCount = if (parentProbeFailureCount < 0) { 0 } else { parentProbeFailureCount }
    }
}

public class GcmProcessProbeResult {
    public let pid: Int64
    public let exists: Bool
    public let status: String
    public let diagnostic: String

    public init(pid: Int64, exists: Bool, status: String, diagnostic!: String = "") {
        this.pid = pid
        this.exists = exists
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class GcmParentPidProbeResult {
    public let parentPid: Int64
    public let status: String
    public let diagnostic: String

    public init(parentPid: Int64, status: String, diagnostic!: String = "") {
        this.parentPid = parentPid
        this.status = status.trimAscii()
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class GcmPluginOrphanHandleResult {
    public let orphanHandled: Bool
    public let frameEmitted: Bool
    public let processorStopped: Bool
    public let listenerStopped: Bool
    public let status: String

    public init(orphanHandled: Bool, frameEmitted: Bool, processorStopped: Bool, listenerStopped: Bool, status: String) {
        this.orphanHandled = orphanHandled
        this.frameEmitted = frameEmitted
        this.processorStopped = processorStopped
        this.listenerStopped = listenerStopped
        this.status = status.trimAscii()
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
    private var consecutiveParentProbeFailures: Int64 = 0

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
            let parentProbe = gcmProbeProcessExists(this.baseLease.parentPid)
            let observedParentProbe = gcmProbeCurrentParentPid()
            let parentSnapshot = GcmPluginOwnerSnapshot(
                parentProbe.exists,
                false,
                0,
                observedParentPid: observedParentProbe.parentPid,
                pidProbeStatus: parentProbe.status,
                parentPidProbeStatus: parentProbe.status,
                observedParentPidStatus: observedParentProbe.status
            )
            let ticked = gcmPluginWatchdogTick(
                GcmPluginWatchdogContext(this.leasePath, this.baseLease, parentSnapshot, parentProbeFailureCount: this.consecutiveParentProbeFailures, parentProbeFailureThreshold: 3, forceOrphan: this.forceOrphan),
                nowMs: DateTime.now().toUnixTimeStamp().toMilliseconds()
            )
            this.consecutiveParentProbeFailures = ticked.parentProbeFailureCount
            if (ticked.orphanDetected) {
                let _ = gcmPluginHandleOrphan(this.leasePath, this.writer, this.listener, this.processorLoop)
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

    let observedProbeUnavailable = context.parentSnapshot.observedParentPidStatus == "probe_unavailable"
    let parentProbeUnavailable = context.parentSnapshot.pidProbeStatus == "probe_unavailable" || context.parentSnapshot.parentPidProbeStatus == "probe_unavailable"
    if (context.parentSnapshot.pidExists) {
        let heartbeat = context.lease.withHeartbeat(nowMs)
        let written = writeGcmPluginLease(context.leasePath, heartbeat)
        if (!written.ok) {
            return GcmPluginWatchdogTickResult(false, written.status)
        }
        if (observedProbeUnavailable) {
            return GcmPluginWatchdogTickResult(false, "parent_probe_suspect", reason: "probe_unavailable", parentProbeFailureCount: 0)
        }
        return GcmPluginWatchdogTickResult(false, "heartbeat", parentProbeFailureCount: 0)
    }

    if (parentProbeUnavailable) {
        let heartbeat = context.lease.withHeartbeat(nowMs)
        let written = writeGcmPluginLease(context.leasePath, heartbeat)
        if (!written.ok) {
            return GcmPluginWatchdogTickResult(false, written.status, reason: "probe_unavailable", parentProbeFailureCount: 0)
        }
        return GcmPluginWatchdogTickResult(false, "parent_probe_suspect", reason: "probe_unavailable", parentProbeFailureCount: 0)
    }

    let currentFailureCount = context.parentProbeFailureCount + 1
    if (currentFailureCount < context.parentProbeFailureThreshold) {
        let heartbeat = context.lease.withHeartbeat(nowMs)
        let written = writeGcmPluginLease(context.leasePath, heartbeat)
        if (!written.ok) {
            return GcmPluginWatchdogTickResult(false, written.status, reason: "parent_probe_suspect", parentProbeFailureCount: currentFailureCount)
        }
        return GcmPluginWatchdogTickResult(false, "parent_probe_suspect", reason: "pid_missing", parentProbeFailureCount: currentFailureCount)
    }

    if (context.parentSnapshot.observedParentPid > 0 && context.parentSnapshot.observedParentPid != context.lease.parentPid) {
        let _ = markGcmPluginLeaseOrphan(context.leasePath, "parent_mismatch_unreachable", nowMs: nowMs)
        return GcmPluginWatchdogTickResult(true, "orphan_detected", reason: "parent_mismatch_unreachable", parentProbeFailureCount: currentFailureCount)
    }
    let _ = markGcmPluginLeaseOrphan(context.leasePath, "parent_lost", nowMs: nowMs)
    GcmPluginWatchdogTickResult(true, "orphan_detected", reason: "parent_lost", parentProbeFailureCount: currentFailureCount)
}

public func gcmPluginHandleOrphanForTest(leasePath: String, writer: GcmPluginStdioWriter, listener: WebhookHttpServerRuntime, processorLoop: WebhookProcessorLoopRuntime): GcmPluginOrphanHandleResult {
    gcmPluginHandleOrphan(leasePath, writer, listener, processorLoop)
}

func gcmPluginHandleOrphan(leasePath: String, writer: GcmPluginStdioWriter, listener: WebhookHttpServerRuntime, processorLoop: WebhookProcessorLoopRuntime): GcmPluginOrphanHandleResult {
    let loaded = readGcmPluginLease(leasePath)
    var frameEmitted = false
    if (loaded.ok) {
        writer.writeFrame(gcmPluginOrphanDetectedFrame(loaded.lease))
        frameEmitted = true
    }
    processorLoop.stop()
    listener.stop()
    let processorStatus = processorLoop.snapshot().processorStatus
    let listenerSnapshot = listener.snapshot()
    let listenerStatus = listenerSnapshot.listenerStatus
    let processorStopped = processorStatus == "stopped" || processorStatus == "disabled" || processorStatus == "not_started"
    let listenerStopped = (listenerStatus == "stopped" || listenerStatus == "disabled" || listenerStatus == "not_started") && listenerSnapshot.serveWorkerDone && listenerSnapshot.stopBounded
    GcmPluginOrphanHandleResult(true, frameEmitted, processorStopped, listenerStopped, if (loaded.ok) { "handled" } else { "lease_unavailable" })
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
    gcmProbeProcessExists(pid).exists
}

public func gcmProbeProcessExists(pid: Int64): GcmProcessProbeResult {
    if (pid <= 0) { return GcmProcessProbeResult(pid, false, "pid_missing") }
    try {
        let (exitCode, _, stderrBytes) = executeWithOutput("kill", ["-0", "${pid}"])
        if (exitCode == 0) {
            GcmProcessProbeResult(pid, true, "ok")
        } else {
            GcmProcessProbeResult(pid, false, "pid_missing", diagnostic: redactServicePayload(String.fromUtf8(stderrBytes)).rawHash)
        }
    } catch (e: Exception) {
        GcmProcessProbeResult(pid, false, "probe_unavailable", diagnostic: redactServicePayload(e.message).rawHash)
    }
}

public func gcmCurrentParentPid(): Int64 {
    gcmProbeCurrentParentPid().parentPid
}

public func gcmProbeCurrentParentPid(): GcmParentPidProbeResult {
    try {
        let (exitCode, stdoutBytes, stderrBytes) = executeWithOutput("ps", ["-o", "ppid=", "-p", "${getProcessId()}"])
        if (exitCode != 0) {
            return GcmParentPidProbeResult(0, "probe_unavailable", diagnostic: redactServicePayload(String.fromUtf8(stderrBytes)).rawHash)
        }
        GcmParentPidProbeResult(Int64.parse(String.fromUtf8(stdoutBytes).trimAscii()), "ok")
    } catch (e: Exception) {
        GcmParentPidProbeResult(0, "probe_unavailable", diagnostic: redactServicePayload(e.message).rawHash)
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
