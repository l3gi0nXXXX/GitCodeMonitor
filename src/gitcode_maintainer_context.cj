package gitcodemonitor

import std.collection.*
import std.convert.Parsable
import std.fs.{Directory, File, Path, exists}
import std.time.DateTime
import stdx.encoding.json.{JsonObject, JsonValue}

public class GcmContextStoreResult {
    public let ok: Bool
    public let status: String
    public init(ok: Bool, status!: String = "ok") {
        this.ok = ok
        this.status = status
    }
}

public class GitCodeChangedFilesResult {
    public let paths: Array<String>
    public let status: String
    public let truncated: Bool
    public let diagnostic: String
    public init(paths!: Array<String> = [], status!: String = "ok", truncated!: Bool = false, diagnostic!: String = "") {
        this.paths = paths
        this.status = status
        this.truncated = truncated
        this.diagnostic = diagnostic
    }
}

public class GcmMaintainerContext {
    public let eventId: String
    public let sourceEventId: String
    public let repo: String
    public let kind: String
    public let number: String
    public let teamLeaderMentions: Array<String>
    public let codeownerMentions: Array<String>
    public let teamLeaderEmails: Array<String>
    public let codeownerEmails: Array<String>
    public let teamLeaderStatus: String
    public let codeownerStatus: String
    public let changedFiles: Array<String>
    public let changedFilesTruncated: Bool
    public let contextSource: String
    public let diagnostics: Array<String>
    public let createdAtMs: Int64

    public init(
        eventId: String,
        repo: String,
        kind: String,
        number: String,
        sourceEventId!: String = "",
        teamLeaderMentions!: Array<String> = [],
        codeownerMentions!: Array<String> = [],
        teamLeaderEmails!: Array<String> = [],
        codeownerEmails!: Array<String> = [],
        teamLeaderStatus!: String = "not_found",
        codeownerStatus!: String = "not_applicable",
        changedFiles!: Array<String> = [],
        changedFilesTruncated!: Bool = false,
        contextSource!: String = "unavailable",
        diagnostics!: Array<String> = [],
        createdAtMs!: Int64 = 0
    ) {
        this.eventId = eventId.trimAscii()
        this.sourceEventId = sourceEventId.trimAscii()
        this.repo = repo.trimAscii()
        this.kind = kind.trimAscii()
        this.number = number.trimAscii()
        this.teamLeaderMentions = sanitizeMentionList(teamLeaderMentions)
        this.codeownerMentions = sanitizeMentionList(codeownerMentions)
        this.teamLeaderEmails = normalizeMaintainerEmails(teamLeaderEmails)
        this.codeownerEmails = normalizeMaintainerEmails(codeownerEmails)
        this.teamLeaderStatus = teamLeaderStatus.trimAscii()
        this.codeownerStatus = codeownerStatus.trimAscii()
        this.changedFiles = changedFiles
        this.changedFilesTruncated = changedFilesTruncated
        this.contextSource = contextSource.trimAscii()
        this.diagnostics = diagnostics
        this.createdAtMs = if (createdAtMs > 0) { createdAtMs } else { DateTime.now().toUnixTimeStamp().toMilliseconds() }
    }
}

public class GcmMaintainerContextStore {
    private let items = ArrayList<GcmMaintainerContext>()
    public let maxEntries: Int64
    public let ttlMs: Int64
    public let path: String

    public init(maxEntries!: Int64 = 512, ttlMs!: Int64 = 7 * 24 * 60 * 60 * 1000, path!: String = "") {
        this.maxEntries = if (maxEntries <= 0) { 512 } else { maxEntries }
        this.ttlMs = if (ttlMs <= 0) { 7 * 24 * 60 * 60 * 1000 } else { ttlMs }
        this.path = path.trimAscii()
        this.load()
    }

    public func put(context: GcmMaintainerContext): GcmContextStoreResult {
        if (context.eventId.isEmpty()) { return GcmContextStoreResult(false, status: "event_id_missing") }
        var index: Int64 = -1
        for (i in 0..items.size) {
            if (items[i].eventId == context.eventId || (!context.sourceEventId.isEmpty() && items[i].eventId == context.sourceEventId)) {
                index = i
                break
            }
        }
        if (index >= 0) {
            items.remove(at: index)
        }
        items.add(context)
        while (items.size > maxEntries) { items.remove(at: 0) }
        persist()
        GcmContextStoreResult(true)
    }

    public func get(eventId: String): ?GcmMaintainerContext {
        let id = eventId.trimAscii()
        if (id.isEmpty()) { return None<GcmMaintainerContext> }
        for (i in 0..items.size) {
            let item = items[items.size - 1 - i]
            if (item.eventId == id || item.sourceEventId == id) { return Some<GcmMaintainerContext>(item) }
        }
        None<GcmMaintainerContext>
    }

