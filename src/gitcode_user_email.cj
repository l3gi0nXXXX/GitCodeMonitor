package gitcodemonitor

import std.collection.*
import std.time.DateTime
import stdx.encoding.json.JsonValue

public class GitCodeUserEmailLookupResult {
    public let login: String
    public let emails: Array<String>
    public let status: String
    public let retryable: Bool
    public let diagnostic: String
    public let source: String

    public init(login: String, emails!: Array<String> = [], status!: String = "email_unavailable", retryable!: Bool = false, diagnostic!: String = "", source!: String = "gitcode_user_api") {
        this.login = normalizeMaintainerLogin(login)
        this.emails = normalizeMaintainerEmails(emails)
        this.status = status.trimAscii()
        this.retryable = retryable
        this.diagnostic = diagnostic.trimAscii()
        this.source = source.trimAscii()
    }
}

public class MaintainerMentionEmailResolveResult {
    public let emails: Array<String>
    public let status: String
    public let retryable: Bool
    public let diagnostics: Array<String>

    public init(emails!: Array<String> = [], status!: String = "email_unavailable", retryable!: Bool = false, diagnostics!: Array<String> = []) {
        this.emails = normalizeMaintainerEmails(emails)
        this.status = status.trimAscii()
        this.retryable = retryable
        this.diagnostics = diagnostics
    }
}

class MaintainerEmailLookupCacheEntry {
    public let login: String
    public let result: GitCodeUserEmailLookupResult
    public let createdAtMs: Int64

    public init(login: String, result: GitCodeUserEmailLookupResult, createdAtMs: Int64) {
        this.login = normalizeMaintainerLogin(login)
        this.result = result
        this.createdAtMs = createdAtMs
    }
}

public class MaintainerEmailLookupCache {
    private let entries = ArrayList<MaintainerEmailLookupCacheEntry>()
    public let maxEntries: Int64
    public let ttlMs: Int64

    public init(maxEntries!: Int64 = 4096, ttlMs!: Int64 = 24 * 60 * 60 * 1000) {
        this.maxEntries = if (maxEntries <= 0) { 4096 } else { maxEntries }
        this.ttlMs = if (ttlMs <= 0) { 24 * 60 * 60 * 1000 } else { ttlMs }
    }

    public func get(loginRaw: String, nowMs!: Int64 = DateTime.now().toUnixTimeStamp().toMilliseconds()): ?GitCodeUserEmailLookupResult {
        let login = normalizeMaintainerLogin(loginRaw)
        if (login.isEmpty()) { return None<GitCodeUserEmailLookupResult> }
        var index: Int64 = 0
        while (index < entries.size) {
            let entry = entries[index]
            if (entry.login == login) {
                if (nowMs - entry.createdAtMs <= ttlMs) {
                    return Some<GitCodeUserEmailLookupResult>(entry.result)
                }
                entries.remove(at: index)
                return None<GitCodeUserEmailLookupResult>
            }
            index++
        }
        None<GitCodeUserEmailLookupResult>
    }

    public func put(result: GitCodeUserEmailLookupResult, nowMs!: Int64 = DateTime.now().toUnixTimeStamp().toMilliseconds()): Unit {
        let login = normalizeMaintainerLogin(result.login)
        if (login.isEmpty()) { return }
        var index: Int64 = 0
        while (index < entries.size) {
            if (entries[index].login == login) {
                entries.remove(at: index)
                break
            }
            index++
        }
        entries.add(MaintainerEmailLookupCacheEntry(login, result, nowMs))
        while (entries.size > maxEntries) { entries.remove(at: 0) }
    }
}

public func normalizeMaintainerLogin(raw: String): String {
    var login = raw.trimAscii()
    if (login.startsWith("@")) { login = login[1..login.size] }
    login = login.trimAscii().toAsciiLower()
    if (login.isEmpty()) { return "" }
    if (login.contains("/") || login.contains("?") || login.contains("#") || login.contains(" ") || login.contains("\t") || login.contains("\n") || login.contains("\r")) {
        return ""
    }
    login
}

