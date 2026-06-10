package gitcodemonitor

import std.collection.*

const GITCODE_CONTEXT_PARENT_BODY_LIMIT: Int64 = 4096
const GITCODE_CONTEXT_COMMENT_BODY_LIMIT: Int64 = 2048
const GITCODE_CONTEXT_TRIGGER_BODY_LIMIT: Int64 = 2048
const GITCODE_CONTEXT_TOTAL_TEXT_LIMIT: Int64 = 12000
const GITCODE_CONTEXT_MAX_PAGES: Int64 = 10

public class GitCodeDiscussionParent {
    public let kind: String
    public let number: String
    public let title: String
    public let body: String
    public let url: String
    public let author: String
    public let authorUrl: String
    public let source: String

    public init(
        kind!: String = "",
        number!: String = "",
        title!: String = "",
        body!: String = "",
        url!: String = "",
        author!: String = "",
        authorUrl!: String = "",
        source!: String = "api"
    ) {
        this.kind = kind
        this.number = number
        this.title = title
        this.body = body
        this.url = url
        this.author = author
        this.authorUrl = authorUrl
        this.source = source
    }
}

public class GitCodeDiscussionComment {
    public let id: String
    public let body: String
    public let url: String
    public let author: String
    public let authorUrl: String
    public let createdAt: String
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
    public let orderIndex: Int64

    public init(
        id!: String = "",
        body!: String = "",
        url!: String = "",
        author!: String = "",
        authorUrl!: String = "",
        createdAt!: String = "",
        createdAtMs!: Int64 = 0,
        updatedAtMs!: Int64 = 0,
        orderIndex!: Int64 = 0
    ) {
        this.id = id
        this.body = body
        this.url = url
        this.author = author
        this.authorUrl = authorUrl
        this.createdAt = createdAt
        this.createdAtMs = createdAtMs
        this.updatedAtMs = updatedAtMs
        this.orderIndex = orderIndex
    }
}

public class GitCodeDiscussionParentFetchResult {
    public let parent: GitCodeDiscussionParent
    public let errorKind: String
    public let retryAfterMs: Int64

    public init(parent!: GitCodeDiscussionParent = GitCodeDiscussionParent(), errorKind!: String = "ok", retryAfterMs!: Int64 = 0) {
        this.parent = parent
        this.errorKind = errorKind
        this.retryAfterMs = retryAfterMs
    }
}

public class GitCodeDiscussionCommentsPageResult {
    public let comments: Array<GitCodeDiscussionComment>
    public let errorKind: String
    public let retryAfterMs: Int64

    public init(comments!: Array<GitCodeDiscussionComment> = [], errorKind!: String = "ok", retryAfterMs!: Int64 = 0) {
        this.comments = comments
        this.errorKind = errorKind
        this.retryAfterMs = retryAfterMs
    }
}

public class GitCodeDiscussionContext {
    public let status: String
    public let repo: String
    public let kind: String
    public let number: String
    public let commentId: String
    public let parent: GitCodeDiscussionParent
    public let triggerComment: GitCodeDiscussionComment
    public let previousComments: Array<GitCodeDiscussionComment>
    public let previousCommentsTotal: Int64
    public let previousCommentsIncluded: Int64
    public let truncated: Bool
    public let diagnostics: Array<String>

    public init(
        status!: String = "resolved",
        repo!: String = "",
        kind!: String = "",
        number!: String = "",
        commentId!: String = "",
        parent!: GitCodeDiscussionParent = GitCodeDiscussionParent(),
        triggerComment!: GitCodeDiscussionComment = GitCodeDiscussionComment(),
        previousComments!: Array<GitCodeDiscussionComment> = [],
        previousCommentsTotal!: Int64 = -1,
        previousCommentsIncluded!: Int64 = -1,
        truncated!: Bool = false,
        diagnostics!: Array<String> = []
    ) {
        this.status = status
        this.repo = repo
        this.kind = kind
        this.number = number
        this.commentId = commentId
        this.parent = parent
        this.triggerComment = triggerComment
        this.previousComments = previousComments
        this.previousCommentsTotal = if (previousCommentsTotal >= 0) { previousCommentsTotal } else { previousComments.size }
        this.previousCommentsIncluded = if (previousCommentsIncluded >= 0) { previousCommentsIncluded } else { previousComments.size }
        this.truncated = truncated
        this.diagnostics = diagnostics
    }

