package gitcodemonitor

import std.collection.*
import std.convert.Parsable
import std.env.getVariable
import std.fs.{Directory, File, Path, exists}
import std.process.executeWithOutput
import std.time.*
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}
import stdx.encoding.url.URL
import stdx.net.http.*
import stdx.net.tls.*

public let SELF_MARKER = "<!-- gitcodemonitor:auto-reply:v1 -->"
public const DEFAULT_MAX_AUDIT_RECORDS: Int64 = 1000

public class AuthorPolicyConfig {
    public var recordOnlyEnabled: Bool
    public var recordOnlyEmailDomains: Array<String>
    public var unknownEmailDecision: String

    public init(
        recordOnlyEnabled!: Bool = true,
        recordOnlyEmailDomains!: Array<String> = [],
        unknownEmailDecision!: String = "process"
    ) {
        this.recordOnlyEnabled = recordOnlyEnabled
        this.recordOnlyEmailDomains = recordOnlyEmailDomains
        this.unknownEmailDecision = unknownEmailDecision
    }
}

public class WritebackScopeConfig {
    public var allowedOrgs: Array<String>
    public var allowedRepos: Array<String>
    public var deniedRepos: Array<String>

    public init(
        allowedOrgs!: Array<String> = [],
        allowedRepos!: Array<String> = [],
        deniedRepos!: Array<String> = []
    ) {
        this.allowedOrgs = allowedOrgs
        this.allowedRepos = allowedRepos
        this.deniedRepos = deniedRepos
    }
}

public class MonitorConfig {
    public var orgs: Array<String>
    public var fullScanIntervalMinutes: Int64
    public var minProduction: Int64
    public var jitterSeconds: Int64
    public var dryRun: Bool
    public var autoReply: Bool
    public var acpEnabled: Bool
    public var repoAllowlist: Array<String>
    public var writebackScope: WritebackScopeConfig
    public var acpEndpoint: String
    public var acpServiceToken: String
    public var acpAllowedTasks: Array<String>
    public var gitCodeBaseUrl: String
    public var gitCodeAuthMode: String
    public var gitCodeToken: String
    public var gitCodeCookie: String
    public var gitCodeUsername: String
    public var gitCodePassword: String
    public var httpTransport: String
    public var mcpEndpoint: String
    public var mcpServiceToken: String
    public var statePath: String
    public var authorPolicy: AuthorPolicyConfig
    public var webhook: WebhookReceiverConfig

    public init() {
        this.orgs = ["cangjie", "cangjie-sig", "cangjie-tpc"]
        this.fullScanIntervalMinutes = 10
        this.minProduction = 5
        this.jitterSeconds = 30
        this.dryRun = true
        this.autoReply = false
        this.acpEnabled = false
        this.repoAllowlist = []
        this.writebackScope = WritebackScopeConfig()
        this.acpEndpoint = ""
        this.acpServiceToken = ""
        this.acpAllowedTasks = []
        this.gitCodeBaseUrl = "https://api.gitcode.com/api/v5"
        this.gitCodeAuthMode = "PRIVATE-TOKEN"
        this.gitCodeToken = ""
        this.gitCodeCookie = ""
        this.gitCodeUsername = ""
        this.gitCodePassword = ""
        this.httpTransport = "native"
        this.mcpEndpoint = ""
        this.mcpServiceToken = ""
        this.statePath = ".gitcodemonitor/state.json"
        this.authorPolicy = AuthorPolicyConfig()
        this.webhook = defaultWebhookReceiverConfigForStatePath(this.statePath)
    }
}

public func defaultConfig(): MonitorConfig {
    MonitorConfig()
}

public func defaultConfigPath(): String {
    match (getVariable("HOME")) {
        case Some(home) => Path(home).join(".metis").join("metis.json").toString()
        case None => ".metis/metis.json"
    }
}

public func loadConfig(path!: String = defaultConfigPath()): MonitorConfig {
    let config = defaultConfig()
    if (!exists(Path(path))) { return config }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(Path(path)))).asObject()
        applyConfigObject(config, root)
    } catch (_: Exception) {
        ()
    }
    config
}

public func validateConfig(config: MonitorConfig): String {
    if (config.fullScanIntervalMinutes < config.minProduction) {
        return "fullScanIntervalMinutes below production minimum"
    }
    if (config.jitterSeconds > 30) {
        return "jitter exceeds 30 seconds"
    }
    if (config.acpEnabled && (config.acpEndpoint.isEmpty() || config.acpServiceToken.isEmpty() || config.acpAllowedTasks.size == 0)) {
        return "acp enabled but endpoint/token/allowedTasks missing"
    }
    let scopeDiagnostics = validateWritebackScopeConfig(config.writebackScope, config.repoAllowlist)
    if (scopeDiagnostics.size > 0) {
        return "writebackScope ${scopeDiagnostics[0]}"
    }
    if (!config.dryRun && config.autoReply && !writebackScopeHasAllow(config)) {
        return "writeback enabled but writebackScope has no allowed orgs or repos"
    }
    let authorPolicyValidation = validateAuthorPolicyConfig(config.authorPolicy)
    if (authorPolicyValidation != "ok") {
        return "authorPolicy ${authorPolicyValidation}"
    }
    let webhookValidation = validateWebhookReceiverConfig(config.webhook)
    if (!webhookValidation.ok) {
        return "webhook ${webhookValidation.status}"
    }
    return "ok"
}

public func validateWritebackScopeConfig(scope: WritebackScopeConfig, legacyRepos: Array<String>): Array<String> {
    let diagnostics = ArrayList<String>()
    for (org in scope.allowedOrgs) {
        if (!writebackOrgScopeIsValid(org)) {
            diagnostics.add("invalid org scope: ${org.trimAscii()}")
        }
    }
    for (repo in scope.allowedRepos) {
        if (!writebackRepoScopeIsValid(repo)) {
            diagnostics.add("invalid repo scope: ${repo.trimAscii()}")
        }
    }
    for (repo in scope.deniedRepos) {
        if (!writebackRepoScopeIsValid(repo)) {
            diagnostics.add("invalid repo scope: ${repo.trimAscii()}")
        }
    }
    for (repo in legacyRepos) {
        if (!writebackRepoScopeIsValid(repo)) {
            diagnostics.add("invalid repo scope: ${repo.trimAscii()}")
        }
    }
    diagnostics.toArray()
}

public func writebackScopeSummary(config: MonitorConfig): String {
    "writebackScope=allowedOrgs=${config.writebackScope.allowedOrgs.size} allowedRepos=${config.writebackScope.allowedRepos.size} deniedRepos=${config.writebackScope.deniedRepos.size} legacyRepoAllowlist=${config.repoAllowlist.size}"
}

public func configSummary(config: MonitorConfig): String {
    let auth = if (gitCodeAuthPresent(config)) { "present" } else { "absent" }
    "GitCodeMonitor config\n" +
        "orgs=${joinStrings(config.orgs, ",")}\n" +
        "gitCodeBaseUrl=${config.gitCodeBaseUrl}\n" +
        "transport=${configuredHttpTransport(config)}\n" +
        "gitCodeAuth=${config.gitCodeAuthMode}:${auth}\n" +
        "dryRun=${config.dryRun}\n" +
        "autoReply=${config.autoReply}\n" +
        "${writebackScopeSummary(config)}\n" +
        "allowlist=${joinStrings(config.repoAllowlist, ",")}\n" +
        "recordOnlyEnabled=${config.authorPolicy.recordOnlyEnabled}\n" +
        "recordOnlyDomainCount=${config.authorPolicy.recordOnlyEmailDomains.size}\n" +
        "recordOnlyEffective=${authorPolicyRecordOnlyEffective(config.authorPolicy)}\n" +
        "statePath=${config.statePath}\n" +
        webhookConfigSummary(config.webhook)
}

public func authorPolicyRecordOnlyEffective(policy: AuthorPolicyConfig): Bool {
    policy.recordOnlyEnabled && policy.recordOnlyEmailDomains.size > 0
}

public class GitCodeEvent {
    public let id: String
    public let org: String
    public let repo: String
    public let itemKind: String
    public let itemId: String
    public let actor: String
    public let actorUrl: String
    public let url: String
    public let content: String
    public let updatedAtMs: Int64

    public init(id: String, org: String, repo: String, itemKind: String, itemId: String, actor: String, actorUrl: String, url: String, content: String, updatedAtMs!: Int64 = 0) {
        this.id = id
        this.org = org
        this.repo = repo
        this.itemKind = itemKind
        this.itemId = itemId
        this.actor = actor
        this.actorUrl = actorUrl
        this.url = url
        this.content = content
        this.updatedAtMs = updatedAtMs
    }
}

public class FilterDecision {
    public let ignored: Bool
    public let reason: String

    public init(ignored: Bool, reason: String) {
        this.ignored = ignored
        this.reason = reason
    }
}

public func filterEvent(event: GitCodeEvent): FilterDecision {
    let actor = event.actor.trimAscii().toAsciiLower()
    let actorUrl = event.actorUrl.trimAscii().toAsciiLower()
    if (actor == "cangjiepl" || actorUrl == "https://gitcode.com/cangjiepl" || actorUrl == "https://gitcode.com/cangjiepl/") {
        return FilterDecision(true, "CangjiePL")
    }
    if (event.content.trimAscii() == "start build") {
        return FilterDecision(true, "start_build")
    }
    if (event.content.contains(SELF_MARKER)) {
        return FilterDecision(true, "self_marker")
    }
    return FilterDecision(false, "accepted")
}

public func containsSecret(text: String): Bool {
    detectSecretKinds(text).size > 0
}

public func detectSecretKinds(text: String): Array<String> {
    let lower = text.toAsciiLower()
    let out = ArrayList<String>()
    if (lower.contains("authorization:") || lower.contains("authorization=") || lower.contains("bearer ")) {
        out.add("Authorization")
    }
    if (lower.contains("private-token") || lower.contains("access_token=") || lower.contains("token=") || lower.contains("api_token") || lower.contains("gitcode_token")) {
        out.add("token")
    }
    if (lower.contains("cookie:") || lower.contains("cookie=")) {
        out.add("cookie")
    }
    if (lower.contains("password=") || lower.contains("\"password\"") || lower.contains("password:")) {
        out.add("password")
    }
    if (looksLikeTelegramBotToken(text)) {
        out.add("bot_token")
    }
    return out.toArray()
}

public func redactSecrets(text: String): String {
    if (containsSecret(text)) {
        return "[REDACTED]"
    }
    text
}

public func jsonEscape(raw: String): String {
    raw.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
}

public func truncateRunes(text: String, maxRunes: Int64): String {
    if (maxRunes <= 0) { return "" }
    let runes = text.toRuneArray()
    if (runes.size <= maxRunes) { return text }
    String(runes[0..maxRunes])
}

public func compactSummary(raw: String, limit!: Int64 = 280): String {
    let t = raw.trimAscii().replace("\n", " ").replace("\r", " ")
    if (limit <= 0) {
        return if (t.isEmpty()) { "" } else { "..." }
    }
    if (t.toRuneArray().size <= limit) { return t }
    truncateRunes(t, limit) + "..."
}

