package gitcodemonitor

import std.collection.*

public class MaintainerMentionSentenceResult {
    public let sentence: String
    public let mentions: Array<String>
    public let templateId: String
    public let diagnostics: Array<String>

    public init(sentence: String, mentions!: Array<String> = [], templateId!: String = "", diagnostics!: Array<String> = []) {
        this.sentence = sentence
        this.mentions = mentions
        this.templateId = templateId
        this.diagnostics = diagnostics
    }
}

public class MaintainerMentionAppendResult {
    public let body: String
    public let appended: Bool
    public let diagnostics: Array<String>

    public init(body: String, appended: Bool, diagnostics!: Array<String> = []) {
        this.body = body
        this.appended = appended
        this.diagnostics = diagnostics
    }
}

public class MaintainerNotificationPlan {
    public let mentionPlan: Array<String>
    public let emailPlan: Array<String>
    public let emailNotificationStatus: String
    public let diagnostics: Array<String>

    public init(mentionPlan: Array<String>, emailPlan!: Array<String> = [], emailNotificationStatus!: String = "email_disabled", diagnostics!: Array<String> = []) {
        this.mentionPlan = mentionPlan
        this.emailPlan = emailPlan
        this.emailNotificationStatus = emailNotificationStatus
        this.diagnostics = diagnostics
    }
}

public func sanitizeMentionList(mentions: Array<String>): Array<String> {
    let out = ArrayList<String>()
    let seen = HashSet<String>()
    for (raw in mentions) {
        let mention = normalizeMaintainerMention(raw)
        if (mention.isEmpty()) { continue }
        let key = mention.toAsciiLower()
        if (seen.contains(key)) { continue }
        seen.add(key)
        out.add(mention)
    }
    out.toArray()
}

public func buildMaintainerMentionSentence(
    eventId: String,
    eventKind: String,
    teamLeaderMentions!: Array<String> = [],
    codeownerMentions!: Array<String> = []
): MaintainerMentionSentenceResult {
    let combined = ArrayList<String>()
    for (m in teamLeaderMentions) { combined.add(m) }
    for (m in codeownerMentions) { combined.add(m) }
    let mentions = sanitizeMentionList(combined.toArray())
    let diagnostics = ArrayList<String>()
    if (mentions.size == 0) {
        diagnostics.add("maintainer_mention_unavailable")
        return MaintainerMentionSentenceResult("", diagnostics: diagnostics.toArray())
    }
    let joined = joinStrings(mentions, "，")
    let templates = maintainerMentionTemplatePool(eventKind)
    let index = stableMaintainerTemplateIndex("${eventId}:${joined}:v1", templates.size)
    let template = templates[index]
    MaintainerMentionSentenceResult(
        template.sentence.replace("{mentions}", joined),
        mentions: mentions,
        templateId: template.templateId,
        diagnostics: diagnostics.toArray()
    )
}

public func appendMaintainerMentionSentence(draft: String, sentence: String): MaintainerMentionAppendResult {
    let diagnostics = ArrayList<String>()
    let normalizedSentence = sentence.trimAscii()
    if (normalizedSentence.isEmpty()) {
        diagnostics.add("maintainer_mention_skipped")
        return MaintainerMentionAppendResult(trimDraftRight(draft), false, diagnostics: diagnostics.toArray())
    }
    let body = trimDraftRight(draft)
    if (body.contains(normalizedSentence)) {
        diagnostics.add("maintainer_mention_already_present")
        return MaintainerMentionAppendResult(body, false, diagnostics: diagnostics.toArray())
    }
    MaintainerMentionAppendResult("${body}\n${normalizedSentence}", true, diagnostics: diagnostics.toArray())
}

public func buildMaintainerNotificationPlan(
    mentions: Array<String>,
    emails!: Array<String> = [],
    emailNotificationEnabled!: Bool = false
): MaintainerNotificationPlan {
    let mentionPlan = sanitizeMentionList(mentions)
    let diagnostics = ArrayList<String>()
    if (!emailNotificationEnabled) {
        return MaintainerNotificationPlan(mentionPlan, diagnostics: diagnostics.toArray())
    }
    let emailPlan = ArrayList<String>()
    let seen = HashSet<String>()
    for (raw in emails) {
        let email = raw.trimAscii()
        if (!isValidMaintainerEmail(email)) {
            if (!email.isEmpty()) { diagnostics.add("invalid_email") }
            continue
        }
        let key = email.toAsciiLower()
        if (seen.contains(key)) { continue }
        seen.add(key)
        emailPlan.add(email)
    }
    let status = if (emailPlan.size > 0) { "ready" } else { "email_unavailable" }
    MaintainerNotificationPlan(mentionPlan, emailPlan: emailPlan.toArray(), emailNotificationStatus: status, diagnostics: diagnostics.toArray())
}

