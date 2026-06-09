package gitcodemonitor

import std.collection.*
import stdx.encoding.json.{JsonObject, JsonValue}

public class GitCodeIdentityDiagnostic {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message!: String = "", retryable!: Bool = false) {
        this.code = code
        this.message = message
        this.retryable = retryable
    }
}

public class GitCodeAuthorIdentity {
    public let login: String
    public let displayName: String
    public let url: String
    public let id: String
    public let emails: Array<String>
    public let emailSources: Array<String>
    public let emailResolveStatus: String
    public let corporateDomainMatched: Bool
    public let corporateDomain: String
    public let decision: String
    public let diagnostics: Array<GitCodeIdentityDiagnostic>

    public init(
        login: String,
        displayName!: String = "",
        url!: String = "",
        id!: String = "",
        emails!: Array<String> = [],
        emailSources!: Array<String> = [],
        emailResolveStatus!: String = "email_unavailable",
        corporateDomainMatched!: Bool = false,
        corporateDomain!: String = "",
        decision!: String = "process",
        diagnostics!: Array<GitCodeIdentityDiagnostic> = []
    ) {
        this.login = if (login.trimAscii().isEmpty()) { "unknown" } else { login.trimAscii() }
        this.displayName = displayName.trimAscii()
        this.url = url.trimAscii()
        this.id = id.trimAscii()
        this.emails = emails
        this.emailSources = emailSources
        this.emailResolveStatus = emailResolveStatus.trimAscii()
        this.corporateDomainMatched = corporateDomainMatched
        this.corporateDomain = corporateDomain.trimAscii()
        this.decision = decision.trimAscii()
        this.diagnostics = diagnostics
    }
}

public class GitCodeWebhookSubjectSet {
    public let targetAuthor: ?GitCodeAuthorIdentity
    public let commentAuthor: ?GitCodeAuthorIdentity
    public let eventActor: ?GitCodeAuthorIdentity
    public let sourceKind: String

    public init(
        targetAuthor!: ?GitCodeAuthorIdentity = None<GitCodeAuthorIdentity>,
        commentAuthor!: ?GitCodeAuthorIdentity = None<GitCodeAuthorIdentity>,
        eventActor!: ?GitCodeAuthorIdentity = None<GitCodeAuthorIdentity>,
        sourceKind!: String = ""
    ) {
        this.targetAuthor = targetAuthor
        this.commentAuthor = commentAuthor
        this.eventActor = eventActor
        this.sourceKind = sourceKind.trimAscii()
    }
}

public class RecordOnlySubjectDecision {
    public let decision: String
    public let matchedScope: String
    public let matchedType: String
    public let matchedValueHash: String
    public let reason: String
    public let missingDiagnostics: Array<String>

    public init(
        decision: String,
        matchedScope!: String = "",
        matchedType!: String = "",
        matchedValueHash!: String = "",
        reason!: String = "process",
        missingDiagnostics!: Array<String> = []
    ) {
        this.decision = decision.trimAscii()
        this.matchedScope = matchedScope.trimAscii()
        this.matchedType = matchedType.trimAscii()
        this.matchedValueHash = matchedValueHash.trimAscii()
        this.reason = reason.trimAscii()
        this.missingDiagnostics = missingDiagnostics
    }
}

public func extractAuthorIdentityFromWebhook(root: JsonObject): GitCodeAuthorIdentity {
    let author = firstAuthorObject(root)
    let login = firstNonEmpty([
        firstJsonString(author, ["login", "username", "name"]),
        firstJsonString(root, ["username", "login", "author"])
    ])
    GitCodeAuthorIdentity(
        if (login.isEmpty()) { "unknown" } else { login },
        displayName: firstJsonString(author, ["name", "display_name", "displayName", "nickname"]),
        url: firstJsonString(author, ["html_url", "web_url", "url"]),
        id: firstJsonString(author, ["id"])
    )
}

