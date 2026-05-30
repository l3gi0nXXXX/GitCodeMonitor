package gitcodemonitor

import std.collection.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

public let GCM_SERVICE_PLUGIN_SCHEMA = "metis.servicePlugin.v1"
public let GCM_SERVICE_PLUGIN_ID = "gitcode-monitor"
public let GCM_SERVICE_PROTOCOL_VERSION = "1.0"

public class ServiceCapabilityRecord {
    public let capabilityId: String
    public let kind: String
    public let direction: String
    public let description: String
    public let inputSchema: String
    public let outputSchema: String
    public let requiredHostApis: Array<String>

    public init(
        capabilityId: String,
        kind: String,
        direction!: String = "",
        description!: String = "",
        inputSchema!: String = "",
        outputSchema!: String = "",
        requiredHostApis!: Array<String> = []
    ) {
        this.capabilityId = capabilityId
        this.kind = kind
        this.direction = direction
        this.description = description
        this.inputSchema = inputSchema
        this.outputSchema = outputSchema
        this.requiredHostApis = requiredHostApis
    }
}

public class CapabilitySetCheckResult {
    public let ok: Bool
    public let missingCapabilityIds: Array<String>
    public let degradedCapabilityIds: Array<String>
    public let diagnostics: Array<String>

    public init(ok: Bool, missingCapabilityIds!: Array<String> = [], degradedCapabilityIds!: Array<String> = [], diagnostics!: Array<String> = []) {
        this.ok = ok
        this.missingCapabilityIds = missingCapabilityIds
        this.degradedCapabilityIds = degradedCapabilityIds
        this.diagnostics = diagnostics
    }
}

public func requiredGitCodeMonitorCapabilityIds(): Array<String> {
    [
        "gitcode.monitor.status",
        "gitcode.monitor.scan_once",
        "gitcode.monitor.job_status",
        "gitcode.monitor.cancel_job",
        "gitcode.monitor.scan_progress",
        "gitcode.monitor.scan_completed",
        "gitcode.monitor.scan_failed",
        "gitcode.monitor.scan_cancelled",
        "gitcode.event.accepted",
        "gitcode.event.ignored",
        "gitcode.agent.draft_request",
        "gitcode.notification.generated_reply",
        "gitcode.writeback.apply_result",
        "gitcode.writeback.audit"
    ]
}

public func buildGitCodeMonitorCapabilityDeclarations(): ArrayList<ServiceCapabilityRecord> {
    let records = ArrayList<ServiceCapabilityRecord>()
    records.add(ServiceCapabilityRecord(
        "gitcode.monitor.status",
        "controlAction",
        direction: "metis-to-gcm",
        description: "Read GitCode monitor status",
        outputSchema: "schemas/gitcode.monitor.status.output.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.monitor.scan_once",
        "controlAction",
        direction: "metis-to-gcm",
        description: "Start one asynchronous GitCode scan job",
        inputSchema: "schemas/gitcode.monitor.scan_once.input.json",
        outputSchema: "schemas/gitcode.monitor.scan_once.output.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.monitor.job_status",
        "controlAction",
        direction: "metis-to-gcm",
        description: "Read GitCode scan job status",
        inputSchema: "schemas/gitcode.monitor.job_status.input.json",
        outputSchema: "schemas/gitcode.monitor.job_status.output.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.monitor.cancel_job",
        "controlAction",
        direction: "metis-to-gcm",
        description: "Request cancellation for a GitCode scan job",
        inputSchema: "schemas/gitcode.monitor.cancel_job.input.json",
        outputSchema: "schemas/gitcode.monitor.cancel_job.output.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.monitor.scan_progress",
        "event",
        direction: "gcm-to-metis",
        description: "GitCode scan job progress event",
        outputSchema: "schemas/gitcode.monitor.scan_progress.event.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.monitor.scan_completed",
        "event",
        direction: "gcm-to-metis",
        description: "GitCode scan job completed event",
        outputSchema: "schemas/gitcode.monitor.scan_completed.event.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.monitor.scan_failed",
        "event",
        direction: "gcm-to-metis",
        description: "GitCode scan job failed event",
        outputSchema: "schemas/gitcode.monitor.scan_failed.event.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.monitor.scan_cancelled",
        "event",
        direction: "gcm-to-metis",
        description: "GitCode scan job cancelled event",
        outputSchema: "schemas/gitcode.monitor.scan_cancelled.event.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.event.accepted",
        "event",
        direction: "gcm-to-metis",
        description: "Accepted GitCode issue/PR/comment event",
        outputSchema: "schemas/gitcode.event.accepted.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.event.ignored",
        "event",
        direction: "gcm-to-metis",
        description: "Ignored GitCode event audit",
        outputSchema: "schemas/gitcode.event.ignored.json"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.agent.draft_request",
        "agentRequest",
        direction: "gcm-to-metis",
        description: "Request summary/draft/safety/citations from Metis Agent Runtime",
        requiredHostApis: ["host.agent.invoke"]
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.notification.generated_reply",
        "notificationTopic",
        direction: "metis-internal-delivery",
        description: "Metis-delivered generated reply notification",
        requiredHostApis: ["host.notification.publish"]
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.writeback.apply_result",
        "controlAction",
        direction: "metis-to-gcm",
        description: "Apply Metis draft result to GCM autoReply/writeback gate"
    ))
    records.add(ServiceCapabilityRecord(
        "gitcode.writeback.audit",
        "event",
        direction: "gcm-to-metis",
        description: "GitCode writeback audit event",
        outputSchema: "schemas/gitcode.writeback.audit.json"
    ))
    records
}

