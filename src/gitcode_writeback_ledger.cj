package gitcodemonitor

import std.collection.*
import std.fs.{Directory, File, Path, exists}
import std.time.DateTime
import stdx.encoding.json.{JsonArray, JsonInt, JsonObject, JsonString, JsonValue}

public const WRITEBACK_LEDGER_TTL_MS: Int64 = 24 * 60 * 60 * 1000

public class WritebackLedgerResult {
    public let ok: Bool
    public let status: String

    public init(ok: Bool, status: String) {
        this.ok = ok
        this.status = status.trimAscii()
    }
}

public class WritebackLedgerMatchResult {
    public let matched: Bool
    public let status: String
    public let sourceEventId: String
    public let matchType: String

    public init(matched: Bool, status!: String = "not_matched", sourceEventId!: String = "", matchType!: String = "") {
        this.matched = matched
        this.status = status.trimAscii()
        this.sourceEventId = sourceEventId.trimAscii()
        this.matchType = matchType.trimAscii()
    }
}

class WritebackLedgerEntry {
    public let repo: String
    public let kind: String
    public let number: String
    public let replyUrl: String
    public let replyAnchor: String
    public let bodyHash: String
    public let sourceEventId: String
    public let createdAtMs: Int64

    public init(repo: String, kind: String, number: String, replyUrl: String, replyAnchor: String, bodyHash: String, sourceEventId: String, createdAtMs: Int64) {
        this.repo = normalizeLedgerRepo(repo)
        this.kind = kind.trimAscii().toAsciiLower()
        this.number = number.trimAscii()
        this.replyUrl = replyUrl.trimAscii()
        this.replyAnchor = replyAnchor.trimAscii()
        this.bodyHash = bodyHash.trimAscii()
        this.sourceEventId = sourceEventId.trimAscii()
        this.createdAtMs = createdAtMs
    }
}

public func writebackLedgerPathForConfig(config: MonitorConfig): String {
    let statePath = config.statePath.trimAscii()
    if (statePath.isEmpty()) { return ".gitcodemonitor/writeback-ledger.json" }
    "${statePath}.writeback-ledger.json"
}

public func recordWriteback(
    ledgerPath: String,
    repo: String,
    kind: String,
    number: String,
    replyUrl: String,
    body: String,
    sourceEventId: String,
    nowMs!: Int64 = DateTime.now().toUnixTimeStamp().toMilliseconds()
): WritebackLedgerResult {
    try {
        let entries = ArrayList<WritebackLedgerEntry>()
        for (entry in readWritebackLedgerEntries(ledgerPath)) {
            if (nowMs - entry.createdAtMs <= WRITEBACK_LEDGER_TTL_MS) { entries.add(entry) }
        }
        let safeReplyUrl = sanitizeWritebackReplyUrlForStorage(replyUrl)
        entries.add(WritebackLedgerEntry(repo, kind, number, safeReplyUrl, ledgerAnchorFromUrl(safeReplyUrl), hashRawPayload(body), sourceEventId, nowMs))
        writeWritebackLedgerEntries(ledgerPath, entries.toArray())
        WritebackLedgerResult(true, "recorded")
    } catch (_: Exception) {
        WritebackLedgerResult(false, "ledger_write_failed")
    }
}

public func matchWebhookComment(
    ledgerPath: String,
    repo: String,
    kind: String,
    number: String,
    objectUrl: String,
    noteAnchor: String,
    body: String,
    nowMs!: Int64 = DateTime.now().toUnixTimeStamp().toMilliseconds()
): WritebackLedgerMatchResult {
    let normalizedRepo = normalizeLedgerRepo(repo)
    let normalizedKind = kind.trimAscii().toAsciiLower()
    let normalizedNumber = number.trimAscii()
    let url = objectUrl.trimAscii()
    let anchor = firstNonEmpty([noteAnchor.trimAscii(), ledgerAnchorFromUrl(url)])
    let bodyHash = hashRawPayload(body)
    for (entry in readWritebackLedgerEntries(ledgerPath)) {
        if (entry.repo != normalizedRepo || entry.kind != normalizedKind || entry.number != normalizedNumber) { continue }
        if (nowMs - entry.createdAtMs > WRITEBACK_LEDGER_TTL_MS) { continue }
        if (!url.isEmpty() && !entry.replyUrl.isEmpty() && url == entry.replyUrl) {
            return WritebackLedgerMatchResult(true, status: "matched", sourceEventId: entry.sourceEventId, matchType: "url")
        }
    }
    for (entry in readWritebackLedgerEntries(ledgerPath)) {
        if (entry.repo != normalizedRepo || entry.kind != normalizedKind || entry.number != normalizedNumber) { continue }
        if (nowMs - entry.createdAtMs > WRITEBACK_LEDGER_TTL_MS) { continue }
        if (!anchor.isEmpty() && !entry.replyAnchor.isEmpty() && anchor == entry.replyAnchor) {
            return WritebackLedgerMatchResult(true, status: "matched", sourceEventId: entry.sourceEventId, matchType: "anchor")
        }
    }
    for (entry in readWritebackLedgerEntries(ledgerPath)) {
        if (entry.repo != normalizedRepo || entry.kind != normalizedKind || entry.number != normalizedNumber) { continue }
        if (nowMs - entry.createdAtMs <= WRITEBACK_LEDGER_TTL_MS && !bodyHash.isEmpty() && bodyHash == entry.bodyHash) {
            return WritebackLedgerMatchResult(false, status: "body_hash_untrusted", sourceEventId: entry.sourceEventId, matchType: "body_hash")
        }
    }
    WritebackLedgerMatchResult(false)
}

