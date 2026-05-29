package gitcodemonitor

import std.fs.{Directory, File, Path, exists, remove}
import std.unittest.testmacro.*

@Test
public class GitCodeMonitorPluginRuntimeTest {
    private func tempConfigPath(name: String): String {
        Path("/tmp").join("${name}.json").toString()
    }

    private func writeConfig(path: String, text!: String = "{\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"statePath\":\"data/state.json\"},\"gitcode\":{\"baseUrl\":\"https://api.gitcode.com/api/v5\",\"token\":\"fake-token\"}}"): Unit {
        File.writeTo(Path(path), text.toArray())
    }

    @TestCase
    public func initializeNegotiatesProtocolAndLoadsConfigWithoutLeakingSecrets(): Unit {
        let path = tempConfigPath("gcm-plugin-init")
        writeConfig(path)
        let initResult = initializeGcmPlugin(ServiceInitializeRequest("1.0", configRef: path, hostApis: ["host.agent.invoke"]))
        @Expect(initResult.ok, true)
        @Expect(initResult.serviceId, GCM_SERVICE_PLUGIN_ID)
        @Expect(initResult.capabilities.size, 8)
        @Expect(initResult.diagnostic.contains("fake-token"), false)
        @Expect(initializeGcmPlugin(ServiceInitializeRequest("2.0", configRef: path)).status, "incompatible_protocol")
        @Expect(initializeGcmPlugin(ServiceInitializeRequest("1.0", configRef: "")).status, "missing_config_ref")
        @Expect(loadGcmRuntimeConfig("/tmp/does-not-exist-gcm-plugin.json").status, "config_missing")
        if (exists(Path(path))) { remove(Path(path)) }
    }

    @TestCase
    public func pluginMainSupportsPluginStdioEntryAndMainConfigRefShape(): Unit {
        let path = tempConfigPath("gcm-plugin-main")
        writeConfig(path)
        @Expect(gcmPluginMain(["--config", path]), 0)
        @Expect(gcmPluginMain(["--config", "/tmp/missing-gcm-plugin-main.json"]), 2)
        if (exists(Path(path))) { remove(Path(path)) }
    }

    @TestCase
    public func configResolutionSecretSummaryAndValidationAreExplicit(): Unit {
        @Expect(resolveGcmPluginConfig("").ok, false)
        let config = defaultConfig()
        config.gitCodeToken = "fake-token"
        config.mcpServiceToken = "metis-token"
        config.telegramChatId = "chat"
        config.fullScanIntervalMinutes = 10
        let secret = summarizeGcmSecretState(config)
        @Expect(secret.gitCodeAuth, "present")
        @Expect(secret.mcpAuth, "present")
        @Expect(secret.legacyNotificationAuth, "legacy_present")
        let summary = summarizeGcmPluginModeConfig(config).text
        @Expect(summary.contains("fake-token"), false)
        @Expect(validateGcmPluginModeConfig(config).ok, true)
        config.fullScanIntervalMinutes = 1
        @Expect(validateGcmPluginModeConfig(config).ok, false)
    }

    @TestCase
    public func statusAndScanOnceCapabilitiesReturnBoundedPluginResults(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        let runtime = GcmRuntime(config)
        let status = handleGcmStatusCapability("{}", runtime)
        @Expect(status.ok, true)
        @Expect(status.summary.contains("dryRun=true"), true)
        let scan = handleGcmScanOnceCapability("{\"offlineFixture\":true}", runtime)
        @Expect(scan.ok, true)
        @Expect(scan.status, "ok")
        @Expect(scan.accepted >= 0, true)
        let runtimeRequired = handleGcmScanOnceCapability("{}", runtime)
        @Expect(runtimeRequired.ok, false)
        @Expect(runtimeRequired.status, "runtime_required")
        let overlap = handleGcmScanOnceCapability("{\"overlap\":true}", runtime)
        @Expect(overlap.status, "skipped_overlap")
        @Expect(runtime.state.skippedOverlappingScans, 1)
    }