    public func prune(nowMs: Int64): Int64 {
        var removed: Int64 = 0
        var index: Int64 = 0
        while (index < items.size) {
            if (nowMs - items[index].createdAtMs > ttlMs) {
                items.remove(at: index)
                removed++
            } else {
                index++
            }
        }
        if (removed > 0) { persist() }
        removed
    }

    public func toSafeJson(): String {
        let parts = ArrayList<String>()
        for (item in items) {
            parts.add("{\"eventId\":\"${jsonEscape(item.eventId)}\",\"sourceEventId\":\"${jsonEscape(item.sourceEventId)}\",\"repo\":\"${jsonEscape(item.repo)}\",\"kind\":\"${jsonEscape(item.kind)}\",\"number\":\"${jsonEscape(item.number)}\",\"teamLeaderMentions\":${stringArrayJson(item.teamLeaderMentions).toJsonString()},\"codeownerMentions\":${stringArrayJson(item.codeownerMentions).toJsonString()},\"teamLeaderEmails\":${stringArrayJson(item.teamLeaderEmails).toJsonString()},\"codeownerEmails\":${stringArrayJson(item.codeownerEmails).toJsonString()},\"teamLeaderStatus\":\"${jsonEscape(item.teamLeaderStatus)}\",\"codeownerStatus\":\"${jsonEscape(item.codeownerStatus)}\",\"changedFiles\":${stringArrayJson(item.changedFiles).toJsonString()},\"changedFilesTruncated\":${item.changedFilesTruncated},\"contextSource\":\"${jsonEscape(item.contextSource)}\",\"createdAtMs\":${item.createdAtMs}}")
        }
        "[${joinStrings(parts.toArray(), ",")}]"
    }

    private func persist(): Unit {
        if (path.isEmpty()) { return }
        try {
            let p = Path(path)
            let parent = p.parent
            if (!exists(parent)) { Directory.create(parent, recursive: true) }
            File.writeTo(p, toSafeJson().toArray())
        } catch (_: Exception) { () }
    }

    private func load(): Unit {
        if (path.isEmpty() || !exists(Path(path))) { return }
        try {
            let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(Path(path))))
            for (obj in jsonObjectItems(root)) {
                let context = GcmMaintainerContext(
                    firstJsonString(obj, ["eventId"]),
                    firstJsonString(obj, ["repo"]),
                    firstJsonString(obj, ["kind"]),
                    firstJsonString(obj, ["number"]),
                    sourceEventId: firstJsonString(obj, ["sourceEventId"]),
                    teamLeaderMentions: firstJsonStringArray(obj, ["teamLeaderMentions"]),
                    codeownerMentions: firstJsonStringArray(obj, ["codeownerMentions"]),
                    teamLeaderEmails: firstJsonStringArray(obj, ["teamLeaderEmails"]),
                    codeownerEmails: firstJsonStringArray(obj, ["codeownerEmails"]),
                    teamLeaderStatus: firstJsonString(obj, ["teamLeaderStatus"]),
                    codeownerStatus: firstJsonString(obj, ["codeownerStatus"]),
                    changedFiles: firstJsonStringArray(obj, ["changedFiles"]),
                    changedFilesTruncated: firstJsonString(obj, ["changedFilesTruncated"]) == "true",
                    contextSource: firstJsonString(obj, ["contextSource"]),
                    createdAtMs: firstJsonInt(obj, ["createdAtMs"])
                )
                if (!context.eventId.isEmpty()) { items.add(context) }
            }
        } catch (_: Exception) { () }
    }
}