    public func toJsonString(): String {
        gitCodeDiscussionContextToJson(sanitizeGitCodeDiscussionContext(this))
    }
}

public func sanitizeGitCodeDiscussionContext(context: GitCodeDiscussionContext): GitCodeDiscussionContext {
    buildSafeDiscussionContext(
        context.status,
        context.repo,
        context.kind,
        context.number,
        context.commentId,
        context.parent,
        context.triggerComment,
        context.previousComments,
        context.diagnostics,
        previousCommentsTotal: context.previousCommentsTotal
    )
}

public func fetchGitCodeDiscussionContext(
    transport: GitCodeHttpTransport,
    event: GitCodeEvent,
    envelope!: ?GitCodeWebhookEnvelope = None<GitCodeWebhookEnvelope>
): GitCodeDiscussionContext {
    let repo = GitCodeRepo(event.org, event.repo)
    let commentId = scanEventCommentId(event)
    let diagnostics = ArrayList<String>()
    var status = "resolved"
    var parent = GitCodeDiscussionParent(kind: event.itemKind, number: event.itemId, title: scanEventTitle(event), body: "", url: event.url, author: event.actor, authorUrl: event.actorUrl, source: "event")

    let parentResult = if (event.itemKind == "pr") {
        transport.fetchPullRequestDetail(repo, event.itemId)
    } else {
        transport.fetchIssueDetail(repo, event.itemId)
    }
    if (parentResult.errorKind == "ok" && (!parentResult.parent.body.isEmpty() || !parentResult.parent.title.isEmpty())) {
        parent = parentResult.parent
    } else {
        if (parentResult.errorKind != "ok") {
            status = "degraded"
            diagnostics.add("detail_fetch_failed:${parentResult.errorKind}")
            if (parentResult.retryAfterMs > 0) { diagnostics.add("detail_retry_after_ms:${parentResult.retryAfterMs}") }
        } else {
            status = "degraded"
            diagnostics.add("detail_missing")
        }
        parent = fallbackParentFromEnvelope(event, envelope)
    }

    let allComments = ArrayList<GitCodeDiscussionComment>()
    var page: Int64 = 1
    while (page <= GITCODE_CONTEXT_MAX_PAGES) {
        let pageResult = transport.listItemCommentsPage(repo, event.itemKind, event.itemId, page)
        if (pageResult.errorKind != "ok") {
            status = "degraded"
            diagnostics.add("comments_fetch_failed:${pageResult.errorKind}")
            if (pageResult.retryAfterMs > 0) { diagnostics.add("comments_retry_after_ms:${pageResult.retryAfterMs}") }
            break
        }
        for (comment in pageResult.comments) {
            allComments.add(comment)
        }
        if (pageResult.comments.size < transport.pageSize || pageResult.comments.size == 0) { break }
        page++
    }

    let ordered = orderDiscussionComments(allComments.toArray(), diagnostics)
    let previous = ArrayList<GitCodeDiscussionComment>()
    var trigger = GitCodeDiscussionComment(id: commentId, body: firstNonEmpty([match (envelope) { case Some(value) => value.commentBody case None => "" }, event.content]), url: event.url, author: event.actor, authorUrl: event.actorUrl)
    var foundTrigger = false
    for (comment in ordered) {
        if (!commentId.isEmpty() && comment.id == commentId) {
            trigger = comment
            foundTrigger = true
        } else if (!foundTrigger) {
            previous.add(comment)
        }
    }
    if (!foundTrigger) {
        if (!commentId.isEmpty()) { diagnostics.add("current_comment_not_found") }
        if (status == "resolved") { status = "degraded" }
        previous.clear()
        for (comment in ordered) { previous.add(comment) }
    }

    buildSafeDiscussionContext(
        status,
        repo.fullName(),
        event.itemKind,
        event.itemId,
        commentId,
        parent,
        trigger,
        previous.toArray(),
        diagnostics.toArray()
    )
}