    @TestCase
    public func pluginStdioFramesHandleStatusScanMalformedAndStopWithTempState(): Unit {
        let configPath = tempConfigPath("gcm-plugin-stdio-loop")
        let statePath = tempConfigPath("gcm-plugin-stdio-state")
        writeConfig(
            configPath,
            text: "{\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"statePath\":\"${statePath}\",\"orgs\":[\"cangjie\"]},\"gitcode\":{\"baseUrl\":\"https://api.gitcode.com/api/v5\",\"token\":\"fake-token\"}}"
        )
        let loaded = loadGcmRuntimeConfig(configPath)
        @Expect(loaded.ok, true)
        let runtime = RuntimeContainer(loaded.config)
        let state = runtime.store.load()
        let statusFrame = ServiceFrame(
            "request",
            "status-1",
            GCM_SERVICE_PLUGIN_ID,
            method: "invokeCapability",
            capabilityId: "gitcode.monitor.status",
            correlationId: "corr-status",
            payload: "{}"
        )
        let scanFrame = ServiceFrame(
            "request",
            "scan-1",
            GCM_SERVICE_PLUGIN_ID,
            method: "invokeCapability",
            capabilityId: "gitcode.monitor.scan_once",
            correlationId: "corr-scan",
            payload: "{\"offlineFixture\":true}"
        )
        let stopFrame = ServiceFrame(
            "request",
            "stop-1",
            GCM_SERVICE_PLUGIN_ID,
            method: "stop",
            correlationId: "corr-stop",
            payload: "{}"
        )
        let out = handleGcmPluginInputLinesForTest(
            ["{not-json", encodeServiceFrame(statusFrame).trimAscii(), encodeServiceFrame(scanFrame).trimAscii(), encodeServiceFrame(stopFrame).trimAscii()],
            loaded.config,
            runtime,
            state
        )
        @Expect(out.size, 4)
        @Expect(out[0].contains("invalid_json"), true)
        let statusResponse = decodeServiceFrame(out[1])
        @Expect(statusResponse.ok, true)
        @Expect(statusResponse.frame.correlationId, "corr-status")
        @Expect(statusResponse.frame.payload.contains("dryRun=true"), true)
        let scanResponse = decodeServiceFrame(out[2])
        @Expect(scanResponse.ok, true)
        @Expect(scanResponse.frame.correlationId, "corr-scan")
        @Expect(scanResponse.frame.payload.contains("\"accepted\":"), true)
        @Expect(scanResponse.frame.payload.contains("\"ignored\":"), true)
        @Expect(scanResponse.frame.payload.contains("\"emitted\":"), true)
        @Expect(exists(Path(statePath)), true)
        let stopResponse = decodeServiceFrame(out[3])
        @Expect(stopResponse.ok, true)
        @Expect(stopResponse.frame.correlationId, "corr-stop")
        if (exists(Path(configPath))) { remove(Path(configPath)) }
        if (exists(Path(statePath))) { remove(Path(statePath)) }
    }

    @TestCase
    public func acceptedIgnoredAndAuditEventsEmitServiceFrames(): Unit {
        let host = MetisHostClient()
        let event = GitCodeEvent("e1", "Cangjie", "community", "issue", "1", "alice", "https://gitcode.com/alice", "https://gitcode.com/Cangjie/community/issues/1", "hello")
        let accepted = emitGcmAcceptedEvent(event, host)
        @Expect(accepted.ok, true)
        @Expect(accepted.frame.capabilityId, "gitcode.event.accepted")
        @Expect(host.emitted.size, 1)
        let ignored = emitGcmIgnoredEvent(GitCodeIgnoredEvent(event, "start_build"), host)
        @Expect(ignored.frame.capabilityId, "gitcode.event.ignored")
        let audit = appendGcmPluginAudit(GcmAuditRecord("e1", "ignored", reason: "token=secret"), host)
        @Expect(audit.ok, true)
        @Expect(host.audits[0].contains("secret"), false)
    }