func looksLikeTelegramBotToken(text: String): Bool {
    var digits = 0
    var seenColon = false
    var suffix = 0
    for (r in text.runes()) {
        if (!seenColon) {
            if (r >= r'0' && r <= r'9') {
                digits++
            } else if (r == r':' && digits >= 6) {
                seenColon = true
            } else {
                digits = 0
            }
        } else {
            if ((r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') || (r >= r'0' && r <= r'9') || r == r'_' || r == r'-') {
                suffix++
                if (suffix >= 20) {
                    return true
                }
            } else {
                seenColon = false
                digits = 0
                suffix = 0
            }
        }
    }
    false
}

public class AuditRecord {
    public let eventId: String
    public var status: String
    public var reason: String
    public var requestId: String
    public var replyUrl: String
    public var draft: String
    public var safety: String
    public var deliveryStatus: String
    public var writeDecision: String

    public init(eventId: String, status!: String = "pending", reason!: String = "") {
        this.eventId = eventId
        this.status = status
        this.reason = reason
        this.requestId = "req-" + eventId
        this.replyUrl = ""
        this.draft = ""
        this.safety = ""
        this.deliveryStatus = "pending"
        this.writeDecision = ""
    }
}

public class MonitorState {
    private let seenEvents = HashSet<String>()
    private let mcpCalled = HashSet<String>()
    private let replied = HashSet<String>()
    private let backoff = HashMap<String, Int64>()
    private let baselineScopes = HashSet<String>()
    private let baselineCounts = HashMap<String, Int64>()
    private var changeVersion: Int64 = 0
    private var lastCoalescedAuditKey: String = ""
    public let audit = ArrayList<AuditRecord>()
    public var lastFullScanAtMs: Int64 = 0
    public var skippedOverlappingScans: Int64 = 0
    public var baselineCreatedAtMs: Int64 = 0
    public var transientAuditCount: Int64 = 0
    public var duplicateAuditSuppressedCount: Int64 = 0

    public init() {}

    public func version(): Int64 { changeVersion }
    public func touch(): Unit { changeVersion++ }
    public func resetVersion(): Unit { changeVersion = 0 }
    public func hasSeen(eventId: String): Bool { seenEvents.contains(eventId) }
    public func markSeen(eventId: String): Unit {
        let id = eventId.trimAscii()
        if (id.isEmpty() || seenEvents.contains(id)) { return }
        seenEvents.add(id)
        touch()
    }
    public func hasBaseline(scopeKey: String): Bool { baselineScopes.contains(scopeKey) }
    public func markBaseline(scopeKey: String, seededEvents: Int64): Unit {
        let key = scopeKey.trimAscii()
        if (key.isEmpty()) { return }
        let normalizedCount = if (seededEvents < 0) { 0 } else { seededEvents }
        var changed = false
        if (!baselineScopes.contains(key)) {
            baselineScopes.add(key)
            changed = true
        }
        if ((baselineCounts.get(key) ?? -1) != normalizedCount) {
            baselineCounts[key] = normalizedCount
            changed = true
        }
        if (baselineCreatedAtMs == 0) {
            baselineCreatedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
            changed = true
        }
        if (changed) { touch() }
    }
    public func hasMcpCall(eventId: String): Bool { mcpCalled.contains(eventId) }
    public func markMcpCall(eventId: String): Unit {
        let id = eventId.trimAscii()
        if (id.isEmpty() || mcpCalled.contains(id)) { return }
        mcpCalled.add(id)
        touch()
    }
    public func hasReply(eventId: String): Bool { replied.contains(eventId) }
    public func markReply(eventId: String): Unit {
        let id = eventId.trimAscii()
        if (id.isEmpty() || replied.contains(id)) { return }
        replied.add(id)
        touch()
    }
    public func addAudit(record: AuditRecord): Unit {
        audit.add(record)
        while (audit.size > DEFAULT_MAX_AUDIT_RECORDS) {
            audit.remove(at: 0)
        }
        touch()
    }
    public func addAuditTransient(record: AuditRecord): Unit {
        let _ = record
        transientAuditCount++
    }
    public func addAuditCoalesced(record: AuditRecord): Unit {
        let key = "${record.eventId}:${record.status}:${record.reason}"
        if (key == lastCoalescedAuditKey) {
            duplicateAuditSuppressedCount++
        } else {
            lastCoalescedAuditKey = key
            duplicateAuditSuppressedCount++
        }
    }
    public func seenCount(): Int64 { seenEvents.size }
    public func baselineScopeCount(): Int64 { baselineScopes.size }
    public func baselineSeenCount(scopeKey: String): Int64 { baselineCounts.get(scopeKey) ?? 0 }
    public func mcpCallCount(): Int64 { mcpCalled.size }
    public func replyCount(): Int64 { replied.size }
    public func setBackoff(key: String, untilMs: Int64): Unit {
        let normalized = key.trimAscii()
        if (normalized.isEmpty()) { return }
        if ((backoff.get(normalized) ?? -1) == untilMs) { return }
        backoff[normalized] = untilMs
        touch()
    }
    public func backoffUntil(key: String): Int64 { backoff.get(key) ?? 0 }
    public func seenIds(): Array<String> {
        let out = ArrayList<String>()
        for (id in seenEvents) { out.add(id) }
        out.toArray()
    }
    public func mcpCallIds(): Array<String> {
        let out = ArrayList<String>()
        for (id in mcpCalled) { out.add(id) }
        out.toArray()
    }
    public func replyIds(): Array<String> {
        let out = ArrayList<String>()
        for (id in replied) { out.add(id) }
        out.toArray()
    }
    public func backoffKeys(): Array<String> {
        let out = ArrayList<String>()
        for ((key, _) in backoff) { out.add(key) }
        out.toArray()
    }
    public func baselineScopeIds(): Array<String> {
        let out = ArrayList<String>()
        for (id in baselineScopes) { out.add(id) }
        out.toArray()
    }
}

public class StateSaveResult {
    public let saved: Bool
    public let skipped: Bool
    public let status: String
    public let durationMs: Int64
    public let bytes: Int64
    public let diagnostic: String

    public init(saved: Bool, skipped: Bool, status: String, durationMs!: Int64 = 0, bytes!: Int64 = 0, diagnostic!: String = "") {
        this.saved = saved
        this.skipped = skipped
        this.status = status.trimAscii()
        this.durationMs = durationMs
        this.bytes = bytes
        this.diagnostic = diagnostic.trimAscii()
    }
}

public class StateStore {
    public let path: Path
    public var loadDegraded: Bool = false
    public var lastSaveStatus: String = "not_started"
    public var lastSaveStartedAtMs: Int64 = 0
    public var lastSaveDurationMs: Int64 = 0
    public var lastSaveBytes: Int64 = 0
    public var lastSaveSkippedReason: String = ""
    public var lastSaveDiagnostic: String = ""
    public init(path: String) { this.path = Path(path) }

    public func save(state: MonitorState): Bool {
        this.writeState(state).saved
    }

    public func saveIfChanged(state: MonitorState, sinceVersion: Int64, reason!: String = "unchanged"): StateSaveResult {
        if (state.version() == sinceVersion) {
            let normalized = reason.trimAscii()
            if (normalized == "duplicate_only") {
                return this.markSaveSkipped("skipped_duplicate_only", normalized)
            }
            return this.markSaveSkipped("skipped_unchanged", if (normalized.isEmpty()) { "unchanged" } else { normalized })
        }
        this.writeState(state)
    }

    public func markSaveSkipped(status: String, reason: String): StateSaveResult {
        this.lastSaveStatus = status.trimAscii()
        this.lastSaveStartedAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        this.lastSaveDurationMs = 0
        this.lastSaveBytes = 0
        this.lastSaveSkippedReason = reason.trimAscii()
        this.lastSaveDiagnostic = ""
        StateSaveResult(false, true, this.lastSaveStatus)
    }

    private func writeState(state: MonitorState): StateSaveResult {
        let started = DateTime.now().toUnixTimeStamp().toMilliseconds()
        this.lastSaveStartedAtMs = started
        this.lastSaveSkippedReason = ""
        try {
            let parent = path.parent
            if (!exists(parent)) { Directory.create(parent, recursive: true) }
            let bytes = stateToJson(state).toJsonString().toArray()
            File.writeTo(path, bytes)
            let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
            this.lastSaveStatus = "saved"
            this.lastSaveDurationMs = if (ended >= started) { ended - started } else { 0 }
            this.lastSaveBytes = bytes.size
            this.lastSaveDiagnostic = ""
            StateSaveResult(true, false, "saved", durationMs: this.lastSaveDurationMs, bytes: this.lastSaveBytes)
        } catch (e: Exception) {
            let ended = DateTime.now().toUnixTimeStamp().toMilliseconds()
            this.lastSaveStatus = "state_save_failed"
            this.lastSaveDurationMs = if (ended >= started) { ended - started } else { 0 }
            this.lastSaveBytes = 0
            this.lastSaveDiagnostic = hashRawPayload(e.message)
            StateSaveResult(false, false, "state_save_failed", durationMs: this.lastSaveDurationMs, diagnostic: this.lastSaveDiagnostic)
        }
    }

    public func load(): MonitorState {
        let state = MonitorState()
        loadDegraded = false
        if (!exists(path)) { return state }
        try {
            let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            state.lastFullScanAtMs = readJsonInt(root, "lastFullScanAtMs")
            state.skippedOverlappingScans = readJsonInt(root, "skippedOverlappingScans")
            for (id in readJsonStringArray(root, "seenEvents")) { state.markSeen(id) }
            state.baselineCreatedAtMs = readJsonInt(root, "baselineCreatedAtMs")
            match (root.get("baselineScopes")) {
                case Some(value) =>
                    try {
                        for (item in value.asArray().getItems()) {
                            try {
                                let obj = item.asObject()
                                let scopeKey = readJsonString(obj, "scopeKey")
                                if (!scopeKey.isEmpty()) {
                                    state.markBaseline(scopeKey, readJsonInt(obj, "seededEvents"))
                                }
                            } catch (_inner: Exception) { () }
                        }
                    } catch (_inner: Exception) { () }
                case None => ()
            }
            for (id in readJsonStringArray(root, "mcpCalled")) { state.markMcpCall(id) }
            for (id in readJsonStringArray(root, "replied")) { state.markReply(id) }
            match (root.get("backoff")) {
                case Some(value) =>
                    for (item in value.asArray().getItems()) {
                        let obj = item.asObject()
                        state.setBackoff(readJsonString(obj, "key"), readJsonInt(obj, "untilMs"))
                    }
                case None => ()
            }
            match (root.get("audit")) {
                case Some(value) =>
                    for (rowValue in value.asArray().getItems()) {
                        let row = rowValue.asObject()
                        let audit = AuditRecord(readJsonString(row, "eventId"), status: readJsonString(row, "status"), reason: readJsonString(row, "reason"))
                        audit.requestId = readJsonString(row, "requestId")
                        audit.replyUrl = readJsonString(row, "replyUrl")
                        audit.draft = readJsonString(row, "draft")
                        audit.safety = readJsonString(row, "safety")
                        audit.deliveryStatus = readJsonString(row, "deliveryStatus")
                        audit.writeDecision = readJsonString(row, "writeDecision")
                        state.addAudit(audit)
                    }
                case None => ()
            }
            state.resetVersion()
        } catch (_: Exception) {
            loadDegraded = true
            try {
                let backup = Path(path.toString() + ".corrupt")
                if (!exists(backup)) { File.writeTo(backup, File.readFrom(path)) }
            } catch (_inner: Exception) { () }
            state.addAudit(AuditRecord("state-load", status: "state_error", reason: "corrupt_or_unreadable"))
        }
        state
    }
}

public func stateToJson(state: MonitorState): JsonObject {
    let root = JsonObject()
    root.put("schemaVersion", JsonInt(2))
    root.put("lastFullScanAtMs", JsonInt(state.lastFullScanAtMs))
    root.put("skippedOverlappingScans", JsonInt(state.skippedOverlappingScans))
    root.put("baselineCreatedAtMs", JsonInt(state.baselineCreatedAtMs))
    root.put("seenEvents", stringArrayJson(state.seenIds()))
    let baselineScopes = JsonArray([])
    for (scopeKey in state.baselineScopeIds()) {
        let row = JsonObject()
        row.put("scopeKey", JsonString(scopeKey))
        row.put("seededEvents", JsonInt(state.baselineSeenCount(scopeKey)))
        baselineScopes.add(row)
    }
    root.put("baselineScopes", baselineScopes)
    root.put("mcpCalled", stringArrayJson(state.mcpCallIds()))
    root.put("replied", stringArrayJson(state.replyIds()))
    let backoff = JsonArray([])
    for (key in state.backoffKeys()) {
        let row = JsonObject()
        row.put("key", JsonString(key))
        row.put("untilMs", JsonInt(state.backoffUntil(key)))
        backoff.add(row)
    }
    root.put("backoff", backoff)
    let audits = JsonArray([])
    for (record in state.audit) {
        let row = JsonObject()
        row.put("eventId", JsonString(record.eventId))
        row.put("status", JsonString(record.status))
        row.put("reason", JsonString(record.reason))
        row.put("requestId", JsonString(record.requestId))
        row.put("replyUrl", JsonString(record.replyUrl))
        row.put("draft", JsonString(record.draft))
        row.put("safety", JsonString(record.safety))
        row.put("deliveryStatus", JsonString(record.deliveryStatus))
        row.put("writeDecision", JsonString(record.writeDecision))
        audits.add(row)
    }
    root.put("audit", audits)
    root
}

public class FakeClock {
    public var nowMs: Int64
    public init(nowMs!: Int64 = 0) { this.nowMs = nowMs }
    public func advanceMinutes(minutes: Int64): Unit { this.nowMs += minutes * 60 * 1000 }
}

public class FullScanScheduler {
    public let intervalMs: Int64
    public let jitterMs: Int64
    public var running: Bool = false
    public var nextRunAtMs: Int64

    public init(config: MonitorConfig, clock: FakeClock) {
        this.intervalMs = config.fullScanIntervalMinutes * 60 * 1000
        this.jitterMs = config.jitterSeconds * 1000
        this.nextRunAtMs = clock.nowMs
    }

    public func due(clock: FakeClock): Bool { clock.nowMs >= nextRunAtMs }

    public func begin(clock: FakeClock, state: MonitorState): Bool {
        if (running) {
            state.skippedOverlappingScans++
            return false
        }
        if (!due(clock)) { return false }
        running = true
        state.lastFullScanAtMs = clock.nowMs
        nextRunAtMs = clock.nowMs + intervalMs + jitterMs
        return true
    }

    public func finish(): Unit { running = false }
}

public class GitCodeRepo {
    public let org: String
    public let name: String
    public let visibility: String
    public let isPublic: Bool
    public let isPrivate: Bool
    public let isInternal: Bool
    public let defaultBranch: String
    public let htmlUrl: String
    public init(org: String, name: String, visibility!: String = "", isPublic!: Bool = false, isPrivate!: Bool = false, isInternal!: Bool = false, defaultBranch!: String = "", htmlUrl!: String = "") {
        this.org = org
        this.name = name
        this.visibility = visibility
        this.isPublic = isPublic
        this.isPrivate = isPrivate
        this.isInternal = isInternal
        this.defaultBranch = defaultBranch
        this.htmlUrl = htmlUrl
    }
    public func fullName(): String { "${org}/${name}" }
}

public func canonicalGitCodeRepoKey(repo: GitCodeRepo): String {
    "${repo.org.trimAscii().toAsciiLower()}/${repo.name.trimAscii().toAsciiLower()}"
}

public func canonicalGitCodeRepoScopeKey(repo: GitCodeRepo): String {
    "gitcode:${canonicalGitCodeRepoKey(repo)}"
}

public func canonicalGitCodeEventId(repo: GitCodeRepo, kind: String, itemId: String, commentId!: String = ""): String {
    let normalizedKind = kind.trimAscii().toAsciiLower()
    let normalizedItem = itemId.trimAscii()
    let base = "${canonicalGitCodeRepoScopeKey(repo)}:${normalizedKind}:${normalizedItem}"
    if (commentId.trimAscii().isEmpty()) { return base }
    "${base}:comment:${commentId.trimAscii()}"
}

public func gitCodeEventScopeKey(event: GitCodeEvent): String {
    canonicalGitCodeRepoScopeKey(GitCodeRepo(event.org, event.repo))
}

public class HttpRequestSpec {
    public let method: String
    public let url: String
    public let headers: Array<(String, String)>
    public let body: String
    public init(method: String, url: String, headers!: Array<(String, String)> = [], body!: String = "") {
        this.method = method
        this.url = url
        this.headers = headers
        this.body = body
    }
    public func redactedLogLine(): String {
        let parts = ArrayList<String>()
        for ((key, value) in headers) {
            let lower = key.toAsciiLower()
            let v = if (lower.contains("authorization") || lower.contains("token") || lower.contains("cookie")) { "[REDACTED]" } else { value }
            parts.add("${key}=${v}")
        }
        "${method} ${redactUrl(url)} headers=${joinStrings(parts.toArray(), ";")}"
    }
}

public class HttpResponseSpec {
    public let statusCode: Int64
    public let body: String
    public let headers: Array<(String, String)>
    public init(statusCode: Int64, body!: String = "", headers!: Array<(String, String)> = []) {
        this.statusCode = statusCode
        this.body = body
        this.headers = headers
    }
}

public interface HttpSender {
    func send(request: HttpRequestSpec): HttpResponseSpec
}

public interface NativeRawHttpTransport {
    func send(request: HttpRequestSpec, timeoutSeconds: Int64): HttpResponseSpec
}

public class FakeHttpSender <: HttpSender {
    public let requests = ArrayList<HttpRequestSpec>()
    public var nextResponse: HttpResponseSpec = HttpResponseSpec(200, body: "{}")
    public let queuedResponses = ArrayList<HttpResponseSpec>()
    public init() {}
    public func enqueue(response: HttpResponseSpec): Unit { queuedResponses.add(response) }
    public func send(request: HttpRequestSpec): HttpResponseSpec {
        requests.add(request)
        if (!queuedResponses.isEmpty()) {
            let response = queuedResponses[0]
            queuedResponses.remove(at: 0)
            return response
        }
        nextResponse
    }
}

public class NativeHttpSender <: HttpSender {
    private let timeoutSeconds: Int64
    private let rawTransport: NativeRawHttpTransport

    public init(timeoutSeconds!: Int64 = 30, rawTransport!: NativeRawHttpTransport = StdxNativeRawHttpTransport()) {
        this.timeoutSeconds = if (timeoutSeconds <= 0) { 30 } else { timeoutSeconds }
        this.rawTransport = rawTransport
    }

    public func send(request: HttpRequestSpec): HttpResponseSpec {
        try {
            rawTransport.send(request, this.timeoutSeconds)
        } catch (e: Exception) {
            HttpResponseSpec(599, body: "transport_error: ${redactSecrets(redactUrl(e.message))}")
        }
    }
}

public class StdxNativeRawHttpTransport <: NativeRawHttpTransport {
    public init() {}

    public func send(request: HttpRequestSpec, timeoutSeconds: Int64): HttpResponseSpec {
        try {
            let client = this.buildClient(request.url, timeoutSeconds)
            try {
                let response = client.send(this.buildRequest(request))
                let body = try {
                    String.fromUtf8(this.readAllBytes(response))
                } catch (_: Exception) {
                    return HttpResponseSpec(598, body: "transport_error: response body is not valid UTF-8")
                }
                HttpResponseSpec(Int64(response.status), body: body)
            } finally {
                client.close()
            }
        } catch (e: Exception) {
            HttpResponseSpec(599, body: "transport_error: ${redactSecrets(redactUrl(e.message))}")
        }
    }

    private func buildClient(url: String, timeoutSeconds: Int64): Client {
        let builder = ClientBuilder()
        builder.readTimeout(Duration.second * timeoutSeconds)
        if (url.trimAscii().toAsciiLower().startsWith("https")) {
            var tlsConfig = TlsClientConfig()
            tlsConfig.domain = URL.parse(url).hostName
            tlsConfig.alpnProtocolsList = ["http/1.1"]
            builder.tlsConfig(tlsConfig)
        }
        builder.build()
    }

    private func buildRequest(request: HttpRequestSpec): HttpRequest {
        let builder = HttpRequestBuilder().url(request.url)
        match (request.method.toAsciiUpper()) {
            case "POST" => builder.post()
            case "PATCH" => builder.method("PATCH")
            case "DELETE" => builder.method("DELETE")
            case "PUT" => builder.method("PUT")
            case _ => builder.get()
        }
        if (!request.body.isEmpty()) {
            builder.body(request.body)
        }
        for ((key, value) in request.headers) {
            builder.header(key, value)
        }
        builder.build()
    }

    private func readAllBytes(response: HttpResponse): Array<Byte> {
        let out = ArrayList<Byte>()
        let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let n = response.body.read(buffer)
            if (n <= 0) { break }
            out.add(all: buffer[..n])
        }
        out.toArray()
    }
}

