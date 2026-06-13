package gitcodemonitor

import std.collection.ArrayList
import std.env.{getStdOut, getVariable}
import std.fs.{File, OpenMode, Path, exists}
import std.io.StringReader
import std.sync.Mutex
import std.time.DateTime
import stdx.encoding.json.{JsonObject, JsonValue}

public class ServiceInitializeRequest {
    public let protocolVersion: String
    public let configRef: String
    public let hostApis: Array<String>

    public init(protocolVersion: String, configRef!: String = "", hostApis!: Array<String> = []) {
        this.protocolVersion = protocolVersion.trimAscii()
        this.configRef = configRef.trimAscii()
        this.hostApis = hostApis
    }
}

public class ServiceInitializeResult {
    public let ok: Bool
    public let status: String
    public let serviceId: String
    public let protocolVersion: String
    public let capabilities: ArrayList<ServiceCapabilityRecord>
    public let diagnostic: String
    public let webhookReceiver: WebhookReceiverRuntimeStatus

    public init(
        ok: Bool,
        status: String,
        serviceId!: String = GCM_SERVICE_PLUGIN_ID,
        protocolVersion!: String = GCM_SERVICE_PROTOCOL_VERSION,
        capabilities!: ArrayList<ServiceCapabilityRecord> = ArrayList<ServiceCapabilityRecord>(),
        diagnostic!: String = "",
        webhookReceiver!: WebhookReceiverRuntimeStatus = WebhookReceiverRuntimeStatus("unknown")
    ) {
        this.ok = ok
        this.status = status
        this.serviceId = serviceId
        this.protocolVersion = protocolVersion
        this.capabilities = capabilities
        this.diagnostic = diagnostic
        this.webhookReceiver = webhookReceiver
    }
}

public class GcmConfigResolution {
    public let ok: Bool
    public let configPath: String
    public let status: String
    public init(ok: Bool, configPath!: String = "", status!: String = "ok") {
        this.ok = ok
        this.configPath = configPath.trimAscii()
        this.status = status
    }
}

public class GcmRuntimeConfigResult {
    public let ok: Bool
    public let status: String
    public let config: MonitorConfig
    public let diagnostic: String
    public init(ok: Bool, status: String, config!: MonitorConfig = defaultConfig(), diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.config = config
        this.diagnostic = diagnostic
    }
}

public class SecretStateSummary {
    public let gitCodeAuth: String
    public let mcpAuth: String
    public init(gitCodeAuth: String, mcpAuth: String) {
        this.gitCodeAuth = gitCodeAuth
        this.mcpAuth = mcpAuth
    }
}

public class GcmPluginContext {
    public let config: MonitorConfig
    public let state: MonitorState
    public let host: MetisHostClient
    public var initialized: Bool

    public init(config: MonitorConfig, state!: MonitorState = MonitorState(), host!: MetisHostClient = MetisHostClient()) {
        this.config = config
        this.state = state
        this.host = host
        this.initialized = true
    }
}

public class GcmRuntime {
    public let config: MonitorConfig
    public let state: MonitorState
    public let writer: GitCodeWritebackWriter
    public let maintainerContextStore: GcmMaintainerContextStore
    public let maintainerEmailLookupCache: MaintainerEmailLookupCache
    public let emailSender: MaintainerEmailSender
    public let gitCode: ?GitCodeHttpTransport
    public init(
        config: MonitorConfig,
        state!: MonitorState = MonitorState(),
        writer!: GitCodeWritebackWriter = FakeCommentWriter(),
        maintainerContextStore!: GcmMaintainerContextStore = GcmMaintainerContextStore(),
        maintainerEmailLookupCache!: MaintainerEmailLookupCache = MaintainerEmailLookupCache(),
        emailSender!: MaintainerEmailSender = NoopMaintainerEmailSender(),
        gitCode!: ?GitCodeHttpTransport = None<GitCodeHttpTransport>
    ) {
        this.config = config
        this.state = state
        this.writer = writer
        this.maintainerContextStore = maintainerContextStore
        this.maintainerEmailLookupCache = maintainerEmailLookupCache
        this.emailSender = emailSender
        this.gitCode = gitCode
    }
}

public class GcmStatusResult {
    public let ok: Bool
    public let status: String
    public let summary: String
    public init(ok: Bool, status: String, summary!: String = "") {
        this.ok = ok
        this.status = status
        this.summary = summary
    }
}

public class GcmScanOnceResult {
    public let ok: Bool
    public let status: String
    public let accepted: Int64
    public let ignored: Int64
    public let emitted: Int64
    public init(ok: Bool, status: String, accepted!: Int64 = 0, ignored!: Int64 = 0, emitted!: Int64 = 0) {
        this.ok = ok
        this.status = status
        this.accepted = accepted
        this.ignored = ignored
        this.emitted = emitted
    }
}

public class GcmPluginFrameHandleResult {
    public let ok: Bool
    public let frame: ServiceFrame
    public let shouldStop: Bool
    public let asyncJobId: String
    public init(ok: Bool, frame!: ServiceFrame = ServiceFrame("", "", ""), shouldStop!: Bool = false, asyncJobId!: String = "") {
        this.ok = ok
        this.frame = frame
        this.shouldStop = shouldStop
        this.asyncJobId = asyncJobId
    }
}

public interface GcmPluginLineSink {
    func writeln(line: String): Unit
    func flush(): Unit
}

public class GcmStdoutLineSink <: GcmPluginLineSink {
    private let stdout = getStdOut()

    public init() {}

    public func writeln(line: String): Unit {
        stdout.writeln(line)
    }

    public func flush(): Unit {
        stdout.flush()
    }
}

public class GcmMemoryLineSink <: GcmPluginLineSink {
    public let lines = ArrayList<String>()

    public init() {}

    public func writeln(line: String): Unit {
        lines.add(line)
    }

    public func flush(): Unit {}
}

public class GcmPluginStdioWriter {
    private let sink: GcmPluginLineSink
    private let lock = Mutex()

    public init(sink: GcmPluginLineSink) {
        this.sink = sink
    }

    public func writeFrame(frame: ServiceFrame): Unit {
        synchronized(lock) {
            sink.writeln(encodeServiceFrame(frame).trimAscii())
            sink.flush()
        }
    }
}

public class PluginPayloadParseResult {
    public let ok: Bool
    public let status: String
    public let payloadObject: JsonObject
    public let diagnostic: String

    public init(ok: Bool, status: String, payloadObject!: JsonObject = JsonObject(), diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.payloadObject = payloadObject
        this.diagnostic = diagnostic
    }
}

public class PluginPayloadBoolResult {
    public let ok: Bool
    public let status: String
    public let value: Bool
    public let diagnostic: String

    public init(ok: Bool, status: String, value!: Bool = false, diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.value = value
        this.diagnostic = diagnostic
    }
}

public class PluginPayloadStringResult {
    public let ok: Bool
    public let status: String
    public let value: String
    public let diagnostic: String

    public init(ok: Bool, status: String, value!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.value = value
        this.diagnostic = diagnostic
    }
}

public class GitCodeIgnoredEvent {
    public let event: GitCodeEvent
    public let reason: String
    public init(event: GitCodeEvent, reason: String) {
        this.event = event
        this.reason = reason
    }
}

public class GcmAuditRecord {
    public let eventId: String
    public let status: String
    public let reason: String
    public init(eventId: String, status: String, reason!: String = "") {
        this.eventId = eventId
        this.status = status
        this.reason = reason
    }
}

public class HostEmitResult {
    public let ok: Bool
    public let status: String
    public let frame: ServiceFrame
    public init(ok: Bool, status: String, frame!: ServiceFrame = ServiceFrame("", "", "")) {
        this.ok = ok
        this.status = status
        this.frame = frame
    }
}

public class HostAuditResult {
    public let ok: Bool
    public let status: String
    public init(ok: Bool, status: String) {
        this.ok = ok
        this.status = status
    }
}

public class MetisHostClient {
    public let emitted = ArrayList<ServiceFrame>()
    public let audits = ArrayList<String>()
    public init() {}
    public func emit(frame: ServiceFrame): HostEmitResult {
        emitted.add(frame)
        HostEmitResult(true, "emitted", frame: frame)
    }
    public func audit(line: String): HostAuditResult {
        audits.add(redactServicePayload(line).text)
        HostAuditResult(true, "appended")
    }
}

public class GcmWritebackRequest {
    public let eventId: String
    public let repo: String
    public let kind: String
    public let number: String
    public let url: String
    public let draft: String
    public let safety: String
    public let needsHumanReview: Bool
    public let duplicate: Bool
    public let parseStatus: String
    public let teamLeaderMentions: Array<String>
    public let codeownerMentions: Array<String>
    public let teamLeaderEmails: Array<String>
    public let codeownerEmails: Array<String>
    public let contextSource: String