class MaintainerMentionTemplate {
    public let templateId: String
    public let sentence: String
    public init(templateId: String, sentence: String) {
        this.templateId = templateId
        this.sentence = sentence
    }
}

func maintainerMentionTemplatePool(eventKind: String): Array<MaintainerMentionTemplate> {
    let kind = eventKind.trimAscii().toAsciiLower()
    let out = ArrayList<MaintainerMentionTemplate>()
    out.add(MaintainerMentionTemplate("general-collaboration", "麻烦 {mentions} 一起看看。"))
    out.add(MaintainerMentionTemplate("respect-confirmation", "{mentions} 看看，以你们确认的结果为准。"))
    out.add(MaintainerMentionTemplate("background", "这块可能还需要 {mentions} 帮忙补充一下背景。"))
    if (kind == "issue" || kind == "bug") {
        out.add(MaintainerMentionTemplate("bug-confirmation", "麻烦 {mentions} 看看这个现象是否和你们那边的判断一致。"))
    } else if (kind == "feature" || kind == "feature-request") {
        out.add(MaintainerMentionTemplate("feature-direction", "也想听听 {mentions} 对这个方向的看法。"))
    } else if (kind == "pr" || kind == "merge_request") {
        out.add(MaintainerMentionTemplate("pr-code", "{mentions} 帮忙看看这块代码，我这边先给一个初步判断。"))
    } else if (kind == "comment" || kind == "note") {
        out.add(MaintainerMentionTemplate("comment-followup", "这个补充也麻烦 {mentions} 一起看看。"))
    } else {
        out.add(MaintainerMentionTemplate("risk-confirmation", "这个风险点也请 {mentions} 一起确认下。"))
    }
    out.toArray()
}

func stableMaintainerTemplateIndex(seed: String, size: Int64): Int64 {
    if (size <= 1) { return 0 }
    var total: Int64 = 0
    for (r in seed.runes()) {
        total = (total + maintainerRuneWeight(r)) % size
    }
    total
}

func maintainerRuneWeight(r: Rune): Int64 {
    if (r >= r'0' && r <= r'9') { return 1 }
    if (r >= r'a' && r <= r'z') { return 2 }
    if (r >= r'A' && r <= r'Z') { return 3 }
    4
}

func normalizeMaintainerMention(raw: String): String {
    var mention = raw.trimAscii()
    if (mention.isEmpty()) { return "" }
    if (!mention.startsWith("@")) {
        mention = "@${mention}"
    }
    if (!isValidMaintainerMention(mention)) { return "" }
    mention
}

func isValidMaintainerMention(mention: String): Bool {
    let runes = mention.toRuneArray()
    if (runes.size < 2 || runes.size > 65 || runes[0] != r'@') { return false }
    for (i in 1..runes.size) {
        let r = runes[i]
        if (!((r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') || (r >= r'0' && r <= r'9') || r == r'_' || r == r'-' || r == r'.')) {
            return false
        }
    }
    true
}

func isValidMaintainerEmail(email: String): Bool {
    let trimmed = email.trimAscii()
    if (trimmed.isEmpty() || trimmed.contains(" ") || trimmed.contains("\n") || !trimmed.contains("@")) { return false }
    let parts = trimmed.split("@", 2)
    if (parts.size != 2 || parts[0].isEmpty() || parts[1].isEmpty() || !parts[1].contains(".")) { return false }
    true
}

func trimDraftRight(text: String): String {
    let runes = text.toRuneArray()
    var end = runes.size
    while (end > 0) {
        let r = runes[end - 1]
        if (r == r' ' || r == r'\n' || r == r'\r' || r == r'\t') {
            end--
        } else {
            break
        }
    }
    if (end <= 0) { return "" }
    String(runes[0..end])
}