public class CurlHttpSender <: HttpSender {
    public init() {}

    public func curlArgs(request: HttpRequestSpec): Array<String> {
        let args = ArrayList<String>()
        args.add("-sS")
        args.add("-X")
        args.add(request.method)
        for ((key, value) in request.headers) {
            args.add("-H")
            args.add("${key}: ${value}")
        }
        if (!request.body.isEmpty()) {
            args.add("--data")
            args.add(request.body)
        }
        args.add("-w")
        args.add("\n%{http_code}")
        args.add(request.url)
        args.toArray()
    }

    public func redactedCurlArgs(request: HttpRequestSpec): Array<String> {
        let args = ArrayList<String>()
        for (arg in curlArgs(request)) { args.add(redactSecrets(redactUrl(arg))) }
        args.toArray()
    }

    public func send(request: HttpRequestSpec): HttpResponseSpec {
        try {
            let (exitCode, stdoutBytes, stderrBytes) = executeWithOutput("curl", curlArgs(request))
            if (exitCode != 0) {
                return HttpResponseSpec(599, body: "transport_error: ${redactSecrets(redactUrl(String.fromUtf8(stderrBytes)))}")
            }
            let text = try { String.fromUtf8(stdoutBytes) } catch (_: Exception) { return HttpResponseSpec(598, body: "transport_error: response body is not valid UTF-8") }
            let lines = text.split("\n")
            if (lines.size == 0) { return HttpResponseSpec(599, body: "transport_error: missing curl status") }
            let code = try { Int64.parse(lines[lines.size - 1].trimAscii()) } catch (_: Exception) { 599 }
            let body = if (lines.size > 1) { joinStrings(lines[0..lines.size - 1], "\n") } else { "" }
            HttpResponseSpec(code, body: body)
        } catch (e: Exception) {
            HttpResponseSpec(599, body: "transport_error: ${redactSecrets(redactUrl(e.message))}")
        }
    }
}

public func configuredHttpTransport(config: MonitorConfig): String {
    let value = config.httpTransport.trimAscii().toAsciiLower()
    if (value == "curl") { return "curl" }
    "native"
}

public func configuredPluginStdioHttpTransport(config: MonitorConfig): String {
    "curl"
}

public func buildHttpSender(config: MonitorConfig, pluginStdioMode!: Bool = false): HttpSender {
    if ((pluginStdioMode && configuredPluginStdioHttpTransport(config) == "curl") || configuredHttpTransport(config) == "curl") {
        return CurlHttpSender()
    }
    NativeHttpSender()
}

public class GitCodeApiClient {
    public let baseUrl: String
    public let authMode: String
    private let token: String
    private let cookie: String

    public init(baseUrl!: String = "https://api.gitcode.com/api/v5", authMode!: String = "PRIVATE-TOKEN", token!: String = "", cookie!: String = "") {
        this.baseUrl = trimTrailingSlash(baseUrl)
        this.authMode = authMode
        this.token = token
        this.cookie = cookie
    }

    public func authHeaders(): Array<(String, String)> {
        let headers = ArrayList<(String, String)>()
        if (!token.isEmpty()) {
            match (authMode) {
                case "Authorization" | "authorization" | "bearer" | "Bearer" => headers.add(("Authorization", if (token.startsWith("Bearer ")) { token } else { "Bearer ${token}" }))
                case "access_token" | "query" => ()
                case _ => headers.add(("PRIVATE-TOKEN", token))
            }
        }
        if (!cookie.isEmpty()) { headers.add(("Cookie", cookie)) }
        return headers.toArray()
    }