public func parseGitCodeUserEmailResponse(loginRaw: String, statusCode: Int64, body: String, allowedDomains!: Array<String> = []): GitCodeUserEmailLookupResult {
    let login = normalizeMaintainerLogin(loginRaw)
    if (login.isEmpty()) {
        return GitCodeUserEmailLookupResult("", status: "invalid_login", retryable: false, diagnostic: "invalid_login")
    }
    if (statusCode < 200 || statusCode >= 300) {
        return GitCodeUserEmailLookupResult(login, status: gitCodeUserEmailHttpStatus(statusCode), retryable: gitCodeUserEmailRetryable(statusCode), diagnostic: "status_${statusCode}")
    }
    try {
        let root = JsonValue.fromStr(body).asObject()
        let candidates = ArrayList<String>()
        for (key in ["email", "mail", "public_email", "publicEmail"]) {
            let value = firstJsonString(root, [key])
            if (!value.isEmpty()) { candidates.add(value) }
        }
        for (key in ["emails", "email_addresses", "emailAddresses"]) {
            for (email in firstJsonStringArray(root, [key])) { candidates.add(email) }
        }
        let valid = normalizeMaintainerEmails(candidates.toArray())
        let filtered = normalizeMaintainerEmails(candidates.toArray(), allowedDomains: allowedDomains)
        if (filtered.size > 0) {
            return GitCodeUserEmailLookupResult(login, emails: filtered, status: "resolved")
        }
        if (valid.size > 0 && allowedDomains.size > 0) {
            return GitCodeUserEmailLookupResult(login, status: "email_filtered", diagnostic: "email_domain_filtered")
        }
        GitCodeUserEmailLookupResult(login, status: "email_unavailable")
    } catch (_: Exception) {
        GitCodeUserEmailLookupResult(login, status: "invalid_content", retryable: false, diagnostic: hashRawPayload(body))
    }
}

public func resolveGitCodeUserEmail(loginRaw: String, client: GitCodeApiClient, sender: HttpSender, config: MaintainerNotificationEmailConfig, cache: MaintainerEmailLookupCache): GitCodeUserEmailLookupResult {
    let login = normalizeMaintainerLogin(loginRaw)
    if (login.isEmpty()) {
        return GitCodeUserEmailLookupResult("", status: "invalid_login", retryable: false, diagnostic: "invalid_login")
    }
    if (!config.enabled || !config.userLookup.enabled) {
        return GitCodeUserEmailLookupResult(login, status: "lookup_disabled", retryable: false, source: "gitcode_user_api")
    }
    match (cache.get(login)) {
        case Some(cached) => return cached
        case None => ()
    }
    let response = sender.send(client.userProfileRequest(login, timeoutMs: config.userLookup.timeoutMs))
    let result = parseGitCodeUserEmailResponse(login, response.statusCode, response.body, allowedDomains: config.allowedDomains)
    cache.put(result)
    result
}

public func resolveMaintainerEmailsForMentions(mentions: Array<String>, client: GitCodeApiClient, sender: HttpSender, config: MaintainerNotificationEmailConfig, cache: MaintainerEmailLookupCache): MaintainerMentionEmailResolveResult {
    if (!config.enabled || !config.userLookup.enabled) {
        return MaintainerMentionEmailResolveResult(status: "lookup_disabled")
    }
    let emails = ArrayList<String>()
    let seenLogins = HashSet<String>()
    let diagnostics = ArrayList<String>()
    var failures: Int64 = 0
    var retryable = false
    var firstFailure = "email_unavailable"
    for (mention in mentions) {
        let login = normalizeMaintainerLogin(mention)
        if (login.isEmpty()) {
            failures++
            if (firstFailure == "email_unavailable") { firstFailure = "invalid_login" }
            diagnostics.add("invalid_login")
            continue
        }
        if (seenLogins.contains(login)) { continue }
        seenLogins.add(login)
        let result = resolveGitCodeUserEmail(login, client, sender, config, cache)
        if (result.emails.size > 0) {
            for (email in result.emails) { emails.add(email) }
        } else {
            failures++
            if (firstFailure == "email_unavailable") { firstFailure = result.status }
            if (result.retryable) { retryable = true }
            diagnostics.add(result.status)
        }
    }
    let normalized = normalizeMaintainerEmails(emails.toArray(), allowedDomains: config.allowedDomains)
    let status = if (normalized.size > 0 && failures == 0) {
        "resolved"
    } else if (normalized.size > 0) {
        "partial"
    } else {
        firstFailure
    }
    MaintainerMentionEmailResolveResult(emails: normalized, status: status, retryable: retryable, diagnostics: diagnostics.toArray())
}

func gitCodeUserEmailHttpStatus(statusCode: Int64): String {
    match (statusCode) {
        case 401 | 403 => "auth_failed"
        case 404 => "user_not_found"
        case 429 => "rate_limited"
        case _ =>
            if (statusCode >= 500 || statusCode == 599) { "network_error" } else { "fetch_failed" }
    }
}

func gitCodeUserEmailRetryable(statusCode: Int64): Bool {
    statusCode == 429 || statusCode >= 500 || statusCode == 599
}
