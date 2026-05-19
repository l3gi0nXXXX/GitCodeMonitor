package gitcodemonitor

import std.collection.*

public let SELF_MARKER = "<!-- gitcodemonitor:auto-reply:v1 -->"

public class MonitorConfig {
    public var orgs: Array<String>
    public var fullScanIntervalMinutes: Int64
    public var minProduction: Int64
    public var jitterSeconds: Int64
    public var dryRun: Bool
    public var autoReply: Bool
    public var acpEnabled: Bool
    public var repoAllowlist: Array<String>
    public var acpEndpoint: String
    public var acpServiceToken: String
    public var acpAllowedTasks: Array<String>

    public init() {
        this.orgs = ["cangjie", "cangjie-sig", "cangjie-tpc"]
        this.fullScanIntervalMinutes = 10
        this.minProduction = 5
        this.jitterSeconds = 30
        this.dryRun = true
        this.autoReply = false
        this.acpEnabled = false
        this.repoAllowlist = []
        this.acpEndpoint = ""
        this.acpServiceToken = ""
        this.acpAllowedTasks = []
    }
}

public func defaultConfig(): MonitorConfig {
    MonitorConfig()
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
    return "ok"
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

    public init(eventId: String, status!: String = "pending", reason!: String = "") {
        this.eventId = eventId
        this.status = status
        this.reason = reason
        this.requestId = "req-" + eventId
        this.replyUrl = ""
    }
}

public class MonitorState {
    private let seenEvents = HashSet<String>()
    private let mcpCalled = HashSet<String>()
    private let replied = HashSet<String>()
    public let audit = ArrayList<AuditRecord>()
    public var lastFullScanAtMs: Int64 = 0
    public var skippedOverlappingScans: Int64 = 0

    public init() {}

    public func hasSeen(eventId: String): Bool { seenEvents.contains(eventId) }
    public func markSeen(eventId: String): Unit { seenEvents.add(eventId) }
    public func hasMcpCall(eventId: String): Bool { mcpCalled.contains(eventId) }
    public func markMcpCall(eventId: String): Unit { mcpCalled.add(eventId) }
    public func hasReply(eventId: String): Bool { replied.contains(eventId) }
    public func markReply(eventId: String): Unit { replied.add(eventId) }
    public func addAudit(record: AuditRecord): Unit { audit.add(record) }
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
    public init(org: String, name: String) {
        this.org = org
        this.name = name
    }
    public func fullName(): String { "${org}/${name}" }
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

public class DeliveryAudit {
    public let eventId: String
    public let channel: String
    public let status: String
    public let error: String
    public init(eventId: String, channel: String, status: String, error!: String = "") {
        this.eventId = eventId
        this.channel = channel
        this.status = status
        this.error = error
    }
}

public class FakeNotifier {
    public let channel: String
    public var failNext: Bool = false
    public let deliveries = ArrayList<DeliveryAudit>()
    public init(channel: String) { this.channel = channel }
    public func notify(event: GitCodeEvent): DeliveryAudit {
        if (failNext) {
            failNext = false
            let audit = DeliveryAudit(event.id, channel, "failed", error: "fake failure")
            deliveries.add(audit)
            return audit
        }
        let audit = DeliveryAudit(event.id, channel, "sent")
        deliveries.add(audit)
        return audit
    }
}

public class ToolSchema {
    public let name: String
    public let version: String
    public let schemaHash: String
    public init(name: String, version!: String = "v1", schemaHash!: String = "hash") {
        this.name = name
        this.version = version
        this.schemaHash = schemaHash
    }
}

public class ToolInput {
    public let toolName: String
    public let eventId: String
    public let repo: String
    public let body: String
    public init(toolName: String, eventId: String, repo: String, body: String) {
        this.toolName = toolName
        this.eventId = eventId
        this.repo = repo
        this.body = body
    }
}

public class McpResult {
    public let ok: Bool
    public let draft: String
    public let approved: Bool
    public let needsHumanReview: Bool
    public let errorKind: String
    public init(ok: Bool, draft!: String = "", approved!: Bool = true, needsHumanReview!: Bool = false, errorKind!: String = "") {
        this.ok = ok
        this.draft = draft
        this.approved = approved
        this.needsHumanReview = needsHumanReview
        this.errorKind = errorKind
    }
}

public class FakeMcpClient {
    public var available: Bool = true
    public var initialized: Bool = false
    public let schemas = ArrayList<ToolSchema>()

    public init() {
        schemas.add(ToolSchema("gitcode_issue_summary"))
        schemas.add(ToolSchema("gitcode_issue_draft_reply"))
        schemas.add(ToolSchema("gitcode_pr_summary"))
        schemas.add(ToolSchema("gitcode_pr_draft_reply"))
        schemas.add(ToolSchema("gitcode_safety_review"))
    }

    public func initialize(): Bool {
        initialized = available
        initialized
    }

