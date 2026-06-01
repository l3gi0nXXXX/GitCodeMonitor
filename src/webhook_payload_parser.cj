package gitcodemonitor

import stdx.encoding.json.{JsonObject, JsonValue}

public class GitCodeWebhookParseResult {
    public let ok: Bool
    public let event: GitCodeEvent
    public let ignored: Bool
    public let ignoreReason: String
    public let errorKind: String
    public let diagnostic: String
    public init(ok: Bool, event!: GitCodeEvent = GitCodeEvent("", "", "", "", "", "", "", "", ""), ignored!: Bool = false, ignoreReason!: String = "", errorKind!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.event = event
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
        case "Merge Request Hook" => parseWebhookItem(root, "pr")
        case "Issue Hook" => parseWebhookItem(root, "issue")
        case "Note Hook" => parseWebhookNote(root)
        case _ => GitCodeWebhookParseResult(true, ignored: true, ignoreReason: "unknown_event")
    }
}

func parseWebhookItem(root: JsonObject, kind: String): GitCodeWebhookParseResult {
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
    let actor = webhookActor(root)
    GitCodeWebhookParseResult(true, event: GitCodeEvent(canonicalGitCodeEventId(repo, kind, itemId), repo.org, repo.name, kind, itemId, actor, "", url, content))
}

func parseWebhookNote(root: JsonObject): GitCodeWebhookParseResult {
    let attrs = nestedObject(root, ["object_attributes"])
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
    let body = sanitizeWebhookContent(firstJsonString(attrs, ["note", "body", "content"]))
    let url = firstNonEmpty([firstJsonString(attrs, ["url", "html_url", "web_url"]), firstJsonString(item, ["url", "html_url", "web_url"])])
    GitCodeWebhookParseResult(true, event: GitCodeEvent(canonicalGitCodeEventId(repo, kind, itemId, commentId: commentId), repo.org, repo.name, kind, itemId, webhookActor(root), "", url, body))
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
