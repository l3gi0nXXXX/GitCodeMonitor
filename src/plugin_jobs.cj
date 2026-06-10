package gitcodemonitor

import std.collection.*
import std.convert.Parsable
import std.sync.*
import std.time.*
import stdx.encoding.json.{JsonObject, JsonValue}

public let GCM_SCAN_STATUS_ACCEPTED = "accepted"
public let GCM_SCAN_STATUS_RUNNING = "running"
public let GCM_SCAN_STATUS_PROGRESS = "progress"
public let GCM_SCAN_STATUS_COMPLETED = "completed"
public let GCM_SCAN_STATUS_FAILED = "failed"
public let GCM_SCAN_STATUS_CANCELLED = "cancelled"
public let GCM_SCAN_STATUS_EXPIRED = "expired"

public class GcmScanJobLimits {
    public let maxRepos: Int64
    public let maxItems: Int64
    public let maxDurationMillis: Int64
    public let perRequestTimeoutMillis: Int64
    public let progressIntervalMillis: Int64

    public init(
        maxRepos!: Int64 = 0,
        maxItems!: Int64 = 0,
        maxDurationMillis!: Int64 = 0,
        perRequestTimeoutMillis!: Int64 = 30000,
        progressIntervalMillis!: Int64 = 10000
    ) {
        this.maxRepos = maxRepos
        this.maxItems = maxItems
        this.maxDurationMillis = maxDurationMillis
        this.perRequestTimeoutMillis = perRequestTimeoutMillis
        this.progressIntervalMillis = progressIntervalMillis
    }
}

public class GcmAsyncScanPayload {
    public let mode: String
    public let jobId: String
    public let idempotencyKey: String
    public let deliveryTargetHash: String
    public let limits: GcmScanJobLimits
    public let offlineFixture: Bool
    public let dryRun: Bool
    public let backfill: Bool

    public init(
        mode!: String = "",
        jobId!: String = "",
        idempotencyKey!: String = "",
        deliveryTargetHash!: String = "",
        limits!: GcmScanJobLimits = GcmScanJobLimits(),
        offlineFixture!: Bool = false,
        dryRun!: Bool = true,
        backfill!: Bool = false
    ) {
        this.mode = mode
        this.jobId = jobId
        this.idempotencyKey = idempotencyKey
        this.deliveryTargetHash = deliveryTargetHash
        this.limits = limits
        this.offlineFixture = offlineFixture
        this.dryRun = dryRun
        this.backfill = backfill
    }
}

public class GcmAsyncScanPayloadParseResult {
    public let ok: Bool
    public let status: String
    public let payload: GcmAsyncScanPayload
    public let diagnostic: String

    public init(ok: Bool, status: String, payload!: GcmAsyncScanPayload = GcmAsyncScanPayload(), diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.payload = payload
        this.diagnostic = diagnostic
    }
}

public class GcmJobAcceptedPayloadResult {
    public let ok: Bool
    public let status: String
    public let jobId: String
    public init(ok: Bool, status: String, jobId!: String = "") {
        this.ok = ok
        this.status = status
        this.jobId = jobId
    }
}

public class GcmJobEventPayloadResult {
    public let ok: Bool
    public let status: String
    public let jobId: String
    public let summary: String
    public init(ok: Bool, status: String, jobId!: String = "", summary!: String = "") {
        this.ok = ok
        this.status = status
        this.jobId = jobId
        this.summary = summary
    }
}

public class GcmScanJob {
    public let jobId: String
    public let idempotencyKey: String
    public var status: String
    public let startedAtMs: Int64
    public var updatedAtMs: Int64
    public let deliveryTargetHash: String
    public let limits: GcmScanJobLimits
    public let offlineFixture: Bool
    public let backfill: Bool
    public var accepted: Int64
    public var ignored: Int64
    public var emitted: Int64
    public var mcpCalls: Int64
    public var writes: Int64
    public var errorKind: String
    public var stage: String
    public var cancelRequested: Bool
    public var stateSaved: Bool
    public var summary: String
    public var report: ScanResult
    public var diagnostic: String

    public init(payload!: GcmAsyncScanPayload = GcmAsyncScanPayload()) {
        this.jobId = payload.jobId
        this.idempotencyKey = payload.idempotencyKey
        this.status = GCM_SCAN_STATUS_ACCEPTED
        this.startedAtMs = gcmNowMillis()
        this.updatedAtMs = this.startedAtMs
        this.deliveryTargetHash = payload.deliveryTargetHash
        this.limits = payload.limits
        this.offlineFixture = payload.offlineFixture
        this.backfill = payload.backfill
        this.accepted = 0
        this.ignored = 0
        this.emitted = 0
        this.mcpCalls = 0
        this.writes = 0
        this.errorKind = ""
        this.stage = "accepted"
        this.cancelRequested = false
        this.stateSaved = false
        this.summary = "GitCode scan job accepted"
        this.report = ScanResult(0, 0, 0, 0, 0)
        this.diagnostic = ""
    }
}

public class GcmScanJobMutationResult {
    public let ok: Bool
    public let status: String
    public let job: GcmScanJob
    public let alreadyRunning: Bool

    public init(ok: Bool, status: String, job!: GcmScanJob = GcmScanJob(), alreadyRunning!: Bool = false) {
        this.ok = ok
        this.status = status
        this.job = job
        this.alreadyRunning = alreadyRunning
    }
}

