package gitcodemonitor

import std.collection.*
import stdx.encoding.json.JsonValue

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

public func fetchRepoListMd(client: GitCodeApiClient, sender!: HttpSender = NativeHttpSender()): GitCodeTextFetchResult {
    let req = client.contentsRequest(GitCodeRepo("Cangjie", "community"), "team/repo_list.md", "main")
    let res = sender.send(req)
    if (res.statusCode == 404) { return GitCodeTextFetchResult(false, "not_found", diagnostic: hashRawPayload(req.url)) }
    if (res.statusCode < 200 || res.statusCode >= 300) {
        return GitCodeTextFetchResult(false, "fetch_failed", diagnostic: hashRawPayload(req.url))
    }
    decodeGitCodeContentsText(res.body)
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

func decodeGitCodeContentsText(body: String): GitCodeTextFetchResult {
    if (body.trimAscii().isEmpty()) { return GitCodeTextFetchResult(false, "invalid_content") }
    let parsed = try {
        JsonValue.fromStr(body).asObject()
    } catch (_: Exception) {
        return GitCodeTextFetchResult(true, "ok", text: body)
    }
    let content = firstJsonString(parsed, ["content", "data", "text", "body"])
    if (content.isEmpty()) { return GitCodeTextFetchResult(false, "invalid_content", diagnostic: hashRawPayload(body)) }
    let encoding = firstJsonString(parsed, ["encoding"]).toAsciiLower()
    if (encoding == "base64" || looksLikeBase64Content(content)) {
        let decoded = decodeBase64Ascii(content)
        if (decoded.isEmpty()) { return GitCodeTextFetchResult(false, "invalid_content", diagnostic: hashRawPayload(content)) }
        return GitCodeTextFetchResult(true, "ok", text: decoded)
    }
    GitCodeTextFetchResult(true, "ok", text: content)
}

func looksLikeBase64Content(raw: String): Bool {
    let value = raw.replace("\n", "").replace("\r", "").trimAscii()
    if (value.size < 16 || value.size % 4 != 0) { return false }
    for (r in value.runes()) {
        if (!((r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') || (r >= r'0' && r <= r'9') || r == r'+' || r == r'/' || r == r'=')) {
            return false
        }
    }
    true
}

func decodeBase64Ascii(raw: String): String {
    let clean = raw.replace("\n", "").replace("\r", "").replace(" ", "").trimAscii()
    let out = StringBuilder()
    var buffer: Int64 = 0
    var bits: Int64 = 0
    for (r in clean.runes()) {
        if (r == r'=') { break }
        let value = base64Value(r)
        if (value < 0) { return "" }
        buffer = buffer * 64 + value
        bits += 6
        while (bits >= 8) {
            bits -= 8
            let byte = (buffer / pow2(bits)) % 256
            out.append(String([asciiRune(byte)]))
        }
        if (bits > 0) { buffer = buffer % pow2(bits) }
    }
    out.toString()
}

func base64Value(r: Rune): Int64 {
    let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    var index: Int64 = 0
    for (candidate in chars.runes()) {
        if (candidate == r) { return index }
        index++
    }
    -1
}

func pow2(bits: Int64): Int64 {
    var value: Int64 = 1
    for (_ in 0..bits) { value *= 2 }
    value
}

func asciiRune(code: Int64): Rune {
    match (code) {
        case 9 => r'\t'
        case 10 => r'\n'
        case 13 => r'\r'
        case 32 => r' '
        case 33 => r'!'
        case 34 => r'"'
        case 35 => r'#'
        case 36 => r'$'
        case 37 => r'%'
        case 38 => r'&'
        case 39 => r'\''
        case 40 => r'('
        case 41 => r')'
        case 42 => r'*'
        case 43 => r'+'
        case 44 => r','
        case 45 => r'-'
        case 46 => r'.'
        case 47 => r'/'
        case 48 => r'0'
        case 49 => r'1'
        case 50 => r'2'
        case 51 => r'3'
        case 52 => r'4'
        case 53 => r'5'
        case 54 => r'6'
        case 55 => r'7'
        case 56 => r'8'
        case 57 => r'9'
        case 58 => r':'
        case 59 => r';'
        case 60 => r'<'
        case 61 => r'='
        case 62 => r'>'
        case 63 => r'?'
        case 64 => r'@'
        case 65 => r'A'
        case 66 => r'B'
        case 67 => r'C'
        case 68 => r'D'
        case 69 => r'E'
        case 70 => r'F'
        case 71 => r'G'
        case 72 => r'H'
        case 73 => r'I'
        case 74 => r'J'
        case 75 => r'K'
        case 76 => r'L'
        case 77 => r'M'
        case 78 => r'N'
        case 79 => r'O'
        case 80 => r'P'
        case 81 => r'Q'
        case 82 => r'R'
        case 83 => r'S'
        case 84 => r'T'
        case 85 => r'U'
        case 86 => r'V'
        case 87 => r'W'
        case 88 => r'X'
        case 89 => r'Y'
        case 90 => r'Z'
        case 91 => r'['
        case 92 => r'\\'
        case 93 => r']'
        case 94 => r'^'
        case 95 => r'_'
        case 96 => r'`'
        case 97 => r'a'
        case 98 => r'b'
        case 99 => r'c'
        case 100 => r'd'
        case 101 => r'e'
        case 102 => r'f'
        case 103 => r'g'
        case 104 => r'h'
        case 105 => r'i'
        case 106 => r'j'
        case 107 => r'k'
        case 108 => r'l'
        case 109 => r'm'
        case 110 => r'n'
        case 111 => r'o'
        case 112 => r'p'
        case 113 => r'q'
        case 114 => r'r'
        case 115 => r's'
        case 116 => r't'
        case 117 => r'u'
        case 118 => r'v'
        case 119 => r'w'
        case 120 => r'x'
        case 121 => r'y'
        case 122 => r'z'
        case 123 => r'{'
        case 124 => r'|'
        case 125 => r'}'
        case 126 => r'~'
        case _ => r'?'
    }
}
