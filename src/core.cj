package gitcodemonitor

import std.collection.*
import std.convert.Parsable
import std.env.getVariable
import std.fs.{Directory, File, Path, exists}
import std.process.executeWithOutput
import stdx.encoding.json.{JsonArray, JsonBool, JsonInt, JsonObject, JsonString, JsonValue}

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
    public var gitCodeBaseUrl: String
    public var gitCodeAuthMode: String
    public var gitCodeToken: String
    public var gitCodeCookie: String
    public var gitCodeUsername: String
    public var gitCodePassword: String
    public var mcpEndpoint: String
    public var mcpServiceToken: String
    public var statePath: String
    public var notifyNetworkEnabled: Bool
    public var feishuWebhook: String
    public var telegramBotToken: String
    public var telegramChatId: String

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
        this.gitCodeBaseUrl = "https://gitcode.com/api/v5"
        this.gitCodeAuthMode = "PRIVATE-TOKEN"
        this.gitCodeToken = ""
        this.gitCodeCookie = ""
        this.gitCodeUsername = ""
        this.gitCodePassword = ""
        this.mcpEndpoint = ""
        this.mcpServiceToken = ""
        this.statePath = "data/gitcodemonitor-state.json"
        this.notifyNetworkEnabled = false
        this.feishuWebhook = ""
        this.telegramBotToken = ""
        this.telegramChatId = ""
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
    if (!config.dryRun && config.autoReply && config.repoAllowlist.size == 0) {
        return "writeback enabled but repo allowlist missing"
    }
    if (!config.notifyNetworkEnabled && (!config.feishuWebhook.isEmpty() || !config.telegramBotToken.isEmpty())) {
        return "ok"
    }
    return "ok"
}

