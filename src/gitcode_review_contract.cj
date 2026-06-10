package gitcodemonitor

import std.collection.*
import stdx.encoding.json.JsonValue

public let GITCODE_REVIEW_CONTRACT_VERSION = "gcm-metis-gitcode-review-v1"

public class GitCodeReviewRequestV1 {
    public let jobId: String
    public let event: GitCodeEvent

    public init(jobId: String, event: GitCodeEvent) {
        this.jobId = jobId
        this.event = event
    }
}

public class GitCodeReviewContractValidationResult {
    public let ok: Bool
    public let status: String
    public let contractVersion: String
    public let legacy: Bool
    public let diagnostic: String

    public init(ok: Bool, status: String, contractVersion!: String = "", legacy!: Bool = false, diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.contractVersion = contractVersion
        this.legacy = legacy
        this.diagnostic = diagnostic
    }
}

public func renderReviewRequestJson(
    jobId: String,
    event: GitCodeEvent,
    envelope!: ?GitCodeWebhookEnvelope = None<GitCodeWebhookEnvelope>,
    identity!: ?GitCodeAuthorIdentity = None<GitCodeAuthorIdentity>,
    maintainer!: ?GitCodeTeamLeaderResolution = None<GitCodeTeamLeaderResolution>,
    codeowners!: ?GitCodeCodeownerResolution = None<GitCodeCodeownerResolution>,
    issueKind!: String = "",
    issueFields!: ?GitCodeIssueFields = None<GitCodeIssueFields>,
    prFields!: ?GitCodePrFields = None<GitCodePrFields>,
    discussionContext!: ?GitCodeDiscussionContext = None<GitCodeDiscussionContext>
): String {
    let legacy = legacyAcceptedPayload(jobId, event)
    let kind = reviewEventKind(event)
    let repo = "${event.org}/${event.repo}"
    let commentId = scanEventCommentId(event)
    let resolvedIdentity = match (identity) {
        case Some(value) => value
        case None => GitCodeAuthorIdentity(event.actor, displayName: event.actor, url: event.actorUrl, emailResolveStatus: "email_unavailable")
    }
    let resolvedMaintainer = match (maintainer) {
        case Some(value) => value
        case None => GitCodeTeamLeaderResolution(repo, teamLeaderStatus: "not_found")
    }
    let resolvedCodeowners = match (codeowners) {
        case Some(value) => value
        case None => GitCodeCodeownerResolution(codeownerStatus: if (event.itemKind == "pr") { "not_found" } else { "not_applicable" })
    }
    let resolvedIssueKind = if (!issueKind.isEmpty()) { issueKind } else { classifyIssueKind(scanEventTitle(event), [], event.content, []) }
    let resolvedIssueFields = match (issueFields) {
        case Some(value) => value
        case None => extractIssueFields(event.content, resolvedIssueKind, [])
    }
    let resolvedPrFields = match (prFields) {
        case Some(value) => value
        case None => extractPrFields(event.content, [])
    }
    let envelopeJson = match (envelope) {
        case Some(value) => webhookEnvelopeJson(value)
        case None => "{\"eventHeader\":\"\",\"action\":\"\",\"deliveryId\":\"\"}"
    }
    let contextJson = match (discussionContext) {
        case Some(value) => ",\"context\":${value.toJsonString()}"
        case None => ""
    }
    "{" +
        legacy[1..legacy.size - 1] + "," +
        "\"contractVersion\":\"${GITCODE_REVIEW_CONTRACT_VERSION}\"," +
        "\"reviewRequest\":{" +
            "\"contractVersion\":\"${GITCODE_REVIEW_CONTRACT_VERSION}\"," +
            "\"jobId\":\"${jsonEscape(jobId.trimAscii())}\"," +
            "\"eventId\":\"${jsonEscape(event.id)}\"," +
            "\"repo\":\"${jsonEscape(repo)}\"," +
            "\"event\":{\"type\":\"${jsonEscape(kind)}\",\"itemKind\":\"${jsonEscape(event.itemKind)}\",\"number\":\"${jsonEscape(event.itemId)}\",\"commentId\":\"${jsonEscape(commentId)}\",\"action\":\"${jsonEscape(webhookEnvelopeAction(envelope))}\"}," +
            "\"delivery\":${envelopeJson}," +
            "\"author\":${authorJson(resolvedIdentity)}," +
            "\"maintainers\":{\"team\":\"${jsonEscape(resolvedMaintainer.team)}\",\"teamLeaderStatus\":\"${jsonEscape(resolvedMaintainer.teamLeaderStatus)}\",\"teamLeaders\":${peopleJson(resolvedMaintainer.teamLeaders)},\"codeownerStatus\":\"${jsonEscape(resolvedCodeowners.codeownerStatus)}\",\"codeowners\":${peopleJson(resolvedCodeowners.owners)}}," +
            "\"templates\":{\"issueKind\":\"${jsonEscape(resolvedIssueKind)}\",\"templateStatus\":\"${jsonEscape(resolvedIssueFields.templateStatus)}\",\"fields\":{\"cjcVersion\":\"${jsonEscape(resolvedIssueFields.cjcVersion)}\",\"branchVersions\":${stringArrayJson(resolvedIssueFields.branchVersions).toJsonString()}}}," +
            "\"pr\":{\"changedFiles\":${stringArrayJson(resolvedCodeowners.changedFiles).toJsonString()},\"changedFilesTruncated\":${resolvedCodeowners.changedFilesTruncated},\"prTemplate\":\"${jsonEscape(resolvedPrFields.prTemplate)}\",\"changeTypes\":${stringArrayJson(resolvedPrFields.changeTypes).toJsonString()},\"selfCheck\":${stringArrayJson(resolvedPrFields.selfCheck).toJsonString()},\"relatedIssues\":${stringArrayJson(resolvedPrFields.relatedIssues).toJsonString()}}," +
            "\"content\":{\"title\":\"${jsonEscape(compactSummary(redactSecrets(scanEventTitle(event)), limit: 160))}\",\"body\":\"${jsonEscape(compactSummary(redactSecrets(resolvedIssueFields.description), limit: 4096))}\"}" +
            contextJson +
        "}" +
    "}"
}

