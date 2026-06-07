package gitcodemonitor

import stdx.encoding.json.{JsonObject, JsonValue}

public class GitCodeWebhookEnvelope {
    public let eventHeader: String
    public let eventType: String
    public let action: String
    public let repoFullName: String
    public let itemId: String
    public let commentId: String
    public let title: String
    public let body: String
    public let commentBody: String
    public let authorLogin: String
    public let authorDisplayName: String
    public let authorUrl: String
    public let deliveryId: String

    public init(
        eventHeader: String,
        eventType: String,
        action!: String = "",
        repoFullName!: String = "",
        itemId!: String = "",
        commentId!: String = "",
        title!: String = "",
        body!: String = "",
        commentBody!: String = "",
        authorLogin!: String = "",
        authorDisplayName!: String = "",
        authorUrl!: String = "",
        deliveryId!: String = ""
    ) {
        this.eventHeader = eventHeader
        this.eventType = eventType
        this.action = action
        this.repoFullName = repoFullName
        this.itemId = itemId
        this.commentId = commentId
        this.title = title
        this.body = body
        this.commentBody = commentBody
        this.authorLogin = authorLogin
        this.authorDisplayName = authorDisplayName
        this.authorUrl = authorUrl
        this.deliveryId = deliveryId
    }
}

public class GitCodeWebhookParseResult {
    public let ok: Bool
    public let event: GitCodeEvent
    public let envelope: ?GitCodeWebhookEnvelope
    public let ignored: Bool
    public let ignoreReason: String
    public let errorKind: String
    public let diagnostic: String
    public init(ok: Bool, event!: GitCodeEvent = GitCodeEvent("", "", "", "", "", "", "", "", ""), envelope!: ?GitCodeWebhookEnvelope = None<GitCodeWebhookEnvelope>, ignored!: Bool = false, ignoreReason!: String = "", errorKind!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.event = event
        this.envelope = envelope
        this.ignored = ignored
        this.ignoreReason = ignoreReason
        this.errorKind = errorKind
        this.diagnostic = diagnostic
    }
}

public func parseGitCodeWebhookPayload(eventName: String, payload: String): GitCodeWebhookParseResult {
    let root = try {
        JsonValue.fromStr(payload).asObject()
    } catch (_: Exception) {
        return GitCodeWebhookParseResult(false, errorKind: "invalid_json", diagnostic: "payloadHash=${hashRawPayload(payload)}")
    }
    match (eventName) {
        case "Merge Request Hook" => parseWebhookItem(root, "pr", eventName)
        case "Issue Hook" => parseWebhookItem(root, "issue", eventName)
        case "Note Hook" => parseWebhookNote(root, eventName)
        case _ => GitCodeWebhookParseResult(true, ignored: true, ignoreReason: "unknown_event")
    }
}

func parseWebhookItem(root: JsonObject, kind: String, eventName: String): GitCodeWebhookParseResult {
    let attrs = nestedObject(root, ["object_attributes", "merge_request", "issue"])
    let action = firstJsonString(attrs, ["action", "state"])
    if ((kind == "pr" && (action == "close" || action == "merge" || action == "merged")) || (kind == "issue" && action == "close")) {
        return GitCodeWebhookParseResult(true, ignored: true, ignoreReason: "non_reply_action")
    }
    let repo = webhookRepo(root)
    if (repo.fullName().trimAscii() == "/") { return GitCodeWebhookParseResult(false, errorKind: "missing_repo", diagnostic: "payloadHash=${hashRawPayload(root.toJsonString())}") }
    let itemId = firstJsonString(attrs, ["iid", "number", "id", "pull_request_number"])
    if (itemId.isEmpty()) { return GitCodeWebhookParseResult(false, errorKind: "missing_item_id", diagnostic: "payloadHash=${hashRawPayload(root.toJsonString())}") }
    let title = firstJsonString(attrs, ["title"])
    let desc = firstJsonString(attrs, ["description", "body", "content"])
    let content = sanitizeWebhookContent("${title}\n${desc}")
    let url = firstNonEmpty([firstJsonString(attrs, ["url", "html_url", "web_url"]), "https://gitcode.com/${repo.fullName()}/${if (kind == "pr") { "pulls" } else { "issues" }}/${itemId}"])
    let identity = extractAuthorIdentityFromWebhook(root)
    GitCodeWebhookParseResult(
        true,
        event: GitCodeEvent(canonicalGitCodeEventId(repo, kind, itemId), repo.org, repo.name, kind, itemId, identity.login, identity.url, url, content),
        envelope: Some<GitCodeWebhookEnvelope>(GitCodeWebhookEnvelope(
            eventName,
            kind,
            action: action,
            repoFullName: repo.fullName(),
            itemId: itemId,
            title: sanitizeWebhookContent(title),
            body: sanitizeWebhookContent(desc),
            authorLogin: identity.login,
            authorDisplayName: identity.displayName,
            authorUrl: identity.url
        ))
    )
}

