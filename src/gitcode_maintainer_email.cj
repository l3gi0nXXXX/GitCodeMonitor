package gitcodemonitor

import std.collection.*
import std.convert.*
import std.env.getVariable
import std.io.*
import std.process.*
import std.sync.*
import std.time.*
import stdx.encoding.base64.toBase64String

public class MaintainerSmtpConfig {
    public let host: String
    public let port: Int64
    public let security: String
    public let username: String
    public let password: String
    public let passwordEnv: String
    public let connectTimeoutMs: Int64
    public let sendTimeoutMs: Int64

    public init(host: String, port: Int64, security: String, username: String, passwordEnv: String, password!: String = "", connectTimeoutMs!: Int64 = 10000, sendTimeoutMs!: Int64 = 30000) {
        this.host = host.trimAscii()
        this.port = port
        this.security = security.trimAscii().toAsciiLower()
        this.username = username.trimAscii()
        this.password = password.trimAscii()
        this.passwordEnv = passwordEnv.trimAscii()
        this.connectTimeoutMs = connectTimeoutMs
        this.sendTimeoutMs = sendTimeoutMs
    }

    public init() {
        this.host = ""
        this.port = 0
        this.security = "ssl"
        this.username = ""
        this.password = ""
        this.passwordEnv = ""
        this.connectTimeoutMs = 10000
        this.sendTimeoutMs = 30000
    }
}

public class MaintainerUserEmailLookupConfig {
    public let enabled: Bool
    public let timeoutMs: Int64
    public let cacheTtlMs: Int64
    public let maxCacheEntries: Int64
    public let fallbackToAddressBook: Bool

    public init(enabled!: Bool = true, timeoutMs!: Int64 = 10000, cacheTtlMs!: Int64 = 24 * 60 * 60 * 1000, maxCacheEntries!: Int64 = 4096, fallbackToAddressBook!: Bool = true) {
        this.enabled = enabled
        this.timeoutMs = if (timeoutMs <= 0) { 10000 } else { timeoutMs }
        this.cacheTtlMs = if (cacheTtlMs <= 0) { 24 * 60 * 60 * 1000 } else { cacheTtlMs }
        this.maxCacheEntries = if (maxCacheEntries <= 0) { 4096 } else { maxCacheEntries }
        this.fallbackToAddressBook = fallbackToAddressBook
    }
}

public class MaintainerNotificationEmailConfig {
    public let enabled: Bool
    public let transport: String
    public let userLookup: MaintainerUserEmailLookupConfig
    public let smtp: MaintainerSmtpConfig
    public let from: String
    public let replyTo: String
    public let allowedDomains: Array<String>
    public let addressBook: HashMap<String, Array<String>>
    public let allowPlainSmtpForTest: Bool

    public init(
        enabled!: Bool = false,
        transport!: String = "smtp",
        userLookup!: MaintainerUserEmailLookupConfig = MaintainerUserEmailLookupConfig(),
        smtp!: MaintainerSmtpConfig = MaintainerSmtpConfig(),
        from!: String = "",
        replyTo!: String = "",
        allowedDomains!: Array<String> = [],
        addressBook!: Array<(String, Array<String>)> = [],
        allowPlainSmtpForTest!: Bool = false
    ) {
        this.enabled = enabled
        this.transport = transport.trimAscii().toAsciiLower()
        this.userLookup = userLookup
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
    public let passwords = ArrayList<String>()
    public var nextResult: MaintainerEmailSendResult = MaintainerEmailSendResult("sent")
    public init() {}
    public func send(config: MaintainerNotificationEmailConfig, message: MaintainerEmailMessage, mime: String, password: String): MaintainerEmailSendResult {
        let _ = config
        passwords.add(password)
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

public interface MaintainerSmtpProcess {
    func write(data: String): Unit
    func readLine(timeoutMs: Int64): Option<String>
    func isAlive(): Bool
    func wait(timeoutMs: Int64): Option<Int64>
    func terminate(force: Bool): Unit
    func stderrSummary(): String
}

public enum MaintainerSmtpProcessStartResult {
    | Started(MaintainerSmtpProcess)
    | Failed(String)
}

public interface MaintainerSmtpProcessRunner {
    func start(config: MaintainerNotificationEmailConfig): MaintainerSmtpProcessStartResult
}

private class MaintainerSmtpLineBuffer {
    private let lock = Mutex()
    private let condition: Condition
    private let lines = ArrayList<String>()
    private let summaryLines = ArrayList<String>()
    private var closed = false
    private var lastErrorText = ""
    private var dropped: Int64 = 0

    public init() {
        synchronized(this.lock) {
            this.condition = this.lock.condition()
        }
    }

    public func appendLine(line: String): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
            if (line.size > 1048576) {
                this.dropped += 1
                this.rememberSummaryLocked("oversized_line")
                return
            }
            while (this.lines.size >= 256) {
                this.lines.remove(at: 0)
                this.dropped += 1
            }
            this.lines.add(line)
            this.rememberSummaryLocked(line)
            this.condition.notifyAll()
        }
    }

    public func readLine(timeoutMs: Int64): Option<String> {
        let effectiveTimeoutMs = if (timeoutMs > 0) { timeoutMs } else { 1000 }
        synchronized(this.lock) {
            if (this.lines.isEmpty() && !this.closed) {
                let _ = this.condition.waitUntil(
                    { => !this.lines.isEmpty() || this.closed },
                    timeout: Duration.millisecond * effectiveTimeoutMs
                )
            }
            if (this.lines.isEmpty()) {
                return None<String>
            }
            let line = this.lines[0]
            this.lines.remove(at: 0)
            Some(line)
        }
    }

    public func close(error!: String = ""): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.closed = true
                this.lastErrorText = error.trimAscii()
            } else if (this.lastErrorText.isEmpty()) {
                this.lastErrorText = error.trimAscii()
            }
            this.condition.notifyAll()
        }
    }

    public func summary(): String {
        synchronized(this.lock) {
            let parts = ArrayList<String>()
            if (this.dropped > 0) {
                parts.add("dropped=${this.dropped}")
            }
            if (!this.lastErrorText.isEmpty()) {
                parts.add("error=${this.lastErrorText}")
            }
            if (this.summaryLines.size > 0) {
                parts.add(joinStrings(this.summaryLines.toArray(), "\n"))
            }
            truncateRunes(redactSecrets(joinStrings(parts.toArray(), "\n")), 512)
        }
    }

    private func rememberSummaryLocked(line: String): Unit {
        this.summaryLines.add(line)
        while (this.summaryLines.size > 8) {
            this.summaryLines.remove(at: 0)
        }
    }
}