    public init(
        eventId: String,
        repo: String,
        kind: String,
        number: String,
        url: String,
        draft: String,
        safety!: String = "approved",
        needsHumanReview!: Bool = false,
        duplicate!: Bool = false,
        parseStatus!: String = "ok",
        teamLeaderMentions!: Array<String> = [],
        codeownerMentions!: Array<String> = [],
        teamLeaderEmails!: Array<String> = [],
        codeownerEmails!: Array<String> = [],
        contextSource!: String = "unavailable"
    ) {
        this.eventId = eventId.trimAscii()
        this.repo = repo.trimAscii()
        this.kind = kind.trimAscii()
        this.number = number.trimAscii()
        this.url = url.trimAscii()
        this.draft = draft
        this.safety = safety.trimAscii()
        this.needsHumanReview = needsHumanReview
        this.duplicate = duplicate
        this.parseStatus = parseStatus.trimAscii()
        this.teamLeaderMentions = sanitizeMentionList(teamLeaderMentions)
        this.codeownerMentions = sanitizeMentionList(codeownerMentions)
        this.teamLeaderEmails = normalizeMaintainerEmails(teamLeaderEmails)
        this.codeownerEmails = normalizeMaintainerEmails(codeownerEmails)
        this.contextSource = contextSource.trimAscii()
    }
}

public class GcmWritebackDecision {
    public let allowed: Bool
    public let reason: String
    public init(allowed: Bool, reason: String) {
        this.allowed = allowed
        this.reason = reason
    }
}

public class GcmWritebackApplyResult {
    public let ok: Bool
    public let decision: GcmWritebackDecision
    public let writerCalled: Bool
    public let replyUrl: String
    public let maintainerMentionAppended: Bool
    public let teamLeaderCount: Int64
    public let codeownerCount: Int64
    public let posted: Bool
    public let retryable: Bool
    public let contextSource: String
    public let emailNotificationStatus: String
    public let emailSentCount: Int64
    public let emailFailedCount: Int64
    public let emailRetryable: Bool
    public init(
        ok: Bool,
        decision: GcmWritebackDecision,
        writerCalled!: Bool = false,
        replyUrl!: String = "",
        maintainerMentionAppended!: Bool = false,
        teamLeaderCount!: Int64 = 0,
        codeownerCount!: Int64 = 0,
        posted!: Bool = false,
        retryable!: Bool = false,
        contextSource!: String = "unavailable",
        emailNotificationStatus!: String = "email_disabled",
        emailSentCount!: Int64 = 0,
        emailFailedCount!: Int64 = 0,
        emailRetryable!: Bool = false
    ) {
        this.ok = ok
        this.decision = decision
        this.writerCalled = writerCalled
        this.replyUrl = replyUrl
        this.maintainerMentionAppended = maintainerMentionAppended
        this.teamLeaderCount = teamLeaderCount
        this.codeownerCount = codeownerCount
        this.posted = posted
        this.retryable = retryable
        this.contextSource = contextSource
        this.emailNotificationStatus = emailNotificationStatus
        this.emailSentCount = emailSentCount
        this.emailFailedCount = emailFailedCount
        this.emailRetryable = emailRetryable
    }
}

public class GitCodeCommentWriteRequest {
    public let repo: String
    public let kind: String
    public let number: String
    public let body: String
    public let credentialScope: String
    public init(repo: String, kind: String, number: String, body: String, credentialScope!: String = "gcm-internal") {
        this.repo = repo
        this.kind = kind
        this.number = number
        this.body = body
        this.credentialScope = credentialScope
    }
}

public class GcmWritebackAudit {
    public let eventId: String
    public let decision: String
    public let bodyHash: String
    public let replyUrl: String
    public init(eventId: String, decision: String, bodyHash: String, replyUrl!: String = "") {
        this.eventId = eventId
        this.decision = decision
        this.bodyHash = bodyHash
        this.replyUrl = replyUrl
    }
}

public class GcmConfigValidationResult {
    public let ok: Bool
    public let diagnostics: Array<String>
    public init(ok: Bool, diagnostics!: Array<String> = []) {
        this.ok = ok
        this.diagnostics = diagnostics
    }
}

public class GcmConfigSummary {
    public let text: String
    public init(text: String) {
        this.text = text
    }
}

public class ConfigConflict {
    public let field: String
    public let reason: String
    public init(field: String, reason: String) {
        this.field = field
        this.reason = reason
    }
}

public class GcmMcpClientMode {
    public let mode: String
    public let endpointPresent: Bool
    public init(mode: String, endpointPresent!: Bool = false) {
        this.mode = mode
        this.endpointPresent = endpointPresent
    }
}

private func gcmPluginStdinPath(): String {
    getVariable("METIS_SERVICE_PLUGIN_STDIN_PATH") ?? "/dev/stdin"
}

private func readGcmPluginStdioLine(reader: StringReader<File>): Option<String> {
    try {
        reader.readln()
    } catch (_: Exception) {
        None<String>
    }
}

private func shutdownGcmPluginRuntime(
    runtime: RuntimeContainer,
    state: MonitorState,
    leasePath: ?String,
    heartbeat: ?GcmPluginLeaseHeartbeatRuntime,
    processorLoop: WebhookProcessorLoopRuntime,
    listener: WebhookHttpServerRuntime
): Unit {
    heartbeat?.stop()
    let _ = runtime.store.save(state)
    match (leasePath) {
        case Some(path) =>
            let _ = markGcmPluginLeaseStopped(path, nowMs: DateTime.now().toUnixTimeStamp().toMilliseconds())
        case None => ()
    }
    processorLoop.stop()
    listener.stop()
}

public func gcmPluginMain(args: Array<String>): Int64 {
    let writer = GcmPluginStdioWriter(GcmStdoutLineSink())
    let configRef = pluginArgValue(args, "--config") ?? pluginArgValue(args, "configRef") ?? defaultConfigPath()
    let bootstrap = initializeGcmPlugin(ServiceInitializeRequest(GCM_SERVICE_PROTOCOL_VERSION, configRef: configRef, hostApis: ["host.audit.append"]))
    if (!bootstrap.ok) {
        writer.writeFrame(ServiceFrame("response", "initialize", GCM_SERVICE_PLUGIN_ID, method: "initialize", payload: gcmInitializeResponsePayload(bootstrap)))
        return 2
    }
    let loaded = loadGcmRuntimeConfig(configRef)
    if (!loaded.ok) {
        writer.writeFrame(ServiceFrame("response", "initialize", GCM_SERVICE_PLUGIN_ID, method: "initialize", payload: "{\"ok\":false,\"status\":\"${jsonEscape(loaded.status)}\"}"))
        return 2
    }
    let runtime = RuntimeContainer(loaded.config, pluginStdioMode: true)
    let state = runtime.store.load()
    let jobs = GcmScanJobStore(maxConcurrent: 1)
    let queue = WebhookQueue(loaded.config.webhook.queueDir)
    let listener = WebhookHttpServerRuntime(loaded.config, queue)
    let _ = listener.start()
    let processorLoop = WebhookProcessorLoopRuntime(loaded.config, runtime, state, queue)
    processorLoop.start(eventWriter: Some<GcmPluginStdioWriter>(writer))
    let startedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
    var heartbeatRuntime: ?GcmPluginLeaseHeartbeatRuntime = None<GcmPluginLeaseHeartbeatRuntime>
    let leasePath = match (buildGcmPluginLeaseFromEnv(loaded.config, startedAtMs)) {
        case Some((leasePath, lease, _)) =>
            let _ = writeGcmPluginLease(leasePath, lease)
            let heartbeat = GcmPluginLeaseHeartbeatRuntime(leasePath, lease)
            heartbeat.start()
            heartbeatRuntime = Some<GcmPluginLeaseHeartbeatRuntime>(heartbeat)
            Some<String>(leasePath)
        case None => None<String>
    }
    let initResult = buildGcmPluginInitializeResult(
        loaded.config,
        listenerSnapshot: Some<WebhookHttpServerSnapshot>(listener.snapshot()),
        processorSnapshot: Some<WebhookProcessorLoopSnapshot>(processorLoop.snapshot())
    )
    writer.writeFrame(ServiceFrame("response", "initialize", GCM_SERVICE_PLUGIN_ID, method: "initialize", payload: gcmInitializeResponsePayload(initResult)))
    try (stdinFile = File(gcmPluginStdinPath(), OpenMode.Read)) {
        let stdin = StringReader<File>(stdinFile)
        while (true) {
            match (readGcmPluginStdioLine(stdin)) {
                case Some(raw) =>
                    let handled = handleGcmPluginInputLineWithJobs(
                        raw,
                        loaded.config,
                        runtime,
                        state,
                        jobs,
                        listenerSnapshot: Some<WebhookHttpServerSnapshot>(listener.snapshot()),
                        processorSnapshot: Some<WebhookProcessorLoopSnapshot>(processorLoop.snapshot())
                    )
                    if (!handled.frame.frameType.isEmpty()) {
                        writer.writeFrame(handled.frame)
                    }
                    if (!handled.asyncJobId.isEmpty()) {
                        startGcmScanJobWorker(handled.asyncJobId, loaded.config, runtime, state, jobs, writer)
                    }
                    if (handled.shouldStop) {
                        shutdownGcmPluginRuntime(runtime, state, leasePath, heartbeatRuntime, processorLoop, listener)
                        return 0
                    }
                case None =>
                    shutdownGcmPluginRuntime(runtime, state, leasePath, heartbeatRuntime, processorLoop, listener)
                    return 0
            }
        }
    } catch (_: Exception) {
        shutdownGcmPluginRuntime(runtime, state, leasePath, heartbeatRuntime, processorLoop, listener)
        return 2
    }
    0
}