public class GcmScanJobStore {
    private let jobs = HashMap<String, GcmScanJob>()
    private let idempotency = HashMap<String, String>()
    private let lock = Mutex()
    public let maxConcurrent: Int64

    public init(maxConcurrent!: Int64 = 1) {
        this.maxConcurrent = if (maxConcurrent <= 0) { 1 } else { maxConcurrent }
    }

    public func createOrGet(payload: GcmAsyncScanPayload): GcmScanJobMutationResult {
        synchronized(lock) {
            if (!payload.idempotencyKey.isEmpty()) {
                match (idempotency.get(payload.idempotencyKey)) {
                    case Some(existingId) =>
                        match (jobs.get(existingId)) {
                            case Some(existingJob) => return GcmScanJobMutationResult(true, existingJob.status, job: existingJob, alreadyRunning: true)
                            case None => ()
                        }
                    case None => ()
                }
            }
            match (jobs.get(payload.jobId)) {
                case Some(existingJob) => return GcmScanJobMutationResult(true, existingJob.status, job: existingJob, alreadyRunning: true)
                case None => ()
            }
            if (runningCountLocked() >= maxConcurrent) {
                return GcmScanJobMutationResult(false, "job_rejected")
            }
            let job = GcmScanJob(payload: payload)
            jobs[payload.jobId] = job
            if (!payload.idempotencyKey.isEmpty()) {
                idempotency[payload.idempotencyKey] = payload.jobId
            }
            GcmScanJobMutationResult(true, GCM_SCAN_STATUS_ACCEPTED, job: job)
        }
    }

    public func find(jobId: String): ?GcmScanJob {
        synchronized(lock) {
            jobs.get(jobId)
        }
    }

    public func markRunning(jobId: String): GcmScanJobMutationResult {
        synchronized(lock) {
            match (jobs.get(jobId)) {
                case Some(job) =>
                    job.status = GCM_SCAN_STATUS_RUNNING
                    job.stage = "running"
                    job.updatedAtMs = gcmNowMillis()
                    return GcmScanJobMutationResult(true, job.status, job: job)
                case None => return GcmScanJobMutationResult(false, "job_not_found")
            }
        }
    }

    public func markProgress(jobId: String, stage: String): GcmScanJobMutationResult {
        synchronized(lock) {
            match (jobs.get(jobId)) {
                case Some(job) =>
                    job.status = GCM_SCAN_STATUS_PROGRESS
                    job.stage = stage
                    job.updatedAtMs = gcmNowMillis()
                    return GcmScanJobMutationResult(true, job.status, job: job)
                case None => return GcmScanJobMutationResult(false, "job_not_found")
            }
        }
    }

    public func markCompleted(jobId: String, result: ScanResult, stateSaved: Bool): GcmScanJobMutationResult {
        synchronized(lock) {
            match (jobs.get(jobId)) {
                case Some(job) =>
                    job.status = GCM_SCAN_STATUS_COMPLETED
                    job.stage = "done"
                    job.accepted = result.accepted
                    job.ignored = result.ignored
                    job.emitted = result.accepted + result.ignored
                    job.mcpCalls = result.mcpCalls
                    job.writes = result.writes
                    job.report = result
                    job.stateSaved = stateSaved
                    job.summary = gcmScanJobSummary(job)
                    job.updatedAtMs = gcmNowMillis()
                    return GcmScanJobMutationResult(true, job.status, job: job)
                case None => return GcmScanJobMutationResult(false, "job_not_found")
            }
        }
    }

    public func markFailed(jobId: String, stage: String, errorKind: String, diagnostic!: String = ""): GcmScanJobMutationResult {
        synchronized(lock) {
            match (jobs.get(jobId)) {
                case Some(job) =>
                    job.status = GCM_SCAN_STATUS_FAILED
                    job.stage = stage
                    job.errorKind = errorKind
                    job.diagnostic = gcmDiagnosticForPayload(diagnostic)
                    job.summary = "GitCode scan failed at ${stage}: ${errorKind}"
                    job.updatedAtMs = gcmNowMillis()
                    return GcmScanJobMutationResult(true, job.status, job: job)
                case None => return GcmScanJobMutationResult(false, "job_not_found")
            }
        }
    }

    public func markCancelled(jobId: String, stage!: String = "cancel_requested"): GcmScanJobMutationResult {
        synchronized(lock) {
            match (jobs.get(jobId)) {
                case Some(job) =>
                    job.status = GCM_SCAN_STATUS_CANCELLED
                    job.stage = stage
                    job.report.stopReason = "cancelled"
                    job.summary = "GitCode scan cancelled"
                    job.updatedAtMs = gcmNowMillis()
                    return GcmScanJobMutationResult(true, job.status, job: job)
                case None => return GcmScanJobMutationResult(false, "job_not_found")
            }
        }
    }

    public func requestCancel(jobId: String): GcmScanJobMutationResult {
        synchronized(lock) {
            match (jobs.get(jobId)) {
                case Some(job) =>
                    if (job.status == GCM_SCAN_STATUS_COMPLETED || job.status == GCM_SCAN_STATUS_FAILED || job.status == GCM_SCAN_STATUS_CANCELLED) {
                        return GcmScanJobMutationResult(false, job.status, job: job)
                    }
                    job.cancelRequested = true
                    job.stage = "cancel_requested"
                    job.updatedAtMs = gcmNowMillis()
                    return GcmScanJobMutationResult(true, "cancel_requested", job: job)
                case None => return GcmScanJobMutationResult(false, "job_not_found")
            }
        }
    }

