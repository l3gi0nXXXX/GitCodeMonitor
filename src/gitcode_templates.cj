package gitcodemonitor

import std.collection.*

public class GitCodeTemplateEntry {
    public let path: String
    public let name: String
    public let content: String

    public init(path: String, name!: String = "", content!: String = "") {
        this.path = path
        this.name = if (name.isEmpty()) { path } else { name }
        this.content = content
    }
}

public class GitCodeIssueFields {
    public let kind: String
    public let cjcVersion: String
    public let branchVersions: Array<String>
    public let description: String
    public let templateStatus: String

    public init(kind: String, cjcVersion!: String = "", branchVersions!: Array<String> = [], description!: String = "", templateStatus!: String = "resolved") {
        this.kind = kind
        this.cjcVersion = cjcVersion.trimAscii()
        this.branchVersions = branchVersions
        this.description = description
        this.templateStatus = templateStatus
    }
}

public class GitCodePrFields {
    public let prTemplate: String
    public let changeTypes: Array<String>
    public let selfCheck: Array<String>
    public let relatedIssues: Array<String>

    public init(prTemplate!: String = "unknown", changeTypes!: Array<String> = [], selfCheck!: Array<String> = [], relatedIssues!: Array<String> = []) {
        this.prTemplate = prTemplate
        this.changeTypes = changeTypes
        this.selfCheck = selfCheck
        this.relatedIssues = relatedIssues
    }
}

public func fetchIssueTemplateCatalog(client: GitCodeApiClient, repo: GitCodeRepo, ref: String): GitCodeTextFetchResult {
    let req = client.contentsRequest(repo, ".gitcode/ISSUE_TEMPLATE", ref)
    GitCodeTextFetchResult(false, "missing", diagnostic: hashRawPayload(req.url))
}

public func fetchPrTemplateCatalog(client: GitCodeApiClient, repo: GitCodeRepo, ref: String): GitCodeTextFetchResult {
    let req = client.contentsRequest(repo, ".gitcode/PULL_REQUEST_TEMPLATE", ref)
    GitCodeTextFetchResult(false, "missing", diagnostic: hashRawPayload(req.url))
}

public func classifyIssueKind(title: String, labels: Array<String>, body: String, templates: Array<GitCodeTemplateEntry>): String {
    let _ = templates
    for (label in labels) {
        let lower = label.toAsciiLower()
        if (lower.contains("question")) { return "question" }
        if (lower.contains("feature")) { return "feature-request" }
        if (lower.contains("bug")) { return "bug" }
    }
    let lowerTitle = title.toAsciiLower()
    if (lowerTitle.contains("[feature]") || lowerTitle.contains("[feature]:") || lowerTitle.contains("feature request")) { return "feature-request" }
    if (lowerTitle.contains("[bug]") || lowerTitle.contains("[bug]:") || lowerTitle.contains("bug")) { return "bug" }
    if (lowerTitle.contains("[question]") || lowerTitle.contains("question")) { return "question" }
    let lowerBody = body.toAsciiLower()
    if (lowerBody.contains("cjc version") || lowerBody.contains("branch version")) { return "bug" }
    "unknown"
}

public func extractIssueFields(body: String, kind: String, templates: Array<GitCodeTemplateEntry>): GitCodeIssueFields {
    let _ = templates
    let clean = sanitizeTemplateText(body)
    let cjc = sectionFirstValue(body, ["cjc version", "cjc版本"])
    let branches = checkedValuesAfterHeading(body, ["branch version", "分支版本", "affected branch"])
    GitCodeIssueFields(kind, cjcVersion: sanitizeTemplateText(cjc), branchVersions: branches, description: clean)
}

public func extractPrFields(body: String, templates: Array<GitCodeTemplateEntry>): GitCodePrFields {
    let _ = templates
    let changes = ArrayList<String>()
    let checks = ArrayList<String>()
    let related = ArrayList<String>()
    var inSelfCheck = false
    for (lineRaw in body.split("\n")) {
        let line = lineRaw.trimAscii()
        let lower = line.toAsciiLower()
        if (lower.contains("self") || line.contains("自验证")) { inSelfCheck = true }
        if (line.contains("[x]") || line.contains("[X]")) {
            let value = checkboxValue(line)
            if (!value.isEmpty()) {
                if (inSelfCheck) {
                    checks.add(value)
                } else {
                    changes.add(value)
                }
            }
        }
        if ((line.startsWith("http://") || line.startsWith("https://")) && line.contains("gitcode.com")) {
            related.add(line)
        }
    }
    GitCodePrFields(
        prTemplate: if (body.contains("变更类型")) { "chinese" } else { "english" },
        changeTypes: dedupeStrings(changes.toArray()),
        selfCheck: dedupeStrings(checks.toArray()),
        relatedIssues: dedupeStrings(related.toArray())
    )
}

func sectionFirstValue(body: String, headings: Array<String>): String {
    var active = false
    for (lineRaw in body.split("\n")) {
        let line = lineRaw.trimAscii()
        let lower = line.toAsciiLower()
        if (line.startsWith("#")) {
            active = false
            for (heading in headings) {
                if (lower.contains(heading.toAsciiLower())) { active = true }
            }
            continue
        }
        if (active && !line.isEmpty() && !line.startsWith("- [")) { return line }
    }
    ""
}

func checkedValuesAfterHeading(body: String, headings: Array<String>): Array<String> {
    var active = false
    let out = ArrayList<String>()
    for (lineRaw in body.split("\n")) {
        let line = lineRaw.trimAscii()
        let lower = line.toAsciiLower()
        if (line.startsWith("#")) {
            active = false
            for (heading in headings) {
                if (lower.contains(heading.toAsciiLower())) { active = true }
            }
            continue
        }
        if (active && (line.contains("[x]") || line.contains("[X]"))) {
            let value = checkboxValue(line)
            if (!value.isEmpty()) { out.add(value) }
        }
    }
    out.toArray()
}

func checkboxValue(line: String): String {
    if (!line.contains("]")) { return "" }
    line.split("]")[1].trimAscii()
}

func sanitizeTemplateText(raw: String): String {
    let out = ArrayList<String>()
    for (line in raw.split("\n")) {
        if (containsSecret(line) || containsLocalPath(line)) {
            out.add("[REDACTED]")
        } else {
            out.add(redactSecrets(redactUrl(line)))
        }
    }
    compactSummary(joinStrings(out.toArray(), "\n"), limit: 4096)
}