public func initializeGcmPlugin(request: ServiceInitializeRequest): ServiceInitializeResult {
    if (!request.protocolVersion.startsWith("1.")) {
        return ServiceInitializeResult(false, "incompatible_protocol", diagnostic: "unsupported protocol ${request.protocolVersion}")
    }
    let resolution = resolveGcmPluginConfig(request.configRef)
    if (!resolution.ok) {
        return ServiceInitializeResult(false, resolution.status, diagnostic: "configRef is required")
    }
    let loaded = loadGcmRuntimeConfig(resolution.configPath)
    if (!loaded.ok) {
        return ServiceInitializeResult(false, loaded.status, diagnostic: loaded.diagnostic)
    }
    buildGcmPluginInitializeResult(loaded.config)
}

public func buildGcmPluginInitializeResult(
    config: MonitorConfig,
    listenerSnapshot!: ?WebhookHttpServerSnapshot = None<WebhookHttpServerSnapshot>,
    processorSnapshot!: ?WebhookProcessorLoopSnapshot = None<WebhookProcessorLoopSnapshot>
): ServiceInitializeResult {
    let caps = buildGitCodeMonitorCapabilities(config)
    let check = validateGitCodeMonitorCapabilitySet(caps)
    let receiver = evaluateWebhookReceiverRuntime(config, listenerSnapshot: listenerSnapshot, processorSnapshot: processorSnapshot)
    let status = if (!check.ok || receiver.status == "degraded") { "capability_degraded" } else { "ok" }
    let diagnostics = ArrayList<String>()
    if (!check.ok) {
        let capabilityDiagnostics = pluginJoin(check.diagnostics, ",")
        if (!capabilityDiagnostics.isEmpty()) { diagnostics.add(capabilityDiagnostics) }
    }
    diagnostics.add(webhookReceiverRuntimeDiagnostic(receiver))
    ServiceInitializeResult(true, status, capabilities: caps, diagnostic: pluginJoin(diagnostics.toArray(), ","), webhookReceiver: receiver)
}

public func gcmInitializeResponsePayload(result: ServiceInitializeResult): String {
    "{\"ok\":${result.ok}," +
        "\"status\":\"${jsonEscape(result.status)}\"," +
        "\"capabilities\":${result.capabilities.size}," +
        "\"webhookReceiverStatus\":\"${jsonEscape(result.webhookReceiver.status)}\"," +
        "\"configStatus\":\"${jsonEscape(result.webhookReceiver.configStatus)}\"," +
        "\"queueStatus\":\"${jsonEscape(result.webhookReceiver.queueStatus)}\"," +
        "\"listenerStatus\":\"${jsonEscape(result.webhookReceiver.listenerStatus)}\"," +
        "\"processorStatus\":\"${jsonEscape(result.webhookReceiver.processorStatus)}\"," +
        "\"webhookBind\":\"${jsonEscape(result.webhookReceiver.bind)}\"," +
        "\"webhookEndpointCount\":${result.webhookReceiver.endpointCount}," +
        "\"webhookQueueDir\":\"${jsonEscape(redactServicePayload(result.webhookReceiver.queueDir).text)}\"," +
        "\"diagnostic\":\"${jsonEscape(result.webhookReceiver.diagnostic)}\"," +
        "\"lastError\":\"${jsonEscape(result.webhookReceiver.lastError)}\"}"
}

public func runGcmPluginLoop(context: GcmPluginContext): Int64 {
    if (!context.initialized) {
        return 2
    }
    let status = handleGcmStatusCapability("{}", GcmRuntime(context.config, state: context.state))
    let _ = context.host.audit("plugin_loop status=${status.status}")
    0
}

public func resolveGcmPluginConfig(configRef: String): GcmConfigResolution {
    let ref = configRef.trimAscii()
    if (ref.isEmpty()) {
        return GcmConfigResolution(false, status: "missing_config_ref")
    }
    GcmConfigResolution(true, configPath: ref)
}

public func loadGcmRuntimeConfig(path: String): GcmRuntimeConfigResult {
    if (path.trimAscii().isEmpty()) {
        return GcmRuntimeConfigResult(false, "missing_config")
    }
    if (!exists(Path(path))) {
        return GcmRuntimeConfigResult(false, "config_missing", diagnostic: "config file is missing")
    }
    let config = loadConfig(path: path)
    let validation = validateGcmPluginModeConfig(config)
    GcmRuntimeConfigResult(validation.ok, if (validation.ok) { "ok" } else { "invalid_config" }, config: config, diagnostic: pluginJoin(validation.diagnostics, ","))
}

public func summarizeGcmSecretState(config: MonitorConfig): SecretStateSummary {
    SecretStateSummary(if (gitCodeAuthPresentForPlugin(config)) { "present" } else { "absent" }, if (config.mcpServiceToken.isEmpty()) { "absent" } else { "present" })
}

public func buildGitCodeMonitorCapabilities(config: MonitorConfig): ArrayList<ServiceCapabilityRecord> {
    buildGitCodeMonitorCapabilityDeclarations()
}

public func handleGcmStatusCapability(payload: String, runtime: GcmRuntime): GcmStatusResult {
    let secret = summarizeGcmSecretState(runtime.config)
    let diagnostics = webhookDiagnosticCounters(runtime.state)
    GcmStatusResult(true, "running", summary: "dryRun=${runtime.config.dryRun} autoReply=${runtime.config.autoReply} ${writebackScopeSummary(runtime.config)} gitCodeAuth=${secret.gitCodeAuth} seen=${runtime.state.seenCount()} baselineScopes=${runtime.state.baselineScopeCount()} recordOnlyEnabled=${runtime.config.authorPolicy.recordOnlyEnabled} recordOnlyDomainCount=${runtime.config.authorPolicy.recordOnlyEmailDomains.size} recordOnlyEffective=${authorPolicyRecordOnlyEffective(runtime.config.authorPolicy)} recordOnly=${diagnostics.recordOnlyCount} recordOnlyTargetAuthor=${diagnostics.recordOnlyTargetAuthorCount} recordOnlyCommentAuthor=${diagnostics.recordOnlyCommentAuthorCount} recordOnlyEventActor=${diagnostics.recordOnlyEventActorCount} selfEchoIgnored=${diagnostics.selfEchoIgnoredCount} accepted=${diagnostics.acceptedCount} writebackPosted=${diagnostics.writebackPostedCount} writebackSkipped=${diagnostics.writebackSkippedCount} maintainerMentionSkipped=${diagnostics.maintainerMentionSkippedCount} mentionDegraded=${diagnostics.mentionDegradedCount}")
}

public func handleGcmScanOnceCapability(payload: String, runtime: GcmRuntime): GcmScanOnceResult {
    let parsed = parsePluginPayloadObject(payload)
    if (!parsed.ok) {
        return GcmScanOnceResult(false, "invalid_payload")
    }
    let overlap = pluginPayloadBoolField(parsed.payloadObject, "overlap", defaultValue: false)
    if (!overlap.ok) {
        return GcmScanOnceResult(false, "invalid_payload")
    }
    if (overlap.value) {
        runtime.state.skippedOverlappingScans++
        return GcmScanOnceResult(true, "skipped_overlap")
    }
    let offlineFixture = pluginPayloadBoolField(parsed.payloadObject, "offlineFixture", defaultValue: false)
    if (!offlineFixture.ok) {
        return GcmScanOnceResult(false, "invalid_payload")
    }
    if (!offlineFixture.value) {
        return GcmScanOnceResult(false, "runtime_required")
    }
    let result = scanOnceOfflineFixture(runtime.config, runtime.state)
    GcmScanOnceResult(true, "ok", accepted: result.accepted, ignored: result.ignored, emitted: result.accepted + result.ignored)
}