public func validateGitCodeMonitorCapabilitySet(records: ArrayList<ServiceCapabilityRecord>): CapabilitySetCheckResult {
    let seen = HashMap<String, ServiceCapabilityRecord>()
    for (record in records) {
        if (!record.capabilityId.isEmpty()) {
            seen[record.capabilityId] = record
        }
    }

    let missing = ArrayList<String>()
    for (id in requiredGitCodeMonitorCapabilityIds()) {
        if (!seen.contains(id)) {
            missing.add(id)
        }
    }

    let degraded = ArrayList<String>()
    match (seen.get("gitcode.agent.draft_request")) {
        case Some(record) =>
            if (!arrayContains(record.requiredHostApis, "host.agent.invoke")) {
                degraded.add("gitcode.agent.draft_request")
            }
        case None => ()
    }
    match (seen.get("gitcode.notification.generated_reply")) {
        case Some(record) =>
            if (!arrayContains(record.requiredHostApis, "host.notification.publish")) {
                degraded.add("gitcode.notification.generated_reply")
            }
        case None => ()
    }

    let diagnostics = ArrayList<String>()
    for (id in missing) { diagnostics.add("missing capability: ${id}") }
    for (id in degraded) { diagnostics.add("degraded capability: ${id}") }
    CapabilitySetCheckResult(missing.size == 0, missingCapabilityIds: missing.toArray(), degradedCapabilityIds: degraded.toArray(), diagnostics: diagnostics.toArray())
}

public func buildGitCodeMonitorServicePluginManifest(): String {
    let root = JsonObject()
    root.put("schema", JsonString(GCM_SERVICE_PLUGIN_SCHEMA))
    root.put("pluginId", JsonString(GCM_SERVICE_PLUGIN_ID))
    root.put("displayName", JsonString("GitCode Monitor"))
    root.put("kind", JsonString("service"))
    root.put("protocolVersion", JsonString(GCM_SERVICE_PROTOCOL_VERSION))

    let entry = JsonObject()
    entry.put("command", JsonString("cjpm"))
    entry.put("args", stringArrayJson(["run", "--skip-build", "--name", "gitcodemonitor", "--run-args", "plugin-stdio"]))
    root.put("entry", entry)

    let capabilities = JsonArray([])
    for (record in buildGitCodeMonitorCapabilityDeclarations()) {
        capabilities.add(serviceCapabilityRecordToJson(record))
    }
    root.put("capabilityDeclarations", capabilities)

    let configSchema = JsonObject()
    configSchema.put("type", JsonString("object"))
    let properties = JsonObject()
    let configPath = JsonObject()
    configPath.put("type", JsonString("string"))
    configPath.put("title", JsonString("GCM config path"))
    properties.put("configPath", configPath)
    configSchema.put("properties", properties)
    configSchema.put("required", stringArrayJson(["configPath"]))
    root.put("configSchema", configSchema)
    root.toJsonString()
}

public func serviceCapabilityRecordToJson(record: ServiceCapabilityRecord): JsonObject {
    let obj = JsonObject()
    obj.put("capabilityId", JsonString(record.capabilityId))
    obj.put("kind", JsonString(record.kind))
    if (!record.direction.isEmpty()) { obj.put("direction", JsonString(record.direction)) }
    if (!record.description.isEmpty()) { obj.put("description", JsonString(record.description)) }
    if (!record.inputSchema.isEmpty()) { obj.put("inputSchema", JsonString(record.inputSchema)) }
    if (!record.outputSchema.isEmpty()) { obj.put("outputSchema", JsonString(record.outputSchema)) }
    if (record.requiredHostApis.size > 0) { obj.put("requiredHostApis", stringArrayJson(record.requiredHostApis)) }
    obj
}

public class ServiceFrame {
    public let frameType: String
    public let frameId: String
    public let serviceId: String
    public let method: String
    public let capabilityId: String
    public let correlationId: String
    public let payload: String