    public func isCancelRequested(jobId: String): Bool {
        synchronized(lock) {
            match (jobs.get(jobId)) {
                case Some(job) => job.cancelRequested
                case None => false
            }
        }
    }

    private func runningCountLocked(): Int64 {
        var count: Int64 = 0
        for ((_, job) in jobs) {
            if (job.status == GCM_SCAN_STATUS_ACCEPTED || job.status == GCM_SCAN_STATUS_RUNNING || job.status == GCM_SCAN_STATUS_PROGRESS) {
                count++
            }
        }
        count
    }
}

public func parseGcmAsyncScanPayload(payload: String): GcmAsyncScanPayloadParseResult {
    let parsed = parsePluginPayloadObject(payload)
    if (!parsed.ok) {
        return GcmAsyncScanPayloadParseResult(false, "job_payload_invalid", diagnostic: parsed.diagnostic)
    }
    let mode = pluginPayloadStringField(parsed.payloadObject, "mode")
    if (!mode.ok || mode.value != "async") {
        return GcmAsyncScanPayloadParseResult(false, "job_payload_invalid", diagnostic: "mode must be async")
    }
    let jobId = pluginPayloadStringField(parsed.payloadObject, "jobId", maxBytes: 128)
    if (!jobId.ok || !isGcmJobIdSafe(jobId.value)) {
        return GcmAsyncScanPayloadParseResult(false, "job_payload_invalid", diagnostic: "invalid jobId")
    }
    let idempotencyKey = pluginPayloadStringField(parsed.payloadObject, "idempotencyKey", defaultValue: "", maxBytes: 512)
    if (!idempotencyKey.ok) {
        return GcmAsyncScanPayloadParseResult(false, "job_payload_invalid", diagnostic: idempotencyKey.diagnostic)
    }
    let deliveryTarget = parseGcmDeliveryTargetHash(parsed.payloadObject)
    if (!deliveryTarget.ok) {
        return GcmAsyncScanPayloadParseResult(false, "job_payload_invalid", diagnostic: deliveryTarget.diagnostic)
    }
    let limits = parseGcmScanJobLimits(parsed.payloadObject)
    if (!limits.ok) {
        return GcmAsyncScanPayloadParseResult(false, "job_payload_invalid", diagnostic: limits.diagnostic)
    }
    let options = parseGcmAsyncScanOptions(parsed.payloadObject)
    if (!options.ok) {
        return GcmAsyncScanPayloadParseResult(false, "job_payload_invalid", diagnostic: options.diagnostic)
    }
    GcmAsyncScanPayloadParseResult(
        true,
        "ok",
        payload: GcmAsyncScanPayload(
            mode: mode.value,
            jobId: jobId.value,
            idempotencyKey: idempotencyKey.value,
            deliveryTargetHash: deliveryTarget.value,
            limits: limits.value,
            offlineFixture: options.offlineFixture,
            dryRun: options.dryRun,
            backfill: options.backfill
        )
    )
}

public func parseGcmJobAcceptedPayload(payload: String, expectedJobId: String): GcmJobAcceptedPayloadResult {
    let parsed = parsePluginPayloadObject(payload)
    if (!parsed.ok) {
        return GcmJobAcceptedPayloadResult(false, "payload_invalid")
    }
    let ok = pluginPayloadBoolField(parsed.payloadObject, "ok", defaultValue: false)
    let status = pluginPayloadStringField(parsed.payloadObject, "status")
    let mode = pluginPayloadStringField(parsed.payloadObject, "mode")
    let jobId = pluginPayloadStringField(parsed.payloadObject, "jobId", maxBytes: 128)
    if (!ok.ok || !ok.value || !status.ok || status.value != "accepted" || !mode.ok || mode.value != "async" || !jobId.ok || jobId.value != expectedJobId) {
        return GcmJobAcceptedPayloadResult(false, "payload_invalid")
    }
    GcmJobAcceptedPayloadResult(true, "accepted", jobId: jobId.value)
}

public func parseGcmJobEventPayload(capabilityId: String, payload: String): GcmJobEventPayloadResult {
    let parsed = parsePluginPayloadObject(payload)
    if (!parsed.ok) {
        return GcmJobEventPayloadResult(false, "payload_invalid")
    }
    let status = pluginPayloadStringField(parsed.payloadObject, "status")
    let jobId = pluginPayloadStringField(parsed.payloadObject, "jobId", maxBytes: 128)
    let summary = pluginPayloadStringField(parsed.payloadObject, "summary", defaultValue: "", maxBytes: 4096)
    if (!status.ok || !jobId.ok || !isGcmJobIdSafe(jobId.value) || !summary.ok || summary.value.isEmpty()) {
        return GcmJobEventPayloadResult(false, "payload_invalid")
    }
    if (!gcmEventCapabilityMatchesStatus(capabilityId, status.value)) {
        return GcmJobEventPayloadResult(false, "payload_invalid")
    }
    GcmJobEventPayloadResult(true, status.value, jobId: jobId.value, summary: summary.value)
}