public func handleGcmScanOnceCapabilityRuntime(payload: String, config: MonitorConfig, runtime: RuntimeContainer, state: MonitorState): GcmScanOnceResult {
    let parsed = parsePluginPayloadObject(payload)
    if (!parsed.ok) {
        return GcmScanOnceResult(false, "invalid_payload")
    }
    let overlap = pluginPayloadBoolField(parsed.payloadObject, "overlap", defaultValue: false)
    if (!overlap.ok) {
        return GcmScanOnceResult(false, "invalid_payload")
    }
    if (overlap.value) {
        state.skippedOverlappingScans++
        return GcmScanOnceResult(true, "skipped_overlap")
    }
    let offlineFixture = pluginPayloadBoolField(parsed.payloadObject, "offlineFixture", defaultValue: false)
    if (!offlineFixture.ok) {
        return GcmScanOnceResult(false, "invalid_payload")
    }
    let result = if (offlineFixture.value) {
        scanOnceOfflineFixture(config, state)
    } else {
        scanOnceRuntime(config, runtime, state)
    }
    GcmScanOnceResult(true, "ok", accepted: result.accepted, ignored: result.ignored, emitted: result.accepted + result.ignored)
}

public func handleGcmPluginInputLine(line: String, config: MonitorConfig, runtime: RuntimeContainer, state: MonitorState): GcmPluginFrameHandleResult {
    handleGcmPluginInputLineWithJobs(line, config, runtime, state, GcmScanJobStore(maxConcurrent: 1))
}

public func handleGcmPluginInputLineWithJobs(
    line: String,
    config: MonitorConfig,
    runtime: RuntimeContainer,
    state: MonitorState,
    jobs: GcmScanJobStore,
    listenerSnapshot!: ?WebhookHttpServerSnapshot = None<WebhookHttpServerSnapshot>,
    processorSnapshot!: ?WebhookProcessorLoopSnapshot = None<WebhookProcessorLoopSnapshot>
): GcmPluginFrameHandleResult {
    let decoded = decodeServiceFrame(line)
    if (!decoded.ok) {
        return GcmPluginFrameHandleResult(false, frame: gcmPluginErrorFrame("decode-error", "", decoded.errorKind, decoded.diagnostic))
    }
    let frame = decoded.frame
    if (frame.serviceId != GCM_SERVICE_PLUGIN_ID) {
        return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "service_mismatch", "{\"ok\":false,\"status\":\"service_mismatch\"}"))
    }
    if (frame.method == "heartbeat") {
        return GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, "ok", "{\"ok\":true,\"status\":\"ok\"}"))
    }
    if (frame.method == "status") {
        let status = handleGcmStatusCapability(frame.payload, GcmRuntime(config, state: state, writer: runtime.writer, maintainerContextStore: runtime.maintainerContextStore, maintainerEmailLookupCache: runtime.maintainerEmailLookupCache, emailSender: runtime.emailSender, gitCode: Some<GitCodeHttpTransport>(runtime.gitCode)))
        return GcmPluginFrameHandleResult(status.ok, frame: gcmPluginResponseFrame(frame, status.ok, status.status, "{\"ok\":${status.ok},\"status\":\"${status.status}\",\"summary\":\"${jsonEscape(status.summary)}\"}"))
    }
    if (frame.method == "stop") {
        return GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, "stopped", "{\"ok\":true,\"status\":\"stopped\"}"), shouldStop: true)
    }
    if (frame.method != "invokeCapability") {
        return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "unknown_method", "{\"ok\":false,\"status\":\"unknown_method\"}"))
    }
    match (frame.capabilityId) {
        case "gitcode.monitor.status" =>
            let status = handleGcmStatusCapability(frame.payload, GcmRuntime(config, state: state, writer: runtime.writer, maintainerContextStore: runtime.maintainerContextStore, maintainerEmailLookupCache: runtime.maintainerEmailLookupCache, emailSender: runtime.emailSender, gitCode: Some<GitCodeHttpTransport>(runtime.gitCode)))
            GcmPluginFrameHandleResult(status.ok, frame: gcmPluginResponseFrame(frame, status.ok, status.status, "{\"ok\":${status.ok},\"status\":\"${status.status}\",\"summary\":\"${jsonEscape(status.summary)}\"}"))
        case "gitcode.monitor.scan_once" =>
            let mode = scanPayloadMode(frame.payload)
            if (mode == "async") {
                let parsed = parseGcmAsyncScanPayload(frame.payload)
                if (!parsed.ok) {
                    return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, parsed.status, gcmJobErrorPayload(parsed.status, diagnostic: parsed.diagnostic)))
                }
                let created = jobs.createOrGet(parsed.payload)
                if (!created.ok) {
                    return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, created.status, gcmJobErrorPayload(created.status, jobId: parsed.payload.jobId)))
                }
                return GcmPluginFrameHandleResult(
                    true,
                    frame: gcmPluginResponseFrame(frame, true, "accepted", gcmJobAcceptedPayload(created.job, created.alreadyRunning)),
                    asyncJobId: if (created.alreadyRunning) { "" } else { created.job.jobId }
                )
            }
            let scan = handleGcmScanOnceCapabilityRuntime(frame.payload, config, runtime, state)
            let saved = runtime.store.save(state)
            let status = if (scan.ok && saved) { scan.status } else { if (!saved) { "state_save_failed" } else { scan.status } }
            GcmPluginFrameHandleResult(scan.ok && saved, frame: gcmPluginResponseFrame(frame, scan.ok && saved, status, gcmScanOncePayload(scan, saved: saved)))
        case "gitcode.monitor.job_status" =>
            let jobId = parseGcmJobIdPayload(frame.payload)
            if (jobId.isEmpty()) {
                return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "job_payload_invalid", gcmJobErrorPayload("job_payload_invalid")))
            }
            match (jobs.find(jobId)) {
                case Some(job) =>
                    GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, job.status, gcmJobSnapshotPayload(job)))
                case None =>
                    GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "job_not_found", gcmJobErrorPayload("job_not_found", jobId: jobId)))
            }
        case "gitcode.monitor.cancel_job" =>
            let jobId = parseGcmJobIdPayload(frame.payload)
            if (jobId.isEmpty()) {
                return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "job_payload_invalid", gcmJobErrorPayload("job_payload_invalid")))
            }
            let cancelled = jobs.requestCancel(jobId)
            if (!cancelled.ok) {
                return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, cancelled.status, gcmJobErrorPayload(cancelled.status, jobId: jobId)))
            }
            GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, "cancel_requested", "{\"ok\":true,\"status\":\"cancel_requested\",\"jobId\":\"${jsonEscape(jobId)}\",\"summary\":\"GitCode scan cancellation requested\"}"))
        case "gitcode.webhook.status" =>
            let queue = WebhookQueue(config.webhook.queueDir)
            GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, "ok", webhookStatusPayload(config, queue, listenerSnapshot: listenerSnapshot, processorSnapshot: processorSnapshot, state: Some<MonitorState>(state))))
        case "gitcode.webhook.dead_letter_list" =>
            let queue = WebhookQueue(config.webhook.queueDir)
            GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, "ok", deadLetterListPayload(queue)))
        case "gitcode.webhook.dead_letter_inspect" =>
            let deliveryId = parseWebhookDeliveryIdPayload(frame.payload)
            if (deliveryId.isEmpty()) {
                return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "delivery_payload_invalid", "{\"ok\":false,\"status\":\"delivery_payload_invalid\"}"))
            }
            let queue = WebhookQueue(config.webhook.queueDir)
            GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, "ok", deadLetterInspectPayload(queue, deliveryId)))
        case "gitcode.webhook.replay" =>
            let deliveryId = parseWebhookDeliveryIdPayload(frame.payload)
            if (deliveryId.isEmpty()) {
                return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "delivery_payload_invalid", "{\"ok\":false,\"status\":\"delivery_payload_invalid\"}"))
            }
            let queue = WebhookQueue(config.webhook.queueDir)
            let replay = replayWebhookDelivery(queue, deliveryId)
            GcmPluginFrameHandleResult(replay.ok, frame: gcmPluginResponseFrame(frame, replay.ok, replay.status, "{\"ok\":${replay.ok},\"status\":\"${jsonEscape(replay.status)}\",\"deliveryId\":\"${jsonEscape(sanitizeDeliveryIdForPath(deliveryId))}\"}"))
        case "gitcode.webhook.cancel" =>
            let deliveryId = parseWebhookDeliveryIdPayload(frame.payload)
            if (deliveryId.isEmpty()) {
                return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "delivery_payload_invalid", "{\"ok\":false,\"status\":\"delivery_payload_invalid\"}"))
            }
            let queue = WebhookQueue(config.webhook.queueDir)
            let cancelled = cancelWebhookDelivery(queue, deliveryId)
            GcmPluginFrameHandleResult(cancelled.ok, frame: gcmPluginResponseFrame(frame, cancelled.ok, cancelled.status, "{\"ok\":${cancelled.ok},\"status\":\"${jsonEscape(cancelled.status)}\",\"deliveryId\":\"${jsonEscape(sanitizeDeliveryIdForPath(deliveryId))}\"}"))
        case "gitcode.webhook.reconcile_hooks" =>
            let parsed = parsePluginPayloadObject(frame.payload)
            if (!parsed.ok) {
                return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, parsed.status, "{\"ok\":false,\"status\":\"${jsonEscape(parsed.status)}\"}"))
            }
            let apply = pluginPayloadBoolField(parsed.payloadObject, "apply", defaultValue: false)
            if (!apply.ok) {
                return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, apply.status, "{\"ok\":false,\"status\":\"${jsonEscape(apply.status)}\"}"))
            }
            GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, "ok", hookReconcilePayload(config, apply.value)))
        case "gitcode.webhook.reconcile_events" =>
            let mode = scanPayloadMode(frame.payload)
            if (mode == "async") {
                let parsed = parseGcmAsyncScanPayload(frame.payload)
                if (!parsed.ok) {
                    return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, parsed.status, gcmJobErrorPayload(parsed.status, diagnostic: parsed.diagnostic)))
                }
                let created = jobs.createOrGet(parsed.payload)
                if (!created.ok) {
                    return GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, created.status, gcmJobErrorPayload(created.status, jobId: parsed.payload.jobId)))
                }
                return GcmPluginFrameHandleResult(
                    true,
                    frame: gcmPluginResponseFrame(frame, true, "accepted", gcmJobAcceptedPayload(created.job, created.alreadyRunning)),
                    asyncJobId: if (created.alreadyRunning) { "" } else { created.job.jobId }
                )
            }
            GcmPluginFrameHandleResult(true, frame: gcmPluginResponseFrame(frame, true, "accepted", eventReconcilePayload(config)))
        case "gitcode.writeback.apply_result" =>
            let beforeVersion = state.version()
            let applied = handleGcmWritebackApplyResult(frame.payload, GcmRuntime(config, state: state, writer: runtime.writer, maintainerContextStore: runtime.maintainerContextStore, maintainerEmailLookupCache: runtime.maintainerEmailLookupCache, emailSender: runtime.emailSender, gitCode: Some<GitCodeHttpTransport>(runtime.gitCode)))
            let saved = runtime.store.saveIfChanged(state, beforeVersion, reason: "writeback_apply_result")
            let ok = applied.ok && saved.status != "state_save_failed"
            let status = if (ok) { applied.decision.reason } else { "state_save_failed" }
            GcmPluginFrameHandleResult(ok, frame: gcmPluginResponseFrame(frame, ok, status, gcmWritebackApplyResultPayload(applied)))
        case _ =>
            GcmPluginFrameHandleResult(false, frame: gcmPluginResponseFrame(frame, false, "capability_unsupported", "{\"ok\":false,\"status\":\"capability_unsupported\",\"capabilityId\":\"${jsonEscape(frame.capabilityId)}\"}"))
    }
}