    public init(frameType: String, frameId: String, serviceId: String, method!: String = "", capabilityId!: String = "", correlationId!: String = "", payload!: String = "{}") {
        this.frameType = frameType
        this.frameId = frameId
        this.serviceId = serviceId
        this.method = method
        this.capabilityId = capabilityId
        this.correlationId = correlationId
        this.payload = payload
    }
}

public class ServiceFrameDecodeResult {
    public let ok: Bool
    public let frame: ServiceFrame
    public let errorKind: String
    public let diagnostic: String

    public init(ok: Bool, frame!: ServiceFrame = ServiceFrame("", "", ""), errorKind!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.frame = frame
        this.errorKind = errorKind
        this.diagnostic = diagnostic
    }
}

public func encodeServiceFrame(frame: ServiceFrame): String {
    let root = JsonObject()
    root.put("type", JsonString(frame.frameType))
    root.put("frameId", JsonString(frame.frameId))
    root.put("serviceId", JsonString(frame.serviceId))
    if (!frame.method.isEmpty()) { root.put("method", JsonString(frame.method)) }
    if (!frame.capabilityId.isEmpty()) { root.put("capabilityId", JsonString(frame.capabilityId)) }
    if (!frame.correlationId.isEmpty()) { root.put("correlationId", JsonString(frame.correlationId)) }
    root.put("payload", parsePayloadJson(frame.payload))
    compactServiceFrameJson(root.toJsonString()) + "\n"
}

public func decodeServiceFrame(line: String, maxBytes!: Int64 = 65536): ServiceFrameDecodeResult {
    let normalized = normalizeServiceFrameLine(line)
    if (normalized.contains("\n") || normalized.contains("\r")) {
        return ServiceFrameDecodeResult(false, errorKind: "multiline_frame", diagnostic: "service frames must be line-delimited")
    }
    if (normalized.size > maxBytes) {
        return ServiceFrameDecodeResult(false, errorKind: "frame_too_large", diagnostic: "frame exceeds ${maxBytes} bytes")
    }
    let root = try {
        JsonValue.fromStr(normalized).asObject()
    } catch (_: Exception) {
        return ServiceFrameDecodeResult(false, errorKind: "invalid_json", diagnostic: "frame is not valid JSON")
    }
    let frameType = firstJsonString(root, ["type", "frameType"])
    let frameId = firstJsonString(root, ["frameId"])
    let serviceId = firstJsonString(root, ["serviceId"])
    if (frameType.isEmpty()) {
        return ServiceFrameDecodeResult(false, errorKind: "missing_field", diagnostic: "missing field: type")
    }
    if (frameId.isEmpty()) {
        return ServiceFrameDecodeResult(false, errorKind: "missing_field", diagnostic: "missing field: frameId")
    }
    if (serviceId.isEmpty()) {
        return ServiceFrameDecodeResult(false, errorKind: "missing_field", diagnostic: "missing field: serviceId")
    }
    if (!isKnownServiceFrameType(frameType)) {
        return ServiceFrameDecodeResult(false, errorKind: "unknown_frame_type", diagnostic: "unknown frame type: ${frameType}")
    }
    let method = firstJsonString(root, ["method"])
    if (!method.isEmpty() && !isKnownServiceFrameMethod(method)) {
        return ServiceFrameDecodeResult(false, errorKind: "unknown_method", diagnostic: "unknown method: ${method}")
    }
    let capabilityId = firstJsonString(root, ["capabilityId"])
    let correlationId = firstJsonString(root, ["correlationId"])
    let payload = match (root.get("payload")) {
        case Some(value) => value.toJsonString()
        case None => "{}"
    }
    ServiceFrameDecodeResult(true, frame: ServiceFrame(frameType, frameId, serviceId, method: method, capabilityId: capabilityId, correlationId: correlationId, payload: payload))
}

public class PendingFrameStore {
    private let pending = HashSet<String>()
    public init() {}
    public func add(correlationId: String): Unit {
        if (!correlationId.isEmpty()) { pending.add(correlationId) }
    }
    public func contains(correlationId: String): Bool { pending.contains(correlationId) }
    public func remove(correlationId: String): Unit {
        if (pending.contains(correlationId)) { pending.remove(correlationId) }
    }
}

public class CorrelationResult {
    public let matched: Bool
    public let correlationId: String
    public let errorKind: String
    public init(matched: Bool, correlationId!: String = "", errorKind!: String = "") {
        this.matched = matched
        this.correlationId = correlationId
        this.errorKind = errorKind
    }
}

public func correlateServiceFrame(frame: ServiceFrame, pending: PendingFrameStore): CorrelationResult {
    if (frame.correlationId.isEmpty()) {
        return CorrelationResult(false, errorKind: "correlation_missing")
    }
    if (!pending.contains(frame.correlationId)) {
        return CorrelationResult(false, correlationId: frame.correlationId, errorKind: "correlation_unknown")
    }
    pending.remove(frame.correlationId)
    CorrelationResult(true, correlationId: frame.correlationId)
}

