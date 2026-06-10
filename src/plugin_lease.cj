package gitcodemonitor

import std.fs.{Directory, File, Path, exists, remove}
import stdx.encoding.json.{JsonInt, JsonObject, JsonString, JsonValue}

public class GcmPluginLease {
    public let pluginId: String
    public let sessionId: String
    public let pid: Int64
    public let parentPid: Int64
    public let bindHost: String
    public let port: Int64
    public let startedAtMs: Int64
    public let lastHeartbeatMs: Int64
    public let state: String
    public let orphanReason: String

    public init(
        pluginId: String,
        sessionId: String,
        pid: Int64,
        parentPid: Int64,
        bindHost: String,
        port: Int64,
        startedAtMs: Int64,
        lastHeartbeatMs: Int64,
        state: String,
        orphanReason: String
    ) {
        this.pluginId = pluginId.trimAscii()
        this.sessionId = sessionId.trimAscii()
        this.pid = pid
        this.parentPid = parentPid
        this.bindHost = bindHost.trimAscii()
        this.port = port
        this.startedAtMs = startedAtMs
        this.lastHeartbeatMs = lastHeartbeatMs
        this.state = state.trimAscii()
        this.orphanReason = orphanReason.trimAscii()
    }

    public func withHeartbeat(nowMs: Int64): GcmPluginLease {
        GcmPluginLease(this.pluginId, this.sessionId, this.pid, this.parentPid, this.bindHost, this.port, this.startedAtMs, nowMs, "running", "")
    }

    public func withState(state: String, nowMs: Int64, orphanReason!: String = this.orphanReason): GcmPluginLease {
        GcmPluginLease(this.pluginId, this.sessionId, this.pid, this.parentPid, this.bindHost, this.port, this.startedAtMs, nowMs, state, orphanReason)
    }
}

public class GcmPluginLeaseIoResult {
    public let ok: Bool
    public let status: String
    public let lease: GcmPluginLease
    public let diagnostic: String

    public init(ok: Bool, status: String, lease!: GcmPluginLease = emptyGcmPluginLease(), diagnostic!: String = "") {
        this.ok = ok
        this.status = status.trimAscii()
        this.lease = lease
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class GcmPluginLeaseClassification {
    public let status: String
    public let stale: Bool

    public init(status: String, stale!: Bool = false) {
        this.status = status.trimAscii()
        this.stale = stale
    }
}

public class GcmPluginOwnerSnapshot {
    public let pidExists: Bool
    public let portOwnerKnown: Bool
    public let portOwnerPid: Int64
    public let observedParentPid: Int64
    public let pidProbeStatus: String
    public let parentPidProbeStatus: String
    public let observedParentPidStatus: String

    public init(
        pidExists: Bool,
        portOwnerKnown: Bool,
        portOwnerPid: Int64,
        observedParentPid!: Int64 = 0,
        pidProbeStatus!: String = "",
        parentPidProbeStatus!: String = "",
        observedParentPidStatus!: String = "ok"
    ) {
        this.pidExists = pidExists
        this.portOwnerKnown = portOwnerKnown
        this.portOwnerPid = portOwnerPid
        this.observedParentPid = observedParentPid
        this.pidProbeStatus = if (pidProbeStatus.trimAscii().isEmpty()) {
            if (pidExists) { "ok" } else { "pid_missing" }
        } else {
            pidProbeStatus.trimAscii()
        }
        this.parentPidProbeStatus = if (parentPidProbeStatus.trimAscii().isEmpty()) {
            this.pidProbeStatus
        } else {
            parentPidProbeStatus.trimAscii()
        }
        this.observedParentPidStatus = observedParentPidStatus.trimAscii()
    }
}

public class GcmPluginOwnerClassification {
    public let status: String
    public let shouldKill: Bool

    public init(status: String, shouldKill!: Bool = false) {
        this.status = status.trimAscii()
        this.shouldKill = shouldKill
    }
}

public func emptyGcmPluginLease(): GcmPluginLease {
    GcmPluginLease("", "", 0, 0, "", 0, 0, 0, "", "")
}

public func gcmPluginLeaseToJson(lease: GcmPluginLease): JsonObject {
    let root = JsonObject()
    root.put("pluginId", JsonString(lease.pluginId))
    root.put("sessionId", JsonString(lease.sessionId))
    root.put("pid", JsonInt(lease.pid))
    root.put("parentPid", JsonInt(lease.parentPid))
    root.put("bindHost", JsonString(lease.bindHost))
    root.put("port", JsonInt(lease.port))
    root.put("startedAtMs", JsonInt(lease.startedAtMs))
    root.put("lastHeartbeatMs", JsonInt(lease.lastHeartbeatMs))
    root.put("state", JsonString(lease.state))
    root.put("orphanReason", JsonString(lease.orphanReason))
    root
}

public func gcmPluginLeaseFromJson(root: JsonObject): GcmPluginLease {
    GcmPluginLease(
        readJsonString(root, "pluginId"),
        readJsonString(root, "sessionId"),
        readJsonInt(root, "pid"),
        readJsonInt(root, "parentPid"),
        readJsonString(root, "bindHost"),
        readJsonInt(root, "port"),
        readJsonInt(root, "startedAtMs"),
        readJsonInt(root, "lastHeartbeatMs"),
        readJsonString(root, "state"),
        readJsonString(root, "orphanReason")
    )
}

public func writeGcmPluginLease(path: String, lease: GcmPluginLease): GcmPluginLeaseIoResult {
    if (path.trimAscii().isEmpty()) {
        return GcmPluginLeaseIoResult(false, "missing_lease_path")
    }
    let leasePath = Path(path)
    try {
        let parent = leasePath.parent
        if (!exists(parent)) { Directory.create(parent, recursive: true) }
        File.writeTo(leasePath, gcmPluginLeaseToJson(lease).toJsonString().toArray())
        GcmPluginLeaseIoResult(true, "ok", lease: lease)
    } catch (e: Exception) {
        GcmPluginLeaseIoResult(false, "lease_write_failed", lease: lease, diagnostic: redactServicePayload(e.message).rawHash)
    }
}

public func readGcmPluginLease(path: String): GcmPluginLeaseIoResult {
    if (path.trimAscii().isEmpty()) {
        return GcmPluginLeaseIoResult(false, "missing_lease_path")
    }
    let leasePath = Path(path)
    if (!exists(leasePath)) {
        return GcmPluginLeaseIoResult(false, "lease_missing")
    }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(leasePath))).asObject()
        GcmPluginLeaseIoResult(true, "ok", lease: gcmPluginLeaseFromJson(root))
    } catch (e: Exception) {
        GcmPluginLeaseIoResult(false, "lease_read_failed", diagnostic: redactServicePayload(e.message).rawHash)
    }
}