public func handleGcmPluginInputLinesForTest(lines: Array<String>, config: MonitorConfig, runtime: RuntimeContainer, state: MonitorState): Array<String> {
    let out = ArrayList<String>()
    for (line in lines) {
        let handled = handleGcmPluginInputLine(line, config, runtime, state)
        if (!handled.frame.frameType.isEmpty()) {
            out.add(encodeServiceFrame(handled.frame).trimAscii())
        }
        if (handled.shouldStop) {
            break
        }
    }
    out.toArray()
}

public func emitGcmAcceptedEvent(event: GitCodeEvent, host: MetisHostClient): HostEmitResult {
    host.emit(ServiceFrame("event", "accepted-${event.id}", GCM_SERVICE_PLUGIN_ID, method: "emitCapabilityEvent", capabilityId: "gitcode.event.accepted", payload: eventPayload(event)))
}

public func emitGcmIgnoredEvent(event: GitCodeIgnoredEvent, host: MetisHostClient): HostEmitResult {
    host.emit(ServiceFrame("event", "ignored-${event.event.id}", GCM_SERVICE_PLUGIN_ID, method: "emitCapabilityEvent", capabilityId: "gitcode.event.ignored", payload: "{\"eventId\":\"${event.event.id}\",\"reason\":\"${event.reason}\"}"))
}

public func appendGcmPluginAudit(audit: GcmAuditRecord, host: MetisHostClient): HostAuditResult {
    host.audit("eventId=${audit.eventId} status=${audit.status} reason=${audit.reason}")
}

public func handleGcmWritebackApplyResult(payload: String, runtime: GcmRuntime): GcmWritebackApplyResult {
    let parsedRequest = parseWritebackRequest(payload)
    let request = withResolvedWritebackMaintainerContext(parsedRequest, runtime)
    let decision = evaluateGcmAutoReplyGate(request, runtime.config)
    if (!decision.allowed) {
        let _ = emitGcmWritebackAudit(buildGcmWritebackAudit(request, decision, replyUrl: ""), MetisHostClient())
        recordGcmWritebackAuditState(runtime.state, request, decision, replyUrl: "", posted: false)
        return GcmWritebackApplyResult(
            request.parseStatus != "invalid_payload",
            decision,
            teamLeaderCount: request.teamLeaderMentions.size,
            codeownerCount: request.codeownerMentions.size,
            contextSource: request.contextSource,
            emailNotificationStatus: "email_disabled"
        )
    }
    let event = GitCodeEvent(request.eventId, request.repo.split("/", 2)[0], if (request.repo.contains("/")) { request.repo.split("/", 2)[1] } else { request.repo }, request.kind, request.number, "metis", "", request.url, request.draft)
    let mention = buildMaintainerMentionSentence(
        request.eventId,
        request.kind,
        teamLeaderMentions: request.teamLeaderMentions,
        codeownerMentions: request.codeownerMentions
    )
    let appended = appendMaintainerMentionSentence(request.draft, mention.sentence)
    if (!appended.appended) {
        runtime.state.addAudit(AuditRecord(request.eventId, status: "maintainer_mention_skipped", reason: pluginJoin(appended.diagnostics, ",")))
    }
    let replyUrl = runtime.writer.write(event, appended.body, runtime.state)
    let writeStatus = if (replyUrl.startsWith("error:")) { replyUrl.split(":", 2)[1] } else { "posted" }
    let finalDecision = GcmWritebackDecision(writeStatus == "posted", writeStatus)
    if (writeStatus == "posted") {
        let _ = recordWriteback(writebackLedgerPathForConfig(runtime.config), request.repo, request.kind, request.number, replyUrl, appended.body, request.eventId)
    }
    let emailResult = if (writeStatus == "posted") {
        sendMaintainerEmailAfterWriteback(request, replyUrl, runtime)
    } else {
        MaintainerEmailSendResult("email_disabled")
    }
    recordGcmWritebackAuditState(runtime.state, request, finalDecision, replyUrl: if (writeStatus == "posted") { replyUrl } else { "" }, posted: writeStatus == "posted", emailResult: emailResult)
    GcmWritebackApplyResult(
        true,
        finalDecision,
        writerCalled: true,
        replyUrl: if (writeStatus == "posted") { replyUrl } else { "" },
        maintainerMentionAppended: appended.appended,
        teamLeaderCount: request.teamLeaderMentions.size,
        codeownerCount: request.codeownerMentions.size,
        posted: writeStatus == "posted",
        retryable: isRetryableGcmWritebackStatus(writeStatus),
        contextSource: request.contextSource,
        emailNotificationStatus: emailResult.status,
        emailSentCount: emailResult.sentCount,
        emailFailedCount: emailResult.failedCount,
        emailRetryable: emailResult.retryable
    )
}