public func extractWebhookSubjectSet(root: JsonObject): GitCodeWebhookSubjectSet {
    let kind = firstNonEmpty([firstJsonString(root, ["object_kind", "objectKind"]), firstJsonString(root, ["event_type", "eventType"])])
        .toAsciiLower()
    let actor = identityFromObject(nestedObject(root, ["user", "author"]), idFallback: "")
    let actorSubject = if (identityIsPresent(actor)) { Some<GitCodeAuthorIdentity>(actor) } else { None<GitCodeAuthorIdentity> }
    if (kind.contains("note")) {
        let attrs = nestedObject(root, ["object_attributes"])
        let comment = identityFromObject(nestedObject(root, ["user", "author"]), idFallback: firstJsonString(attrs, ["author_id", "authorId"]))
        let commentSubject = if (identityIsPresent(comment)) { Some<GitCodeAuthorIdentity>(comment) } else { None<GitCodeAuthorIdentity> }
        let noteableType = firstJsonString(attrs, ["noteable_type", "noteableType"]).toAsciiLower()
        let targetObj = if (noteableType.contains("merge") || noteableType == "pullrequest" || rootHasObject(root, "merge_request")) {
            firstNestedAuthorObjectStrict(root, ["merge_request", "pull_request"])
        } else {
            firstNestedAuthorObjectStrict(root, ["issue"])
        }
        let target = identityFromObject(targetObj[0], idFallback: targetObj[1])
        return GitCodeWebhookSubjectSet(
            targetAuthor: if (identityIsPresent(target)) { Some<GitCodeAuthorIdentity>(target) } else { None<GitCodeAuthorIdentity> },
            commentAuthor: commentSubject,
            eventActor: actorSubject,
            sourceKind: "note"
        )
    }
    if (kind.contains("merge") || rootHasObject(root, "merge_request")) {
        let targetObj = firstNestedAuthorObject(root, ["merge_request", "object_attributes", "pull_request"])
        let target = identityFromObject(targetObj[0], idFallback: targetObj[1])
        return GitCodeWebhookSubjectSet(
            targetAuthor: if (identityIsPresent(target)) { Some<GitCodeAuthorIdentity>(target) } else { None<GitCodeAuthorIdentity> },
            eventActor: actorSubject,
            sourceKind: "pr"
        )
    }
    let targetObj = firstNestedAuthorObject(root, ["object_attributes", "issue"])
    let target = identityFromObject(targetObj[0], idFallback: targetObj[1])
    GitCodeWebhookSubjectSet(
        targetAuthor: if (identityIsPresent(target)) { Some<GitCodeAuthorIdentity>(target) } else { None<GitCodeAuthorIdentity> },
        eventActor: actorSubject,
        sourceKind: "issue"
    )
}

public func classifyRecordOnlySubjects(subjects: GitCodeWebhookSubjectSet, policy: AuthorPolicyConfig): RecordOnlySubjectDecision {
    if (!authorPolicyRecordOnlyEffective(policy)) {
        return RecordOnlySubjectDecision("process")
    }
    let missing = ArrayList<String>()
    let commentDecision = classifySubjectForRule(subjects.commentAuthor, mergeAuthorPolicyIdentityRule(policy.commentAuthorRule), "comment_author")
    if (subjects.commentAuthor.isNone() && authorPolicyIdentityRuleEffective(policy.commentAuthorRule)) { missing.add("comment_subject_missing") }

    let targetDecision = classifySubjectForRule(subjects.targetAuthor, mergeAuthorPolicyIdentityRule(policy.targetAuthorRule, emailDomains: policy.recordOnlyEmailDomains), "target_author")
    if (subjects.targetAuthor.isNone() && (authorPolicyIdentityRuleEffective(policy.targetAuthorRule) || policy.recordOnlyEmailDomains.size > 0)) { missing.add("target_subject_missing") }

    let actorDecision = classifySubjectForRule(subjects.eventActor, mergeAuthorPolicyIdentityRule(policy.eventActorRule), "event_actor")
    if (subjects.eventActor.isNone() && authorPolicyIdentityRuleEffective(policy.eventActorRule)) { missing.add("event_actor_missing") }

    let missingDiagnostics = missing.toArray()
    if (commentDecision.decision == "record_only") { return recordOnlyDecisionWithMissing(commentDecision, missingDiagnostics) }
    if (targetDecision.decision == "record_only") { return recordOnlyDecisionWithMissing(targetDecision, missingDiagnostics) }
    if (actorDecision.decision == "record_only") { return recordOnlyDecisionWithMissing(actorDecision, missingDiagnostics) }
    RecordOnlySubjectDecision("process", missingDiagnostics: missing.toArray())
}

func recordOnlyDecisionWithMissing(decision: RecordOnlySubjectDecision, missingDiagnostics: Array<String>): RecordOnlySubjectDecision {
    RecordOnlySubjectDecision(
        decision.decision,
        matchedScope: decision.matchedScope,
        matchedType: decision.matchedType,
        matchedValueHash: decision.matchedValueHash,
        reason: decision.reason,
        missingDiagnostics: missingDiagnostics
    )
}

