package gitcodemonitor

import std.collection.*

public class GitCodeCodeownerRule {
    public let pattern: String
    public let owners: Array<GitCodeMaintainerPerson>

    public init(pattern: String, owners: Array<GitCodeMaintainerPerson>) {
        this.pattern = pattern.trimAscii()
        this.owners = owners
    }
}

public class GitCodeCodeownersParseResult {
    public let rules: Array<GitCodeCodeownerRule>
    public let status: String
    public let diagnostics: Array<GitCodeIdentityDiagnostic>

    public init(rules!: Array<GitCodeCodeownerRule> = [], status!: String = "ok", diagnostics!: Array<GitCodeIdentityDiagnostic> = []) {
        this.rules = rules
        this.status = status
        this.diagnostics = diagnostics
    }
}

public class GitCodeCodeownerResolution {
    public let owners: Array<GitCodeMaintainerPerson>
    public let codeownerStatus: String
    public let changedFiles: Array<String>
    public let changedFilesTruncated: Bool
    public let diagnostics: Array<GitCodeIdentityDiagnostic>

    public init(owners!: Array<GitCodeMaintainerPerson> = [], codeownerStatus!: String = "not_found", changedFiles!: Array<String> = [], changedFilesTruncated!: Bool = false, diagnostics!: Array<GitCodeIdentityDiagnostic> = []) {
        this.owners = owners
        this.codeownerStatus = codeownerStatus
        this.changedFiles = changedFiles
        this.changedFilesTruncated = changedFilesTruncated
        this.diagnostics = diagnostics
    }
}

public func fetchCodeowners(client: GitCodeApiClient, repo: GitCodeRepo, ref: String): GitCodeTextFetchResult {
    let req = client.contentsRequest(repo, ".gitcode/CODEOWNERS", ref)
    GitCodeTextFetchResult(false, "missing", diagnostic: hashRawPayload(req.url))
}

public func parseCodeowners(text: String): GitCodeCodeownersParseResult {
    let rules = ArrayList<GitCodeCodeownerRule>()
    let diagnostics = ArrayList<GitCodeIdentityDiagnostic>()
    for (lineRaw in text.split("\n")) {
        let line = lineRaw.trimAscii()
        if (line.isEmpty() || line.startsWith("#")) { continue }
        let parts = splitWhitespace(line)
        if (parts.size < 2) { continue }
        let owners = ArrayList<GitCodeMaintainerPerson>()
        for (owner in parts[1..parts.size]) {
            if (owner.startsWith("@") && owner.size > 1) {
                owners.add(GitCodeMaintainerPerson(owner))
            } else {
                diagnostics.add(GitCodeIdentityDiagnostic("invalid_owner", message: hashRawPayload(owner)))
            }
        }
        if (owners.size > 0) { rules.add(GitCodeCodeownerRule(parts[0], owners.toArray())) }
    }
    GitCodeCodeownersParseResult(rules: rules.toArray(), status: if (rules.size == 0) { "empty" } else { "ok" }, diagnostics: diagnostics.toArray())
}

public func resolveCodeownersForPaths(rules: Array<GitCodeCodeownerRule>, paths: Array<String>): GitCodeCodeownerResolution {
    if (rules.size == 0) {
        return GitCodeCodeownerResolution(codeownerStatus: "empty", changedFiles: paths)
    }
    let sampled = if (paths.size > 100) { paths[0..100] } else { paths }
    let ownerMap = HashMap<String, GitCodeMaintainerPerson>()
    for (pathRaw in sampled) {
        let path = normalizeCodeownerPath(pathRaw)
        var matched = Array<GitCodeMaintainerPerson>()
        for (rule in rules) {
            if (codeownerPatternMatches(rule.pattern, path)) {
                matched = rule.owners
            }
        }
        for (owner in matched) { ownerMap[owner.mention] = owner }
    }
    let owners = ArrayList<GitCodeMaintainerPerson>()
    for ((_, owner) in ownerMap) { owners.add(owner) }
    GitCodeCodeownerResolution(
        owners: owners.toArray(),
        codeownerStatus: if (owners.size > 0) { "resolved" } else { "not_found" },
        changedFiles: sampled,
        changedFilesTruncated: paths.size > 100
    )
}

func codeownerPatternMatches(patternRaw: String, path: String): Bool {
    let pattern = normalizeCodeownerPath(patternRaw)
    if (pattern == "*") { return true }
    if (pattern.endsWith("/")) { return path.startsWith(pattern) }
    if (pattern.contains("*")) {
        let parts = pattern.split("*")
        let prefix = if (parts.size > 0) { parts[0] } else { "" }
        let suffix = if (parts.size > 1) { parts[1] } else { "" }
        return path.startsWith(prefix) && path.endsWith(suffix)
    }
    path == pattern
}

func normalizeCodeownerPath(path: String): String {
    var value = path.trimAscii()
    while (value.startsWith("/")) { value = value[1..value.size] }
    value
}

func splitWhitespace(line: String): Array<String> {
    let out = ArrayList<String>()
    for (part in line.replace("\t", " ").split(" ")) {
        let value = part.trimAscii()
        if (!value.isEmpty()) { out.add(value) }
    }
    out.toArray()
}