func withResolvedWritebackMaintainerContext(request: GcmWritebackRequest, runtime: GcmRuntime): GcmWritebackRequest {
    if (request.parseStatus != "ok") { return request }
    let context = match (runtime.maintainerContextStore.get(request.eventId)) {
        case Some(stored) => stored
        case None =>
            match (runtime.gitCode) {
                case Some(transport) =>
                    let parts = request.repo.split("/", 2)
                    if (parts.size == 2 && !request.number.isEmpty()) {
                        let fallbackEvent = GitCodeEvent(request.eventId, parts[0], parts[1], request.kind, request.number, "metis", "", request.url, request.draft)
                        let resolved = resolveGcmMaintainerContext(
                            transport,
                            fallbackEvent,
                            emailConfig: runtime.config.maintainerNotificationEmail,
                            emailCache: runtime.maintainerEmailLookupCache
                        )
                        if (resolved.teamLeaderMentions.size > 0 || resolved.codeownerMentions.size > 0) {
                            resolved
                        } else if (request.teamLeaderMentions.size > 0 || request.codeownerMentions.size > 0) {
                            GcmMaintainerContext(request.eventId, request.repo, request.kind, request.number, teamLeaderMentions: request.teamLeaderMentions, codeownerMentions: request.codeownerMentions, contextSource: "payload_compat")
                        } else {
                            GcmMaintainerContext(request.eventId, request.repo, request.kind, request.number, contextSource: "unavailable")
                        }
                    } else {
                        GcmMaintainerContext(request.eventId, request.repo, request.kind, request.number, contextSource: "unavailable")
                    }
                case None =>
                    if (request.teamLeaderMentions.size > 0 || request.codeownerMentions.size > 0) {
                        GcmMaintainerContext(request.eventId, request.repo, request.kind, request.number, teamLeaderMentions: request.teamLeaderMentions, codeownerMentions: request.codeownerMentions, contextSource: "payload_compat")
                    } else {
                        GcmMaintainerContext(request.eventId, request.repo, request.kind, request.number, contextSource: "unavailable")
                    }
            }
    }
    let withEmails = match (runtime.gitCode) {
        case Some(transport) =>
            contextWithResolvedUserEmails(
                context,
                transport.client,
                transport.sender,
                runtime.config.maintainerNotificationEmail,
                runtime.maintainerEmailLookupCache
            )
        case None => contextWithAddressBookEmails(context, runtime.config.maintainerNotificationEmail)
    }
    GcmWritebackRequest(
        request.eventId,
        request.repo,
        request.kind,
        request.number,
        request.url,
        request.draft,
        safety: request.safety,
        needsHumanReview: request.needsHumanReview,
        duplicate: request.duplicate,
        parseStatus: request.parseStatus,
        teamLeaderMentions: withEmails.teamLeaderMentions,
        codeownerMentions: withEmails.codeownerMentions,
        teamLeaderEmails: withEmails.teamLeaderEmails,
        codeownerEmails: withEmails.codeownerEmails,
        contextSource: if (withEmails.contextSource.isEmpty()) { "unavailable" } else { withEmails.contextSource }
    )
}

func sendMaintainerEmailAfterWriteback(request: GcmWritebackRequest, replyUrl: String, runtime: GcmRuntime): MaintainerEmailSendResult {
    let emails = ArrayList<String>()
    for (email in request.teamLeaderEmails) { emails.add(email) }
    for (email in request.codeownerEmails) { emails.add(email) }
    let mentions = ArrayList<String>()
    for (mention in request.teamLeaderMentions) { mentions.add(mention) }
    for (mention in request.codeownerMentions) { mentions.add(mention) }
    let plan = buildMaintainerNotificationPlan(mentions.toArray(), emails: emails.toArray(), emailNotificationEnabled: runtime.config.maintainerNotificationEmail.enabled)
    if (plan.emailNotificationStatus != "ready") {
        return MaintainerEmailSendResult(plan.emailNotificationStatus)
    }
    let message = MaintainerEmailMessage(
        plan.emailPlan,
        "GitCode ${request.repo} ${request.kind} #${request.number} 需要维护者关注",
        "GitCode 讨论有新回复，请在页面中查看。\nrepo=${request.repo}\nkind=${request.kind}\nnumber=${request.number}\nurl=${request.url}\nreplyUrl=${replyUrl}",
        repo: request.repo,
        kind: request.kind,
        number: request.number,
        url: request.url,
        replyUrl: replyUrl
    )
    runtime.emailSender.send(message)
}

public func evaluateGcmAutoReplyGate(request: GcmWritebackRequest, config: MonitorConfig): GcmWritebackDecision {
    if (request.parseStatus != "ok") { return GcmWritebackDecision(false, request.parseStatus) }
    if (request.draft.trimAscii().isEmpty()) { return GcmWritebackDecision(false, "draft_empty") }
    if (!config.autoReply) { return GcmWritebackDecision(false, "auto_reply_disabled") }
    if (config.dryRun) { return GcmWritebackDecision(false, "dry_run") }
    let scopeDecision = evaluateWritebackScope(config, request.repo)
    if (!scopeDecision.allowed) { return GcmWritebackDecision(false, scopeDecision.reason) }
    let safety = request.safety.toAsciiLower()
    if (safety != "approved" && safety != "safe") { return GcmWritebackDecision(false, "safety_rejected") }
    if (request.needsHumanReview) { return GcmWritebackDecision(false, "needs_human_review") }
    if (request.duplicate) { return GcmWritebackDecision(false, "duplicate") }
    if (containsSecret(request.draft)) { return GcmWritebackDecision(false, "secret_detected") }
    if (containsLocalPath(request.draft)) { return GcmWritebackDecision(false, "local_path_detected") }
    if (gcmWritebackDraftLooksLikeToolJson(request.draft)) { return GcmWritebackDecision(false, "draft_invalid_tool_json") }
    if (gcmWritebackDraftLooksLikeRawJson(request.draft)) { return GcmWritebackDecision(false, "draft_raw_json") }
    if (gcmWritebackDraftContainsForbiddenMarker(request.draft)) { return GcmWritebackDecision(false, "draft_forbidden_marker") }
    GcmWritebackDecision(true, "allow_write")
}

private func gcmWritebackDraftLooksLikeToolJson(draft: String): Bool {
    let trimmed = draft.trimAscii()
    let root = try {
        JsonValue.fromStr(trimmed).asObject()
    } catch (_: Exception) {
        return false
    }
    if (gcmJsonObjectHasAnyKey(root, ["tool", "name", "arguments", "function_call", "tool_calls"])) {
        return true
    }
    gcmJsonObjectHasAnyStringValue(root, ["tool", "name", "function_call"], ["_answer_", "functions._answer_"]) ||
        gcmJsonTextHasAnyQuotedValue(root.toJsonString(), ["_answer_", "functions._answer_"])
}

private func gcmWritebackDraftLooksLikeRawJson(draft: String): Bool {
    let trimmed = draft.trimAscii()
    let parsed = try {
        JsonValue.fromStr(trimmed)
    } catch (_: Exception) {
        return false
    }
    try {
        let _ = parsed.asObject()
        return !gcmWritebackDraftLooksLikeToolJson(draft)
    } catch (_: Exception) {
        ()
    }
    try {
        let _ = parsed.asArray()
        return true
    } catch (_: Exception) {
        return false
    }
}

private func gcmWritebackDraftContainsForbiddenMarker(draft: String): Bool {
    let lower = draft.toAsciiLower()
    lower.contains("auto-reply") ||
        lower.contains("gitcodemonitor") ||
        lower.contains("<!--") ||
        lower.contains("hidden marker") ||
        lower.contains("bot attribution")
}

private func gcmJsonObjectHasAnyKey(root: JsonObject, keys: Array<String>): Bool {
    for (key in keys) {
        match (root.get(key)) {
            case Some(_) => return true
            case None => ()
        }
    }
    false
}

private func gcmJsonObjectHasAnyStringValue(root: JsonObject, keys: Array<String>, values: Array<String>): Bool {
    for (key in keys) {
        match (root.get(key)) {
            case Some(value) =>
                let text = try { value.asString().getValue() } catch (_: Exception) { "" }
                for (expected in values) {
                    if (text == expected) { return true }
                }
            case None => ()
        }
    }
    false
}

private func gcmJsonTextHasAnyQuotedValue(json: String, values: Array<String>): Bool {
    for (value in values) {
        if (json.contains("\"${jsonEscape(value)}\"")) { return true }
    }
    false
}

public func emitGcmWritebackAudit(audit: GcmWritebackAudit, host: MetisHostClient): HostEmitResult {
    let safeReplyUrl = sanitizeWritebackReplyUrlForStorage(audit.replyUrl)
    let frame = ServiceFrame("event", "writeback-${audit.eventId}", GCM_SERVICE_PLUGIN_ID, method: "emitCapabilityEvent", capabilityId: "gitcode.writeback.audit", payload: "{\"eventId\":\"${jsonEscape(audit.eventId)}\",\"decision\":\"${jsonEscape(audit.decision)}\",\"bodyHash\":\"${jsonEscape(audit.bodyHash)}\",\"replyUrl\":\"${jsonEscape(safeReplyUrl)}\"}")
    host.emit(frame)
}