    public func listReposRequest(org: String, page: Int64, pageSize: Int64): HttpRequestSpec {
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/orgs/${urlPart(org)}/repos?type=public&page=${page}&per_page=${boundedPageSize(pageSize)}"), headers: authHeaders())
    }

    public func listIssuesRequest(repo: GitCodeRepo, page: Int64, pageSize: Int64, since!: String = ""): HttpRequestSpec {
        var url = "${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/issues?state=all&sort=updated_at&direction=desc&page=${page}&per_page=${boundedPageSize(pageSize)}"
        if (!since.isEmpty()) { url = "${url}&since=${urlPart(since)}" }
        HttpRequestSpec("GET", withAuthQuery(url), headers: authHeaders())
    }

    public func listPullRequestsRequest(repo: GitCodeRepo, page: Int64, pageSize: Int64, updatedAfter!: String = ""): HttpRequestSpec {
        var url = "${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/pulls?state=all&sort=updated&direction=desc&page=${page}&per_page=${boundedPageSize(pageSize)}"
        if (!updatedAfter.isEmpty()) { url = "${url}&updated_after=${urlPart(updatedAfter)}" }
        HttpRequestSpec("GET", withAuthQuery(url), headers: authHeaders())
    }

    public func listCommentsRequest(repo: GitCodeRepo, itemKind: String, itemId: String, page: Int64, pageSize: Int64): HttpRequestSpec {
        if (itemKind == "pr") {
            return listPullRequestCommentsRequest(repo, itemId, page, pageSize)
        }
        listIssueCommentsRequest(repo, page, pageSize)
    }

    public func listIssueCommentsRequest(repo: GitCodeRepo, page: Int64, pageSize: Int64): HttpRequestSpec {
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/issues/comments?page=${page}&per_page=${boundedPageSize(pageSize)}"), headers: authHeaders())
    }

    public func listPullRequestCommentsRequest(repo: GitCodeRepo, itemId: String, page: Int64, pageSize: Int64): HttpRequestSpec {
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/pulls/${urlPart(itemId)}/comments?page=${page}&per_page=${boundedPageSize(pageSize)}"), headers: authHeaders())
    }

    public func contentsRequest(repo: GitCodeRepo, path: String, ref: String): HttpRequestSpec {
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/contents/${urlPart(path)}?ref=${urlPart(ref)}"), headers: authHeaders())
    }

    public func pullRequestFilesRequest(repo: GitCodeRepo, number: Int64): HttpRequestSpec {
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/pulls/${number}/files"), headers: authHeaders())
    }

    public func postCommentRequest(event: GitCodeEvent, body: String): HttpRequestSpec {
        let kind = if (event.itemKind == "pr") { "pulls" } else { "issues" }
        let json = "{\"body\":\"${jsonEscape(body)}\"}"
        HttpRequestSpec("POST", withAuthQuery("${baseUrl}/repos/${urlPart(event.org)}/${urlPart(event.repo)}/${kind}/${urlPart(event.itemId)}/comments"), headers: authHeaders().concat([("Content-Type", "application/json")]), body: json)
    }

    public func createRepoWebhookRequest(repo: GitCodeRepo, hookUrl: String, token: String, events: Array<String>): HttpRequestSpec {
        let eventItems = ArrayList<String>()
        for (eventName in events) {
            eventItems.add("\"${jsonEscape(eventName)}\"")
        }
        let body = "{" +
            "\"url\":\"${jsonEscape(hookUrl)}\"," +
            "\"token\":\"${jsonEscape(token)}\"," +
            "\"events\":[${joinStrings(eventItems.toArray(), ",")}]" +
        "}"
        HttpRequestSpec("POST", withAuthQuery("${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/hooks"), headers: authHeaders().concat([("Content-Type", "application/json")]), body: body)
    }

    private func withAuthQuery(url: String): String {
        if ((authMode == "access_token" || authMode == "query") && !token.isEmpty()) {
            let sep = if (url.contains("?")) { "&" } else { "?" }
            return "${url}${sep}access_token=${urlPart(token)}"
        }
        url
    }
}

public class GitCodeListResult {
    public let repos: Array<GitCodeRepo>
    public let events: Array<GitCodeEvent>
    public let errorKind: String
    public let retryAfterMs: Int64
    public init(repos!: Array<GitCodeRepo> = [], events!: Array<GitCodeEvent> = [], errorKind!: String = "ok", retryAfterMs!: Int64 = 0) {
        this.repos = repos
        this.events = events
        this.errorKind = errorKind
        this.retryAfterMs = retryAfterMs
    }
}

public class GitCodeHttpTransport {
    public let client: GitCodeApiClient
    public let sender: HttpSender
    public let pageSize: Int64
    public init(client: GitCodeApiClient, sender!: HttpSender = FakeHttpSender(), pageSize!: Int64 = 50) {
        this.client = client
        this.sender = sender
        this.pageSize = pageSize
    }

    public func listReposPage(org: String, page: Int64): GitCodeListResult {
        let res = sender.send(client.listReposRequest(org, page, pageSize))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            return GitCodeListResult(errorKind: mapGitCodeError(res.statusCode), retryAfterMs: retryAfterMs(res))
        }
        GitCodeListResult(repos: parseReposResponse(res.body, org))
    }

    public func listIssuesPage(repo: GitCodeRepo, page: Int64): GitCodeListResult {
        let res = sender.send(client.listIssuesRequest(repo, page, pageSize))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            return GitCodeListResult(errorKind: mapGitCodeError(res.statusCode), retryAfterMs: retryAfterMs(res))
        }
        GitCodeListResult(events: parseItemsResponse(res.body, repo, "issue"))
    }

    public func listPullRequestsPage(repo: GitCodeRepo, page: Int64): GitCodeListResult {
        let res = sender.send(client.listPullRequestsRequest(repo, page, pageSize))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            return GitCodeListResult(errorKind: mapGitCodeError(res.statusCode), retryAfterMs: retryAfterMs(res))
        }
        GitCodeListResult(events: parseItemsResponse(res.body, repo, "pr"))
    }

    public func listCommentsPage(repo: GitCodeRepo, kind: String, itemId: String, page: Int64): GitCodeListResult {
        let res = sender.send(client.listCommentsRequest(repo, kind, itemId, page, pageSize))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            return GitCodeListResult(errorKind: mapGitCodeError(res.statusCode), retryAfterMs: retryAfterMs(res))
        }
        GitCodeListResult(events: parseCommentsResponse(res.body, repo, kind, itemId))
    }
}

public class RuntimeContainer {
    public let config: MonitorConfig
    public let store: StateStore
    public let sender: HttpSender
    public let gitCode: GitCodeHttpTransport
    public let writer: GitCodeCommentWriter
    public let httpTransportKind: String

    public init(config: MonitorConfig, sender!: ?HttpSender = None<HttpSender>, pluginStdioMode!: Bool = false) {
        this.config = config
        this.store = StateStore(config.statePath)
        this.httpTransportKind = match (sender) {
            case Some(_) => "injected"
            case None => if (pluginStdioMode) { configuredPluginStdioHttpTransport(config) } else { configuredHttpTransport(config) }
        }
        this.sender = match (sender) {
            case Some(s) => s
            case None => buildHttpSender(config, pluginStdioMode: pluginStdioMode)
        }
        let client = GitCodeApiClient(baseUrl: config.gitCodeBaseUrl, authMode: config.gitCodeAuthMode, token: config.gitCodeToken, cookie: config.gitCodeCookie)
        this.gitCode = GitCodeHttpTransport(client, sender: this.sender, pageSize: 100)
        this.writer = GitCodeCommentWriter(client, sender: this.sender)
    }
}

public func scanOnceRuntime(config: MonitorConfig, runtime: RuntimeContainer, state: MonitorState): ScanResult {
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
                for (event in collection.events) {
                    result.checkedItems++
                    let processed = processRuntimeEvent(config, state, event, baselineMode: !hadBaseline)
                    result.absorb(processed)
                }
                if (!hadBaseline && collection.completed) {
                    state.markBaseline(scopeKey, result.baselineSeededEvents - baselineStart)
                    result.baselineScopesCreated++
                }
            }
            if (repoResult.repos.size < runtime.gitCode.pageSize) { break }
            page++
        }
    }
    finalizeScanResult(state, "scan_runtime", result)
}

public func scanOnceOfflineFixture(config: MonitorConfig, state: MonitorState): ScanResult {
    let transport = FakeGitCodeTransport()
    transport.seedDefaultRepos()
    transport.events.add(GitCodeEvent("evt-1", "cangjie", "compiler", "issue", "1", "alice", "https://gitcode.com/alice", "https://gitcode.com/cangjie/compiler/issues/1", "Please check this issue."))
    scanOnce(config, transport, state)
}

public class GitCodeCurlTransport {
    public let client: GitCodeApiClient
    public let sender: CurlHttpSender
    public let pageSize: Int64
    public init(client: GitCodeApiClient, sender!: CurlHttpSender = CurlHttpSender(), pageSize!: Int64 = 50) {
        this.client = client
        this.sender = sender
        this.pageSize = pageSize
    }

    public func listReposPage(org: String, page: Int64): GitCodeListResult {
        let res = sender.send(client.listReposRequest(org, page, pageSize))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            return GitCodeListResult(errorKind: mapGitCodeError(res.statusCode), retryAfterMs: retryAfterMs(res))
        }
        GitCodeListResult(repos: parseReposResponse(res.body, org))
    }

    public func listIssuesPage(repo: GitCodeRepo, page: Int64): GitCodeListResult {
        let res = sender.send(client.listIssuesRequest(repo, page, pageSize))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            return GitCodeListResult(errorKind: mapGitCodeError(res.statusCode), retryAfterMs: retryAfterMs(res))
        }
        GitCodeListResult(events: parseItemsResponse(res.body, repo, "issue"))
    }

    public func listPullRequestsPage(repo: GitCodeRepo, page: Int64): GitCodeListResult {
        let res = sender.send(client.listPullRequestsRequest(repo, page, pageSize))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            return GitCodeListResult(errorKind: mapGitCodeError(res.statusCode), retryAfterMs: retryAfterMs(res))
        }
        GitCodeListResult(events: parseItemsResponse(res.body, repo, "pr"))
    }

    public func listCommentsPage(repo: GitCodeRepo, kind: String, itemId: String, page: Int64): GitCodeListResult {
        let res = sender.send(client.listCommentsRequest(repo, kind, itemId, page, pageSize))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            return GitCodeListResult(errorKind: mapGitCodeError(res.statusCode), retryAfterMs: retryAfterMs(res))
        }
        GitCodeListResult(events: parseCommentsResponse(res.body, repo, kind, itemId))
    }
}


public func mapGitCodeError(statusCode: Int64): String {
    if (statusCode == 401) { return "unauthorized" }
    if (statusCode == 403) { return "forbidden" }
    if (statusCode == 404) { return "not_found" }
    if (statusCode == 429) { return "rate_limited" }
    if (statusCode >= 500) { return "server_error" }
    return "ok"
}

public class FakeGitCodeTransport {
    public let repos = ArrayList<GitCodeRepo>()
    public let events = ArrayList<GitCodeEvent>()
    public var nextStatusCode: Int64 = 200

    public init() {}

    public func seedDefaultRepos(): Unit {
        repos.add(GitCodeRepo("cangjie", "compiler"))
        repos.add(GitCodeRepo("cangjie-sig", "tools"))
        repos.add(GitCodeRepo("cangjie-tpc", "stdx"))
    }

    public func listRepos(org: String, page: Int64, pageSize: Int64): Array<GitCodeRepo> {
        let out = ArrayList<GitCodeRepo>()
        var seen: Int64 = 0
        let start = (page - 1) * pageSize
        let end = start + pageSize
        for (repo in repos) {
            if (repo.org == org) {
                if (seen >= start && seen < end) { out.add(repo) }
                seen++
            }
        }
        return out.toArray()
    }