func classifySubjectForRule(subject: ?GitCodeAuthorIdentity, rule: AuthorPolicyIdentityRule, scope: String): RecordOnlySubjectDecision {
    match (subject) {
        case Some(identity) =>
            let id = identity.id.trimAscii()
            if (!id.isEmpty() && rule.ids.contains(id)) {
                return recordOnlyDecision(scope, "id", id)
            }
            for (email in identity.emails) {
                let lower = email.trimAscii().toAsciiLower()
                if (!lower.isEmpty() && rule.emails.contains(lower)) {
                    return recordOnlyDecision(scope, "email", lower)
                }
                for (domain in rule.emailDomains) {
                    if (!domain.trimAscii().isEmpty() && lower.endsWith(domain.trimAscii().toAsciiLower())) {
                        return RecordOnlySubjectDecision(
                            "record_only",
                            matchedScope: scope,
                            matchedType: "email_domain",
                            matchedValueHash: hashRawPayload(domain),
                            reason: "corporate_author"
                        )
                    }
                }
            }
            let login = identity.login.trimAscii().toAsciiLower()
            if (!login.isEmpty() && rule.usernames.contains(login)) {
                return recordOnlyDecision(scope, "username", login)
            }
        case None => ()
    }
    RecordOnlySubjectDecision("process")
}

func recordOnlyDecision(scope: String, matchedType: String, matchedValue: String): RecordOnlySubjectDecision {
    RecordOnlySubjectDecision(
        "record_only",
        matchedScope: scope,
        matchedType: matchedType,
        matchedValueHash: hashRawPayload(matchedValue),
        reason: "record_only_${scope}_${matchedType}"
    )
}

public func resolveAuthorEmails(root: JsonObject, client: GitCodeApiClient): GitCodeAuthorIdentity {
    let _ = client
    let base = extractAuthorIdentityFromWebhook(root)
    let emails = ArrayList<String>()
    let sources = ArrayList<String>()
    let diagnostics = ArrayList<GitCodeIdentityDiagnostic>()
    collectEmailsFromObject(firstAuthorObject(root), "webhook", emails, sources, diagnostics)
    collectEmailsFromObject(root, "webhook", emails, sources, diagnostics)
    collectEmailsFromObject(nestedObject(root, ["commit"]), "commit", emails, sources, diagnostics)
    collectEmailsFromObject(nestedObject(nestedObject(root, ["commit"]), ["author"]), "commit.author", emails, sources, diagnostics)

    let explicitStatus = firstJsonString(root, ["emailResolveStatus", "email_resolve_status"])
    let status = if (!explicitStatus.isEmpty()) {
        explicitStatus
    } else if (emails.size > 0) {
        "resolved"
    } else {
        "email_unavailable"
    }
    GitCodeAuthorIdentity(
        base.login,
        displayName: base.displayName,
        url: base.url,
        id: base.id,
        emails: dedupeStrings(emails.toArray()),
        emailSources: dedupeStrings(sources.toArray()),
        emailResolveStatus: status,
        diagnostics: diagnostics.toArray()
    )
}

public func classifyCorporateAuthor(identity: GitCodeAuthorIdentity, domains: Array<String>): GitCodeAuthorIdentity {
    for (email in identity.emails) {
        let lower = email.toAsciiLower()
        for (domain in domains) {
            let normalized = domain.trimAscii().toAsciiLower()
            if (!normalized.isEmpty() && lower.endsWith(normalized)) {
                return GitCodeAuthorIdentity(
                    identity.login,
                    displayName: identity.displayName,
                    url: identity.url,
                    id: identity.id,
                    emails: identity.emails,
                    emailSources: identity.emailSources,
                    emailResolveStatus: identity.emailResolveStatus,
                    corporateDomainMatched: true,
                    corporateDomain: normalized,
                    decision: "record_only",
                    diagnostics: identity.diagnostics
                )
            }
        }
    }
    GitCodeAuthorIdentity(
        identity.login,
        displayName: identity.displayName,
        url: identity.url,
        id: identity.id,
        emails: identity.emails,
        emailSources: identity.emailSources,
        emailResolveStatus: identity.emailResolveStatus,
        decision: "process",
        diagnostics: identity.diagnostics
    )
}