    @TestCase
    public func autoReplyGateRejectsEveryUnsafeConditionAndAllowsOnlySafeLiveWriteback(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        let request = GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", "https://gitcode.com/Cangjie/community/issues/1", "safe draft", safety: "approved")
        @Expect(evaluateGcmAutoReplyGate(request, config).reason, "auto_reply_disabled")
        config.autoReply = true
        @Expect(evaluateGcmAutoReplyGate(request, config).reason, "dry_run")
        config.dryRun = false
        @Expect(evaluateGcmAutoReplyGate(request, config).reason, "repo_not_allowlisted")
        config.repoAllowlist = ["Cangjie/community"]
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "safe", safety: "rejected"), config).reason, "safety_rejected")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "safe", needsHumanReview: true), config).reason, "needs_human_review")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "safe", duplicate: true), config).reason, "duplicate")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, appendGcmSelfMarker("safe")), config).reason, "self_marker")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "token=secret"), config).reason, "secret_detected")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "/Users/name/file"), config).reason, "local_path_detected")
        @Expect(evaluateGcmAutoReplyGate(request, config).reason, "allow_write")
    }

    @TestCase
    public func writebackApplyUsesFakeWriterOnlyWhenGateAllows(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.autoReply = true
        config.dryRun = false
        config.repoAllowlist = ["Cangjie/community"]
        let runtime = GcmRuntime(config)
        let payload = "{\"eventId\":\"e1\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"1\",\"url\":\"https://gitcode.com/Cangjie/community/issues/1\",\"draft\":\"safe draft\",\"safety\":\"approved\"}"
        let applied = handleGcmWritebackApplyResult(payload, runtime)
        @Expect(applied.ok, true)
        @Expect(applied.writerCalled, true)
        @Expect(runtime.writer.written.size, 1)
        @Expect(runtime.writer.written[0].contains(SELF_MARKER), true)

        let blocked = handleGcmWritebackApplyResult(payload.replace("\"approved\"", "\"rejected\""), runtime)
        @Expect(blocked.writerCalled, false)
        @Expect(blocked.decision.reason, "safety_rejected")
    }

    @TestCase
    public func writebackHelpersBuildRequestsMarkerAndAuditsWithoutSecrets(): Unit {
        let request = GcmWritebackRequest("e2", "Cangjie/stdx", "pr", "2", "https://gitcode.com/Cangjie/stdx/pulls/2", "draft")
        let write = buildGitCodeCommentWriteRequest(request)
        @Expect(write.credentialScope, "gcm-internal")
        @Expect(write.body.contains(SELF_MARKER), true)
        @Expect(hasGcmSelfMarker(write.body), true)
        @Expect(appendGcmSelfMarker(write.body), write.body)
        let audit = buildGcmWritebackAudit(request, GcmWritebackDecision(false, "dry_run"))
        @Expect(audit.bodyHash.startsWith("payload-"), true)
        let host = MetisHostClient()
        let emitted = emitGcmWritebackAudit(audit, host)
        @Expect(emitted.ok, true)
        @Expect(emitted.frame.capabilityId, "gitcode.writeback.audit")
        @Expect(emitted.frame.payload.contains("draft"), false)
    }

    @TestCase
    public func legacyNotificationAndMcpModesAreWarningsNotPrimaryPaths(): Unit {
        let config = defaultConfig()
        @Expect(classifyGcmLegacyNotificationConfig(config).status, "absent")
        config.feishuWebhook = "https://example.invalid/webhook"
        config.telegramChatId = "chat"
        let legacy = classifyGcmLegacyNotificationConfig(config)
        @Expect(legacy.status, "legacy_present")
        @Expect(renderLegacyNotificationWarning(legacy).contains("Metis Gateway"), true)
        @Expect(classifyGcmMcpClientMode(config).mode, "disabled")
        config.mcpEndpoint = "http://127.0.0.1:9000"
        let mcp = classifyGcmMcpClientMode(config)
        @Expect(mcp.mode, "diagnostic_legacy")
        @Expect(renderGcmMcpLegacyNotice(mcp).contains("diagnostic/legacy"), true)
    }

    @TestCase
    public func autoReplyMigrationAndProtocolMalformedInputAreCovered(): Unit {
        let config = defaultConfig()
        @Expect(migrateLegacyAutoReply(config).autoReply, false)
        @Expect(detectAutoReplyConfigConflict(config).isNone(), true)
        match (detectAutoReplyConfigTextConflict("{\"autoReply\":true,\"autoReply\":{\"enabled\":false}}")) {
            case Some(conflict) =>
                @Expect(conflict.field, "autoReply")
            case None => @Expect(true, false)
        }
        @Expect(decodeServiceFrame("{not-json").errorKind, "invalid_json")
        @Expect(decodeServiceFrame("{\"type\":\"request\",\"frameId\":\"f\",\"serviceId\":\"gitcode-monitor\",\"method\":\"unknown\"}").errorKind, "unknown_method")
        @Expect(decodeServiceFrame("0123456789", maxBytes: 4).errorKind, "frame_too_large")
    }
}