    public func scanRepo(repo: GitCodeRepo): Array<GitCodeEvent> {
        let out = ArrayList<GitCodeEvent>()
        for (event in events) {
            if (event.org == repo.org && event.repo == repo.name) { out.add(event) }
        }
        return out.toArray()
    }
}

public class RepoRefreshResult {
    public let repoCount: Int64
    public let errorCount: Int64
    public init(repoCount: Int64, errorCount: Int64) {
        this.repoCount = repoCount
        this.errorCount = errorCount
    }
}

public func refreshRepos(config: MonitorConfig, transport: FakeGitCodeTransport): RepoRefreshResult {
    if (transport.nextStatusCode != 200) { return RepoRefreshResult(0, 1) }
    var count: Int64 = 0
    for (org in config.orgs) {
        var page: Int64 = 1
        while (true) {
            let repos = transport.listRepos(org, page, 2)
            count += repos.size
            if (repos.size < 2) { break }
            page++
        }
    }
    return RepoRefreshResult(count, 0)
}

public func refreshReposHttp(config: MonitorConfig, transport: GitCodeHttpTransport, state: MonitorState): RepoRefreshResult {
    var count: Int64 = 0
    var errors: Int64 = 0
    for (org in config.orgs) {
        var page: Int64 = 1
        while (true) {
            let result = transport.listReposPage(org, page)
            if (result.errorKind != "ok") {
                errors++
                state.setBackoff("org:${org}", result.retryAfterMs)
                break
            }
            count += result.repos.size
            if (result.repos.size < transport.pageSize) { break }
            page++
        }
    }
    RepoRefreshResult(count, errors)
}

public func collectRepoEventsHttp(repo: GitCodeRepo, transport: GitCodeHttpTransport, state: MonitorState): Array<GitCodeEvent> {
    collectRepoEventsHttpDetailed(repo, transport, state).events
}

public class GitCodeRepoEventCollection {
    public let events: Array<GitCodeEvent>
    public let completed: Bool
    public let errorKind: String

    public init(events: Array<GitCodeEvent>, completed!: Bool = true, errorKind!: String = "") {
        this.events = events
        this.completed = completed
        this.errorKind = errorKind
    }
}

public func collectRepoEventsHttpDetailed(repo: GitCodeRepo, transport: GitCodeHttpTransport, state: MonitorState): GitCodeRepoEventCollection {
    let out = ArrayList<GitCodeEvent>()
    let issueStatus = collectPagedEvents(repo, "issue", transport, state, out)
    let prStatus = collectPagedEvents(repo, "pr", transport, state, out)
    let ok = issueStatus == "ok" && prStatus == "ok"
    let errorKind = if (issueStatus != "ok") { issueStatus } else { if (prStatus != "ok") { prStatus } else { "" } }
    GitCodeRepoEventCollection(out.toArray(), completed: ok, errorKind: errorKind)
}

public class WritebackScopeDecision {
    public let allowed: Bool
    public let reason: String
    public let matchedBy: String
    public let matchedValue: String

    public init(allowed: Bool, reason: String, matchedBy!: String = "none", matchedValue!: String = "") {
        this.allowed = allowed
        this.reason = reason
        this.matchedBy = matchedBy
        this.matchedValue = matchedValue
    }
}

public func evaluateWritebackScope(config: MonitorConfig, repoFullName: String): WritebackScopeDecision {
    if (config.dryRun) { return WritebackScopeDecision(false, "dry_run") }
    if (!config.autoReply) { return WritebackScopeDecision(false, "auto_reply_disabled") }
    let normalizedRepo = normalizeWritebackRepoFullName(repoFullName)
    if (normalizedRepo.isEmpty()) {
        return WritebackScopeDecision(false, "invalid_repo_scope")
    }
    let denied = findWritebackRepoScopeMatch(config.writebackScope.deniedRepos, normalizedRepo)
    if (!denied.isEmpty()) {
        return WritebackScopeDecision(false, "repo_denied_by_writeback_scope", matchedBy: "denied_repo", matchedValue: denied)
    }
    let allowedRepo = findWritebackRepoScopeMatch(config.writebackScope.allowedRepos, normalizedRepo)
    if (!allowedRepo.isEmpty()) {
        return WritebackScopeDecision(true, "allowed", matchedBy: "allowed_repo", matchedValue: allowedRepo)
    }
    let owner = normalizedRepo.split("/")[0]
    let allowedOrg = findWritebackOrgScopeMatch(config.writebackScope.allowedOrgs, owner)
    if (!allowedOrg.isEmpty()) {
        return WritebackScopeDecision(true, "allowed", matchedBy: "allowed_org", matchedValue: allowedOrg)
    }
    WritebackScopeDecision(false, "repo_not_allowlisted")
}

public interface GitCodeWritebackWriter {
    func write(event: GitCodeEvent, body: String, state: MonitorState): String
}

public class FakeCommentWriter <: GitCodeWritebackWriter {
    public let written = ArrayList<String>()
    public var nextStatus: String = "ok"
    public init() {}
    public func write(event: GitCodeEvent, body: String, state: MonitorState): String {
        if (nextStatus != "ok") {
            let status = nextStatus
            nextStatus = "ok"
            return "error:${status}"
        }
        written.add(body)
        state.markReply(event.id)
        "https://gitcode.com/${event.org}/${event.repo}/comments/${written.size}"
    }
}

public class GitCodeCommentWriter <: GitCodeWritebackWriter {
    public let client: GitCodeApiClient
    public let sender: HttpSender
    public init(client: GitCodeApiClient, sender!: HttpSender = FakeHttpSender()) {
        this.client = client
        this.sender = sender
    }
    public func write(event: GitCodeEvent, body: String, state: MonitorState): String {
        let res = sender.send(client.postCommentRequest(event, body))
        if (res.statusCode >= 200 && res.statusCode < 300) {
            state.markReply(event.id)
            return gitCodeCommentReplyUrl(res.body, event)
        }
        "error:${mapGitCodeWritebackError(res.statusCode)}"
    }
}

func gitCodeCommentReplyUrl(body: String, event: GitCodeEvent): String {
    try {
        let obj = JsonValue.fromStr(body).asObject()
        let html = firstJsonString(obj, ["html_url", "url", "web_url"])
        if (!html.isEmpty()) { return html }
    } catch (_: Exception) {
        ()
    }
    if (!event.url.isEmpty()) { return event.url }
    "https://gitcode.com/${event.org}/${event.repo}/${if (event.itemKind == "pr") { "pulls" } else { "issues" }}/${event.itemId}"
}

func mapGitCodeWritebackError(statusCode: Int64): String {
    if (statusCode == 401) { return "gitcode_api_unauthorized" }
    if (statusCode == 403) { return "gitcode_api_forbidden" }
    if (statusCode == 404) { return "gitcode_api_not_found" }
    if (statusCode == 429) { return "rate_limited" }
    if (statusCode == 599) { return "gitcode_api_timeout" }
    if (statusCode >= 500) { return "server_error" }
    "gitcode_api_error"
}

public class AcpTaskRequest {
    public let task: String
    public let freshnessPolicy: String
    public init(task: String, freshnessPolicy!: String = "use_active") {
        this.task = task
        this.freshnessPolicy = freshnessPolicy
    }
}

public class AcpRun {
    public let runId: String
    public var status: String
    public var resultSource: String
    public var finalDraft: String
    public init(runId: String, status!: String = "pending") {
        this.runId = runId
        this.status = status
        this.resultSource = "acp"
        this.finalDraft = ""
    }
}

public class FakeAcpClient {
    public init() {}
    public func allowed(config: MonitorConfig, request: AcpTaskRequest): Bool {
        config.acpEnabled && arrayContains(config.acpAllowedTasks, request.task) && request.task != "gitcode_issue_draft_reply"
    }
    public func createRun(config: MonitorConfig, request: AcpTaskRequest): AcpRun {
        if (!allowed(config, request)) { return AcpRun("rejected", status: "failed") }
        AcpRun("acp-run-1", status: "pending")
    }
    public func poll(run: AcpRun): AcpRun {
        run.status = "succeeded"
        run.finalDraft = "ACP result for audit only"
        run
    }
}

public let SCAN_REPORT_SAMPLE_LIMIT: Int64 = 5

public class ScanEventSummary {
    public let eventId: String
    public let repo: String
    public let kind: String
    public let number: String
    public let commentId: String
    public let title: String
    public let url: String
    public let status: String
    public let reason: String

    public init(eventId: String, repo: String, kind: String, number: String, commentId: String, title: String, url: String, status: String, reason: String) {
        this.eventId = sanitizeScanReportText(eventId, limit: 160)
        this.repo = sanitizeScanReportText(repo, limit: 160)
        this.kind = sanitizeScanReportText(kind, limit: 32)
        this.number = sanitizeScanReportText(number, limit: 64)
        this.commentId = sanitizeScanReportText(commentId, limit: 64)
        this.title = sanitizeScanReportText(title, limit: 160)
        this.url = sanitizeScanReportText(url, limit: 240)
        this.status = sanitizeScanReportText(status, limit: 80)
        this.reason = sanitizeScanReportText(reason, limit: 160)
    }
}

public class ScanResult {
    public var accepted: Int64
    public var ignored: Int64
    public var notified: Int64
    public var mcpCalls: Int64
    public var writes: Int64
    public var orgs: Array<String>
    public var scannedRepos: Int64
    public var checkedItems: Int64
    public var newEvents: Int64
    public var duplicateEvents: Int64
    public var filteredEvents: Int64
    public var failedEvents: Int64
    public var baselineScopesCreated: Int64
    public var baselineSeededEvents: Int64
    public var backfillEvents: Int64
    public var draftsGenerated: Int64
    public var draftsFailed: Int64
    public var notificationsSent: Int64
    public var writeMode: String
    public var stopReason: String
    public let samplesNew: ArrayList<ScanEventSummary>
    public let samplesDuplicate: ArrayList<ScanEventSummary>
    public let samplesFiltered: ArrayList<ScanEventSummary>
    public let samplesFailed: ArrayList<ScanEventSummary>
    public let samplesBaseline: ArrayList<ScanEventSummary>

    public init(
        accepted: Int64,
        ignored: Int64,
        notified: Int64,
        mcpCalls: Int64,
        writes: Int64,
        orgs!: Array<String> = [],
        scannedRepos!: Int64 = 0,
        checkedItems!: Int64 = 0,
        newEvents!: Int64 = 0,
        duplicateEvents!: Int64 = 0,
        filteredEvents!: Int64 = 0,
        failedEvents!: Int64 = 0,
        baselineScopesCreated!: Int64 = 0,
        baselineSeededEvents!: Int64 = 0,
        backfillEvents!: Int64 = 0,
        draftsGenerated!: Int64 = 0,
        draftsFailed!: Int64 = 0,
        notificationsSent!: Int64 = 0,
        writeMode!: String = "dry_run",
        stopReason!: String = "completed"
    ) {
        this.accepted = accepted
        this.ignored = ignored
        this.notified = notified
        this.mcpCalls = mcpCalls
        this.writes = writes
        this.orgs = orgs
        this.scannedRepos = scannedRepos
        this.checkedItems = checkedItems
        this.newEvents = newEvents
        this.duplicateEvents = duplicateEvents
        this.filteredEvents = filteredEvents
        this.failedEvents = failedEvents
        this.baselineScopesCreated = baselineScopesCreated
        this.baselineSeededEvents = baselineSeededEvents
        this.backfillEvents = backfillEvents
        this.draftsGenerated = draftsGenerated
        this.draftsFailed = draftsFailed
        this.notificationsSent = notificationsSent
        this.writeMode = writeMode
        this.stopReason = normalizeScanStopReason(stopReason)
        this.samplesNew = ArrayList<ScanEventSummary>()
        this.samplesDuplicate = ArrayList<ScanEventSummary>()
        this.samplesFiltered = ArrayList<ScanEventSummary>()
        this.samplesFailed = ArrayList<ScanEventSummary>()
        this.samplesBaseline = ArrayList<ScanEventSummary>()
    }