public class OpenSslMaintainerSmtpProcess <: MaintainerSmtpProcess {
    private let process: SubProcess
    private let writer: StringWriter<OutputStream>
    private let stateLock = Mutex()
    private let stdoutBuffer = MaintainerSmtpLineBuffer()
    private let stderrBuffer = MaintainerSmtpLineBuffer()
    private var closed = false

    public init(process: SubProcess) {
        this.process = process
        this.writer = StringWriter<OutputStream>(process.stdInPipe)
        let stdoutReader = StringReader<InputStream>(process.stdOutPipe)
        let stderrReader = StringReader<InputStream>(process.stdErrPipe)
        spawn {
            this.readPipeLines(stdoutReader, this.stdoutBuffer)
        }
        spawn {
            this.readPipeLines(stderrReader, this.stderrBuffer)
        }
    }

    public func write(data: String): Unit {
        this.writer.write(data)
        this.writer.flush()
    }

    public func readLine(timeoutMs: Int64): Option<String> {
        this.stdoutBuffer.readLine(timeoutMs)
    }

    public func isAlive(): Bool {
        !this.isClosed() && this.process.isAlive()
    }

    public func wait(timeoutMs: Int64): Option<Int64> {
        try {
            let result = this.process.wait(timeout: Some(Duration.millisecond * if (timeoutMs > 0) { timeoutMs } else { 500 }))
            this.closeBuffers("")
            Some(result)
        } catch (_: Exception) {
            None<Int64>
        }
    }

    public func terminate(force: Bool): Unit {
        this.closeBuffers("terminated")
        try { this.process.terminate(force: force) } catch (_: Exception) { () }
    }

    public func stderrSummary(): String {
        this.stderrBuffer.summary()
    }

    private func readPipeLines(reader: StringReader<InputStream>, buffer: MaintainerSmtpLineBuffer): Unit {
        while (!this.isClosed()) {
            let line = try {
                reader.readln()
            } catch (e: Exception) {
                buffer.close(error: "read_failed")
                let _ = e
                return
            }
            match (line) {
                case Some(value) => buffer.appendLine(value)
                case None =>
                    buffer.close()
                    return
            }
        }
    }

    private func closeBuffers(reason: String): Unit {
        synchronized(this.stateLock) {
            this.closed = true
        }
        this.stdoutBuffer.close(error: reason)
        this.stderrBuffer.close(error: reason)
    }

    private func isClosed(): Bool {
        synchronized(this.stateLock) {
            this.closed
        }
    }
}

public class OpenSslMaintainerSmtpProcessRunner <: MaintainerSmtpProcessRunner {
    public init() {}

