package gitcodemonitor

import std.collection.ArrayList
import std.fs.{Path, exists}

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

    public init(
        ok: Bool,
        status: String,
        serviceId!: String = GCM_SERVICE_PLUGIN_ID,
        protocolVersion!: String = GCM_SERVICE_PROTOCOL_VERSION,
        capabilities!: ArrayList<ServiceCapabilityRecord> = ArrayList<ServiceCapabilityRecord>(),
        diagnostic!: String = ""
    ) {
        this.ok = ok
        this.status = status
        this.serviceId = serviceId
        this.protocolVersion = protocolVersion
        this.capabilities = capabilities
        this.diagnostic = diagnostic
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
    public let legacyNotificationAuth: String
    public init(gitCodeAuth: String, mcpAuth: String, legacyNotificationAuth: String) {
        this.gitCodeAuth = gitCodeAuth
        this.mcpAuth = mcpAuth
        this.legacyNotificationAuth = legacyNotificationAuth
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
    public let writer: FakeCommentWriter
    public init(config: MonitorConfig, state!: MonitorState = MonitorState(), writer!: FakeCommentWriter = FakeCommentWriter()) {
        this.config = config
        this.state = state
        this.writer = writer
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

    public init(
        eventId: String,
        repo: String,
        kind: String,
        number: String,
        url: String,
        draft: String,
        safety!: String = "approved",
        needsHumanReview!: Bool = false,
        duplicate!: Bool = false
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
    public init(ok: Bool, decision: GcmWritebackDecision, writerCalled!: Bool = false, replyUrl!: String = "") {
        this.ok = ok
        this.decision = decision
        this.writerCalled = writerCalled
        this.replyUrl = replyUrl
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

public class LegacyNotificationConfigSummary {
    public let hasFeishuWebhook: Bool
    public let hasTelegramChatId: Bool
    public let status: String
    public init(hasFeishuWebhook: Bool, hasTelegramChatId: Bool, status: String) {
        this.hasFeishuWebhook = hasFeishuWebhook
        this.hasTelegramChatId = hasTelegramChatId
        this.status = status
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

public func gcmPluginMain(args: Array<String>): Int64 {
    let configRef = pluginArgValue(args, "--config") ?? pluginArgValue(args, "configRef") ?? defaultConfigPath()
    let initResult = initializeGcmPlugin(ServiceInitializeRequest(GCM_SERVICE_PROTOCOL_VERSION, configRef: configRef, hostApis: ["host.agent.invoke", "host.audit.append"]))
    if (!initResult.ok) {
        println(encodeServiceFrame(ServiceFrame("response", "initialize", GCM_SERVICE_PLUGIN_ID, method: "initialize", payload: "{\"ok\":false,\"status\":\"${initResult.status}\"}")).trimAscii())
        return 2
    }
    println(encodeServiceFrame(ServiceFrame("response", "initialize", GCM_SERVICE_PLUGIN_ID, method: "initialize", payload: "{\"ok\":true,\"status\":\"${initResult.status}\",\"capabilities\":${initResult.capabilities.size}}")).trimAscii())
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
    let caps = buildGitCodeMonitorCapabilities(loaded.config)
    let check = validateGitCodeMonitorCapabilitySet(caps)
    ServiceInitializeResult(check.ok, if (check.ok) { "ok" } else { "capability_degraded" }, capabilities: caps, diagnostic: pluginJoin(check.diagnostics, ","))
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
    SecretStateSummary(if (gitCodeAuthPresentForPlugin(config)) { "present" } else { "absent" }, if (config.mcpServiceToken.isEmpty()) { "absent" } else { "present" }, if (config.feishuWebhook.isEmpty() && config.telegramChatId.isEmpty() && config.telegramBotToken.isEmpty()) { "absent" } else { "legacy_present" })
}

public func buildGitCodeMonitorCapabilities(config: MonitorConfig): ArrayList<ServiceCapabilityRecord> {
    buildGitCodeMonitorCapabilityDeclarations()
}

public func handleGcmStatusCapability(payload: String, runtime: GcmRuntime): GcmStatusResult {
    let secret = summarizeGcmSecretState(runtime.config)
    GcmStatusResult(true, "running", summary: "dryRun=${runtime.config.dryRun} autoReply=${runtime.config.autoReply} gitCodeAuth=${secret.gitCodeAuth} legacyNotify=${secret.legacyNotificationAuth} seen=${runtime.state.seenCount()}")
}

public func handleGcmScanOnceCapability(payload: String, runtime: GcmRuntime): GcmScanOnceResult {
    if (payload.contains("\"overlap\":true")) {
        runtime.state.skippedOverlappingScans++
        return GcmScanOnceResult(true, "skipped_overlap")
    }
    let result = scanOnceOfflineFixture(runtime.config, runtime.state)
    GcmScanOnceResult(true, "ok", accepted: result.accepted, ignored: result.ignored, emitted: result.accepted + result.ignored)
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
    let request = parseWritebackRequest(payload)
    let decision = evaluateGcmAutoReplyGate(request, runtime.config)
    if (!decision.allowed) {
        let _ = emitGcmWritebackAudit(buildGcmWritebackAudit(request, decision, replyUrl: ""), MetisHostClient())
        return GcmWritebackApplyResult(true, decision)
    }
    let event = GitCodeEvent(request.eventId, request.repo.split("/", 2)[0], if (request.repo.contains("/")) { request.repo.split("/", 2)[1] } else { request.repo }, request.kind, request.number, "metis", "", request.url, request.draft)
    let replyUrl = runtime.writer.write(event, appendGcmSelfMarker(request.draft), runtime.state)
    GcmWritebackApplyResult(true, decision, writerCalled: true, replyUrl: replyUrl)
}

public func evaluateGcmAutoReplyGate(request: GcmWritebackRequest, config: MonitorConfig): GcmWritebackDecision {
    if (!config.autoReply) { return GcmWritebackDecision(false, "auto_reply_disabled") }
    if (config.dryRun) { return GcmWritebackDecision(false, "dry_run") }
    if (!pluginRepoAllowlisted(config.repoAllowlist, request.repo)) { return GcmWritebackDecision(false, "repo_not_allowlisted") }
    let safety = request.safety.toAsciiLower()
    if (safety != "approved" && safety != "safe") { return GcmWritebackDecision(false, "safety_rejected") }
    if (request.needsHumanReview) { return GcmWritebackDecision(false, "needs_human_review") }
    if (request.duplicate) { return GcmWritebackDecision(false, "duplicate") }
    if (hasGcmSelfMarker(request.draft)) { return GcmWritebackDecision(false, "self_marker") }
    if (containsSecret(request.draft)) { return GcmWritebackDecision(false, "secret_detected") }
    if (containsLocalPath(request.draft)) { return GcmWritebackDecision(false, "local_path_detected") }
    GcmWritebackDecision(true, "allow_write")
}

public func emitGcmWritebackAudit(audit: GcmWritebackAudit, host: MetisHostClient): HostEmitResult {
    let frame = ServiceFrame("event", "writeback-${audit.eventId}", GCM_SERVICE_PLUGIN_ID, method: "emitCapabilityEvent", capabilityId: "gitcode.writeback.audit", payload: "{\"eventId\":\"${audit.eventId}\",\"decision\":\"${audit.decision}\",\"bodyHash\":\"${audit.bodyHash}\",\"replyUrl\":\"${audit.replyUrl}\"}")
    host.emit(frame)
}

public func buildGitCodeCommentWriteRequest(request: GcmWritebackRequest): GitCodeCommentWriteRequest {
    GitCodeCommentWriteRequest(request.repo, request.kind, request.number, appendGcmSelfMarker(request.draft))
}

public func appendGcmSelfMarker(body: String): String {
    if (hasGcmSelfMarker(body)) { return body }
    body + "\n\n" + SELF_MARKER
}

public func hasGcmSelfMarker(body: String): Bool {
    body.contains(SELF_MARKER)
}

public func buildGcmWritebackAudit(request: GcmWritebackRequest, decision: GcmWritebackDecision, replyUrl!: String = ""): GcmWritebackAudit {
    GcmWritebackAudit(request.eventId, decision.reason, hashRawPayload(request.draft), replyUrl: replyUrl)
}

public func classifyGcmLegacyNotificationConfig(config: MonitorConfig): LegacyNotificationConfigSummary {
    let hasFeishu = !config.feishuWebhook.trimAscii().isEmpty()
    let hasTelegram = !config.telegramBotToken.trimAscii().isEmpty() || !config.telegramChatId.trimAscii().isEmpty()
    LegacyNotificationConfigSummary(hasFeishu, hasTelegram, if (hasFeishu || hasTelegram) { "legacy_present" } else { "absent" })
}

public func renderLegacyNotificationWarning(summary: LegacyNotificationConfigSummary): String {
    if (summary.status == "absent") {
        return "legacy notification config absent"
    }
    "legacy notification config detected; plugin mode delivers Telegram/Feishu notifications through Metis Gateway subscriptions"
}

public func validateGcmPluginModeConfig(config: MonitorConfig): GcmConfigValidationResult {
    let diagnostics = ArrayList<String>()
    if (config.gitCodeBaseUrl.trimAscii().isEmpty()) { diagnostics.add("gitcode.baseUrl missing") }
    if (config.statePath.trimAscii().isEmpty()) { diagnostics.add("statePath missing") }
    if (config.fullScanIntervalMinutes < 5) { diagnostics.add("fullScanIntervalMinutes below production minimum") }
    if (!config.dryRun && config.autoReply && config.repoAllowlist.size == 0) { diagnostics.add("repoAllowlist required for live autoReply") }
    GcmConfigValidationResult(diagnostics.size == 0, diagnostics: diagnostics.toArray())
}

public func summarizeGcmPluginModeConfig(config: MonitorConfig): GcmConfigSummary {
    let secret = summarizeGcmSecretState(config)
    GcmConfigSummary("orgs=${config.orgs.size} dryRun=${config.dryRun} autoReply=${config.autoReply} gitCodeAuth=${secret.gitCodeAuth} mcpAuth=${secret.mcpAuth} legacyNotify=${secret.legacyNotificationAuth} statePath=${redactServicePayload(config.statePath).text}")
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

private func eventPayload(event: GitCodeEvent): String {
    "{\"eventId\":\"${event.id}\",\"repo\":\"${event.org}/${event.repo}\",\"kind\":\"${event.itemKind}\",\"number\":\"${event.itemId}\",\"author\":\"${event.actor}\",\"url\":\"${event.url}\",\"content\":\"${jsonEscape(compactSummary(redactSecrets(event.content), limit: 500))}\"}"
}

private func parseWritebackRequest(payload: String): GcmWritebackRequest {
    GcmWritebackRequest(
        pluginFieldValue(payload, "eventId"),
        pluginFieldValue(payload, "repo"),
        pluginFieldValue(payload, "kind"),
        pluginFieldValue(payload, "number"),
        pluginFieldValue(payload, "url"),
        pluginFieldValue(payload, "draft"),
        safety: pluginFieldValue(payload, "safety"),
        needsHumanReview: payload.contains("\"needsHumanReview\":true"),
        duplicate: payload.contains("\"duplicate\":true")
    )
}

private func pluginFieldValue(raw: String, key: String): String {
    let needle = "\"${key}\":\""
    if (!raw.contains(needle)) { return "" }
    raw.split(needle, 2)[1].split("\"", 2)[0]
}

private func pluginRepoAllowlisted(allowlist: Array<String>, repo: String): Bool {
    let normalized = repo.trimAscii().toAsciiLower()
    for (entry in allowlist) {
        if (entry.trimAscii().toAsciiLower() == normalized) {
            return true
        }
    }
    false
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