public class RedactionPolicy {
    public let maxPayloadBytes: Int64
    public init(maxPayloadBytes!: Int64 = 4096) {
        this.maxPayloadBytes = maxPayloadBytes
    }
}

public class RedactedPayload {
    public let text: String
    public let rawHash: String
    public let truncated: Bool
    public init(text: String, rawHash: String, truncated!: Bool = false) {
        this.text = text
        this.rawHash = rawHash
        this.truncated = truncated
    }
}

public func redactServicePayload(payload: String, policy!: RedactionPolicy = RedactionPolicy()): RedactedPayload {
    let hash = hashRawPayload(payload)
    var text = redactSecrets(redactUrl(payload))
    if (containsLocalPath(text)) {
        text = "[REDACTED_LOCAL_PATH]"
    }
    var truncated = false
    if (pluginServiceRuneSize(text) > policy.maxPayloadBytes) {
        text = pluginServiceTruncateRunes(text, policy.maxPayloadBytes) + "...[TRUNCATED]"
        truncated = true
    }
    RedactedPayload(text, hash, truncated: truncated)
}

public class ServiceFrameLimits {
    public let maxFrameBytes: Int64
    public let maxPayloadBytes: Int64
    public let maxFieldBytes: Int64
    public let maxArrayItems: Int64

    public init(maxFrameBytes!: Int64 = 65536, maxPayloadBytes!: Int64 = 16384, maxFieldBytes!: Int64 = 4096, maxArrayItems!: Int64 = 128) {
        this.maxFrameBytes = maxFrameBytes
        this.maxPayloadBytes = maxPayloadBytes
        this.maxFieldBytes = maxFieldBytes
        this.maxArrayItems = maxArrayItems
    }
}

public class ServiceFrameLimitResult {
    public let ok: Bool
    public let rejected: Bool
    public let reason: String
    public let payloadHash: String

    public init(ok: Bool, rejected!: Bool = false, reason!: String = "", payloadHash!: String = "") {
        this.ok = ok
        this.rejected = rejected
        this.reason = reason
        this.payloadHash = payloadHash
    }
}

public func enforceServiceFrameLimits(frame: ServiceFrame, limits!: ServiceFrameLimits = ServiceFrameLimits()): ServiceFrameLimitResult {
    let encoded = encodeServiceFrame(frame)
    if (encoded.size > limits.maxFrameBytes) {
        return ServiceFrameLimitResult(false, rejected: true, reason: "frame_too_large", payloadHash: hashRawPayload(frame.payload))
    }
    if (frame.payload.size > limits.maxPayloadBytes) {
        return ServiceFrameLimitResult(false, rejected: true, reason: "payload_too_large", payloadHash: hashRawPayload(frame.payload))
    }
    for (field in [frame.frameType, frame.frameId, frame.serviceId, frame.method, frame.capabilityId, frame.correlationId]) {
        if (field.size > limits.maxFieldBytes) {
            return ServiceFrameLimitResult(false, rejected: true, reason: "field_too_large", payloadHash: hashRawPayload(frame.payload))
        }
    }
    ServiceFrameLimitResult(true, payloadHash: hashRawPayload(frame.payload))
}

public func hashRawPayload(payload: String): String {
    "payload-${payload.size}-${payload.toRuneArray().size}"
}

func pluginServiceRuneSize(text: String): Int64 {
    text.toRuneArray().size
}

func pluginServiceTruncateRunes(text: String, maxRunes: Int64): String {
    if (maxRunes <= 0) { return "" }
    let runes = text.toRuneArray()
    if (runes.size <= maxRunes) { return text }
    String(runes[0..maxRunes])
}

func normalizeServiceFrameLine(line: String): String {
    if (line.endsWith("\r\n") && line.size >= 2) {
        return line[0..line.size - 2]
    }
    if ((line.endsWith("\n") || line.endsWith("\r")) && line.size >= 1) {
        return line[0..line.size - 1]
    }
    line
}

func compactServiceFrameJson(raw: String): String {
    raw.replace("\n", "").replace("\r", "")
}

func parsePayloadJson(payload: String): JsonValue {
    try { JsonValue.fromStr(payload) } catch (_: Exception) { JsonString(payload) }
}

func isKnownServiceFrameType(frameType: String): Bool {
    frameType == "request" || frameType == "response" || frameType == "event" || frameType == "audit" || frameType == "heartbeat"
}

func isKnownServiceFrameMethod(method: String): Bool {
    method == "initialize" ||
        method == "registerCapabilities" ||
        method == "invokeCapability" ||
        method == "emitCapabilityEvent" ||
        method == "requestHostApi" ||
        method == "status" ||
        method == "stop" ||
        method == "heartbeat" ||
        method == "audit"
}