    public func start(config: MaintainerNotificationEmailConfig): MaintainerSmtpProcessStartResult {
        if (config.smtp.security == "none") {
            return MaintainerSmtpProcessStartResult.Failed("smtp_plain_transport_unavailable")
        }
        try {
            let process = launch(
                "openssl",
                openSslMaintainerSmtpArgs(config),
                stdIn: ProcessRedirect.Pipe,
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe
            )
            MaintainerSmtpProcessStartResult.Started(OpenSslMaintainerSmtpProcess(process))
        } catch (e: Exception) {
            MaintainerSmtpProcessStartResult.Failed("smtp_transport_start_failed: ${redactSecrets(e.message)}")
        }
    }
}

func openSslMaintainerSmtpArgs(config: MaintainerNotificationEmailConfig): Array<String> {
    let args = ArrayList<String>()
    args.add("s_client")
    args.add("-quiet")
    if (config.smtp.security == "starttls") {
        args.add("-starttls")
        args.add("smtp")
    }
    args.add("-connect")
    args.add("${config.smtp.host}:${config.smtp.port}")
    args.add("-servername")
    args.add(config.smtp.host)
    args.toArray()
}

class MaintainerSmtpProtocolResponse {
    public let ok: Bool
    public let code: Int64
    public let status: String

    public init(ok: Bool, code!: Int64 = 0, status!: String = "") {
        this.ok = ok
        this.code = code
        this.status = status.trimAscii()
    }
}

public class NativeSmtpTransport <: MaintainerSmtpTransport {
    private let runner: MaintainerSmtpProcessRunner

    public init(runner!: MaintainerSmtpProcessRunner = OpenSslMaintainerSmtpProcessRunner()) {
        this.runner = runner
    }

    public func send(config: MaintainerNotificationEmailConfig, message: MaintainerEmailMessage, mime: String, password: String): MaintainerEmailSendResult {
        match (this.runner.start(config)) {
            case MaintainerSmtpProcessStartResult.Failed(reason) =>
                return MaintainerEmailSendResult(
                    "send_failed",
                    retryable: true,
                    failedCount: message.recipients.size,
                    diagnostic: maintainerSmtpDiagnostic(reason)
                )
            case MaintainerSmtpProcessStartResult.Started(process) =>
                try {
                    this.sendWithProcess(process, config, message, mime, password)
                } catch (e: Exception) {
                    MaintainerEmailSendResult(
                        "send_failed",
                        retryable: true,
                        failedCount: message.recipients.size,
                        diagnostic: maintainerSmtpDiagnostic("smtp_transport_exception: ${e.message}")
                    )
                } finally {
                    if (process.isAlive()) {
                        match (process.wait(500)) {
                            case Some(_) => ()
                            case None => process.terminate(true)
                        }
                    }
                }
        }
    }

    private func sendWithProcess(process: MaintainerSmtpProcess, config: MaintainerNotificationEmailConfig, message: MaintainerEmailMessage, mime: String, password: String): MaintainerEmailSendResult {
        let timeoutMs = if (config.smtp.sendTimeoutMs > 0) { config.smtp.sendTimeoutMs } else { 30000 }
        let greeting = readMaintainerSmtpResponse(process, timeoutMs)
        if (!smtpCodeIs(greeting, 220)) {
            return maintainerSmtpFailure("smtp_greeting_failed", greeting, message.recipients.size)
        }
        writeMaintainerSmtpCommand(process, "EHLO localhost")
        let ehlo = readMaintainerSmtpResponse(process, timeoutMs)
        if (!smtpCodeIs(ehlo, 250)) {
            return maintainerSmtpFailure("smtp_ehlo_failed", ehlo, message.recipients.size)
        }
        writeMaintainerSmtpCommand(process, "AUTH PLAIN ${smtpAuthPlainToken(config.smtp.username, password)}")
        let auth = readMaintainerSmtpResponse(process, timeoutMs)
        if (!smtpCodeIs(auth, 235)) {
            writeMaintainerSmtpCommand(process, "QUIT")
            return maintainerSmtpFailure("smtp_auth_failed", auth, message.recipients.size, retryableOverride: Some(false))
        }
        let from = if (!config.from.isEmpty()) { config.from } else { normalizeMaintainerEmail(config.smtp.username) }
        writeMaintainerSmtpCommand(process, "MAIL FROM:<${from}>")
        let mailFrom = readMaintainerSmtpResponse(process, timeoutMs)
        if (!smtpCodeIs(mailFrom, 250)) {
            writeMaintainerSmtpCommand(process, "QUIT")
            return maintainerSmtpFailure("smtp_mail_from_failed", mailFrom, message.recipients.size)
        }
        var accepted: Int64 = 0
        var failed: Int64 = 0
        var lastRcptCode: Int64 = 250
        for (recipient in message.recipients) {
            writeMaintainerSmtpCommand(process, "RCPT TO:<${recipient}>")
            let rcpt = readMaintainerSmtpResponse(process, timeoutMs)
            lastRcptCode = rcpt.code
            if (smtpCodeClassIs(rcpt, 2)) {
                accepted++
            } else {
                failed++
            }
        }
        if (accepted == 0) {
            writeMaintainerSmtpCommand(process, "QUIT")
            return mapSmtpFailureToEmailResult(lastRcptCode, accepted, failed)
        }
        writeMaintainerSmtpCommand(process, "DATA")
        let dataReady = readMaintainerSmtpResponse(process, timeoutMs)
        if (!smtpCodeIs(dataReady, 354)) {
            writeMaintainerSmtpCommand(process, "QUIT")
            return maintainerSmtpFailure("smtp_data_failed", dataReady, message.recipients.size)
        }
        process.write(mime + ".\r\n")
        let dataAccepted = readMaintainerSmtpResponse(process, timeoutMs)
        if (!smtpCodeClassIs(dataAccepted, 2)) {
            writeMaintainerSmtpCommand(process, "QUIT")
            return maintainerSmtpFailure("smtp_message_failed", dataAccepted, message.recipients.size)
        }
        writeMaintainerSmtpCommand(process, "QUIT")
        let _ = readMaintainerSmtpResponse(process, 1000)
        MaintainerEmailSendResult("sent", sentCount: accepted, failedCount: failed)
    }
}