func buildSafeDiscussionContext(
    status: String,
    repo: String,
    kind: String,
    number: String,
    commentId: String,
    parent: GitCodeDiscussionParent,
    trigger: GitCodeDiscussionComment,
    previous: Array<GitCodeDiscussionComment>,
    diagnostics: Array<String>,
    previousCommentsTotal!: Int64 = -1
): GitCodeDiscussionContext {
    var truncated = false
    var budget = GITCODE_CONTEXT_TOTAL_TEXT_LIMIT
    let (safeTitle, titleTruncated) = safeDiscussionText(parent.title, 240)
    let (safeParentBody, parentTruncated) = safeDiscussionText(parent.body, GITCODE_CONTEXT_PARENT_BODY_LIMIT)
    let (safeTriggerBody, triggerTruncated) = safeDiscussionText(trigger.body, GITCODE_CONTEXT_TRIGGER_BODY_LIMIT)
    if (titleTruncated || parentTruncated || triggerTruncated) { truncated = true }
    budget -= safeTitle.toRuneArray().size
    budget -= safeParentBody.toRuneArray().size
    budget -= safeTriggerBody.toRuneArray().size

    let safeParent = GitCodeDiscussionParent(
        kind: parent.kind,
        number: parent.number,
        title: safeTitle,
        body: safeParentBody,
        url: safeDiscussionUrl(parent.url),
        author: safeDiscussionTextValue(parent.author, 160),
        authorUrl: safeDiscussionUrl(parent.authorUrl),
        source: parent.source
    )
    let safeTrigger = GitCodeDiscussionComment(
        id: safeDiscussionTextValue(trigger.id, 80),
        body: safeTriggerBody,
        url: safeDiscussionUrl(trigger.url),
        author: safeDiscussionTextValue(trigger.author, 160),
        authorUrl: safeDiscussionUrl(trigger.authorUrl),
        createdAt: safeDiscussionTextValue(trigger.createdAt, 80),
        createdAtMs: trigger.createdAtMs,
        updatedAtMs: trigger.updatedAtMs,
        orderIndex: trigger.orderIndex
    )

    let included = ArrayList<GitCodeDiscussionComment>()
    for (comment in previous) {
        if (budget <= 0) {
            truncated = true
            break
        }
        let perCommentLimit = if (budget < GITCODE_CONTEXT_COMMENT_BODY_LIMIT) { budget } else { GITCODE_CONTEXT_COMMENT_BODY_LIMIT }
        let (safeBody, bodyTruncated) = safeDiscussionText(comment.body, perCommentLimit)
        if (bodyTruncated) { truncated = true }
        included.add(GitCodeDiscussionComment(
            id: safeDiscussionTextValue(comment.id, 80),
            body: safeBody,
            url: safeDiscussionUrl(comment.url),
            author: safeDiscussionTextValue(comment.author, 160),
            authorUrl: safeDiscussionUrl(comment.authorUrl),
            createdAt: safeDiscussionTextValue(comment.createdAt, 80),
            createdAtMs: comment.createdAtMs,
            updatedAtMs: comment.updatedAtMs,
            orderIndex: comment.orderIndex
        ))
        budget -= safeBody.toRuneArray().size
    }
    let total = if (previousCommentsTotal >= 0) { previousCommentsTotal } else { previous.size }
    if (included.size < total) { truncated = true }

    GitCodeDiscussionContext(
        status: safeDiscussionTextValue(status, 40),
        repo: safeDiscussionTextValue(repo, 240),
        kind: safeDiscussionTextValue(kind, 40),
        number: safeDiscussionTextValue(number, 80),
        commentId: safeDiscussionTextValue(commentId, 80),
        parent: safeParent,
        triggerComment: safeTrigger,
        previousComments: included.toArray(),
        previousCommentsTotal: total,
        previousCommentsIncluded: included.size,
        truncated: truncated,
        diagnostics: safeDiagnostics(diagnostics)
    )
}

func orderDiscussionComments(comments: Array<GitCodeDiscussionComment>, diagnostics: ArrayList<String>): Array<GitCodeDiscussionComment> {
    var missingCreatedAt = false
    for (comment in comments) {
        if (comment.createdAtMs == 0 && comment.createdAt.isEmpty()) {
            missingCreatedAt = true
        }
    }
    if (missingCreatedAt && !diagnostics.contains("order_degraded")) {
        diagnostics.add("order_degraded")
    }
    comments
}