func parseWebhookNote(root: JsonObject, eventName: String): GitCodeWebhookParseResult {
    let attrs = nestedObject(root, ["object_attributes"])
    let action = firstJsonString(attrs, ["action", "state"])
    let noteableType = firstJsonString(attrs, ["noteable_type", "noteableType"]).toAsciiLower()
    var kind = ""
    var item = JsonObject()
    if (!noteableType.isEmpty() && !(noteableType.contains("merge") || noteableType == "pullrequest" || noteableType.contains("issue"))) {
        return GitCodeWebhookParseResult(true, ignored: true, ignoreReason: "unsupported_noteable_type")
    }
    if (noteableType.contains("merge") || noteableType == "pullrequest" || (noteableType.isEmpty() && rootHasObject(root, "merge_request"))) {
        kind = "pr"
        item = nestedObject(root, ["merge_request", "pull_request"])
    } else if (noteableType.contains("issue") || (noteableType.isEmpty() && rootHasObject(root, "issue"))) {
        kind = "issue"
        item = nestedObject(root, ["issue"])
    } else {
        return GitCodeWebhookParseResult(true, ignored: true, ignoreReason: "unsupported_noteable_type")
    }
    let repo = webhookRepo(root)
    if (repo.fullName().trimAscii() == "/") { return GitCodeWebhookParseResult(false, errorKind: "missing_repo", diagnostic: "payloadHash=${hashRawPayload(root.toJsonString())}") }
    let itemId = firstJsonString(item, ["iid", "number", "id"])
    if (itemId.isEmpty()) { return GitCodeWebhookParseResult(false, errorKind: "missing_item_id", diagnostic: "payloadHash=${hashRawPayload(root.toJsonString())}") }
    let commentId = firstJsonString(attrs, ["id", "note_id", "comment_id"])
    if (commentId.isEmpty()) { return GitCodeWebhookParseResult(false, errorKind: "missing_comment_id", diagnostic: "payloadHash=${hashRawPayload(root.toJsonString())}") }
    let rawComment = firstJsonString(attrs, ["note", "body", "content"])
    let body = sanitizeWebhookContent(rawComment)
    let url = firstNonEmpty([firstJsonString(attrs, ["url", "html_url", "web_url"]), firstJsonString(item, ["url", "html_url", "web_url"])])
    let identity = extractAuthorIdentityFromWebhook(root)
    GitCodeWebhookParseResult(
        true,
        event: GitCodeEvent(canonicalGitCodeEventId(repo, kind, itemId, commentId: commentId), repo.org, repo.name, kind, itemId, identity.login, identity.url, url, body),
        envelope: Some<GitCodeWebhookEnvelope>(GitCodeWebhookEnvelope(
            eventName,
            "comment",
            action: action,
            repoFullName: repo.fullName(),
            itemId: itemId,
            commentId: commentId,
            title: sanitizeWebhookContent(firstJsonString(item, ["title"])),
            body: sanitizeWebhookContent(firstJsonString(item, ["description", "body", "content"])),
            commentBody: body,
            authorLogin: identity.login,
            authorDisplayName: identity.displayName,
            authorUrl: identity.url
        ))
    )
}

func webhookRepo(root: JsonObject): GitCodeRepo {
    let project = nestedObject(root, ["project", "repository"])
    let full = firstJsonString(project, ["path_with_namespace", "full_name", "name_with_namespace"])
    if (full.contains("/")) {
        let parts = full.split("/")
        if (parts.size >= 2) { return GitCodeRepo(parts[0], parts[1]) }
    }
    let url = firstJsonString(project, ["web_url", "html_url", "url"])
    if (url.contains("gitcode.com/")) {
        let tail = url.split("gitcode.com/")[1].split("/")
        if (tail.size >= 2) { return GitCodeRepo(tail[0], tail[1]) }
    }
    GitCodeRepo("", "")
}

func webhookActor(root: JsonObject): String {
    let user = nestedObject(root, ["user", "author"])
    let actor = firstJsonString(user, ["name", "username", "login"])
    if (actor.isEmpty()) { "unknown" } else { actor }
}

func nestedObject(root: JsonObject, keys: Array<String>): JsonObject {
    for (key in keys) {
        match (root.get(key)) {
            case Some(value) =>
                try { return value.asObject() } catch (_: Exception) { () }
            case None => ()
        }
    }
    JsonObject()
}

func rootHasObject(root: JsonObject, key: String): Bool {
    match (root.get(key)) {
        case Some(value) =>
            try { let _ = value.asObject(); true } catch (_: Exception) { false }
        case None => false
    }
}

func sanitizeWebhookContent(raw: String): String {
    var text = redactSecrets(redactUrl(raw))
    if (containsLocalPath(text)) { text = "[REDACTED_LOCAL_PATH]" }
    compactSummary(text, limit: 1000)
}

func firstNonEmpty(items: Array<String>): String {
    for (item in items) {
        if (!item.trimAscii().isEmpty()) { return item.trimAscii() }
    }
    ""
}