    public func absorb(other: ScanResult): Unit {
        this.accepted += other.accepted
        this.ignored += other.ignored
        this.notified += other.notified
        this.mcpCalls += other.mcpCalls
        this.writes += other.writes
        this.scannedRepos += other.scannedRepos
        this.checkedItems += other.checkedItems
        this.newEvents += other.newEvents
        this.duplicateEvents += other.duplicateEvents
        this.filteredEvents += other.filteredEvents
        this.failedEvents += other.failedEvents
        this.baselineScopesCreated += other.baselineScopesCreated
        this.baselineSeededEvents += other.baselineSeededEvents
        this.backfillEvents += other.backfillEvents
        this.draftsGenerated += other.draftsGenerated
        this.draftsFailed += other.draftsFailed
        this.notificationsSent += other.notificationsSent
        if (this.orgs.size == 0 && other.orgs.size > 0) { this.orgs = other.orgs }
        if (this.writeMode.isEmpty() && !other.writeMode.isEmpty()) { this.writeMode = other.writeMode }
        if (this.stopReason == "completed" && other.stopReason != "completed") { this.stopReason = other.stopReason }
        for (sample in other.samplesNew) { addSampleLimited(this.samplesNew, sample) }
        for (sample in other.samplesDuplicate) { addSampleLimited(this.samplesDuplicate, sample) }
        for (sample in other.samplesFiltered) { addSampleLimited(this.samplesFiltered, sample) }
        for (sample in other.samplesFailed) { addSampleLimited(this.samplesFailed, sample) }
        for (sample in other.samplesBaseline) { addSampleLimited(this.samplesBaseline, sample) }
    }

    public func addNewSample(event: GitCodeEvent, status: String, reason!: String = ""): Unit {
        addSampleLimited(this.samplesNew, scanEventSummary(event, status, reason))
    }

    public func addDuplicateSample(event: GitCodeEvent, reason: String): Unit {
        addSampleLimited(this.samplesDuplicate, scanEventSummary(event, "seen", reason))
    }

    public func addFilteredSample(event: GitCodeEvent, reason: String): Unit {
        addSampleLimited(this.samplesFiltered, scanEventSummary(event, "filtered", reason))
    }

    public func addFailedSample(repo: String, reason: String): Unit {
        addSampleLimited(this.samplesFailed, ScanEventSummary("", repo, "", "", "", "", "", "failed", reason))
    }

    public func addBaselineSample(event: GitCodeEvent, reason: String): Unit {
        addSampleLimited(this.samplesBaseline, scanEventSummary(event, "baseline", reason))
    }
}

public func scanOnce(config: MonitorConfig, transport: FakeGitCodeTransport, state: MonitorState): ScanResult {
    let result = emptyScanResult(config)
    for (repo in transport.repos) {
        result.scannedRepos++
        let scopeKey = canonicalGitCodeRepoScopeKey(repo)
        let hadBaseline = state.hasBaseline(scopeKey)
        var baselineSeededForRepo: Int64 = 0
        for (event in transport.scanRepo(repo)) {
            result.checkedItems++
            let filter = filterEvent(event)
            if (filter.ignored) {
                result.ignored++
                result.filteredEvents++
                result.addFilteredSample(event, filter.reason)
                state.addAudit(AuditRecord(event.id, status: "ignored", reason: filter.reason))
                continue
            }
            if (state.hasSeen(event.id)) {
                result.duplicateEvents++
                result.addDuplicateSample(event, "seen")
                state.addAudit(AuditRecord(event.id, status: "skipped_duplicate", reason: "seen"))
                continue
            }
            if (!hadBaseline) {
                state.markSeen(event.id)
                baselineSeededForRepo++
                result.baselineSeededEvents++
                result.addBaselineSample(event, "first_baseline")
                state.addAudit(AuditRecord(event.id, status: "baseline_seeded", reason: "first_baseline"))
                continue
            }
            state.markSeen(event.id)
            result.accepted++
            result.newEvents++
            let audit = AuditRecord(event.id, status: "accepted")
            audit.deliveryStatus = "metis_service_plugin"
            state.addAudit(audit)
            result.addNewSample(event, "accepted")
        }
        if (!hadBaseline) {
            state.markBaseline(scopeKey, baselineSeededForRepo)
            result.baselineScopesCreated++
        }
    }
    finalizeScanResult(state, "scan_once", result)
}

func processRuntimeEvent(config: MonitorConfig, state: MonitorState, event: GitCodeEvent, baselineMode!: Bool = false): ScanResult {
    let filter = filterEvent(event)
    if (filter.ignored) {
        state.addAudit(AuditRecord(event.id, status: "ignored", reason: filter.reason))
        let result = ScanResult(0, 1, 0, 0, 0, filteredEvents: 1, writeMode: scanWriteMode(config))
        result.addFilteredSample(event, filter.reason)
        return result
    }
    if (state.hasSeen(event.id)) {
        state.addAuditCoalesced(AuditRecord(event.id, status: "skipped_duplicate", reason: "seen"))
        let result = ScanResult(0, 0, 0, 0, 0, duplicateEvents: 1, writeMode: scanWriteMode(config))
        result.addDuplicateSample(event, "seen")
        return result
    }
    if (baselineMode) {
        state.markSeen(event.id)
        state.addAudit(AuditRecord(event.id, status: "baseline_seeded", reason: "first_baseline"))
        let result = ScanResult(0, 0, 0, 0, 0, baselineSeededEvents: 1, writeMode: scanWriteMode(config))
        result.addBaselineSample(event, "first_baseline")
        return result
    }
    state.markSeen(event.id)
    let audit = AuditRecord(event.id, status: "accepted")
    audit.deliveryStatus = "metis_service_plugin"
    state.addAudit(audit)

    let result = ScanResult(1, 0, 0, 0, 0, newEvents: 1, writeMode: scanWriteMode(config))
    result.addNewSample(event, "accepted")
    result
}

func emptyScanResult(config: MonitorConfig): ScanResult {
    ScanResult(0, 0, 0, 0, 0, orgs: config.orgs, writeMode: scanWriteMode(config))
}

func scanWriteMode(config: MonitorConfig): String {
    if (config.dryRun) { "dry_run" } else { "writeback" }
}

func finalizeScanResult(state: MonitorState, scanId: String, result: ScanResult): ScanResult {
    result.stopReason = normalizeScanStopReason(result.stopReason)
    state.addAudit(AuditRecord(scanId, status: "scan_summary", reason: scanSummaryReason(result)))
    result
}

func scanSummaryReason(result: ScanResult): String {
    "scannedRepos=${result.scannedRepos} checkedItems=${result.checkedItems} newEvents=${result.newEvents} duplicateEvents=${result.duplicateEvents} filteredEvents=${result.filteredEvents} failedEvents=${result.failedEvents} baselineScopesCreated=${result.baselineScopesCreated} baselineSeededEvents=${result.baselineSeededEvents} draftsGenerated=${result.draftsGenerated} notificationsSent=${result.notificationsSent} writes=${result.writes} stopReason=${result.stopReason}"
}

func normalizeScanStopReason(stopReason: String): String {
    match (stopReason) {
        case "completed" => "completed"
        case "max_repos_reached" => "max_repos_reached"
        case "max_items_reached" => "max_items_reached"
        case "cancelled" => "cancelled"
        case "degraded" => "degraded"
        case _ => "completed"
    }
}

func addSampleLimited(samples: ArrayList<ScanEventSummary>, sample: ScanEventSummary): Unit {
    if (samples.size < SCAN_REPORT_SAMPLE_LIMIT) { samples.add(sample) }
}

func scanEventSummary(event: GitCodeEvent, status: String, reason: String): ScanEventSummary {
    ScanEventSummary(
        event.id,
        "${event.org}/${event.repo}",
        event.itemKind,
        event.itemId,
        scanEventCommentId(event),
        scanEventTitle(event),
        event.url,
        status,
        reason
    )
}

func scanEventTitle(event: GitCodeEvent): String {
    let text = event.content.trimAscii()
    if (text.isEmpty()) { return "" }
    text.split("\n")[0].trimAscii()
}

func scanEventCommentId(event: GitCodeEvent): String {
    if (!event.id.contains(":comment:")) { return "" }
    let parts = event.id.split(":comment:")
    if (parts.size < 2) { return "" }
    parts[1]
}

func sanitizeScanReportText(raw: String, limit!: Int64 = 160): String {
    var text = redactSecrets(redactUrl(raw)).trimAscii().replace("\n", " ").replace("\r", " ")
    if (containsLocalPath(text)) { text = "[REDACTED_LOCAL_PATH]" }
    compactSummary(text, limit: limit)
}

public func doctorReport(config: MonitorConfig, state: MonitorState): String {
    let acp = if (config.acpEnabled) { "enabled" } else { "disabled" }
    let auth = if (gitCodeAuthPresent(config)) { "present" } else { "absent" }
    "GitCodeMonitor doctor\nmode=service-plugin-only\norgs=${config.orgs.size}\ngitCodeBaseUrl=${config.gitCodeBaseUrl}\ntransport=${configuredHttpTransport(config)}\ngitCodeAuth=${auth}\nstatePath=${config.statePath}\nfullScanIntervalMinutes=${config.fullScanIntervalMinutes}\ndryRun=${config.dryRun}\nautoReply=${config.autoReply}\nacp=${acp}\naudit=${state.audit.size}"
}

public func probeGitCode(config: MonitorConfig): String {
    let client = GitCodeApiClient(baseUrl: config.gitCodeBaseUrl, authMode: config.gitCodeAuthMode, token: config.gitCodeToken, cookie: config.gitCodeCookie)
    let req = client.listReposRequest(config.orgs[0], 1, 20)
    "probe-gitcode\n${req.redactedLogLine()}\nauth=${if (gitCodeAuthPresent(config)) { "present" } else { "absent" }}"
}

public func probeMcp(config: MonitorConfig): String {
    let _ = config
    "probe-mcp unsupported: GitCodeMonitor is service-plugin-only; Metis generates drafts and calls gitcode.writeback.apply_result"
}

public func serveOnceBaseline(config: MonitorConfig): String {
    "serve baseline: intervalMinutes=${config.fullScanIntervalMinutes} dryRun=${config.dryRun} autoReply=${config.autoReply}"
}

public class ServiceControl {
    public var stopRequested: Bool = false
    public var maxScans: Int64
    public init(maxScans!: Int64 = 0) { this.maxScans = maxScans }
    public func requestStop(): Unit { stopRequested = true }
    public func shouldStop(completedScans: Int64): Bool {
        stopRequested || (maxScans > 0 && completedScans >= maxScans)
    }
}

public class ServiceRunSummary {
    public let scans: Int64
    public let skipped: Int64
    public let stopped: Bool
    public init(scans: Int64, skipped: Int64, stopped: Bool) {
        this.scans = scans
        this.skipped = skipped
        this.stopped = stopped
    }
}

public func runServiceTicks(config: MonitorConfig, clock: FakeClock, scheduler: FullScanScheduler, state: MonitorState, control: ServiceControl, tickMinutes!: Int64 = 1): ServiceRunSummary {
    var scans: Int64 = 0
    while (!control.shouldStop(scans)) {
        if (scheduler.begin(clock, state)) {
            scans++
            scheduler.finish()
        }
        clock.advanceMinutes(tickMinutes)
    }
    ServiceRunSummary(scans, state.skippedOverlappingScans, true)
}

public func runServiceScans(config: MonitorConfig, runtime: RuntimeContainer, clock: FakeClock, scheduler: FullScanScheduler, state: MonitorState, control: ServiceControl, tickMinutes!: Int64 = 1): ServiceRunSummary {
    var scans: Int64 = 0
    while (!control.shouldStop(scans)) {
        if (scheduler.begin(clock, state)) {
            let _ = scanOnceRuntime(config, runtime, state)
            if (!runtime.store.save(state)) {
                state.addAudit(AuditRecord("state-save", status: "state_error", reason: "save_failed"))
            }
            scans++
            scheduler.finish()
        }
        clock.advanceMinutes(tickMinutes)
    }
    ServiceRunSummary(scans, state.skippedOverlappingScans, true)
}