func writeMaintainerSmtpCommand(process: MaintainerSmtpProcess, command: String): Unit {
    process.write(command + "\r\n")
}

func readMaintainerSmtpResponse(process: MaintainerSmtpProcess, timeoutMs: Int64): MaintainerSmtpProtocolResponse {
    var remaining: Int64 = 64
    while (remaining > 0) {
        remaining--
        match (process.readLine(timeoutMs)) {
            case Some(raw) =>
                let line = raw.trimAscii()
                let code = parseMaintainerSmtpCode(line)
                if (code <= 0) {
                    continue
                }
                let runes = line.toRuneArray()
                if (runes.size <= 3 || runes[3] != r'-') {
                    return MaintainerSmtpProtocolResponse(true, code: code, status: "smtp_${code}")
                }
            case None => return MaintainerSmtpProtocolResponse(false, status: "smtp_response_timeout")
        }
    }
    MaintainerSmtpProtocolResponse(false, status: "smtp_response_overflow")
}

func parseMaintainerSmtpCode(line: String): Int64 {
    let runes = line.toRuneArray()
    if (runes.size < 3) {
        return 0
    }
    for (idx in 0..3) {
        if (runes[idx] < r'0' || runes[idx] > r'9') {
            return 0
        }
    }
    try {
        Int64.parse(line[0..3])
    } catch (_: Exception) {
        0
    }
}

func smtpCodeIs(response: MaintainerSmtpProtocolResponse, code: Int64): Bool {
    response.ok && response.code == code
}

func smtpCodeClassIs(response: MaintainerSmtpProtocolResponse, codeClass: Int64): Bool {
    response.ok && response.code / 100 == codeClass
}

func smtpAuthPlainToken(username: String, password: String): String {
    let bytes = ArrayList<Byte>()
    bytes.add(UInt8(0))
    bytes.add(all: username.toArray())
    bytes.add(UInt8(0))
    bytes.add(all: password.toArray())
    toBase64String(bytes.toArray())
}

func maintainerSmtpFailure(prefix: String, response: MaintainerSmtpProtocolResponse, failedCount: Int64, retryableOverride!: Option<Bool> = None<Bool>): MaintainerEmailSendResult {
    let retryable = match (retryableOverride) {
        case Some(value) => value
        case None => smtpResponseRetryable(response)
    }
    let suffix = if (response.code > 0) { "${response.code}" } else { response.status }
    MaintainerEmailSendResult(
        "send_failed",
        retryable: retryable,
        failedCount: failedCount,
        diagnostic: maintainerSmtpDiagnostic("${prefix}_${suffix}")
    )
}

func smtpResponseRetryable(response: MaintainerSmtpProtocolResponse): Bool {
    if (!response.ok) {
        return true
    }
    response.code >= 400 && response.code < 500
}

func maintainerSmtpDiagnostic(raw: String): String {
    truncateRunes(redactSecrets(raw).replace("\r", " ").replace("\n", " "), 200)
}

public class SmtpMaintainerEmailSender <: MaintainerEmailSender {
    public let config: MaintainerNotificationEmailConfig
    public let transport: MaintainerSmtpTransport
    public var connectCount: Int64 = 0

    public init(config: MaintainerNotificationEmailConfig, transport!: MaintainerSmtpTransport = NativeSmtpTransport()) {
        this.config = config
        this.transport = transport
    }

    public func send(message: MaintainerEmailMessage): MaintainerEmailSendResult {
        if (!config.enabled) { return MaintainerEmailSendResult("email_disabled") }
        let password = if (!config.smtp.password.isEmpty()) { config.smtp.password } else { getVariable(config.smtp.passwordEnv) ?? "" }
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