public func buildGitCodeCommentWriteRequest(request: GcmWritebackRequest): GitCodeCommentWriteRequest {
    let mention = buildMaintainerMentionSentence(request.eventId, request.kind, teamLeaderMentions: request.teamLeaderMentions, codeownerMentions: request.codeownerMentions)
    GitCodeCommentWriteRequest(request.repo, request.kind, request.number, appendMaintainerMentionSentence(request.draft, mention.sentence).body)
}

public func hasGcmSelfMarker(body: String): Bool {
    body.contains(SELF_MARKER)
}

public func buildGcmWritebackAudit(request: GcmWritebackRequest, decision: GcmWritebackDecision, replyUrl!: String = ""): GcmWritebackAudit {
    GcmWritebackAudit(request.eventId, decision.reason, hashRawPayload(request.draft), replyUrl: sanitizeWritebackReplyUrlForStorage(replyUrl))
}

private func recordGcmWritebackAuditState(state: MonitorState, request: GcmWritebackRequest, decision: GcmWritebackDecision, replyUrl!: String = "", posted!: Bool = false, emailResult!: MaintainerEmailSendResult = MaintainerEmailSendResult("email_disabled")): Unit {
    let status = if (posted) { "writeback_posted" } else { "writeback_skipped" }
    let record = AuditRecord(if (request.eventId.isEmpty()) { "writeback" } else { request.eventId }, status: status, reason: decision.reason)
    record.replyUrl = sanitizeWritebackReplyUrlForStorage(replyUrl)
    record.writeDecision = decision.reason
    record.safety = request.safety
    record.emailNotificationStatus = emailResult.status
    record.emailSentCount = emailResult.sentCount
    record.emailFailedCount = emailResult.failedCount
    record.emailRetryable = emailResult.retryable
    record.emailDiagnostic = sanitizeGcmEmailDiagnosticForAudit(emailResult.diagnostic)
    state.addAudit(record)
}

private func sanitizeGcmEmailDiagnosticForAudit(raw: String): String {
    compactSummary(redactSecrets(raw), limit: 200)
}

private func isRetryableGcmWritebackStatus(status: String): Bool {
    status == "gitcode_api_unavailable" || status == "gitcode_api_timeout" || status == "rate_limited" || status == "server_error"
}

public func gcmWritebackApplyResultPayload(result: GcmWritebackApplyResult): String {
    "{\"ok\":${result.ok}," +
        "\"status\":\"${jsonEscape(result.decision.reason)}\"," +
        "\"writerCalled\":${result.writerCalled}," +
        "\"posted\":${result.posted}," +
        "\"retryable\":${result.retryable}," +
        "\"replyUrl\":\"${jsonEscape(result.replyUrl)}\"," +
        "\"maintainerMentionAppended\":${result.maintainerMentionAppended}," +
        "\"teamLeaderCount\":${result.teamLeaderCount}," +
        "\"codeownerCount\":${result.codeownerCount}," +
        "\"contextSource\":\"${jsonEscape(result.contextSource)}\"," +
        "\"emailNotificationStatus\":\"${jsonEscape(result.emailNotificationStatus)}\"," +
        "\"emailSentCount\":${result.emailSentCount}," +
        "\"emailFailedCount\":${result.emailFailedCount}," +
        "\"emailRetryable\":${result.emailRetryable}" +
    "}"
}

public func validateGcmPluginModeConfig(config: MonitorConfig): GcmConfigValidationResult {
    let diagnostics = ArrayList<String>()
    if (config.gitCodeBaseUrl.trimAscii().isEmpty()) { diagnostics.add("gitcode.baseUrl missing") }
    if (config.statePath.trimAscii().isEmpty()) { diagnostics.add("statePath missing") }
    if (config.fullScanIntervalMinutes < 5) { diagnostics.add("fullScanIntervalMinutes below production minimum") }
    for (diagnostic in validateWritebackScopeConfig(config.writebackScope, config.repoAllowlist)) {
        diagnostics.add("writebackScope ${diagnostic}")
    }
    if (!config.dryRun && config.autoReply && !writebackScopeHasAllow(config)) { diagnostics.add("writebackScope has no allowed orgs or repos") }
    GcmConfigValidationResult(diagnostics.size == 0, diagnostics: diagnostics.toArray())
}

public func summarizeGcmPluginModeConfig(config: MonitorConfig): GcmConfigSummary {
    let secret = summarizeGcmSecretState(config)
    GcmConfigSummary("orgs=${config.orgs.size} dryRun=${config.dryRun} autoReply=${config.autoReply} ${writebackScopeSummary(config)} gitCodeAuth=${secret.gitCodeAuth} mcpAuth=${secret.mcpAuth} statePath=${redactServicePayload(config.statePath).text}")
}

public func migrateLegacyAutoReply(config: MonitorConfig): MonitorConfig {
    config
}

public func detectAutoReplyConfigConflict(config: MonitorConfig): ?ConfigConflict {
    None<ConfigConflict>
}

public func detectAutoReplyConfigTextConflict(raw: String): ?ConfigConflict {
    if (raw.contains("\"autoReply\":true") && raw.contains("\"autoReply\":{\"enabled\":false")) {
        return Some(ConfigConflict("autoReply", "legacy true conflicts with autoReply.enabled false"))
    }
    if (raw.contains("\"autoReply\":false") && raw.contains("\"autoReply\":{\"enabled\":true")) {
        return Some(ConfigConflict("autoReply", "legacy false conflicts with autoReply.enabled true"))
    }
    None<ConfigConflict>
}

public func classifyGcmMcpClientMode(config: MonitorConfig): GcmMcpClientMode {
    if (config.mcpEndpoint.trimAscii().isEmpty()) {
        return GcmMcpClientMode("disabled")
    }
    GcmMcpClientMode("diagnostic_legacy", endpointPresent: true)
}

public func renderGcmMcpLegacyNotice(mode: GcmMcpClientMode): String {
    if (mode.mode == "disabled") {
        return "MCP client disabled"
    }
    "GCM MCP client is diagnostic/legacy; main intelligent reply flow is Metis service plugin host"
}

func scanPayloadMode(payload: String): String {
    let parsed = parsePluginPayloadObject(payload)
    if (!parsed.ok) { return "" }
    let mode = pluginPayloadStringField(parsed.payloadObject, "mode", defaultValue: "")
    if (!mode.ok) { return "" }
    mode.value
}

func parseGcmJobIdPayload(payload: String): String {
    let parsed = parsePluginPayloadObject(payload)
    if (!parsed.ok) { return "" }
    let jobId = pluginPayloadStringField(parsed.payloadObject, "jobId", maxBytes: 128)
    if (!jobId.ok || !isGcmJobIdSafe(jobId.value)) { return "" }
    jobId.value
}

func parseWebhookDeliveryIdPayload(payload: String): String {
    let parsed = parsePluginPayloadObject(payload)
    if (!parsed.ok) { return "" }
    let deliveryId = pluginPayloadStringField(parsed.payloadObject, "deliveryId", maxBytes: 256)
    if (!deliveryId.ok || !isWebhookDeliveryIdSafe(deliveryId.value)) { return "" }
    deliveryId.value
}

func isWebhookDeliveryIdSafe(value: String): Bool {
    let id = value.trimAscii()
    if (id.isEmpty()) { return false }
    if (id.contains("/") || id.contains("\\") || id.contains("..") || id.contains(" ")) { return false }
    true
}

private func pluginArgValue(args: Array<String>, key: String): ?String {
    var index = 0
    while (index < args.size) {
        if (args[index] == key && index + 1 < args.size) {
            return Some(args[index + 1])
        }
        if (args[index].startsWith("${key}=")) {
            return Some(args[index].split("=", 2)[1])
        }
        index++
    }
    None<String>
}

private func eventPayload(event: GitCodeEvent, jobId!: String = ""): String {
    let jobPart = if (jobId.trimAscii().isEmpty()) { "" } else { "\"jobId\":\"${jsonEscape(jobId.trimAscii())}\"," }
    "{\"eventId\":\"${jsonEscape(event.id)}\",${jobPart}\"repo\":\"${jsonEscape(event.org)}/${jsonEscape(event.repo)}\",\"kind\":\"${jsonEscape(event.itemKind)}\",\"number\":\"${jsonEscape(event.itemId)}\",\"author\":\"${jsonEscape(event.actor)}\",\"url\":\"${jsonEscape(event.url)}\",\"title\":\"${jsonEscape(compactSummary(redactSecrets(scanEventTitle(event)), limit: 160))}\",\"content\":\"${jsonEscape(compactSummary(redactSecrets(event.content), limit: 500))}\"}"
}

const GCM_WRITEBACK_DRAFT_MAX_BYTES: Int64 = 32768

