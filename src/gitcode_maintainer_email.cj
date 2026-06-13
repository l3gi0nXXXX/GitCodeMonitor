package gitcodemonitor

import std.collection.*
import std.env.getVariable

public class MaintainerSmtpConfig {
    public let host: String
    public let port: Int64
    public let security: String
    public let username: String
    public let passwordEnv: String
    public let connectTimeoutMs: Int64
    public let sendTimeoutMs: Int64

    public init(host: String, port: Int64, security: String, username: String, passwordEnv: String, connectTimeoutMs!: Int64 = 10000, sendTimeoutMs!: Int64 = 30000) {
        this.host = host.trimAscii()
        this.port = port
        this.security = security.trimAscii().toAsciiLower()
        this.username = username.trimAscii()
        this.passwordEnv = passwordEnv.trimAscii()
        this.connectTimeoutMs = connectTimeoutMs
        this.sendTimeoutMs = sendTimeoutMs
    }

    public init() {
        this.host = ""
        this.port = 0
        this.security = "ssl"
        this.username = ""
        this.passwordEnv = ""
        this.connectTimeoutMs = 10000
        this.sendTimeoutMs = 30000
    }
}

public class MaintainerNotificationEmailConfig {
    public let enabled: Bool
    public let transport: String
    public let smtp: MaintainerSmtpConfig
    public let from: String
    public let replyTo: String
    public let allowedDomains: Array<String>
    public let addressBook: HashMap<String, Array<String>>
    public let allowPlainSmtpForTest: Bool

    public init(
        enabled!: Bool = false,
        transport!: String = "smtp",
        smtp!: MaintainerSmtpConfig = MaintainerSmtpConfig(),
        from!: String = "",
        replyTo!: String = "",
        allowedDomains!: Array<String> = [],
        addressBook!: Array<(String, Array<String>)> = [],
        allowPlainSmtpForTest!: Bool = false
    ) {
        this.enabled = enabled
        this.transport = transport.trimAscii().toAsciiLower()
        this.smtp = smtp
        this.from = normalizeMaintainerEmail(from)
        this.replyTo = normalizeMaintainerEmail(replyTo)
        this.allowedDomains = normalizeEmailDomains(allowedDomains)
        let book = HashMap<String, Array<String>>()
        for ((rawKey, rawEmails) in addressBook) {
            let key = normalizeMaintainerMention(rawKey).toAsciiLower()
            if (key.isEmpty()) { continue }
            let emails = normalizeMaintainerEmails(rawEmails)
            if (emails.size > 0) { book[key] = emails }
        }
        this.addressBook = book
        this.allowPlainSmtpForTest = allowPlainSmtpForTest
    }
}

public class MaintainerEmailMessage {
    public let recipients: Array<String>
    public let subject: String
    public let body: String
    public let repo: String
    public let kind: String
    public let number: String
    public let url: String
    public let replyUrl: String

    public init(recipients: Array<String>, subject: String, body: String, repo!: String = "", kind!: String = "", number!: String = "", url!: String = "", replyUrl!: String = "") {
        this.recipients = normalizeMaintainerEmails(recipients)
        this.subject = sanitizeEmailText(subject, 160)
        this.body = sanitizeEmailBody(body, 4096)
        this.repo = repo.trimAscii()
        this.kind = kind.trimAscii()
        this.number = number.trimAscii()
        this.url = sanitizeEmailUrl(url)
        this.replyUrl = sanitizeEmailUrl(replyUrl)
    }
}

public class MaintainerEmailSendResult {
    public let status: String
    public let retryable: Bool
    public let sentCount: Int64
    public let failedCount: Int64
    public let diagnostic: String

    public init(status: String, retryable!: Bool = false, sentCount!: Int64 = 0, failedCount!: Int64 = 0, diagnostic!: String = "") {
        this.status = status.trimAscii()
        this.retryable = retryable
        this.sentCount = sentCount
        this.failedCount = failedCount
        this.diagnostic = diagnostic.trimAscii()
    }
}

public interface MaintainerEmailSender {
    func send(message: MaintainerEmailMessage): MaintainerEmailSendResult
}