public func gcmJobAcceptedPayload(job: GcmScanJob, alreadyRunning: Bool): String {
    "{\"ok\":true,\"status\":\"accepted\",\"mode\":\"async\",\"jobId\":\"${jsonEscape(job.jobId)}\",\"alreadyRunning\":${alreadyRunning},\"summary\":\"${jsonEscape(job.summary)}\"}"
}

public func gcmJobSnapshotPayload(job: GcmScanJob): String {
    var payload = "{\"ok\":true,\"status\":\"${jsonEscape(job.status)}\",\"mode\":\"async\",\"jobId\":\"${jsonEscape(job.jobId)}\",\"stage\":\"${jsonEscape(job.stage)}\",\"accepted\":${job.accepted},\"ignored\":${job.ignored},\"emitted\":${job.emitted},\"mcpCalls\":${job.mcpCalls},\"writes\":${job.writes},\"stateSaved\":${job.stateSaved},\"summary\":\"${jsonEscape(job.summary)}\""
    if (job.status == GCM_SCAN_STATUS_COMPLETED) {
        payload += ",\"report\":${gcmScanReportPayload(job)}"
    }
    if (!job.diagnostic.isEmpty()) {
        payload += ",\"diagnostic\":${gcmDiagnosticPayloadJson(job.diagnostic)}"
    }
    payload + "}"
}

public func gcmJobErrorPayload(status: String, jobId!: String = "", diagnostic!: String = ""): String {
    "{\"ok\":false,\"status\":\"${jsonEscape(status)}\",\"jobId\":\"${jsonEscape(jobId)}\",\"diagnostic\":\"${jsonEscape(redactServicePayload(diagnostic).text)}\"}"
}

public func startGcmScanJobWorker(jobId: String, config: MonitorConfig, runtime: RuntimeContainer, state: MonitorState, store: GcmScanJobStore, writer: GcmPluginStdioWriter): Unit {
    let _ = spawn {
        runGcmScanJobWorker(jobId, config, runtime, state, store, writer)
    }
}

public func waitForGcmJobTerminal(store: GcmScanJobStore, jobId: String, timeoutMs!: Int64 = 3000): Bool {
    let deadline = gcmNowMillis() + timeoutMs
    while (gcmNowMillis() <= deadline) {
        match (store.find(jobId)) {
            case Some(job) =>
                if (isGcmTerminalJobStatus(job.status)) {
                    sleep(Duration.millisecond * 200)
                    return true
                }
            case None => return false
        }
        sleep(Duration.millisecond * 20)
    }
    false
}

func runGcmScanJobWorker(jobId: String, config: MonitorConfig, runtime: RuntimeContainer, state: MonitorState, store: GcmScanJobStore, writer: GcmPluginStdioWriter): Unit {
    let running = store.markRunning(jobId)
    if (!running.ok) { return }
    if (store.isCancelRequested(jobId)) {
        emitGcmScanJobEvent(store.markCancelled(jobId).job, writer)
        return
    }
    emitGcmScanJobEvent(store.markProgress(jobId, "scan_start").job, writer)
    if (store.isCancelRequested(jobId)) {
        emitGcmScanJobEvent(store.markCancelled(jobId).job, writer)
        return
    }

    let auditStart = state.audit.size
    let result = try {
        if (running.job.offlineFixture) {
            scanOnceOfflineFixture(config, state)
        } else {
            scanOnceRuntimeBoundedForJob(config, runtime, state, running.job, eventWriter: Some<GcmPluginStdioWriter>(writer))
        }
    } catch (e: Exception) {
        let diagnostic = gcmScanRuntimeDiagnostic("scan_runtime", e.message)
        emitGcmScanJobEvent(store.markFailed(jobId, "scan_runtime", gcmClassifyScanRuntimeError(e.message), diagnostic: diagnostic).job, writer)
        return
    }
    if (store.isCancelRequested(jobId)) {
        emitGcmScanJobEvent(store.markCancelled(jobId).job, writer)
        return
    }
    let degraded = gcmFirstScanDegradedReason(state, auditStart)
    if (!degraded.isEmpty()) {
        emitGcmScanJobEvent(store.markFailed(jobId, "scan_runtime", degraded, diagnostic: gcmScanRuntimeDiagnostic("scan_runtime", degraded)).job, writer)
        return
    }
    let saved = runtime.store.save(state)
    emitGcmScanJobEvent(store.markCompleted(jobId, result, saved).job, writer)
}