private func parseWritebackRequest(payload: String): GcmWritebackRequest {
    let parsed = parsePluginPayloadObject(payload, maxBytes: 65536)
    if (!parsed.ok) {
        return GcmWritebackRequest("", "", "", "", "", "", parseStatus: "invalid_payload")
    }
    let root = generatedReplyObjectForWriteback(parsed.payloadObject)
    let eventId = pluginPayloadStringField(root, "eventId")
    let repo = pluginPayloadStringField(root, "repo")
    let kind = pluginPayloadStringField(root, "kind")
    let number = pluginPayloadStringField(root, "number")
    let url = pluginPayloadStringField(root, "url")
    let draft = pluginPayloadStringField(root, "draft", maxBytes: 65536)
    let safety = pluginPayloadStringField(root, "safety", defaultValue: "approved")
    let needsHumanReview = pluginPayloadBoolField(root, "needsHumanReview", defaultValue: false)
    let duplicate = pluginPayloadBoolField(root, "duplicate", defaultValue: false)
    if (!eventId.ok || !repo.ok || !kind.ok || !number.ok || !url.ok || !draft.ok || !safety.ok || !needsHumanReview.ok || !duplicate.ok) {
        return GcmWritebackRequest("", "", "", "", "", "", parseStatus: "invalid_payload")
    }
    if (draft.value.size > GCM_WRITEBACK_DRAFT_MAX_BYTES) {
        return GcmWritebackRequest(eventId.value, repo.value, kind.value, number.value, url.value, "", parseStatus: "draft_too_large")
    }
    let maintainers = writebackMaintainerContext(parsed.payloadObject, root)
    GcmWritebackRequest(
        eventId.value,
        repo.value,
        kind.value,
        number.value,
        url.value,
        draft.value,
        safety: safety.value,
        needsHumanReview: needsHumanReview.value,
        duplicate: duplicate.value,
        teamLeaderMentions: maintainers.teamLeaderMentions,
        codeownerMentions: maintainers.codeownerMentions
    )
}

public class WritebackMaintainerContext {
    public let teamLeaderMentions: Array<String>
    public let codeownerMentions: Array<String>
    public init(teamLeaderMentions!: Array<String> = [], codeownerMentions!: Array<String> = []) {
        this.teamLeaderMentions = teamLeaderMentions
        this.codeownerMentions = codeownerMentions
    }
}

private func generatedReplyObjectForWriteback(root: JsonObject): JsonObject {
    match (root.get("generatedReply")) {
        case Some(value) =>
            try { return value.asObject() } catch (_: Exception) { () }
        case None => ()
    }
    root
}

public func writebackMaintainerContext(payloadRoot: JsonObject, replyRoot: JsonObject): WritebackMaintainerContext {
    let team = ArrayList<String>()
    let owners = ArrayList<String>()
    addJsonStringArray(team, replyRoot, "teamLeaders")
    addJsonStringArray(owners, replyRoot, "codeowners")
    addJsonStringArray(team, payloadRoot, "teamLeaders")
    addJsonStringArray(owners, payloadRoot, "codeowners")
    addMaintainersObject(team, owners, replyRoot)
    addMaintainersObject(team, owners, payloadRoot)
    match (payloadRoot.get("reviewRequest")) {
        case Some(value) =>
            try {
                let review = value.asObject()
                addMaintainersObject(team, owners, review)
            } catch (_: Exception) { () }
        case None => ()
    }
    WritebackMaintainerContext(teamLeaderMentions: sanitizeMentionList(team.toArray()), codeownerMentions: sanitizeMentionList(owners.toArray()))
}

private func addMaintainersObject(team: ArrayList<String>, owners: ArrayList<String>, root: JsonObject): Unit {
    match (root.get("maintainers")) {
        case Some(value) =>
            try {
                let obj = value.asObject()
                addJsonStringArray(team, obj, "teamLeaders")
                addJsonStringArray(team, obj, "teamLeaderMentions")
                addJsonStringArray(owners, obj, "codeowners")
                addJsonStringArray(owners, obj, "codeownerMentions")
            } catch (_: Exception) { () }
        case None => ()
    }
}

private func addJsonStringArray(out: ArrayList<String>, root: JsonObject, key: String): Unit {
    match (root.get(key)) {
        case Some(value) =>
            try {
                let text = value.asString().getValue()
                out.add(text)
                return
            } catch (_: Exception) { () }
            try {
                for (item in value.asArray().getItems()) {
                    try { out.add(item.asString().getValue()) } catch (_: Exception) { () }
                    try {
                        let obj = item.asObject()
                        let mention = firstJsonString(obj, ["mention", "login", "username", "name"])
                        if (!mention.isEmpty()) { out.add(mention) }
                    } catch (_: Exception) { () }
                }
            } catch (_: Exception) { () }
        case None => ()
    }
}

public func parsePluginPayloadObject(payload: String, maxBytes!: Int64 = 16384): PluginPayloadParseResult {
    let normalized = payload.trimAscii()
    if (normalized.size > maxBytes) {
        return PluginPayloadParseResult(false, "invalid_payload", diagnostic: "payload_too_large")
    }
    if (normalized.isEmpty()) {
        return PluginPayloadParseResult(true, "ok", payloadObject: JsonObject())
    }
    let root = try {
        JsonValue.fromStr(normalized).asObject()
    } catch (_: Exception) {
        return PluginPayloadParseResult(false, "invalid_payload", diagnostic: "payload must be a JSON object")
    }
    PluginPayloadParseResult(true, "ok", payloadObject: root)
}

public func pluginPayloadBoolField(root: JsonObject, key: String, defaultValue!: Bool = false): PluginPayloadBoolResult {
    match (root.get(key)) {
        case Some(value) =>
            let raw = value.toJsonString().trimAscii()
            if (raw == "true") {
                return PluginPayloadBoolResult(true, "ok", value: true)
            }
            if (raw == "false") {
                return PluginPayloadBoolResult(true, "ok", value: false)
            }
            PluginPayloadBoolResult(false, "invalid_payload", diagnostic: "field ${key} must be bool")
        case None => PluginPayloadBoolResult(true, "ok", value: defaultValue)
    }
}

public func pluginPayloadStringField(root: JsonObject, key: String, defaultValue!: String = "", maxBytes!: Int64 = 4096): PluginPayloadStringResult {
    match (root.get(key)) {
        case Some(value) =>
            let text = try {
                value.asString().getValue()
            } catch (_: Exception) {
                return PluginPayloadStringResult(false, "invalid_payload", diagnostic: "field ${key} must be string")
            }
            if (text.size > maxBytes) {
                return PluginPayloadStringResult(false, "invalid_payload", diagnostic: "field ${key} exceeds ${maxBytes} bytes")
            }
            PluginPayloadStringResult(true, "ok", value: text)
        case None => PluginPayloadStringResult(true, "ok", value: defaultValue)
    }
}

private func gcmPluginResponseFrame(request: ServiceFrame, ok: Bool, status: String, payload: String): ServiceFrame {
    let normalizedPayload = if (payload.trimAscii().isEmpty()) {
        "{\"ok\":${ok},\"status\":\"${jsonEscape(status)}\"}"
    } else {
        payload
    }
    ServiceFrame(
        "response",
        "response-${request.frameId}",
        GCM_SERVICE_PLUGIN_ID,
        method: request.method,
        capabilityId: request.capabilityId,
        correlationId: request.correlationId,
        payload: normalizedPayload
    )
}

private func gcmPluginErrorFrame(frameId: String, correlationId: String, status: String, diagnostic: String): ServiceFrame {
    ServiceFrame(
        "response",
        frameId,
        GCM_SERVICE_PLUGIN_ID,
        method: "invokeCapability",
        correlationId: correlationId,
        payload: "{\"ok\":false,\"status\":\"${jsonEscape(status)}\",\"diagnostic\":\"${jsonEscape(diagnostic)}\"}"
    )
}

private func gcmScanOncePayload(result: GcmScanOnceResult, saved!: Bool = true): String {
    let status = if (saved) { result.status } else { "state_save_failed" }
    "{\"ok\":${result.ok && saved},\"status\":\"${status}\",\"accepted\":${result.accepted},\"ignored\":${result.ignored},\"emitted\":${result.emitted},\"stateSaved\":${saved}}"
}

private func gitCodeAuthPresentForPlugin(config: MonitorConfig): Bool {
    !config.gitCodeToken.isEmpty() || !config.gitCodeCookie.isEmpty() || (!config.gitCodeUsername.isEmpty() && !config.gitCodePassword.isEmpty())
}

private func pluginJoin(items: Array<String>, separator: String): String {
    var out = ""
    for (item in items) {
        if (out.isEmpty()) {
            out = item
        } else {
            out += separator + item
        }
    }
    out
}