public class NoopMaintainerEmailSender <: MaintainerEmailSender {
    public init() {}
    public func send(message: MaintainerEmailMessage): MaintainerEmailSendResult {
        let _ = message
        MaintainerEmailSendResult("email_disabled")
    }
}

public class FakeMaintainerEmailSender <: MaintainerEmailSender {
    public let messages = ArrayList<MaintainerEmailMessage>()
    public var nextResult: MaintainerEmailSendResult = MaintainerEmailSendResult("sent")
    public init() {}
    public func send(message: MaintainerEmailMessage): MaintainerEmailSendResult {
        messages.add(message)
        if (nextResult.status == "sent") {
            return MaintainerEmailSendResult("sent", sentCount: message.recipients.size)
        }
        let result = nextResult
        nextResult = MaintainerEmailSendResult("sent")
        result
    }
}

public interface MaintainerSmtpTransport {
    func send(config: MaintainerNotificationEmailConfig, message: MaintainerEmailMessage, mime: String, password: String): MaintainerEmailSendResult
}

public class FakeSmtpTransport <: MaintainerSmtpTransport {
    public let mimeMessages = ArrayList<String>()
    public let recipients = ArrayList<String>()
    public var nextResult: MaintainerEmailSendResult = MaintainerEmailSendResult("sent")
    public init() {}
    public func send(config: MaintainerNotificationEmailConfig, message: MaintainerEmailMessage, mime: String, password: String): MaintainerEmailSendResult {
        let _ = config
        let _ = password
        mimeMessages.add(mime)
        for (recipient in message.recipients) { recipients.add(recipient) }
        if (nextResult.status == "sent") {
            return MaintainerEmailSendResult("sent", sentCount: message.recipients.size)
        }
        let result = nextResult
        nextResult = MaintainerEmailSendResult("sent")
        result
    }
}

public class SmtpMaintainerEmailSender <: MaintainerEmailSender {
    public let config: MaintainerNotificationEmailConfig
    public let transport: MaintainerSmtpTransport
    public var connectCount: Int64 = 0

    public init(config: MaintainerNotificationEmailConfig, transport!: MaintainerSmtpTransport = FakeSmtpTransport()) {
        this.config = config
        this.transport = transport
    }

    public func send(message: MaintainerEmailMessage): MaintainerEmailSendResult {
        if (!config.enabled) { return MaintainerEmailSendResult("email_disabled") }
        let password = getVariable(config.smtp.passwordEnv) ?? ""
        if (password.trimAscii().isEmpty()) {
            return MaintainerEmailSendResult("send_failed", retryable: false, failedCount: message.recipients.size, diagnostic: "smtp_password_env_missing")
        }
        let mime = buildSmtpMimeMessage(message, config)
        if (!mime.ok) {
            return MaintainerEmailSendResult("send_failed", retryable: false, failedCount: message.recipients.size, diagnostic: mime.status)
        }
        connectCount++
        transport.send(config, message, mime.data, password)
    }
}

public class SmtpMimeBuildResult {
    public let ok: Bool
    public let status: String
    public let data: String
    public init(ok: Bool, status: String, data!: String = "") {
        this.ok = ok
        this.status = status
        this.data = data
    }
}

public func buildSmtpMimeMessage(message: MaintainerEmailMessage, config: MaintainerNotificationEmailConfig): SmtpMimeBuildResult {
    if (message.recipients.size == 0) { return SmtpMimeBuildResult(false, "recipients_missing") }
    let from = if (!config.from.isEmpty()) { config.from } else { normalizeMaintainerEmail(config.smtp.username) }
    if (!isValidMaintainerEmail(from)) { return SmtpMimeBuildResult(false, "from_invalid") }
    let replyTo = if (!config.replyTo.isEmpty()) { config.replyTo } else { from }
    let lines = ArrayList<String>()
    lines.add("From: ${from}")
    lines.add("Reply-To: ${replyTo}")
    lines.add("To: ${joinStrings(message.recipients, ", ")}")
    lines.add("Subject: ${message.subject}")
    lines.add("MIME-Version: 1.0")
    lines.add("Content-Type: text/plain; charset=utf-8")
    lines.add("Content-Transfer-Encoding: 8bit")
    lines.add("")
    for (line in message.body.split("\n")) {
        let safe = line.replace("\r", "")
        lines.add(if (safe.startsWith(".")) { ".${safe}" } else { safe })
    }
    SmtpMimeBuildResult(true, "ok", data: joinStrings(lines.toArray(), "\r\n") + "\r\n")
}

