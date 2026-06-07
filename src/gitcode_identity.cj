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