func scanOnceRuntimeBoundedForJob(
    config: MonitorConfig,
    runtime: RuntimeContainer,
    state: MonitorState,
    job: GcmScanJob,
    eventWriter!: Option<GcmPluginStdioWriter> = None<GcmPluginStdioWriter>
): ScanResult {
    let result = emptyScanResult(config)
    for (org in config.orgs) {
        var page: Int64 = 1
        while (true) {
            let repoResult = runtime.gitCode.listReposPage(org, page)
            if (repoResult.errorKind != "ok") {
                state.setBackoff("org:${org}", repoResult.retryAfterMs)
                state.addAudit(AuditRecord("org:${org}", status: "scan_degraded", reason: repoResult.errorKind))
                result.failedEvents++
                result.stopReason = "degraded"
                result.addFailedSample("org:${org}", repoResult.errorKind)
                break
            }
            for (repo in repoResult.repos) {
                if (job.limits.maxRepos > 0 && result.scannedRepos >= job.limits.maxRepos) {
                    result.stopReason = "max_repos_reached"
                    return finalizeScanResult(state, job.jobId, result)
                }
                result.scannedRepos++
                let scopeKey = canonicalGitCodeRepoScopeKey(repo)
                let hadBaseline = state.hasBaseline(scopeKey)
                let collection = collectRepoEventsHttpDetailed(repo, runtime.gitCode, state)
                if (!collection.completed) {
                    result.failedEvents++
                    result.stopReason = "degraded"
                    result.addFailedSample(repo.fullName(), collection.errorKind)
                    state.addAudit(AuditRecord(scopeKey, status: "scan_degraded", reason: collection.errorKind))
                    if (!hadBaseline) { continue }
                }
                let baselineStart = result.baselineSeededEvents
                var repoCompleted = true
                for (event in collection.events) {
                    if (job.limits.maxItems > 0 && result.checkedItems >= job.limits.maxItems) {
                        result.stopReason = "max_items_reached"
                        repoCompleted = false
                        return finalizeScanResult(state, job.jobId, result)
                    }
                    result.checkedItems++
                    let baselineMode = !job.backfill && !hadBaseline
                    try {
                        let processed = processRuntimeEvent(config, state, event, baselineMode: baselineMode)
                        if (processed.newEvents > 0) {
                            match (eventWriter) {
                                case Some(writer) => emitGcmAcceptedScanEvent(job.jobId, event, writer)
                                case None => ()
                            }
                        }
                        result.absorb(processed)
                    } catch (e: Exception) {
                        let errorKind = gcmClassifyScanRuntimeError(e.message)
                        let audit = AuditRecord(event.id, status: "scan_degraded", reason: errorKind)
                        audit.deliveryStatus = gcmScanEventDeliveryStatus(repo, "event_runtime", redactServicePayload(e.message).rawHash)
                        state.addAudit(audit)
                        result.failedEvents++
                        result.addEventFailedSample(event, errorKind)
                    }
                }
                if (!job.backfill && !hadBaseline && collection.completed && repoCompleted) {
                    state.markBaseline(scopeKey, result.baselineSeededEvents - baselineStart)
                    result.baselineScopesCreated++
                }
            }
            if (repoResult.repos.size < runtime.gitCode.pageSize) { break }
            page++
        }
    }
    finalizeScanResult(state, job.jobId, result)
}

func emitGcmScanJobEvent(job: GcmScanJob, writer: GcmPluginStdioWriter): Unit {
    writer.writeFrame(gcmScanJobEventFrame(job))
}

func emitGcmAcceptedScanEvent(jobId: String, event: GitCodeEvent, writer: GcmPluginStdioWriter, discussionContext!: ?GitCodeDiscussionContext = None<GitCodeDiscussionContext>): Unit {
    writer.writeFrame(gcmAcceptedScanEventFrame(jobId, event, discussionContext: discussionContext))
}

func gcmAcceptedScanEventFrame(jobId: String, event: GitCodeEvent, discussionContext!: ?GitCodeDiscussionContext = None<GitCodeDiscussionContext>): ServiceFrame {
    ServiceFrame(
        "event",
        "accepted-${jobId}-${hashRawPayload(event.id)}",
        GCM_SERVICE_PLUGIN_ID,
        method: "emitCapabilityEvent",
        capabilityId: "gitcode.event.accepted",
        correlationId: "corr-${jobId}",
        payload: gcmAcceptedScanEventPayload(jobId, event, discussionContext: discussionContext)
    )
}

func gcmAcceptedScanEventPayload(jobId: String, event: GitCodeEvent, discussionContext!: ?GitCodeDiscussionContext = None<GitCodeDiscussionContext>): String {
    renderReviewRequestJson(jobId, event, discussionContext: discussionContext)
}

func gcmScanJobEventFrame(job: GcmScanJob): ServiceFrame {
    let capabilityId = match (job.status) {
        case "progress" => "gitcode.monitor.scan_progress"
        case "completed" => "gitcode.monitor.scan_completed"
        case "cancelled" => "gitcode.monitor.scan_cancelled"
        case "failed" => "gitcode.monitor.scan_failed"
        case _ => "gitcode.monitor.scan_progress"
    }
    ServiceFrame(
        "event",
        "scan-${job.status}-${job.jobId}",
        GCM_SERVICE_PLUGIN_ID,
        method: "emitCapabilityEvent",
        capabilityId: capabilityId,
        correlationId: "corr-${job.jobId}",
        payload: gcmScanJobEventPayload(job)
    )
}

