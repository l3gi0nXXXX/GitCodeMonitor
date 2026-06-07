package gitcodemonitor

import std.collection.*

public class GitCodeTextFetchResult {
    public let ok: Bool
    public let status: String
    public let text: String
    public let diagnostic: String

    public init(ok: Bool, status: String, text!: String = "", diagnostic!: String = "") {
        this.ok = ok
        this.status = status
        this.text = text
        this.diagnostic = diagnostic
    }
}

public class GitCodeRepoMaintainerRow {
    public let team: String
    public let org: String
    public let repoName: String
    public let leaders: Array<GitCodeMaintainerPerson>

    public init(team: String, org: String, repoName: String, leaders!: Array<GitCodeMaintainerPerson> = []) {
        this.team = team.trimAscii()
        this.org = org.trimAscii()
        this.repoName = repoName.trimAscii()
        this.leaders = leaders
    }
}

public class GitCodeMaintainerPerson {
    public let mention: String
    public let login: String
    public let url: String

    public init(mention: String, url!: String = "") {
        this.mention = mention.trimAscii()
        this.login = this.mention.trimAscii().trimStart({c: Rune => c == r'@'})
        this.url = url.trimAscii()
    }
}

public class GitCodeRepoListParseResult {
    public let rows: Array<GitCodeRepoMaintainerRow>
    public let status: String
    public let diagnostics: Array<GitCodeIdentityDiagnostic>

    public init(rows!: Array<GitCodeRepoMaintainerRow> = [], status!: String = "ok", diagnostics!: Array<GitCodeIdentityDiagnostic> = []) {
        this.rows = rows
        this.status = status
        this.diagnostics = diagnostics
    }
}

public class GitCodeTeamLeaderResolution {
    public let repo: String
    public let team: String
    public let teamLeaders: Array<GitCodeMaintainerPerson>
    public let teamLeaderStatus: String
    public let diagnostics: Array<GitCodeIdentityDiagnostic>

    public init(repo: String, team!: String = "", teamLeaders!: Array<GitCodeMaintainerPerson> = [], teamLeaderStatus!: String = "not_found", diagnostics!: Array<GitCodeIdentityDiagnostic> = []) {
        this.repo = repo.trimAscii()
        this.team = team.trimAscii()
        this.teamLeaders = teamLeaders
        this.teamLeaderStatus = teamLeaderStatus
        this.diagnostics = diagnostics
    }
}

public func fetchRepoListMd(client: GitCodeApiClient): GitCodeTextFetchResult {
    let req = client.contentsRequest(GitCodeRepo("Cangjie", "community"), "team/repo_list.md", "main")
    GitCodeTextFetchResult(false, "fetch_failed", diagnostic: hashRawPayload(req.url))
}

public func parseRepoListMd(text: String): GitCodeRepoListParseResult {
    if (text.size > 200000) {
        return GitCodeRepoListParseResult(status: "truncated_catalog", diagnostics: [GitCodeIdentityDiagnostic("truncated_catalog")])
    }
    let rows = ArrayList<GitCodeRepoMaintainerRow>()
    for (rowRaw in text.split("<tr")) {
        if (!rowRaw.contains("<td")) { continue }
        let cells = htmlCells(rowRaw)
        if (cells.size < 4) { continue }
        let leaders = parseLeaderCell(cells[1])
        rows.add(GitCodeRepoMaintainerRow(
            stripHtml(cells[0]),
            stripHtml(cells[2]),
            stripHtml(cells[3]),
            leaders: if (leaders.size > 0) { leaders } else { parseLeaderCell(rowRaw) }
        ))
    }
    GitCodeRepoListParseResult(rows: rows.toArray(), status: "ok")
}

public func resolveTeamLeaders(repo: String, rows!: Array<GitCodeRepoMaintainerRow> = []): GitCodeTeamLeaderResolution {
    let parts = repo.split("/")
    if (parts.size < 2) { return GitCodeTeamLeaderResolution(repo, diagnostics: [GitCodeIdentityDiagnostic("repo_missing")]) }
    let org = parts[0].toAsciiLower()
    let name = parts[1].toAsciiLower()
    for (row in rows) {
        if (row.org.toAsciiLower() == org && row.repoName.toAsciiLower() == name && row.leaders.size > 0) {
            return GitCodeTeamLeaderResolution(repo, team: row.team, teamLeaders: row.leaders, teamLeaderStatus: "resolved")
        }
    }
    GitCodeTeamLeaderResolution(repo, teamLeaderStatus: "not_found", diagnostics: [GitCodeIdentityDiagnostic("not_found")])
}

func htmlCells(rowRaw: String): Array<String> {
    let out = ArrayList<String>()
    for (part in rowRaw.split("<td")) {
        if (!part.contains("</td>")) { continue }
        out.add(between(part, ">", "</td>"))
    }
    out.toArray()
}

func parseLeaderCell(cell: String): Array<GitCodeMaintainerPerson> {
    let out = ArrayList<GitCodeMaintainerPerson>()
    for (part in cell.split("<a")) {
        if (part.contains("</a>")) {
            let url = between(part, "href=\"", "\"")
            let text = between(part, ">", "</a>").trimAscii()
            for (token in text.split(" ")) {
                let mention = token.trimAscii()
                if (mention.startsWith("@")) { out.add(GitCodeMaintainerPerson(mention, url: url)) }
            }
        }
    }
    if (out.size == 0) {
        for (token in stripHtml(cell).replace("/", " ").split(" ")) {
            let mention = token.trimAscii()
            if (mention.startsWith("@")) { out.add(GitCodeMaintainerPerson(mention)) }
        }
    }
    if (out.size == 0 && cell.contains("@")) {
        for (part in cell.split("@")[1..cell.split("@").size]) {
            let login = leadingLogin(part)
            if (!login.isEmpty()) { out.add(GitCodeMaintainerPerson("@${login}")) }
        }
    }
    out.toArray()
}

func leadingLogin(raw: String): String {
    let out = StringBuilder()
    for (r in raw.runes()) {
        if ((r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') || (r >= r'0' && r <= r'9') || r == r'_' || r == r'-') {
            out.append(String([r]))
        } else {
            break
        }
    }
    out.toString()
}

func stripHtml(raw: String): String {
    var inTag = false
    let out = StringBuilder()
    for (r in raw.runes()) {
        if (r == r'<') {
            inTag = true
        } else if (r == r'>') {
            inTag = false
        } else if (!inTag) {
            out.append(String([r]))
        }
    }
    out.toString().replace("&nbsp;", " ").trimAscii()
}

func between(raw: String, left: String, right: String): String {
    if (!raw.contains(left)) { return "" }
    let leftParts = raw.split(left)
    let tail = joinStrings(leftParts[1..leftParts.size], left)
    if (!tail.contains(right)) { return "" }
    tail.split(right)[0]
}