public func removeGcmPluginLease(path: String): GcmPluginLeaseIoResult {
    if (path.trimAscii().isEmpty()) {
        return GcmPluginLeaseIoResult(false, "missing_lease_path")
    }
    try {
        let leasePath = Path(path)
        if (exists(leasePath)) { remove(leasePath) }
        GcmPluginLeaseIoResult(true, "removed")
    } catch (e: Exception) {
        GcmPluginLeaseIoResult(false, "lease_remove_failed", diagnostic: redactServicePayload(e.message).rawHash)
    }
}

public func markGcmPluginLeaseStopped(path: String, nowMs!: Int64): GcmPluginLeaseIoResult {
    let loaded = readGcmPluginLease(path)
    if (!loaded.ok) { return loaded }
    writeGcmPluginLease(path, loaded.lease.withState("stopped", nowMs, orphanReason: ""))
}

public func markGcmPluginLeaseOrphan(path: String, reason: String, nowMs!: Int64): GcmPluginLeaseIoResult {
    let loaded = readGcmPluginLease(path)
    if (!loaded.ok) { return loaded }
    writeGcmPluginLease(path, loaded.lease.withState("orphan_detected", nowMs, orphanReason: reason))
}

public func classifyGcmPluginLease(lease: GcmPluginLease, nowMs: Int64, heartbeatTtlMs!: Int64 = 15000): GcmPluginLeaseClassification {
    if (lease.state == "orphan_detected") { return GcmPluginLeaseClassification("orphan_detected") }
    if (lease.state == "stopped") { return GcmPluginLeaseClassification("stopped") }
    let ttl = if (heartbeatTtlMs <= 0) { 15000 } else { heartbeatTtlMs }
    if (lease.lastHeartbeatMs > 0 && nowMs - lease.lastHeartbeatMs > ttl) {
        return GcmPluginLeaseClassification("stale", stale: true)
    }
    GcmPluginLeaseClassification(if (lease.state.isEmpty()) { "unknown" } else { lease.state })
}

public func classifyGcmPluginOwner(lease: GcmPluginLease, snapshot: GcmPluginOwnerSnapshot): GcmPluginOwnerClassification {
    if (snapshot.pidProbeStatus == "probe_unavailable" || snapshot.parentPidProbeStatus == "probe_unavailable") {
        return GcmPluginOwnerClassification("probe_unavailable")
    }
    if (!snapshot.pidExists) {
        return GcmPluginOwnerClassification("pid_missing")
    }
    if (snapshot.portOwnerKnown && snapshot.portOwnerPid != lease.pid) {
        return GcmPluginOwnerClassification("port_owner_mismatch")
    }
    GcmPluginOwnerClassification("owner_aligned")
}