public func resolveGcmMaintainerContext(
    transport: GitCodeHttpTransport,
    event: GitCodeEvent,
    emailConfig!: MaintainerNotificationEmailConfig = MaintainerNotificationEmailConfig(),
    emailCache!: MaintainerEmailLookupCache = MaintainerEmailLookupCache()
): GcmMaintainerContext {
    let repo = "${event.org}/${event.repo}"
    let diagnostics = ArrayList<String>()
    let repoList = fetchRepoListMd(transport.client, sender: transport.sender)
    let teamResolution = if (repoList.ok) {
        resolveTeamLeaders(repo, rows: parseRepoListMd(repoList.text).rows)
    } else {
        GitCodeTeamLeaderResolution(repo, teamLeaderStatus: repoList.status, diagnostics: [GitCodeIdentityDiagnostic(repoList.status)])
    }
    if (!repoList.ok) { diagnostics.add("repo_list_${repoList.status}:${repoList.diagnostic}") }
    var codeownerResolution = GitCodeCodeownerResolution(codeownerStatus: "not_applicable")
    if (event.itemKind == "pr") {
        let codeowners = fetchCodeowners(transport.client, GitCodeRepo(event.org, event.repo), "main", sender: transport.sender)
        if (codeowners.ok) {
            let parsed = parseCodeowners(codeowners.text)
            let files = fetchPullRequestChangedFiles(transport.client, GitCodeRepo(event.org, event.repo), event.itemId, sender: transport.sender)
            if (files.status != "ok") { diagnostics.add("pr_files_${files.status}:${files.diagnostic}") }
            codeownerResolution = resolveCodeownersForPaths(parsed.rules, files.paths)
            if (files.truncated) {
                codeownerResolution = GitCodeCodeownerResolution(owners: codeownerResolution.owners, codeownerStatus: codeownerResolution.codeownerStatus, changedFiles: codeownerResolution.changedFiles, changedFilesTruncated: true, diagnostics: codeownerResolution.diagnostics)
            }
        } else {
            codeownerResolution = GitCodeCodeownerResolution(codeownerStatus: codeowners.status, diagnostics: [GitCodeIdentityDiagnostic(codeowners.status)])
            diagnostics.add("codeowners_${codeowners.status}:${codeowners.diagnostic}")
        }
    }
    let baseContext = GcmMaintainerContext(
        event.id,
        repo,
        event.itemKind,
        event.itemId,
        teamLeaderMentions: peopleMentions(teamResolution.teamLeaders),
        codeownerMentions: peopleMentions(codeownerResolution.owners),
        teamLeaderStatus: teamResolution.teamLeaderStatus,
        codeownerStatus: codeownerResolution.codeownerStatus,
        changedFiles: codeownerResolution.changedFiles,
        changedFilesTruncated: codeownerResolution.changedFilesTruncated,
        contextSource: if (teamResolution.teamLeaderStatus == "resolved" || codeownerResolution.codeownerStatus == "resolved") { "deterministic_fallback" } else { "unavailable" },
        diagnostics: diagnostics.toArray()
    )
    contextWithResolvedUserEmails(baseContext, transport.client, transport.sender, emailConfig, emailCache)
}

public func fetchPullRequestChangedFiles(client: GitCodeApiClient, repo: GitCodeRepo, number: String, sender!: HttpSender = NativeHttpSender()): GitCodeChangedFilesResult {
    let prNumber = try { Int64.parse(number.trimAscii()) } catch (_: Exception) { return GitCodeChangedFilesResult(status: "invalid_number") }
    let req = client.pullRequestFilesRequest(repo, prNumber)
    let res = sender.send(req)
    if (res.statusCode < 200 || res.statusCode >= 300) {
        return GitCodeChangedFilesResult(status: mapGitCodeError(res.statusCode), diagnostic: hashRawPayload(req.url))
    }
    let paths = ArrayList<String>()
    try {
        let root = JsonValue.fromStr(res.body)
        addChangedFileObjects(paths, root)
    } catch (_: Exception) {
        return GitCodeChangedFilesResult(status: "invalid_content", diagnostic: hashRawPayload(res.body))
    }
    GitCodeChangedFilesResult(paths: paths.toArray(), status: "ok", truncated: paths.size >= 100)
}

func addChangedFileObjects(paths: ArrayList<String>, root: JsonValue): Unit {
    for (obj in jsonObjectItems(root)) {
        let path = firstJsonString(obj, ["filename", "path", "new_path", "old_path"])
        if (!path.isEmpty()) { paths.add(path) }
        if (paths.size >= 100) { return }
    }
    if (paths.size > 0) { return }
    try {
        let obj = root.asObject()
        for (key in ["files", "data", "items", "result"]) {
            match (obj.get(key)) {
                case Some(value) =>
                    try {
                        for (item in value.asArray().getItems()) {
                            let fileObj = item.asObject()
                            let path = firstJsonString(fileObj, ["filename", "path", "new_path", "old_path"])
                            if (!path.isEmpty()) { paths.add(path) }
                            if (paths.size >= 100) { return }
                        }
                    } catch (_: Exception) { () }
                case None => ()
            }
        }
    } catch (_: Exception) { () }
}

public func contextFromPayloadCompat(payloadRoot: JsonObject, replyRoot: JsonObject): GcmMaintainerContext {
    let maintainers = writebackMaintainerContext(payloadRoot, replyRoot)
    GcmMaintainerContext("", "", "", "", teamLeaderMentions: maintainers.teamLeaderMentions, codeownerMentions: maintainers.codeownerMentions, contextSource: if (maintainers.teamLeaderMentions.size > 0 || maintainers.codeownerMentions.size > 0) { "payload_compat" } else { "unavailable" })
}