    public func toolsList(): Array<ToolSchema> { schemas.toArray() }

    public func call(input: ToolInput): McpResult {
        if (!available) { return McpResult(false, errorKind: "mcp_down") }
        McpResult(true, draft: "Draft reply for ${input.eventId}", approved: true, needsHumanReview: false)
    }
}

public func eventToToolInput(event: GitCodeEvent): ToolInput {
    let tool = if (event.itemKind == "pr") { "gitcode_pr_draft_reply" } else { "gitcode_issue_draft_reply" }
    ToolInput(tool, event.id, "${event.org}/${event.repo}", event.content)
}

public class WriteDecision {
    public let allowed: Bool
    public let reason: String
    public init(allowed: Bool, reason: String) {
        this.allowed = allowed
        this.reason = reason
    }
}

public func writebackGate(config: MonitorConfig, state: MonitorState, event: GitCodeEvent, mcp: McpResult): WriteDecision {
    if (config.dryRun) { return WriteDecision(false, "dry_run") }
    if (!config.autoReply) { return WriteDecision(false, "auto_reply_disabled") }
    if (!arrayContains(config.repoAllowlist, "${event.org}/${event.repo}")) { return WriteDecision(false, "repo_not_allowlisted") }
    if (!mcp.ok || !mcp.approved || mcp.needsHumanReview) { return WriteDecision(false, "safety_rejected") }
    if (state.hasReply(event.id)) { return WriteDecision(false, "duplicate") }
    if (event.content.contains(SELF_MARKER)) { return WriteDecision(false, "self_marker") }
    if (containsSecret(mcp.draft)) { return WriteDecision(false, "secret_detected") }
    return WriteDecision(true, "allowed")
}

public class FakeCommentWriter {
    public let written = ArrayList<String>()
    public init() {}
    public func write(event: GitCodeEvent, body: String, state: MonitorState): String {
        let withMarker = body + "\n\n" + SELF_MARKER
        written.add(withMarker)
        state.markReply(event.id)
        "https://gitcode.com/${event.org}/${event.repo}/comments/${written.size}"
    }
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

public class ScanResult {
    public let accepted: Int64
    public let ignored: Int64
    public let notified: Int64
    public let mcpCalls: Int64
    public let writes: Int64
    public init(accepted: Int64, ignored: Int64, notified: Int64, mcpCalls: Int64, writes: Int64) {
        this.accepted = accepted
        this.ignored = ignored
        this.notified = notified
        this.mcpCalls = mcpCalls
        this.writes = writes
    }
}

public func scanOnce(config: MonitorConfig, transport: FakeGitCodeTransport, state: MonitorState, feishu: FakeNotifier, telegram: FakeNotifier, mcp: FakeMcpClient, writer: FakeCommentWriter): ScanResult {
    var accepted: Int64 = 0
    var ignored: Int64 = 0
    var notified: Int64 = 0
    var mcpCalls: Int64 = 0
    var writes: Int64 = 0
    for (repo in transport.repos) {
        for (event in transport.scanRepo(repo)) {
            let filter = filterEvent(event)
            if (filter.ignored) {
                ignored++
                state.addAudit(AuditRecord(event.id, status: "ignored", reason: filter.reason))
                continue
            }
            if (state.hasSeen(event.id)) {
                state.addAudit(AuditRecord(event.id, status: "skipped_duplicate", reason: "seen"))
                continue
            }
            state.markSeen(event.id)
            accepted++
            feishu.notify(event)
            telegram.notify(event)
            notified += 2
            let audit = AuditRecord(event.id, status: "accepted")
            state.addAudit(audit)
            if (!state.hasMcpCall(event.id)) {
                let input = eventToToolInput(event)
                let mcpResult = mcp.call(input)
                if (mcpResult.ok) {
                    state.markMcpCall(event.id)
                    mcpCalls++
                    audit.status = "drafted"
                    let decision = writebackGate(config, state, event, mcpResult)
                    audit.reason = decision.reason
                    if (decision.allowed) {
                        audit.replyUrl = writer.write(event, mcpResult.draft, state)
                        writes++
                    }
                } else {
                    audit.status = "mcp_degraded"
                    audit.reason = mcpResult.errorKind
                }
            }
        }
    }
    ScanResult(accepted, ignored, notified, mcpCalls, writes)
}

public func doctorReport(config: MonitorConfig, state: MonitorState, mcp: FakeMcpClient): String {
    let acp = if (config.acpEnabled) { "enabled" } else { "disabled" }
    "GitCodeMonitor doctor\norgs=${config.orgs.size}\nfullScanIntervalMinutes=${config.fullScanIntervalMinutes}\ndryRun=${config.dryRun}\nautoReply=${config.autoReply}\nacp=${acp}\nmcpInitialized=${mcp.initialized}\naudit=${state.audit.size}"
}

func arrayContains(items: Array<String>, value: String): Bool {
    for (item in items) {
        if (item == value) { return true }
    }
    false
}