func gcmScanJobEventPayload(job: GcmScanJob): String {
    let ok = job.status != GCM_SCAN_STATUS_FAILED
    var payload = "{\"ok\":${ok},\"status\":\"${jsonEscape(job.status)}\",\"jobId\":\"${jsonEscape(job.jobId)}\",\"stage\":\"${jsonEscape(job.stage)}\",\"accepted\":${job.accepted},\"ignored\":${job.ignored},\"emitted\":${job.emitted},\"mcpCalls\":${job.mcpCalls},\"writes\":${job.writes},\"summary\":\"${jsonEscape(job.summary)}\""
    if (job.status == GCM_SCAN_STATUS_COMPLETED) {
        payload += ",\"durationMs\":${gcmJobDurationMs(job)},\"stateSaved\":${job.stateSaved},\"report\":${gcmScanReportPayload(job)}"
    }
    if (job.status == GCM_SCAN_STATUS_FAILED) {
        payload += ",\"errorKind\":\"${jsonEscape(job.errorKind)}\",\"retryable\":true,\"diagnosticHash\":\"${jsonEscape(hashRawPayload(job.errorKind))}\""
        if (!job.diagnostic.isEmpty()) {
            payload += ",\"diagnostic\":${gcmDiagnosticPayloadJson(job.diagnostic)}"
        }
    }
    payload + "}"
}

extend ScanResult {
    public func addEventFailedSample(event: GitCodeEvent, reason: String): Unit {
        if (this.samplesFailed.size < SCAN_REPORT_SAMPLE_LIMIT) {
            this.samplesFailed.add(ScanEventSummary(
                event.id,
                "${event.org}/${event.repo}",
                event.itemKind,
                event.itemId,
                "",
                scanEventTitle(event),
                event.url,
                "failed",
                reason
            ))
        }
    }
}

func gcmScanReportPayload(job: GcmScanJob): String {
    let report = job.report
    let baselineStatus = gcmBaselineReportStatus(job, report)
    "{" +
        "\"orgs\":${stringArrayJson(report.orgs).toJsonString()}," +
        "\"limits\":{\"maxRepos\":${job.limits.maxRepos},\"maxItems\":${job.limits.maxItems},\"timeoutMillis\":${job.limits.maxDurationMillis}}," +
        "\"stopReason\":\"${jsonEscape(report.stopReason)}\"," +
        "\"scannedRepos\":${report.scannedRepos}," +
        "\"checkedItems\":${report.checkedItems}," +
        "\"newEvents\":${report.newEvents}," +
        "\"duplicateEvents\":${report.duplicateEvents}," +
        "\"filteredEvents\":${report.filteredEvents}," +
        "\"failedEvents\":${report.failedEvents}," +
        "\"baselineScopesCreated\":${report.baselineScopesCreated}," +
        "\"baselineSeededEvents\":${report.baselineSeededEvents}," +
        "\"backfillEvents\":${report.backfillEvents}," +
        "\"baseline\":{\"createdScopes\":${report.baselineScopesCreated},\"seededEvents\":${report.baselineSeededEvents},\"backfillEvents\":${report.backfillEvents},\"enabled\":true,\"backfill\":${job.backfill},\"status\":\"${jsonEscape(baselineStatus)}\"}," +
        "\"draftsGenerated\":${report.draftsGenerated}," +
        "\"draftsFailed\":${report.draftsFailed}," +
        "\"notificationsSent\":${report.notificationsSent}," +
        "\"writes\":${report.writes}," +
        "\"writeMode\":\"${jsonEscape(report.writeMode)}\"," +
        "\"samples\":{\"new\":${gcmScanSamplesJson(report.samplesNew)},\"duplicate\":${gcmScanSamplesJson(report.samplesDuplicate)},\"filtered\":${gcmScanSamplesJson(report.samplesFiltered)},\"failed\":${gcmScanSamplesJson(report.samplesFailed)},\"baseline\":${gcmScanSamplesJson(report.samplesBaseline)}}," +
        "\"sampleRemaining\":{\"new\":${gcmSampleRemaining(report.newEvents, report.samplesNew.size)},\"duplicate\":${gcmSampleRemaining(report.duplicateEvents, report.samplesDuplicate.size)},\"filtered\":${gcmSampleRemaining(report.filteredEvents, report.samplesFiltered.size)},\"failed\":${gcmSampleRemaining(report.failedEvents, report.samplesFailed.size)},\"baseline\":${gcmSampleRemaining(report.baselineSeededEvents, report.samplesBaseline.size)}}" +
    "}"
}

func gcmBaselineReportStatus(job: GcmScanJob, report: ScanResult): String {
    if (!job.stateSaved && report.baselineSeededEvents > 0) { return "state_save_failed" }
    if (job.backfill || report.backfillEvents > 0) { return "backfill" }
    if (report.baselineScopesCreated > 0 || report.baselineSeededEvents > 0) {
        return if (report.failedEvents > 0) { "partial" } else { "created" }
    }
    "existing"
}

func gcmScanSamplesJson(samples: ArrayList<ScanEventSummary>): String {
    let out = StringBuilder()
    out.append("[")
    for (i in 0..samples.size) {
        if (i > 0) { out.append(",") }
        let sample = samples[i]
        out.append("{\"eventId\":\"${jsonEscape(sample.eventId)}\",\"repo\":\"${jsonEscape(sample.repo)}\",\"kind\":\"${jsonEscape(sample.kind)}\",\"number\":\"${jsonEscape(sample.number)}\",\"commentId\":\"${jsonEscape(sample.commentId)}\",\"title\":\"${jsonEscape(sample.title)}\",\"url\":\"${jsonEscape(sample.url)}\",\"status\":\"${jsonEscape(sample.status)}\",\"reason\":\"${jsonEscape(sample.reason)}\"}")
    }
    out.append("]")
    out.toString()
}

