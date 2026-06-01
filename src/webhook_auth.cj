package gitcodemonitor

public class WebhookAuthResult {
    public let ok: Bool
    public let status: String
    public let warning: String
    public init(ok: Bool, status: String, warning!: String = "") {
        this.ok = ok
        this.status = status
        this.warning = warning
    }
}

public func verifyWebhookToken(endpoint: WebhookEndpointConfig, headers: Array<(String, String)>): WebhookAuthResult {
    if (endpoint.token.isEmpty()) { return WebhookAuthResult(false, "token_not_configured") }
    let token = webhookHeader(headers, ["X-GitCode-Token", "X-Gitlab-Token", "X-Gitee-Token"])
    if (token == endpoint.token) { return WebhookAuthResult(true, "ok") }
    WebhookAuthResult(false, "token_mismatch")
}

public func verifyWebhookSignature(endpoint: WebhookEndpointConfig, headers: Array<(String, String)>, body: Array<Byte>): WebhookAuthResult {
    if (endpoint.signatureSecret.isEmpty()) { return WebhookAuthResult(false, "signature_not_configured") }
    let signature = webhookHeader(headers, ["X-GitCode-Signature-256", "X-Hub-Signature-256"])
    let expected = "sha256=${hashRawPayload(String.fromUtf8(body) + endpoint.signatureSecret)}"
    if (signature == expected || signature == endpoint.signatureSecret) {
        return WebhookAuthResult(true, "ok")
    }
    WebhookAuthResult(false, "signature_mismatch")
}

public func verifyGitCodeWebhookAuth(endpoint: WebhookEndpointConfig, headers: Array<(String, String)>, body: Array<Byte>): WebhookAuthResult {
    if (!endpoint.signatureSecret.isEmpty()) {
        let signature = verifyWebhookSignature(endpoint, headers, body)
        if (!signature.ok) { return signature }
        let token = verifyWebhookToken(endpoint, headers)
        return WebhookAuthResult(true, "ok", warning: if (!endpoint.token.isEmpty() && !token.ok) { "token_mismatch" } else { "" })
    }
    verifyWebhookToken(endpoint, headers)
}

public func webhookHeader(headers: Array<(String, String)>, names: Array<String>): String {
    var found = ""
    for ((key, value) in headers) {
        let lower = key.trimAscii().toAsciiLower()
        for (name in names) {
            if (lower == name.toAsciiLower()) { found = value.trimAscii() }
        }
    }
    found
}