func identityFromObject(obj: JsonObject, idFallback!: String = ""): GitCodeAuthorIdentity {
    let emails = ArrayList<String>()
    let sources = ArrayList<String>()
    let diagnostics = ArrayList<GitCodeIdentityDiagnostic>()
    collectEmailsFromObject(obj, "webhook", emails, sources, diagnostics)
    let login = firstJsonString(obj, ["login", "username", "name"])
    GitCodeAuthorIdentity(
        if (login.isEmpty()) { "unknown" } else { login },
        displayName: firstJsonString(obj, ["display_name", "displayName", "nickname", "name"]),
        url: firstJsonString(obj, ["html_url", "web_url", "url"]),
        id: firstNonEmpty([firstJsonString(obj, ["id", "user_id", "userId", "author_id", "authorId"]), idFallback]),
        emails: dedupeStrings(emails.toArray()),
        emailSources: dedupeStrings(sources.toArray()),
        emailResolveStatus: if (emails.size > 0) { "resolved" } else { "email_unavailable" },
        diagnostics: diagnostics.toArray()
    )
}

func identityIsPresent(identity: GitCodeAuthorIdentity): Bool {
    identity.id.trimAscii() != "" || identity.login.trimAscii().toAsciiLower() != "unknown" || identity.emails.size > 0
}

func firstNestedAuthorObject(root: JsonObject, parentKeys: Array<String>): (JsonObject, String) {
    for (parentKey in parentKeys) {
        let parent = nestedObject(root, [parentKey])
        let author = nestedObject(parent, ["author", "user"])
        let fallback = firstJsonString(parent, ["author_id", "authorId", "user_id", "userId"])
        if (identityIsPresent(identityFromObject(author, idFallback: fallback))) {
            return (author, fallback)
        }
        if (!fallback.isEmpty()) {
            return (author, fallback)
        }
    }
    (firstAuthorObject(root), "")
}

func firstNestedAuthorObjectStrict(root: JsonObject, parentKeys: Array<String>): (JsonObject, String) {
    for (parentKey in parentKeys) {
        let parent = nestedObject(root, [parentKey])
        let author = nestedObject(parent, ["author", "user"])
        let fallback = firstJsonString(parent, ["author_id", "authorId", "user_id", "userId"])
        if (identityIsPresent(identityFromObject(author, idFallback: fallback))) {
            return (author, fallback)
        }
        if (!fallback.isEmpty()) {
            return (author, fallback)
        }
    }
    (JsonObject(), "")
}

func firstAuthorObject(root: JsonObject): JsonObject {
    for (key in ["user", "author"]) {
        let obj = nestedObject(root, [key])
        if (!firstJsonString(obj, ["login", "username", "name", "email"]).isEmpty()) { return obj }
    }
    for (parentKey in ["object_attributes", "merge_request", "pull_request", "issue", "note"]) {
        let parent = nestedObject(root, [parentKey])
        for (key in ["author", "user"]) {
            let obj = nestedObject(parent, [key])
            if (!firstJsonString(obj, ["login", "username", "name", "email"]).isEmpty()) { return obj }
        }
    }
    JsonObject()
}

func collectEmailsFromObject(obj: JsonObject, source: String, emails: ArrayList<String>, sources: ArrayList<String>, diagnostics: ArrayList<GitCodeIdentityDiagnostic>): Unit {
    for (key in ["email", "mail", "public_email", "publicEmail"]) {
        addEmailCandidate(firstJsonString(obj, [key]), source, emails, sources, diagnostics)
    }
    for (email in firstJsonStringArray(obj, ["emails", "email_addresses", "emailAddresses"])) {
        addEmailCandidate(email, source, emails, sources, diagnostics)
    }
}

func addEmailCandidate(raw: String, source: String, emails: ArrayList<String>, sources: ArrayList<String>, diagnostics: ArrayList<GitCodeIdentityDiagnostic>): Unit {
    let email = raw.trimAscii()
    if (email.isEmpty()) { return }
    if (!looksLikeEmail(email)) {
        diagnostics.add(GitCodeIdentityDiagnostic("invalid_email", message: hashRawPayload(email)))
        return
    }
    let lower = email.toAsciiLower()
    if (!emails.contains(lower)) {
        emails.add(lower)
        sources.add(source)
    }
}

func looksLikeEmail(email: String): Bool {
    let parts = email.split("@")
    parts.size == 2 && !parts[0].isEmpty() && parts[1].contains(".")
}

func dedupeStrings(items: Array<String>): Array<String> {
    let seen = HashSet<String>()
    let out = ArrayList<String>()
    for (item in items) {
        let value = item.trimAscii()
        if (!value.isEmpty() && !seen.contains(value)) {
            seen.add(value)
            out.add(value)
        }
    }
    out.toArray()
}