func fallbackParentFromEnvelope(event: GitCodeEvent, envelope: ?GitCodeWebhookEnvelope): GitCodeDiscussionParent {
    match (envelope) {
        case Some(value) =>
            GitCodeDiscussionParent(
                kind: if (value.eventType.isEmpty() || value.eventType == "comment") { event.itemKind } else { value.eventType },
                number: firstNonEmpty([value.itemId, event.itemId]),
                title: firstNonEmpty([value.title, scanEventTitle(event)]),
                body: value.body,
                url: event.url,
                author: firstNonEmpty([value.authorLogin, value.authorDisplayName, event.actor]),
                authorUrl: firstNonEmpty([value.authorUrl, event.actorUrl]),
                source: "webhook_envelope"
            )
        case None =>
            GitCodeDiscussionParent(kind: event.itemKind, number: event.itemId, title: scanEventTitle(event), body: "", url: event.url, author: event.actor, authorUrl: event.actorUrl, source: "event")
    }
}

func safeDiscussionTextValue(raw: String, limit: Int64): String {
    let (text, _) = safeDiscussionText(raw, limit)
    text
}

func safeDiscussionText(raw: String, limit: Int64): (String, Bool) {
    var text = redactSecrets(raw)
    if (containsLocalPath(text)) { text = "[REDACTED_LOCAL_PATH]" }
    if (containsSecret(text)) { text = "[REDACTED]" }
    let runes = text.toRuneArray()
    if (runes.size <= limit) { return (text, false) }
    if (limit <= 0) { return ("", true) }
    (String(runes[0..limit]) + "...", true)
}

func safeDiscussionUrl(raw: String): String {
    let text = redactUrl(redactSecrets(raw))
    if (containsLocalPath(text) || containsSecret(text)) { return "[REDACTED]" }
    compactSummary(text, limit: 1024)
}

func safeDiagnostics(items: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (item in items) {
        let safe = safeDiscussionTextValue(item, 240)
        if (!safe.isEmpty() && !out.contains(safe)) { out.add(safe) }
    }
    out.toArray()
}

public func gitCodeDiscussionContextToJson(context: GitCodeDiscussionContext): String {
    let previousItems = ArrayList<String>()
    for (comment in context.previousComments) {
        previousItems.add(gitCodeDiscussionCommentToJson(comment))
    }
    "{" +
        "\"status\":\"${jsonEscape(context.status)}\"," +
        "\"repo\":\"${jsonEscape(context.repo)}\"," +
        "\"kind\":\"${jsonEscape(context.kind)}\"," +
        "\"number\":\"${jsonEscape(context.number)}\"," +
        "\"commentId\":\"${jsonEscape(context.commentId)}\"," +
        "\"parent\":${gitCodeDiscussionParentToJson(context.parent)}," +
        "\"triggerComment\":${gitCodeDiscussionCommentToJson(context.triggerComment)}," +
        "\"previousComments\":[${joinStrings(previousItems.toArray(), ",")}]," +
        "\"previousCommentsTotal\":${context.previousCommentsTotal}," +
        "\"previousCommentsIncluded\":${context.previousCommentsIncluded}," +
        "\"truncated\":${context.truncated}," +
        "\"diagnostics\":${stringArrayJson(context.diagnostics).toJsonString()}" +
    "}"
}

func gitCodeDiscussionParentToJson(parent: GitCodeDiscussionParent): String {
    "{" +
        "\"kind\":\"${jsonEscape(parent.kind)}\"," +
        "\"number\":\"${jsonEscape(parent.number)}\"," +
        "\"title\":\"${jsonEscape(parent.title)}\"," +
        "\"body\":\"${jsonEscape(parent.body)}\"," +
        "\"url\":\"${jsonEscape(parent.url)}\"," +
        "\"author\":\"${jsonEscape(parent.author)}\"," +
        "\"authorUrl\":\"${jsonEscape(parent.authorUrl)}\"," +
        "\"source\":\"${jsonEscape(parent.source)}\"" +
    "}"
}

func gitCodeDiscussionCommentToJson(comment: GitCodeDiscussionComment): String {
    "{" +
        "\"id\":\"${jsonEscape(comment.id)}\"," +
        "\"body\":\"${jsonEscape(comment.body)}\"," +
        "\"url\":\"${jsonEscape(comment.url)}\"," +
        "\"author\":\"${jsonEscape(comment.author)}\"," +
        "\"authorUrl\":\"${jsonEscape(comment.authorUrl)}\"," +
        "\"createdAt\":\"${jsonEscape(comment.createdAt)}\"," +
        "\"createdAtMs\":${comment.createdAtMs}," +
        "\"updatedAtMs\":${comment.updatedAtMs}" +
    "}"
}