public func validateReviewRequestForTest(payload: String): GitCodeReviewContractValidationResult {
    let hasReviewRequest = payload.contains("\"reviewRequest\"")
    if (!hasReviewRequest) {
        return GitCodeReviewContractValidationResult(true, "ok", legacy: true)
    }
    if (containsSecret(payload)) {
        return GitCodeReviewContractValidationResult(false, "payload_contains_secret", diagnostic: hashRawPayload(payload))
    }
    if (containsLocalPath(payload)) {
        return GitCodeReviewContractValidationResult(false, "payload_contains_local_path", diagnostic: hashRawPayload(payload))
    }
    let root = try {
        JsonValue.fromStr(payload).asObject()
    } catch (_: Exception) {
        return GitCodeReviewContractValidationResult(false, "invalid_json", diagnostic: hashRawPayload(payload))
    }
    let version = firstJsonString(root, ["contractVersion"])
    if (version.isEmpty()) { return GitCodeReviewContractValidationResult(false, "contract_version_missing") }
    if (version != GITCODE_REVIEW_CONTRACT_VERSION) { return GitCodeReviewContractValidationResult(false, "contract_version_unsupported", contractVersion: version) }
    let request = nestedObject(root, ["reviewRequest"])
    if (firstJsonString(request, ["repo"]).trimAscii().isEmpty()) {
        return GitCodeReviewContractValidationResult(false, "repo_missing", contractVersion: version)
    }
    GitCodeReviewContractValidationResult(true, "ok", contractVersion: version)
}

func legacyAcceptedPayload(jobId: String, event: GitCodeEvent): String {
    let redacted = containsSecret(event.content) || containsSecret(scanEventTitle(event))
    let truncated = event.content.toRuneArray().size > 4096
    let content = compactSummary(redactSecrets(event.content), limit: 4096)
    let commentId = scanEventCommentId(event)
    let kind = if (commentId.isEmpty()) { event.itemKind } else { "comment" }
    let commentPart = if (commentId.isEmpty()) { "" } else { ",\"commentId\":\"${jsonEscape(commentId)}\"" }
    "{\"jobId\":\"${jsonEscape(jobId.trimAscii())}\",\"eventId\":\"${jsonEscape(event.id)}\",\"repo\":\"${jsonEscape(event.org)}/${jsonEscape(event.repo)}\",\"kind\":\"${jsonEscape(kind)}\",\"number\":\"${jsonEscape(event.itemId)}\"${commentPart},\"author\":\"${jsonEscape(event.actor)}\",\"url\":\"${jsonEscape(event.url)}\",\"title\":\"${jsonEscape(compactSummary(redactSecrets(scanEventTitle(event)), limit: 160))}\",\"content\":\"${jsonEscape(content)}\",\"contentRedacted\":${redacted},\"truncated\":${truncated}}"
}

func reviewEventKind(event: GitCodeEvent): String {
    if (!scanEventCommentId(event).isEmpty()) { return "comment" }
    event.itemKind
}

func authorJson(identity: GitCodeAuthorIdentity): String {
    "{\"login\":\"${jsonEscape(identity.login)}\",\"displayName\":\"${jsonEscape(identity.displayName)}\",\"url\":\"${jsonEscape(identity.url)}\",\"id\":\"${jsonEscape(identity.id)}\",\"emails\":${stringArrayJson(identity.emails).toJsonString()},\"emailSources\":${stringArrayJson(identity.emailSources).toJsonString()},\"emailResolveStatus\":\"${jsonEscape(identity.emailResolveStatus)}\",\"corporateDomainMatched\":${identity.corporateDomainMatched},\"corporateDomain\":\"${jsonEscape(identity.corporateDomain)}\",\"decision\":\"${jsonEscape(identity.decision)}\"}"
}

func peopleJson(people: Array<GitCodeMaintainerPerson>): String {
    let items = ArrayList<String>()
    for (person in people) {
        items.add("{\"mention\":\"${jsonEscape(person.mention)}\",\"login\":\"${jsonEscape(person.login)}\",\"url\":\"${jsonEscape(person.url)}\"}")
    }
    "[${joinStrings(items.toArray(), ",")}]"
}

func webhookEnvelopeJson(envelope: GitCodeWebhookEnvelope): String {
    "{\"eventHeader\":\"${jsonEscape(envelope.eventHeader)}\",\"action\":\"${jsonEscape(envelope.action)}\",\"deliveryId\":\"${jsonEscape(envelope.deliveryId)}\"}"
}

func webhookEnvelopeAction(envelope: ?GitCodeWebhookEnvelope): String {
    match (envelope) {
        case Some(value) => value.action
        case None => ""
    }
}