public func cliHelp(): String {
    "Usage: gitcodemonitor [--config path] <plugin-stdio|doctor|probe-gitcode|config summary|tests>"
}

public func servicePluginOnlyUnsupportedCommand(command: String): String {
    "${command} unsupported: GitCodeMonitor runs as a Metis service-plugin only; use plugin-stdio"
}

public func containsLocalPath(text: String): Bool {
    text.contains("/Users/") || text.contains("/private/var/") || text.contains("C:\\")
}

func applyConfigObject(config: MonitorConfig, root: JsonObject): Unit {
    applyMonitorSection(config, root)
    match (root.get("gitcode")) {
        case Some(v) => try { applyGitCodeSection(config, v.asObject()) } catch (_: Exception) { () }
        case None => applyGitCodeSection(config, root)
    }
    match (root.get("metis")) {
        case Some(v) => try { applyMetisSection(config, v.asObject()) } catch (_: Exception) { () }
        case None => applyMetisSection(config, root)
    }
    match (root.get("monitor")) {
        case Some(v) => try { applyMonitorSection(config, v.asObject()) } catch (_: Exception) { () }
        case None => ()
    }
}

func applyGitCodeSection(config: MonitorConfig, obj: JsonObject): Unit {
    let baseUrl = firstJsonString(obj, ["baseUrl", "apiBaseUrl", "gitCodeBaseUrl"])
    if (!baseUrl.isEmpty()) { config.gitCodeBaseUrl = baseUrl }
    let authMode = firstJsonString(obj, ["authMode", "gitCodeAuthMode"])
    if (!authMode.isEmpty()) { config.gitCodeAuthMode = authMode }
    let transport = firstJsonString(obj, ["transport", "httpTransport"])
    if (!transport.isEmpty()) { config.httpTransport = transport }
    let token = firstJsonString(obj, ["token", "privateToken", "accessToken", "gitCodeToken"])
    if (!token.isEmpty()) { config.gitCodeToken = token }
    let cookie = firstJsonString(obj, ["cookie", "gitCodeCookie"])
    if (!cookie.isEmpty()) { config.gitCodeCookie = cookie }
    let username = firstJsonString(obj, ["username", "account", "gitCodeUsername"])
    if (!username.isEmpty()) { config.gitCodeUsername = username }
    let password = firstJsonString(obj, ["password", "gitCodePassword"])
    if (!password.isEmpty()) { config.gitCodePassword = password }
    match (obj.get("authorPolicy")) {
        case Some(v) => try { applyAuthorPolicySection(config, v.asObject()) } catch (_: Exception) { () }
        case None => ()
    }
    match (obj.get("webhook")) {
        case Some(v) => try { applyWebhookSection(config, v.asObject()) } catch (_: Exception) { () }
        case None => ()
    }
}

func applyAuthorPolicySection(config: MonitorConfig, obj: JsonObject): Unit {
    config.authorPolicy.recordOnlyEnabled = firstJsonBool(obj, ["recordOnlyEnabled"], config.authorPolicy.recordOnlyEnabled)
    match (obj.get("recordOnlyEmailDomains")) {
        case Some(value) =>
            let domains = ArrayList<String>()
            try {
                for (item in value.asArray().getItems()) {
                    let normalized = normalizeAuthorPolicyDomain(jsonValueToString(item))
                    if (!domains.contains(normalized)) { domains.add(normalized) }
                }
                config.authorPolicy.recordOnlyEmailDomains = domains.toArray()
            } catch (_: Exception) { () }
        case None => ()
    }
    let unknown = firstJsonString(obj, ["unknownEmailDecision"])
    if (!unknown.isEmpty()) { config.authorPolicy.unknownEmailDecision = unknown.trimAscii().toAsciiLower() }
}

public func normalizeAuthorPolicyDomain(raw: String): String {
    let trimmed = raw.trimAscii().toAsciiLower()
    if (trimmed.startsWith("@")) { trimmed } else { "@${trimmed}" }
}

public func validateAuthorPolicyConfig(policy: AuthorPolicyConfig): String {
    if (policy.unknownEmailDecision.trimAscii().toAsciiLower() != "process") {
        return "author_policy_unknown_email_decision"
    }
    for (domain in policy.recordOnlyEmailDomains) {
        if (!authorPolicyDomainIsValid(domain)) {
            return "author_policy_invalid_domain"
        }
    }
    "ok"
}

func authorPolicyDomainIsValid(domain: String): Bool {
    let value = domain.trimAscii().toAsciiLower()
    if (value.isEmpty() || value == "@") { return false }
    if (!value.startsWith("@")) { return false }
    if (!value.contains(".")) { return false }
    if (value.contains(" ") || value.contains("\t") || value.contains("\n") || value.contains("\r")) { return false }
    if (value.contains("*") || value.contains("://") || value.contains("/") || value.contains("\\") || value.contains(",") || value.contains(";")) { return false }
    if (value.startsWith("@.") || value.endsWith(".")) { return false }
    true
}

func applyMetisSection(config: MonitorConfig, obj: JsonObject): Unit {
    let endpoint = firstJsonString(obj, ["mcpEndpoint", "endpoint", "metisMcpEndpoint"])
    if (!endpoint.isEmpty()) { config.mcpEndpoint = endpoint }
    let token = firstJsonString(obj, ["mcpServiceToken", "serviceToken", "metisServiceToken"])
    if (!token.isEmpty()) { config.mcpServiceToken = token }
}

func applyMonitorSection(config: MonitorConfig, obj: JsonObject): Unit {
    let interval = firstJsonInt(obj, ["fullScanIntervalMinutes"])
    if (interval > 0) { config.fullScanIntervalMinutes = interval }
    let jitter = firstJsonInt(obj, ["jitterSeconds"])
    if (jitter >= 0) { config.jitterSeconds = jitter }
    let statePath = firstJsonString(obj, ["statePath"])
    if (!statePath.isEmpty()) {
        config.statePath = statePath
        if (config.webhook.queueDir == "data/webhook-queue") {
            config.webhook = defaultWebhookReceiverConfigForStatePath(config.statePath)
        }
    }
    let transport = firstJsonString(obj, ["transport", "httpTransport"])
    if (!transport.isEmpty()) { config.httpTransport = transport }
    config.dryRun = firstJsonBool(obj, ["dryRun"], config.dryRun)
    config.autoReply = firstJsonBool(obj, ["autoReply"], config.autoReply)
    let orgs = firstJsonStringArray(obj, ["orgs", "organizations"])
    if (orgs.size > 0) { config.orgs = orgs }
    let allowlist = firstJsonStringArray(obj, ["repoAllowlist", "allowlist"])
    if (allowlist.size > 0) { config.repoAllowlist = normalizeWritebackScopeArray(allowlist) }
    match (obj.get("writebackScope")) {
        case Some(value) => try { applyWritebackScopeSection(config, value.asObject()) } catch (_: Exception) { () }
        case None => ()
    }
}

func applyWritebackScopeSection(config: MonitorConfig, obj: JsonObject): Unit {
    config.writebackScope.allowedOrgs = normalizeWritebackScopeArray(firstJsonStringArray(obj, ["allowedOrgs"]))
    config.writebackScope.allowedRepos = normalizeWritebackScopeArray(firstJsonStringArray(obj, ["allowedRepos"]))
    config.writebackScope.deniedRepos = normalizeWritebackScopeArray(firstJsonStringArray(obj, ["deniedRepos"]))
}

func applyWebhookSection(config: MonitorConfig, obj: JsonObject): Unit {
    let endpoints = ArrayList<WebhookEndpointConfig>()
    match (obj.get("endpoints")) {
        case Some(value) =>
            try {
                for (item in value.asArray().getItems()) {
                    try {
                        endpoints.add(parseWebhookEndpoint(item.asObject()))
                    } catch (_inner: Exception) { () }
                }
            } catch (_: Exception) { () }
        case None => ()
    }
    let enabled = firstJsonBool(obj, ["enabled"], config.webhook.enabled)
    let bindHost = firstNonEmpty([firstJsonString(obj, ["bindHost", "host"]), config.webhook.bindHost])
    let port = firstPositiveOrDefault(firstJsonInt(obj, ["port"]), config.webhook.port)
    let publicBaseUrl = firstNonEmpty([firstJsonString(obj, ["publicBaseUrl", "publicUrl"]), config.webhook.publicBaseUrl])
    let maxBodyBytes = firstPositiveOrDefault(firstJsonInt(obj, ["maxBodyBytes"]), config.webhook.maxBodyBytes)
    let queueDir = firstNonEmpty([firstJsonString(obj, ["queueDir"]), config.webhook.queueDir])
    let deadLetterDir = firstJsonString(obj, ["deadLetterDir"])
    let ackMode = firstNonEmpty([firstJsonString(obj, ["ackMode"]), config.webhook.ackMode])
    config.webhook = WebhookReceiverConfig(
        enabled: enabled,
        bindHost: bindHost,
        port: port,
        publicBaseUrl: publicBaseUrl,
        maxBodyBytes: maxBodyBytes,
        queueDir: queueDir,
        deadLetterDir: if (deadLetterDir.isEmpty()) { "" } else { deadLetterDir },
        ackMode: ackMode,
        endpoints: if (endpoints.size > 0) { endpoints.toArray() } else { config.webhook.endpoints },
        processor: config.webhook.processor,
        reconcile: config.webhook.reconcile
    )
}

func parseWebhookEndpoint(obj: JsonObject): WebhookEndpointConfig {
    WebhookEndpointConfig(
        firstJsonString(obj, ["id", "name"]),
        firstJsonString(obj, ["path"]),
        token: firstJsonString(obj, ["token", "secretToken"]),
        signatureSecret: firstJsonString(obj, ["signatureSecret", "signingSecret"]),
        allowedEvents: if (firstJsonStringArray(obj, ["allowedEvents", "events"]).size > 0) { firstJsonStringArray(obj, ["allowedEvents", "events"]) } else { ["Merge Request Hook", "Issue Hook", "Note Hook"] },
        enabled: firstJsonBool(obj, ["enabled"], true)
    )
}

func firstPositiveOrDefault(value: Int64, fallback: Int64): Int64 {
    if (value > 0) { value } else { fallback }
}

func gitCodeAuthPresent(config: MonitorConfig): Bool {
    !config.gitCodeToken.isEmpty() || !config.gitCodeCookie.isEmpty() || (!config.gitCodeUsername.isEmpty() && !config.gitCodePassword.isEmpty())
}

func collectPagedEvents(repo: GitCodeRepo, kind: String, transport: GitCodeHttpTransport, state: MonitorState, out: ArrayList<GitCodeEvent>): String {
    var page: Int64 = 1
    while (true) {
        let result = if (kind == "pr") { transport.listPullRequestsPage(repo, page) } else { transport.listIssuesPage(repo, page) }
        if (result.errorKind != "ok") {
            state.setBackoff(repo.fullName(), result.retryAfterMs)
            return result.errorKind
        }
        for (event in result.events) {
            out.add(event)
            var commentPage: Int64 = 1
            while (true) {
                let comments = transport.listCommentsPage(repo, kind, event.itemId, commentPage)
                if (comments.errorKind != "ok") {
                    state.setBackoff(repo.fullName(), comments.retryAfterMs)
                    return comments.errorKind
                }
                for (comment in comments.events) { out.add(comment) }
                if (comments.events.size < transport.pageSize) { break }
                commentPage++
            }
        }
        if (result.events.size < transport.pageSize) { break }
        page++
    }
    "ok"
}