public func configSummary(config: MonitorConfig): String {
    let auth = if (gitCodeAuthPresent(config)) { "present" } else { "absent" }
    let mcpAuth = if (config.mcpServiceToken.isEmpty()) { "absent" } else { "present" }
    let notifyAuth = if (!config.feishuWebhook.isEmpty() || (!config.telegramBotToken.isEmpty() && !config.telegramChatId.isEmpty())) { "present" } else { "absent" }
    "GitCodeMonitor config\n" +
        "orgs=${joinStrings(config.orgs, ",")}\n" +
        "gitCodeBaseUrl=${config.gitCodeBaseUrl}\n" +
        "gitCodeAuth=${config.gitCodeAuthMode}:${auth}\n" +
        "mcpEndpoint=${config.mcpEndpoint}\n" +
        "mcpAuth=${mcpAuth}\n" +
        "notificationAuth=${notifyAuth}\n" +
        "dryRun=${config.dryRun}\n" +
        "autoReply=${config.autoReply}\n" +
        "allowlist=${joinStrings(config.repoAllowlist, ",")}\n" +
        "notifyNetworkEnabled=${config.notifyNetworkEnabled}\n" +
        "statePath=${config.statePath}"
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

public func compactSummary(raw: String, limit!: Int64 = 280): String {
    let t = raw.trimAscii().replace("\n", " ").replace("\r", " ")
    if (t.size <= limit) { return t }
    t[0..limit] + "..."
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
    public func seenCount(): Int64 { seenEvents.size }
    public func mcpCallCount(): Int64 { mcpCalled.size }
    public func replyCount(): Int64 { replied.size }
    public func setBackoff(key: String, untilMs: Int64): Unit { backoff[key] = untilMs }
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
}

public class StateStore {
    public let path: Path
    public init(path: String) { this.path = Path(path) }

    public func save(state: MonitorState): Bool {
        try {
            let parent = path.parent
            if (!exists(parent)) { Directory.create(parent, recursive: true) }
            File.writeTo(path, stateToJson(state).toJsonString().toArray())
            true
        } catch (_: Exception) {
            false
        }
    }

    public func load(): MonitorState {
        let state = MonitorState()
        if (!exists(path)) { return state }
        try {
            let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
            state.lastFullScanAtMs = readJsonInt(root, "lastFullScanAtMs")
            state.skippedOverlappingScans = readJsonInt(root, "skippedOverlappingScans")
            for (id in readJsonStringArray(root, "seenEvents")) { state.markSeen(id) }
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
        } catch (_: Exception) {
            state.addAudit(AuditRecord("state-load", status: "state_error", reason: "corrupt_or_unreadable"))
        }
        state
    }
}

public func stateToJson(state: MonitorState): JsonObject {
    let root = JsonObject()
    root.put("schemaVersion", JsonInt(1))
    root.put("lastFullScanAtMs", JsonInt(state.lastFullScanAtMs))
    root.put("skippedOverlappingScans", JsonInt(state.skippedOverlappingScans))
    root.put("seenEvents", stringArrayJson(state.seenIds()))
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
    public init(org: String, name: String) {
        this.org = org
        this.name = name
    }
    public func fullName(): String { "${org}/${name}" }
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

public class FakeHttpSender {
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

public class CurlHttpSender {
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
        let (exitCode, stdoutBytes, stderrBytes) = executeWithOutput("curl", curlArgs(request))
        if (exitCode != 0) {
            return HttpResponseSpec(599, body: String.fromUtf8(stderrBytes))
        }
        let text = String.fromUtf8(stdoutBytes)
        let lines = text.split("\n")
        if (lines.size == 0) { return HttpResponseSpec(599) }
        let code = try { Int64.parse(lines[lines.size - 1].trimAscii()) } catch (_: Exception) { 599 }
        let body = if (lines.size > 1) { joinStrings(lines[0..lines.size - 1], "\n") } else { "" }
        HttpResponseSpec(code, body: body)
    }
}

public class GitCodeApiClient {
    public let baseUrl: String
    public let authMode: String
    private let token: String
    private let cookie: String

    public init(baseUrl!: String = "https://gitcode.com/api/v5", authMode!: String = "PRIVATE-TOKEN", token!: String = "", cookie!: String = "") {
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
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/orgs/${urlPart(org)}/projects?page=${page}&per_page=${pageSize}"), headers: authHeaders())
    }

    public func listIssuesRequest(repo: GitCodeRepo, page: Int64, pageSize: Int64): HttpRequestSpec {
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/issues?page=${page}&per_page=${pageSize}"), headers: authHeaders())
    }

    public func listPullRequestsRequest(repo: GitCodeRepo, page: Int64, pageSize: Int64): HttpRequestSpec {
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/pulls?page=${page}&per_page=${pageSize}"), headers: authHeaders())
    }

    public func listCommentsRequest(repo: GitCodeRepo, itemKind: String, itemId: String, page: Int64, pageSize: Int64): HttpRequestSpec {
        let kind = if (itemKind == "pr") { "pulls" } else { "issues" }
        HttpRequestSpec("GET", withAuthQuery("${baseUrl}/repos/${urlPart(repo.org)}/${urlPart(repo.name)}/${kind}/${urlPart(itemId)}/comments?page=${page}&per_page=${pageSize}"), headers: authHeaders())
    }

    public func postCommentRequest(event: GitCodeEvent, body: String): HttpRequestSpec {
        let kind = if (event.itemKind == "pr") { "pulls" } else { "issues" }
        let json = "{\"body\":\"${jsonEscape(body + "\n\n" + SELF_MARKER)}\"}"
        HttpRequestSpec("POST", withAuthQuery("${baseUrl}/repos/${urlPart(event.org)}/${urlPart(event.repo)}/${kind}/${urlPart(event.itemId)}/comments"), headers: authHeaders().concat([("Content-Type", "application/json")]), body: json)
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
    public let sender: FakeHttpSender
    public let pageSize: Int64
    public init(client: GitCodeApiClient, sender!: FakeHttpSender = FakeHttpSender(), pageSize!: Int64 = 50) {
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
    let out = ArrayList<GitCodeEvent>()
    collectPagedEvents(repo, "issue", transport, state, out)
    collectPagedEvents(repo, "pr", transport, state, out)
    out.toArray()
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

public class NotifierPayload {
    public let channel: String
    public let request: HttpRequestSpec
    public init(channel: String, request: HttpRequestSpec) {
        this.channel = channel
        this.request = request
    }
}

public func buildFeishuPayload(webhook: String, event: GitCodeEvent): NotifierPayload {
    let body = "{" +
        "\"msg_type\":\"text\"," +
        "\"content\":{\"text\":\"${jsonEscape(notificationText(event))}\"}" +
        "}"
    NotifierPayload("feishu", HttpRequestSpec("POST", webhook, headers: [("Content-Type", "application/json")], body: body))
}

public func buildTelegramPayload(botToken: String, chatId: String, event: GitCodeEvent): NotifierPayload {
    let body = "{" +
        "\"chat_id\":\"${jsonEscape(chatId)}\"," +
        "\"text\":\"${jsonEscape(notificationText(event))}\"," +
        "\"disable_web_page_preview\":true" +
        "}"
    NotifierPayload("telegram", HttpRequestSpec("POST", "https://api.telegram.org/bot${botToken}/sendMessage", headers: [("Content-Type", "application/json")], body: body))
}

public class HttpNotifier {
    public let channel: String
    public let networkEnabled: Bool
    public let sender: FakeHttpSender
    private let webhookOrToken: String
    private let chatId: String
    public let deliveries = ArrayList<DeliveryAudit>()

    public init(channel: String, networkEnabled!: Bool = false, webhookOrToken!: String = "", chatId!: String = "", sender!: FakeHttpSender = FakeHttpSender()) {
        this.channel = channel
        this.networkEnabled = networkEnabled
        this.webhookOrToken = webhookOrToken
        this.chatId = chatId
        this.sender = sender
    }

    public func notify(event: GitCodeEvent): DeliveryAudit {
        let payload = if (channel == "telegram") { buildTelegramPayload(webhookOrToken, chatId, event) } else { buildFeishuPayload(webhookOrToken, event) }
        if (!networkEnabled) {
            let audit = DeliveryAudit(event.id, channel, "dry_run")
            deliveries.add(audit)
            return audit
        }
        let res = sender.send(payload.request)
        let status = if (res.statusCode >= 200 && res.statusCode < 300) { "sent" } else { mapGitCodeError(res.statusCode) }
        let audit = DeliveryAudit(event.id, channel, status)
        deliveries.add(audit)
        audit
    }
}

public class CurlNotifier {
    public let channel: String
    public let networkEnabled: Bool
    public let sender: CurlHttpSender
    private let webhookOrToken: String
    private let chatId: String
    public let deliveries = ArrayList<DeliveryAudit>()

    public init(channel: String, networkEnabled!: Bool = false, webhookOrToken!: String = "", chatId!: String = "", sender!: CurlHttpSender = CurlHttpSender()) {
        this.channel = channel
        this.networkEnabled = networkEnabled
        this.webhookOrToken = webhookOrToken
        this.chatId = chatId
        this.sender = sender
    }

    public func notify(event: GitCodeEvent): DeliveryAudit {
        let payload = if (channel == "telegram") { buildTelegramPayload(webhookOrToken, chatId, event) } else { buildFeishuPayload(webhookOrToken, event) }
        if (!networkEnabled) {
            let audit = DeliveryAudit(event.id, channel, "dry_run")
            deliveries.add(audit)
            return audit
        }
        let res = sender.send(payload.request)
        let status = if (res.statusCode >= 200 && res.statusCode < 300) { "sent" } else { mapGitCodeError(res.statusCode) }
        let audit = DeliveryAudit(event.id, channel, status)
        deliveries.add(audit)
        audit
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

public class McpHttpClient {
    public let endpoint: String
    private let serviceToken: String
    public let sender: FakeHttpSender
    public var requestSeq: Int64 = 0
    public var initialized: Bool = false
    public var degradedReason: String = ""
    public let schemaCache = ArrayList<ToolSchema>()

    public init(endpoint: String, serviceToken!: String = "", sender!: FakeHttpSender = FakeHttpSender()) {
        this.endpoint = endpoint
        this.serviceToken = serviceToken
        this.sender = sender
    }

    public func nextRequestId(prefix: String): String {
        requestSeq++
        "${prefix}-${requestSeq}"
    }

    public func buildInitializeRequest(): HttpRequestSpec {
        jsonRpcRequest("initialize", "{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"GitCodeMonitor\",\"version\":\"0.1.0\"}}", nextRequestId("mcp-init"))
    }

    public func buildToolsListRequest(): HttpRequestSpec {
        jsonRpcRequest("tools/list", "{}", nextRequestId("mcp-tools"))
    }

    public func buildToolsCallRequest(input: ToolInput): HttpRequestSpec {
        let args = "{\"eventId\":\"${jsonEscape(input.eventId)}\",\"repo\":\"${jsonEscape(input.repo)}\",\"body\":\"${jsonEscape(input.body)}\"}"
        jsonRpcRequest("tools/call", "{\"name\":\"${jsonEscape(input.toolName)}\",\"arguments\":${args}}", nextRequestId("mcp-call"))
    }

    public func initialize(): Bool {
        let res = sender.send(buildInitializeRequest())
        initialized = res.statusCode >= 200 && res.statusCode < 300
        if (!initialized) { degradedReason = mapGitCodeError(res.statusCode) }
        initialized
    }

    public func toolsList(): Array<ToolSchema> {
        let res = sender.send(buildToolsListRequest())
        if (res.statusCode < 200 || res.statusCode >= 300) {
            degradedReason = mapGitCodeError(res.statusCode)
            return schemaCache.toArray()
        }
        if (schemaCache.isEmpty()) {
            schemaCache.add(ToolSchema("gitcode_issue_summary", version: "v1", schemaHash: "http-cache"))
            schemaCache.add(ToolSchema("gitcode_issue_draft_reply", version: "v1", schemaHash: "http-cache"))
            schemaCache.add(ToolSchema("gitcode_pr_summary", version: "v1", schemaHash: "http-cache"))
            schemaCache.add(ToolSchema("gitcode_pr_draft_reply", version: "v1", schemaHash: "http-cache"))
            schemaCache.add(ToolSchema("gitcode_safety_review", version: "v1", schemaHash: "http-cache"))
        }
        schemaCache.toArray()
    }

    public func call(input: ToolInput): McpResult {
        if (!hasGitCodeTool(input.toolName)) {
            return McpResult(false, approved: false, needsHumanReview: true, errorKind: "tool_not_available")
        }
        let res = sender.send(buildToolsCallRequest(input))
        if (res.statusCode < 200 || res.statusCode >= 300) {
            degradedReason = mapGitCodeError(res.statusCode)
            return McpResult(false, approved: false, needsHumanReview: true, errorKind: degradedReason)
        }
        McpResult(true, draft: "MCP HTTP draft for ${input.eventId}", approved: true, needsHumanReview: false)
    }

    private func jsonRpcRequest(method: String, params: String, id: String): HttpRequestSpec {
        let headers = if (serviceToken.isEmpty()) {
            [("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream"), ("MCP-Protocol-Version", "2025-03-26")]
        } else {
            [("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream"), ("MCP-Protocol-Version", "2025-03-26"), ("Authorization", "Bearer ${serviceToken}")]
        }
        HttpRequestSpec("POST", endpoint, headers: headers, body: "{\"jsonrpc\":\"2.0\",\"id\":\"${jsonEscape(id)}\",\"method\":\"${jsonEscape(method)}\",\"params\":${params}}")
    }

    private func hasGitCodeTool(name: String): Bool {
        if (schemaCache.isEmpty()) { let _ = toolsList() }
        for (schema in schemaCache) {
            if (schema.name == name) { return true }
        }
        false
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
    if (containsLocalPath(mcp.draft)) { return WriteDecision(false, "local_path_detected") }
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

public class GitCodeCommentWriter {
    public let client: GitCodeApiClient
    public let sender: FakeHttpSender
    public init(client: GitCodeApiClient, sender!: FakeHttpSender = FakeHttpSender()) {
        this.client = client
        this.sender = sender
    }
    public func writeIfAllowed(config: MonitorConfig, state: MonitorState, event: GitCodeEvent, mcp: McpResult): WriteDecision {
        let decision = writebackGate(config, state, event, mcp)
        if (!decision.allowed) { return decision }
        let res = sender.send(client.postCommentRequest(event, mcp.draft))
        if (res.statusCode >= 200 && res.statusCode < 300) {
            state.markReply(event.id)
            return WriteDecision(true, "posted")
        }
        state.setBackoff("${event.org}/${event.repo}", 60000)
        WriteDecision(false, mapGitCodeError(res.statusCode))
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
    let auth = if (gitCodeAuthPresent(config)) { "present" } else { "absent" }
    "GitCodeMonitor doctor\norgs=${config.orgs.size}\ngitCodeAuth=${auth}\nfullScanIntervalMinutes=${config.fullScanIntervalMinutes}\ndryRun=${config.dryRun}\nautoReply=${config.autoReply}\nacp=${acp}\nmcpInitialized=${mcp.initialized}\naudit=${state.audit.size}"
}

public func probeGitCode(config: MonitorConfig): String {
    let client = GitCodeApiClient(baseUrl: config.gitCodeBaseUrl, authMode: config.gitCodeAuthMode, token: config.gitCodeToken, cookie: config.gitCodeCookie)
    let req = client.listReposRequest(config.orgs[0], 1, 20)
    "probe-gitcode\n${req.redactedLogLine()}\nauth=${if (gitCodeAuthPresent(config)) { "present" } else { "absent" }}"
}

public func probeMcp(config: MonitorConfig): String {
    let client = McpHttpClient(config.mcpEndpoint, serviceToken: config.mcpServiceToken)
    let req = client.buildInitializeRequest()
    "probe-mcp\n${req.redactedLogLine()}\nrequestBody=${req.body}"
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

public func cliHelp(): String {
    "Usage: gitcodemonitor [--config path] <doctor|scan-once|serve|probe-gitcode|probe-mcp|config summary|tests>"
}

public func notificationText(event: GitCodeEvent): String {
    "[${event.itemKind}] ${event.org}/${event.repo}#${event.itemId} by ${event.actor}\n${event.url}\n${compactSummary(redactSecrets(event.content))}"
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
    match (root.get("feishu")) {
        case Some(v) => try { applyFeishuSection(config, v.asObject()) } catch (_: Exception) { () }
        case None => ()
    }
    match (root.get("telegram")) {
        case Some(v) => try { applyTelegramSection(config, v.asObject()) } catch (_: Exception) { () }
        case None => ()
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
    let token = firstJsonString(obj, ["token", "privateToken", "accessToken", "gitCodeToken"])
    if (!token.isEmpty()) { config.gitCodeToken = token }
    let cookie = firstJsonString(obj, ["cookie", "gitCodeCookie"])
    if (!cookie.isEmpty()) { config.gitCodeCookie = cookie }
    let username = firstJsonString(obj, ["username", "account", "gitCodeUsername"])
    if (!username.isEmpty()) { config.gitCodeUsername = username }
    let password = firstJsonString(obj, ["password", "gitCodePassword"])
    if (!password.isEmpty()) { config.gitCodePassword = password }
}

func applyFeishuSection(config: MonitorConfig, obj: JsonObject): Unit {
    let webhook = firstJsonString(obj, ["webhook", "webhookUrl", "feishuWebhook"])
    if (!webhook.isEmpty()) { config.feishuWebhook = webhook }
}

func applyTelegramSection(config: MonitorConfig, obj: JsonObject): Unit {
    let token = firstJsonString(obj, ["botToken", "token", "telegramBotToken"])
    if (!token.isEmpty()) { config.telegramBotToken = token }
    let chatId = firstJsonString(obj, ["chatId", "telegramChatId"])
    if (!chatId.isEmpty()) { config.telegramChatId = chatId }
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
    if (!statePath.isEmpty()) { config.statePath = statePath }
    config.dryRun = firstJsonBool(obj, ["dryRun"], config.dryRun)
    config.autoReply = firstJsonBool(obj, ["autoReply"], config.autoReply)
    config.notifyNetworkEnabled = firstJsonBool(obj, ["notifyNetworkEnabled"], config.notifyNetworkEnabled)
    let orgs = firstJsonStringArray(obj, ["orgs", "organizations"])
    if (orgs.size > 0) { config.orgs = orgs }
    let allowlist = firstJsonStringArray(obj, ["repoAllowlist", "allowlist"])
    if (allowlist.size > 0) { config.repoAllowlist = allowlist }
}

func gitCodeAuthPresent(config: MonitorConfig): Bool {
    !config.gitCodeToken.isEmpty() || !config.gitCodeCookie.isEmpty() || (!config.gitCodeUsername.isEmpty() && !config.gitCodePassword.isEmpty())
}

func collectPagedEvents(repo: GitCodeRepo, kind: String, transport: GitCodeHttpTransport, state: MonitorState, out: ArrayList<GitCodeEvent>): Unit {
    var page: Int64 = 1
    while (true) {
        let result = if (kind == "pr") { transport.listPullRequestsPage(repo, page) } else { transport.listIssuesPage(repo, page) }
        if (result.errorKind != "ok") {
            state.setBackoff(repo.fullName(), result.retryAfterMs)
            break
        }
        for (event in result.events) {
            out.add(event)
            var commentPage: Int64 = 1
            while (true) {
                let comments = transport.listCommentsPage(repo, kind, event.itemId, commentPage)
                if (comments.errorKind != "ok") {
                    state.setBackoff(repo.fullName(), comments.retryAfterMs)
                    break
                }
                for (comment in comments.events) { out.add(comment) }
                if (comments.events.size < transport.pageSize) { break }
                commentPage++
            }
        }
        if (result.events.size < transport.pageSize) { break }
        page++
    }
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
            if (!name.isEmpty()) { out.add(GitCodeRepo(org, name)) }
        }
    } catch (_: Exception) { () }
    out.toArray()
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
                out.add(GitCodeEvent("${repo.fullName()}:${kind}:${itemId}", repo.org, repo.name, kind, itemId, actor, actorUrl(obj), url, content, updatedAtMs: firstJsonInt(obj, ["updated_at_ms", "updatedAtMs"])))
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
                out.add(GitCodeEvent("${repo.fullName()}:${kind}:${itemId}:comment:${commentId}", repo.org, repo.name, kind, itemId, actorName(obj), actorUrl(obj), firstJsonString(obj, ["html_url", "web_url", "url"]), bodyText, updatedAtMs: firstJsonInt(obj, ["updated_at_ms", "updatedAtMs"])))
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