func gcmSampleRemaining(total: Int64, sampleSize: Int64): Int64 {
    let remaining = total - sampleSize
    if (remaining < 0) { 0 } else { remaining }
}

func isGcmJobIdSafe(jobId: String): Bool {
    let trimmed = jobId.trimAscii()
    if (trimmed.isEmpty() || trimmed.size > 128) { return false }
    for (r in trimmed.runes()) {
        if (!((r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') || (r >= r'0' && r <= r'9') || r == r'-' || r == r'_' || r == r'.' || r == r':')) {
            return false
        }
    }
    true
}

func isGcmTerminalJobStatus(status: String): Bool {
    status == GCM_SCAN_STATUS_COMPLETED || status == GCM_SCAN_STATUS_FAILED || status == GCM_SCAN_STATUS_CANCELLED || status == GCM_SCAN_STATUS_EXPIRED
}

func gcmEventCapabilityMatchesStatus(capabilityId: String, status: String): Bool {
    (status == GCM_SCAN_STATUS_PROGRESS && capabilityId == "gitcode.monitor.scan_progress") ||
        (status == GCM_SCAN_STATUS_COMPLETED && capabilityId == "gitcode.monitor.scan_completed") ||
        (status == GCM_SCAN_STATUS_FAILED && capabilityId == "gitcode.monitor.scan_failed") ||
        (status == GCM_SCAN_STATUS_CANCELLED && capabilityId == "gitcode.monitor.scan_cancelled") ||
        (status == GCM_SCAN_STATUS_EXPIRED && capabilityId == "gitcode.monitor.scan_failed")
}

func gcmScanJobSummary(job: GcmScanJob): String {
    "accepted=${job.accepted} ignored=${job.ignored} emitted=${job.emitted} stateSaved=${job.stateSaved}"
}

func gcmJobDurationMs(job: GcmScanJob): Int64 {
    let duration = job.updatedAtMs - job.startedAtMs
    if (duration < 0) { 0 } else { duration }
}

func gcmNowMillis(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

func gcmClassifyScanRuntimeError(message: String): String {
    let lower = message.toAsciiLower()
    if (lower.contains("invalid utf8") || lower.contains("invalid utf-8")) { return "invalid_utf8" }
    if (lower.contains("timeout") || lower.contains("timed out")) { return "timeout" }
    if ((lower.contains("json") && (lower.contains("parse") || lower.contains("decode"))) || lower.contains("parse error")) { return "json_parse_error" }
    "runtime_exception"
}

func gcmScanRuntimeDiagnostic(stage: String, message: String): String {
    let redacted = redactServicePayload(message)
    let errorKind = gcmClassifyScanRuntimeError(message)
    "{\"stage\":\"${jsonEscape(stage)}\",\"errorKind\":\"${jsonEscape(errorKind)}\",\"errorHash\":\"${jsonEscape(redacted.rawHash)}\",\"message\":\"${jsonEscape(redacted.text)}\"}"
}

func gcmDiagnosticForPayload(diagnostic: String): String {
    if (diagnostic.trimAscii().isEmpty()) { return "" }
    try {
        let root = JsonValue.fromStr(diagnostic).asObject()
        let stage = firstJsonString(root, ["stage"])
        let errorKind = firstJsonString(root, ["errorKind"])
        let errorHash = firstJsonString(root, ["errorHash"])
        if (!stage.isEmpty() || !errorKind.isEmpty() || !errorHash.isEmpty()) {
            var payload = "{\"stage\":\"${jsonEscape(stage)}\",\"errorKind\":\"${jsonEscape(errorKind)}\",\"errorHash\":\"${jsonEscape(errorHash)}\""
            let repo = firstJsonString(root, ["repo"])
            let eventId = firstJsonString(root, ["eventId"])
            let kind = firstJsonString(root, ["kind"])
            let itemId = firstJsonString(root, ["itemId"])
            if (!repo.isEmpty()) { payload += ",\"repo\":\"${jsonEscape(redactServicePayload(repo).text)}\"" }
            if (!eventId.isEmpty()) { payload += ",\"eventId\":\"${jsonEscape(redactServicePayload(eventId).text)}\"" }
            if (!kind.isEmpty()) { payload += ",\"kind\":\"${jsonEscape(redactServicePayload(kind).text)}\"" }
            if (!itemId.isEmpty()) { payload += ",\"itemId\":\"${jsonEscape(redactServicePayload(itemId).text)}\"" }
            return payload + "}"
        }
    } catch (_: Exception) {
        ()
    }
    redactServicePayload(diagnostic).text
}

func gcmDiagnosticPayloadJson(diagnostic: String): String {
    let safe = gcmDiagnosticForPayload(diagnostic)
    if (safe.trimAscii().startsWith("{")) { return safe }
    "\"${jsonEscape(safe)}\""
}

func gcmScanEventDeliveryStatus(repo: GitCodeRepo, stage: String, errorHash: String): String {
    redactServicePayload("repo=${repo.fullName()} stage=${stage} hash=${errorHash}").text
}

class GcmStringResult {
    public let ok: Bool
    public let value: String
    public let diagnostic: String
    public init(ok: Bool, value!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.value = value
        this.diagnostic = diagnostic
    }
}

class GcmLimitsResult {
    public let ok: Bool
    public let value: GcmScanJobLimits
    public let diagnostic: String
    public init(ok: Bool, value!: GcmScanJobLimits = GcmScanJobLimits(), diagnostic!: String = "") {
        this.ok = ok
        this.value = value
        this.diagnostic = diagnostic
    }
}

class GcmOptionsResult {
    public let ok: Bool
    public let offlineFixture: Bool
    public let dryRun: Bool
    public let backfill: Bool
    public let diagnostic: String
    public init(ok: Bool, offlineFixture!: Bool = false, dryRun!: Bool = true, backfill!: Bool = false, diagnostic!: String = "") {
        this.ok = ok
        this.offlineFixture = offlineFixture
        this.dryRun = dryRun
        this.backfill = backfill
        this.diagnostic = diagnostic
    }
}

class GcmIntResult {
    public let ok: Bool
    public let value: Int64
    public let diagnostic: String
    public init(ok: Bool, value!: Int64 = 0, diagnostic!: String = "") {
        this.ok = ok
        this.value = value
        this.diagnostic = diagnostic
    }
}

func parseGcmDeliveryTargetHash(root: JsonObject): GcmStringResult {
    let target = match (root.get("deliveryTarget")) {
        case Some(value) =>
            try { value.asObject() } catch (_: Exception) { return GcmStringResult(false, diagnostic: "deliveryTarget must be object") }
        case None => return GcmStringResult(false, diagnostic: "deliveryTarget required")
    }
    let channel = pluginPayloadStringField(target, "channel", defaultValue: "", maxBytes: 64)
    let accountId = pluginPayloadStringField(target, "accountId", defaultValue: "", maxBytes: 128)
    let peerId = pluginPayloadStringField(target, "peerId", maxBytes: 1024)
    if (!channel.ok || !accountId.ok || !peerId.ok || peerId.value.trimAscii().isEmpty()) {
        return GcmStringResult(false, diagnostic: "deliveryTarget peerId must be string")
    }
    GcmStringResult(true, value: hashRawPayload("${channel.value}:${accountId.value}:${peerId.value}"))
}

func parseGcmScanJobLimits(root: JsonObject): GcmLimitsResult {
    let limits = match (root.get("limits")) {
        case Some(value) =>
            try { value.asObject() } catch (_: Exception) { return GcmLimitsResult(false, diagnostic: "limits must be object") }
        case None => return GcmLimitsResult(true, value: GcmScanJobLimits())
    }
    let maxRepos = gcmPayloadIntField(limits, "maxRepos", defaultValue: 0)
    let maxItems = gcmPayloadIntField(limits, "maxItems", defaultValue: 0)
    let maxDuration = gcmPayloadIntField(limits, "maxDurationMillis", defaultValue: 0)
    let perRequest = gcmPayloadIntField(limits, "perRequestTimeoutMillis", defaultValue: 30000)
    let progress = gcmPayloadIntField(limits, "progressIntervalMillis", defaultValue: 10000)
    if (!maxRepos.ok || !maxItems.ok || !maxDuration.ok || !perRequest.ok || !progress.ok) {
        return GcmLimitsResult(false, diagnostic: "limits fields must be integers")
    }
    if (maxRepos.value < 0 || maxItems.value < 0 || maxDuration.value < 0 || perRequest.value < 0 || progress.value < 0) {
        return GcmLimitsResult(false, diagnostic: "limits must be non-negative")
    }
    GcmLimitsResult(true, value: GcmScanJobLimits(maxRepos: maxRepos.value, maxItems: maxItems.value, maxDurationMillis: 0, perRequestTimeoutMillis: perRequest.value, progressIntervalMillis: progress.value))
}

func parseGcmAsyncScanOptions(root: JsonObject): GcmOptionsResult {
    let options = match (root.get("options")) {
        case Some(value) =>
            try { value.asObject() } catch (_: Exception) { return GcmOptionsResult(false, diagnostic: "options must be object") }
        case None => JsonObject()
    }
    let offlineFixture = pluginPayloadBoolField(options, "offlineFixture", defaultValue: false)
    let dryRun = pluginPayloadBoolField(options, "dryRun", defaultValue: true)
    let backfill = pluginPayloadBoolField(options, "backfill", defaultValue: false)
    if (!offlineFixture.ok || !dryRun.ok || !backfill.ok) {
        return GcmOptionsResult(false, diagnostic: "options fields must be bool")
    }
    GcmOptionsResult(true, offlineFixture: offlineFixture.value, dryRun: dryRun.value, backfill: backfill.value)
}

func gcmPayloadIntField(root: JsonObject, key: String, defaultValue!: Int64 = 0): GcmIntResult {
    match (root.get(key)) {
        case Some(value) =>
            let parsed = try { Int64.parse(value.toJsonString()) } catch (_: Exception) { return GcmIntResult(false, diagnostic: "field ${key} must be integer") }
            GcmIntResult(true, value: parsed)
        case None => GcmIntResult(true, value: defaultValue)
    }
}

func gcmFirstScanDegradedReason(state: MonitorState, auditStart: Int64): String {
    var index = auditStart
    while (index < state.audit.size) {
        let record = state.audit[index]
        if (record.status == "scan_degraded" || record.status == "state_error") {
            if (record.deliveryStatus.contains("stage=event_runtime")) {
                index++
                continue
            }
            if (!record.reason.isEmpty()) { return record.reason }
            return record.status
        }
        index++
    }
    ""
}