public func expireOldEntries(ledgerPath: String, nowMs!: Int64 = DateTime.now().toUnixTimeStamp().toMilliseconds()): WritebackLedgerResult {
    try {
        let kept = ArrayList<WritebackLedgerEntry>()
        for (entry in readWritebackLedgerEntries(ledgerPath)) {
            if (nowMs - entry.createdAtMs <= WRITEBACK_LEDGER_TTL_MS) { kept.add(entry) }
        }
        writeWritebackLedgerEntries(ledgerPath, kept.toArray())
        WritebackLedgerResult(true, "expired")
    } catch (_: Exception) {
        WritebackLedgerResult(false, "ledger_expire_failed")
    }
}

func readWritebackLedgerEntries(ledgerPath: String): Array<WritebackLedgerEntry> {
    let out = ArrayList<WritebackLedgerEntry>()
    if (!exists(Path(ledgerPath))) { return out.toArray() }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(Path(ledgerPath)))).asObject()
        match (root.get("entries")) {
            case Some(value) =>
                for (item in value.asArray().getItems()) {
                    try {
                        let obj = item.asObject()
                        out.add(WritebackLedgerEntry(
                            readJsonString(obj, "repo"),
                            readJsonString(obj, "kind"),
                            readJsonString(obj, "number"),
                            readJsonString(obj, "replyUrl"),
                            readJsonString(obj, "replyAnchor"),
                            readJsonString(obj, "bodyHash"),
                            readJsonString(obj, "sourceEventId"),
                            readJsonInt(obj, "createdAtMs")
                        ))
                    } catch (_inner: Exception) { () }
                }
            case None => ()
        }
    } catch (_: Exception) { () }
    out.toArray()
}

func writeWritebackLedgerEntries(ledgerPath: String, entries: Array<WritebackLedgerEntry>): Unit {
    let path = Path(ledgerPath)
    let parent = path.parent
    if (!exists(parent)) { Directory.create(parent, recursive: true) }
    let root = JsonObject()
    root.put("schemaVersion", JsonInt(1))
    let arr = JsonArray([])
    for (entry in entries) {
        let obj = JsonObject()
        obj.put("repo", JsonString(entry.repo))
        obj.put("kind", JsonString(entry.kind))
        obj.put("number", JsonString(entry.number))
        obj.put("replyUrl", JsonString(entry.replyUrl))
        obj.put("replyAnchor", JsonString(entry.replyAnchor))
        obj.put("bodyHash", JsonString(entry.bodyHash))
        obj.put("sourceEventId", JsonString(entry.sourceEventId))
        obj.put("createdAtMs", JsonInt(entry.createdAtMs))
        arr.add(obj)
    }
    root.put("entries", arr)
    File.writeTo(path, root.toJsonString().toArray())
}

func normalizeLedgerRepo(repo: String): String {
    repo.trimAscii().toAsciiLower()
}

func ledgerAnchorFromUrl(url: String): String {
    let value = url.trimAscii()
    if (!value.contains("#")) { return "" }
    let parts = value.split("#", 2)
    if (parts.size < 2) { return "" }
    let anchor = parts[1].split("?", 2)[0].split("&", 2)[0]
    anchor.trimAscii()
}

public func sanitizeWritebackReplyUrlForStorage(raw: String): String {
    let value = raw.trimAscii()
    if (value.isEmpty()) { return "" }
    if (containsSecret(value) || containsLocalPath(value)) { return "" }
    if (value.startsWith("/") || value.startsWith("file:")) { return "" }
    let noQuery = value.split("?", 2)[0]
    noQuery.trimAscii()
}