public func mapSmtpFailureToEmailResult(statusCode: Int64, accepted: Int64, failed: Int64): MaintainerEmailSendResult {
    if (accepted > 0) { return MaintainerEmailSendResult("sent", sentCount: accepted, failedCount: failed) }
    if (statusCode >= 400 && statusCode < 500) { return MaintainerEmailSendResult("send_failed", retryable: true, failedCount: failed) }
    MaintainerEmailSendResult("send_failed", retryable: false, failedCount: failed)
}

public func normalizeMaintainerEmail(raw: String): String {
    let email = raw.trimAscii().toAsciiLower()
    if (isValidMaintainerEmail(email)) { email } else { "" }
}

public func normalizeMaintainerEmails(rawEmails: Array<String>, allowedDomains!: Array<String> = []): Array<String> {
    let out = ArrayList<String>()
    let seen = HashSet<String>()
    for (raw in rawEmails) {
        let email = normalizeMaintainerEmail(raw)
        if (email.isEmpty()) { continue }
        if (allowedDomains.size > 0 && !emailDomainAllowed(email, allowedDomains)) { continue }
        if (seen.contains(email)) { continue }
        seen.add(email)
        out.add(email)
    }
    out.toArray()
}

public func emailDomainsForMentions(mentions: Array<String>, config: MaintainerNotificationEmailConfig): Array<String> {
    let out = ArrayList<String>()
    for (mentionRaw in mentions) {
        let mention = normalizeMaintainerMention(mentionRaw).toAsciiLower()
        if (mention.isEmpty()) { continue }
        match (config.addressBook.get(mention)) {
            case Some(emails) =>
                for (email in emails) { out.add(email) }
            case None => ()
        }
    }
    normalizeMaintainerEmails(out.toArray(), allowedDomains: config.allowedDomains)
}

func normalizeEmailDomains(domains: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (raw in domains) {
        var domain = raw.trimAscii().toAsciiLower()
        if (domain.startsWith("@")) { domain = domain[1..domain.size] }
        if (!domain.isEmpty() && domain.contains(".") && !out.contains(domain)) { out.add(domain) }
    }
    out.toArray()
}

func emailDomainAllowed(email: String, domains: Array<String>): Bool {
    let parts = email.split("@", 2)
    if (parts.size != 2) { return false }
    let domain = parts[1].toAsciiLower()
    for (allowed in domains) {
        if (domain == allowed) { return true }
    }
    false
}

func sanitizeEmailText(raw: String, maxRunes: Int64): String {
    let redacted = redactSecrets(raw).replace("/Users/", "[local-path]/")
    compactSummary(redacted, limit: maxRunes)
}

func sanitizeEmailBody(raw: String, maxRunes: Int64): String {
    let lines = ArrayList<String>()
    for (line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
        if (containsSecret(line) || containsLocalPath(line)) {
            lines.add("[REDACTED]")
        } else {
            lines.add(line)
        }
    }
    truncateRunes(joinStrings(lines.toArray(), "\n"), maxRunes)
}

func sanitizeEmailUrl(raw: String): String {
    let url = raw.trimAscii()
    if (containsSecret(url) || containsLocalPath(url)) { return "" }
    url
}

func envNameIsValid(raw: String): Bool {
    let value = raw.trimAscii()
    if (value.isEmpty()) { return false }
    let runes = value.toRuneArray()
    let first = runes[0]
    if (!((first >= r'A' && first <= r'Z') || (first >= r'a' && first <= r'z') || first == r'_')) { return false }
    for (r in runes) {
        if (!((r >= r'A' && r <= r'Z') || (r >= r'a' && r <= r'z') || (r >= r'0' && r <= r'9') || r == r'_')) { return false }
    }
    true
}