public func contextWithAddressBookEmails(context: GcmMaintainerContext, config: MaintainerNotificationEmailConfig): GcmMaintainerContext {
    let teamEmails = ArrayList<String>()
    for (email in context.teamLeaderEmails) { teamEmails.add(email) }
    for (email in emailDomainsForMentions(context.teamLeaderMentions, config)) { teamEmails.add(email) }
    let ownerEmails = ArrayList<String>()
    for (email in context.codeownerEmails) { ownerEmails.add(email) }
    for (email in emailDomainsForMentions(context.codeownerMentions, config)) { ownerEmails.add(email) }
    GcmMaintainerContext(
        context.eventId,
        context.repo,
        context.kind,
        context.number,
        sourceEventId: context.sourceEventId,
        teamLeaderMentions: context.teamLeaderMentions,
        codeownerMentions: context.codeownerMentions,
        teamLeaderEmails: normalizeMaintainerEmails(teamEmails.toArray(), allowedDomains: config.allowedDomains),
        codeownerEmails: normalizeMaintainerEmails(ownerEmails.toArray(), allowedDomains: config.allowedDomains),
        teamLeaderStatus: context.teamLeaderStatus,
        codeownerStatus: context.codeownerStatus,
        changedFiles: context.changedFiles,
        changedFilesTruncated: context.changedFilesTruncated,
        contextSource: context.contextSource,
        diagnostics: context.diagnostics,
        createdAtMs: context.createdAtMs
    )
}

public func contextWithResolvedUserEmails(
    context: GcmMaintainerContext,
    client: GitCodeApiClient,
    sender: HttpSender,
    config: MaintainerNotificationEmailConfig,
    cache: MaintainerEmailLookupCache
): GcmMaintainerContext {
    let diagnostics = ArrayList<String>()
    for (diagnostic in context.diagnostics) { diagnostics.add(diagnostic) }

    let teamEmails = ArrayList<String>()
    for (email in context.teamLeaderEmails) { teamEmails.add(email) }
    if (teamEmails.size == 0 && config.enabled && config.userLookup.enabled) {
        let resolved = resolveMaintainerEmailsForMentions(context.teamLeaderMentions, client, sender, config, cache)
        for (email in resolved.emails) { teamEmails.add(email) }
        if (resolved.status != "resolved" && resolved.status != "lookup_disabled") { diagnostics.add("team_email_${resolved.status}") }
    }
    if (teamEmails.size == 0 && config.enabled && config.userLookup.fallbackToAddressBook) {
        for (email in emailDomainsForMentions(context.teamLeaderMentions, config)) { teamEmails.add(email) }
    }

    let ownerEmails = ArrayList<String>()
    for (email in context.codeownerEmails) { ownerEmails.add(email) }
    if (ownerEmails.size == 0 && config.enabled && config.userLookup.enabled) {
        let resolved = resolveMaintainerEmailsForMentions(context.codeownerMentions, client, sender, config, cache)
        for (email in resolved.emails) { ownerEmails.add(email) }
        if (resolved.status != "resolved" && resolved.status != "lookup_disabled") { diagnostics.add("codeowner_email_${resolved.status}") }
    }
    if (ownerEmails.size == 0 && config.enabled && config.userLookup.fallbackToAddressBook) {
        for (email in emailDomainsForMentions(context.codeownerMentions, config)) { ownerEmails.add(email) }
    }

    GcmMaintainerContext(
        context.eventId,
        context.repo,
        context.kind,
        context.number,
        sourceEventId: context.sourceEventId,
        teamLeaderMentions: context.teamLeaderMentions,
        codeownerMentions: context.codeownerMentions,
        teamLeaderEmails: normalizeMaintainerEmails(teamEmails.toArray(), allowedDomains: config.allowedDomains),
        codeownerEmails: normalizeMaintainerEmails(ownerEmails.toArray(), allowedDomains: config.allowedDomains),
        teamLeaderStatus: context.teamLeaderStatus,
        codeownerStatus: context.codeownerStatus,
        changedFiles: context.changedFiles,
        changedFilesTruncated: context.changedFilesTruncated,
        contextSource: context.contextSource,
        diagnostics: diagnostics.toArray(),
        createdAtMs: context.createdAtMs
    )
}

func peopleMentions(people: Array<GitCodeMaintainerPerson>): Array<String> {
    let out = ArrayList<String>()
    for (person in people) { out.add(person.mention) }
    sanitizeMentionList(out.toArray())
}