public func parseReposResponse(body: String, org: String): Array<GitCodeRepo> {
    let out = ArrayList<GitCodeRepo>()
    try {
        let root = JsonValue.fromStr(body)
        for (obj in jsonObjectItems(root)) {
            var name = firstJsonString(obj, ["path", "name", "repo", "slug"])
            if (name.isEmpty()) {
                let full = firstJsonString(obj, ["full_name", "path_with_namespace", "name_with_namespace"])
                if (full.contains("/")) { name = full.split("/")[full.split("/").size - 1].trimAscii() }
            }
            let visibility = firstJsonString(obj, ["visibility"]).toAsciiLower()
            let isPublic = firstJsonBool(obj, ["public"], false)
            let isPrivate = firstJsonBool(obj, ["private"], false)
            let isInternal = firstJsonBool(obj, ["internal"], false)
            if (!name.isEmpty() && repoVisibilityDecision(isPublic, isPrivate, isInternal, visibility) == "public") {
                out.add(GitCodeRepo(
                    org,
                    name,
                    visibility: visibility,
                    isPublic: isPublic || visibility == "public",
                    isPrivate: isPrivate || visibility == "private",
                    isInternal: isInternal || visibility == "internal",
                    defaultBranch: firstJsonString(obj, ["default_branch", "defaultBranch"]),
                    htmlUrl: firstJsonString(obj, ["html_url", "web_url", "url"])
                ))
            }
        }
    } catch (_: Exception) { () }
    out.toArray()
}

public func repoVisibilityDecision(isPublic: Bool, isPrivate: Bool, isInternal: Bool, visibility: String): String {
    let v = visibility.toAsciiLower()
    if (isPrivate || v == "private") { return "private" }
    if (isInternal || v == "internal") { return "internal" }
    if (isPublic || v == "public") { return "public" }
    "visibility_unknown"
}

public func parseItemsResponse(body: String, repo: GitCodeRepo, kind: String): Array<GitCodeEvent> {
    let out = ArrayList<GitCodeEvent>()
    try {
        let root = JsonValue.fromStr(body)
        for (obj in jsonObjectItems(root)) {
            let itemId = firstJsonString(obj, ["iid", "number", "id", "pull_request_number"])
            let title = firstJsonString(obj, ["title", "name"])
            let desc = firstJsonString(obj, ["body", "description", "content"])
            let actor = actorName(obj)
            let url = firstJsonString(obj, ["html_url", "web_url", "url"])
            let content = if (desc.isEmpty()) { title } else { "${title}\n${desc}" }
            if (!itemId.isEmpty()) {
                out.add(GitCodeEvent(canonicalGitCodeEventId(repo, kind, itemId), repo.org, repo.name, kind, itemId, actor, actorUrl(obj), url, content, updatedAtMs: firstJsonInt(obj, ["updated_at_ms", "updatedAtMs"])))
            }
        }
    } catch (_: Exception) { () }
    out.toArray()
}

public func parseCommentsResponse(body: String, repo: GitCodeRepo, kind: String, itemId: String): Array<GitCodeEvent> {
    let out = ArrayList<GitCodeEvent>()
    try {
        let root = JsonValue.fromStr(body)
        for (obj in jsonObjectItems(root)) {
            let commentId = firstJsonString(obj, ["id", "note_id", "comment_id"])
            let bodyText = firstJsonString(obj, ["body", "note", "content"])
            if (!commentId.isEmpty()) {
                out.add(GitCodeEvent(canonicalGitCodeEventId(repo, kind, itemId, commentId: commentId), repo.org, repo.name, kind, itemId, actorName(obj), actorUrl(obj), firstJsonString(obj, ["html_url", "web_url", "url"]), bodyText, updatedAtMs: firstJsonInt(obj, ["updated_at_ms", "updatedAtMs"])))
            }
        }
    } catch (_: Exception) { () }
    out.toArray()
}

func retryAfterMs(res: HttpResponseSpec): Int64 {
    for ((key, value) in res.headers) {
        if (key.toAsciiLower() == "retry-after") {
            return try { Int64.parse(value.trimAscii()) * 1000 } catch (_: Exception) { 60000 }
        }
    }
    if (res.statusCode == 429) { return 60000 }
    if (res.statusCode >= 500) { return 30000 }
    0
}

func arrayContains(items: Array<String>, value: String): Bool {
    for (item in items) {
        if (item == value) { return true }
    }
    false
}

func writebackScopeHasAllow(config: MonitorConfig): Bool {
    config.writebackScope.allowedOrgs.size > 0 || config.writebackScope.allowedRepos.size > 0
}

func writebackOrgScopeIsValid(raw: String): Bool {
    let value = raw.trimAscii()
    !value.isEmpty() && !value.contains("/")
}

func writebackRepoScopeIsValid(raw: String): Bool {
    let value = raw.trimAscii()
    if (value.isEmpty()) { return false }
    let parts = value.split("/")
    parts.size == 2 && !parts[0].trimAscii().isEmpty() && !parts[1].trimAscii().isEmpty()
}

func normalizeWritebackRepoFullName(repoFullName: String): String {
    if (!writebackRepoScopeIsValid(repoFullName)) { return "" }
    let parts = repoFullName.trimAscii().split("/")
    "${parts[0].trimAscii()}/${parts[1].trimAscii()}"
}

func normalizeWritebackScopeArray(items: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (item in items) {
        addUniqueWritebackScopeValue(out, item)
    }
    out.toArray()
}

func addUniqueWritebackScopeValue(out: ArrayList<String>, raw: String): Unit {
    let value = raw.trimAscii()
    if (value.isEmpty()) { return }
    let expected = value.toAsciiLower()
    for (item in out) {
        if (item.trimAscii().toAsciiLower() == expected) { return }
    }
    out.add(value)
}

func findWritebackRepoScopeMatch(items: Array<String>, normalizedRepo: String): String {
    let expected = normalizedRepo.trimAscii().toAsciiLower()
    for (item in items) {
        let normalizedItem = normalizeWritebackRepoFullName(item)
        if (!normalizedItem.isEmpty() && normalizedItem.toAsciiLower() == expected) {
            return item.trimAscii()
        }
    }
    ""
}

func findWritebackOrgScopeMatch(items: Array<String>, owner: String): String {
    let expected = owner.trimAscii().toAsciiLower()
    for (item in items) {
        let value = item.trimAscii()
        if (!value.isEmpty() && !value.contains("/") && value.toAsciiLower() == expected) {
            return value
        }
    }
    ""
}

func joinStrings(items: Array<String>, sep: String): String {
    let out = StringBuilder()
    for (i in 0..items.size) {
        if (i > 0) { out.append(sep) }
        out.append(items[i])
    }
    out.toString()
}

func stringArrayJson(items: Array<String>): JsonArray {
    let arr = JsonArray([])
    for (item in items) { arr.add(JsonString(item)) }
    arr
}

func readJsonString(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(v) => try { v.asString().getValue() } catch (_: Exception) { "" }
        case None => ""
    }
}

func readJsonInt(o: JsonObject, key: String): Int64 {
    match (o.get(key)) {
        case Some(v) => try { Int64.parse(v.toJsonString()) } catch (_: Exception) { 0 }
        case None => 0
    }
}

func readJsonStringArray(o: JsonObject, key: String): Array<String> {
    let out = ArrayList<String>()
    match (o.get(key)) {
        case Some(v) =>
            try {
                for (item in v.asArray().getItems()) {
                    try { out.add(item.asString().getValue()) } catch (_inner: Exception) { () }
                }
            } catch (_: Exception) { () }
        case None => ()
    }
    out.toArray()
}

func firstJsonString(o: JsonObject, keys: Array<String>): String {
    for (key in keys) {
        match (o.get(key)) {
            case Some(v) =>
                let value = jsonValueToString(v)
                if (!value.isEmpty()) { return value }
            case None => ()
        }
    }
    ""
}

func firstJsonInt(o: JsonObject, keys: Array<String>): Int64 {
    for (key in keys) {
        match (o.get(key)) {
            case Some(v) =>
                let parsed = try { Int64.parse(jsonValueToString(v)) } catch (_: Exception) { 0 }
                if (parsed != 0) { return parsed }
            case None => ()
        }
    }
    0
}

func firstJsonBool(o: JsonObject, keys: Array<String>, fallback: Bool): Bool {
    for (key in keys) {
        match (o.get(key)) {
            case Some(v) =>
                let raw = jsonValueToString(v).toAsciiLower()
                if (raw == "true") { return true }
                if (raw == "false") { return false }
            case None => ()
        }
    }
    fallback
}

func firstJsonStringArray(o: JsonObject, keys: Array<String>): Array<String> {
    for (key in keys) {
        match (o.get(key)) {
            case Some(v) =>
                let out = ArrayList<String>()
                try {
                    for (item in v.asArray().getItems()) {
                        let text = jsonValueToString(item)
                        if (!text.isEmpty()) { out.add(text) }
                    }
                } catch (_: Exception) { () }
                if (out.size > 0) { return out.toArray() }
            case None => ()
        }
    }
    []
}

func jsonObjectItems(root: JsonValue): Array<JsonObject> {
    let out = ArrayList<JsonObject>()
    try {
        for (item in root.asArray().getItems()) {
            try { out.add(item.asObject()) } catch (_inner: Exception) { () }
        }
    } catch (_: Exception) {
        try {
            let obj = root.asObject()
            for (key in ["data", "items", "projects", "repos", "issues", "pulls", "comments", "result"]) {
                match (obj.get(key)) {
                    case Some(v) =>
                        try {
                            for (item in v.asArray().getItems()) {
                                try { out.add(item.asObject()) } catch (_inner: Exception) { () }
                            }
                            if (out.size > 0) { return out.toArray() }
                        } catch (_inner: Exception) { () }
                    case None => ()
                }
            }
        } catch (_inner: Exception) { () }
    }
    out.toArray()
}

func actorName(obj: JsonObject): String {
    let direct = firstJsonString(obj, ["author", "user", "login", "username", "name"])
    if (!direct.startsWith("{")) { return direct }
    nestedUserString(obj, ["author", "user"], ["login", "username", "name"])
}

func actorUrl(obj: JsonObject): String {
    let direct = firstJsonString(obj, ["author_url", "user_url"])
    if (!direct.isEmpty()) { return direct }
    nestedUserString(obj, ["author", "user"], ["html_url", "web_url", "url"])
}

func nestedUserString(obj: JsonObject, objectKeys: Array<String>, valueKeys: Array<String>): String {
    for (key in objectKeys) {
        match (obj.get(key)) {
            case Some(v) =>
                try {
                    let nested = v.asObject()
                    let text = firstJsonString(nested, valueKeys)
                    if (!text.isEmpty()) { return text }
                } catch (_: Exception) { () }
            case None => ()
        }
    }
    ""
}

func jsonValueToString(v: JsonValue): String {
    try {
        return v.asString().getValue()
    } catch (_: Exception) {
        let raw = v.toJsonString()
        if (raw.startsWith("\"") && raw.endsWith("\"") && raw.size >= 2) {
            return raw[1..raw.size - 1]
        }
        raw
    }
}

func trimTrailingSlash(raw: String): String {
    if (raw.endsWith("/")) { raw[0..raw.size - 1] } else { raw }
}

func boundedPageSize(pageSize: Int64): Int64 {
    if (pageSize > 100) { return 100 }
    if (pageSize < 1) { return 1 }
    pageSize
}

func urlPart(raw: String): String {
    raw.replace(" ", "%20").replace("/", "%2F").replace(":", "%3A").replace("+", "%2B")
}

func redactUrl(raw: String): String {
    if (raw.contains("/bot") && raw.contains("/sendMessage")) {
        let before = raw.split("/bot")[0]
        let after = raw.split("/sendMessage")[1]
        return "${before}/bot[REDACTED]/sendMessage${after}"
    }
    if (raw.contains("access_token=")) {
        return raw.replace(raw.split("access_token=")[1].split("&")[0], "[REDACTED]")
    }
    raw
}
