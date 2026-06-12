package gitcodemonitor

import std.fs.{Directory, File, Path, exists, remove}
import std.time.DateTime
import std.unittest.testmacro.*

@Test
public class GitCodeMonitorPluginRuntimeTest {
    private func tempConfigPath(name: String): String {
        Path("/tmp").join("${name}.json").toString()
    }

    private func tempRuntimeDir(name: String): Path {
        let dir = Path("/tmp").join("${name}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(dir, recursive: true)
        dir
    }

    private func writeConfig(path: String, text!: String = "{\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"statePath\":\".gitcodemonitor/state.json\"},\"gitcode\":{\"baseUrl\":\"https://api.gitcode.com/api/v5\",\"token\":\"fake-token\"}}"): Unit {
        File.writeTo(Path(path), text.toArray())
    }

    private func readFixture(path: String): String {
        String.fromUtf8(File.readFrom(Path(path))).trimAscii()
    }

    private func joinDiagnostics(items: Array<String>): String {
        var out = ""
        for (item in items) {
            if (out.isEmpty()) {
                out = item
            } else {
                out += "," + item
            }
        }
        out
    }

    private func scanResponsePayloadFor(rawPayload: String): String {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempConfigPath("gcm-plugin-payload-state")
        let fakeSender = FakeHttpSender()
        fakeSender.nextResponse = HttpResponseSpec(200, body: "[]")
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let scanFrame = ServiceFrame(
            "request",
            "scan-payload",
            GCM_SERVICE_PLUGIN_ID,
            method: "invokeCapability",
            capabilityId: "gitcode.monitor.scan_once",
            correlationId: "corr-payload",
            payload: rawPayload
        )
        let handled = handleGcmPluginInputLine(encodeServiceFrame(scanFrame).trimAscii(), config, runtime, state)
        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
        handled.frame.payload
    }

    @TestCase
    public func initializeNegotiatesProtocolAndLoadsConfigWithoutLeakingSecrets(): Unit {
        let path = tempConfigPath("gcm-plugin-init")
        writeConfig(path)
        let initResult = initializeGcmPlugin(ServiceInitializeRequest("1.0", configRef: path, hostApis: ["host.agent.invoke"]))
        @Expect(initResult.ok, true)
        @Expect(initResult.serviceId, GCM_SERVICE_PLUGIN_ID)
        @Expect(initResult.capabilities.size, 20)
        @Expect(arrayContains(requiredGitCodeMonitorCapabilityIds(), "gitcode.event.accepted"), true)
        @Expect(arrayContains(requiredGitCodeMonitorCapabilityIds(), "gitcode.monitor.orphan_detected"), true)
        @Expect(arrayContains(requiredGitCodeMonitorCapabilityIds(), "gitcode.writeback.apply_result"), true)
        @Expect(arrayContains(requiredGitCodeMonitorCapabilityIds(), "gitcode.agent.draft_request"), false)
        @Expect(arrayContains(requiredGitCodeMonitorCapabilityIds(), "gitcode.notification.generated_reply"), false)
        @Expect(initResult.diagnostic.contains("fake-token"), false)
        @Expect(initializeGcmPlugin(ServiceInitializeRequest("2.0", configRef: path)).status, "incompatible_protocol")
        @Expect(initializeGcmPlugin(ServiceInitializeRequest("1.0", configRef: "")).status, "missing_config_ref")
        @Expect(loadGcmRuntimeConfig("/tmp/does-not-exist-gcm-plugin.json").status, "config_missing")
        if (exists(Path(path))) { remove(Path(path)) }
    }

    @TestCase
    public func initializeReportsWebhookReceiverDisabledWithoutSecretLeaks(): Unit {
        let dir = tempRuntimeDir("gcm-plugin-init-webhook-disabled")
        let path = dir.join("gcm.json").toString()
        writeConfig(
            path,
            text: "{\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"statePath\":\"${dir.join("state.json").toString()}\"},\"gitcode\":{\"baseUrl\":\"https://api.gitcode.com/api/v5\",\"token\":\"fake-token\",\"webhook\":{\"enabled\":false}}}"
        )
        let initResult = initializeGcmPlugin(ServiceInitializeRequest("1.0", configRef: path))
        @Expect(initResult.ok, true)
        @Expect(initResult.status, "ok")
        @Expect(initResult.diagnostic.contains("webhookReceiver.status=disabled"), true)
        @Expect(initResult.diagnostic.contains("fake-token"), false)
        let payload = gcmInitializeResponsePayload(initResult)
        @Expect(payload.contains("\"webhookReceiverStatus\":\"disabled\""), true)
        @Expect(payload.contains("fake-token"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func initializeReportsWebhookReceiverNotStartedWithRedactedSummary(): Unit {
        let dir = tempRuntimeDir("gcm-plugin-init-webhook-running")
        let queueDir = dir.join("queue").toString()
        let path = dir.join("gcm.json").toString()
        writeConfig(
            path,
            text: "{\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"statePath\":\"${dir.join("state.json").toString()}\"},\"gitcode\":{\"baseUrl\":\"https://api.gitcode.com/api/v5\",\"token\":\"fake-token\",\"webhook\":{\"enabled\":true,\"bindHost\":\"127.0.0.1\",\"port\":18080,\"queueDir\":\"${queueDir}\",\"endpoints\":[{\"id\":\"main\",\"path\":\"/webhooks/gitcode/main\",\"token\":\"receiver-token\",\"signatureSecret\":\"signature-secret\"}]}}}"
        )
        let initResult = initializeGcmPlugin(ServiceInitializeRequest("1.0", configRef: path))
        @Expect(initResult.ok, true)
        @Expect(initResult.status, "capability_degraded")
        @Expect(initResult.diagnostic.contains("webhookReceiver.status=degraded"), true)
        @Expect(initResult.diagnostic.contains("listenerStatus=not_started"), true)
        let payload = gcmInitializeResponsePayload(initResult)
        @Expect(payload.contains("\"webhookReceiverStatus\":\"degraded\""), true)
        @Expect(payload.contains("\"listenerStatus\":\"not_started\""), true)
        @Expect(payload.contains("\"webhookBind\":\"127.0.0.1:18080\""), true)
        @Expect(payload.contains("\"webhookEndpointCount\":1"), true)
        @Expect(payload.contains("\"webhookQueueDir\""), true)
        @Expect(payload.contains("receiver-token"), false)
        @Expect(payload.contains("signature-secret"), false)
        @Expect(payload.contains("fake-token"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func initializeDegradesWebhookReceiverWithoutCrashingWhenSecretMissing(): Unit {
        let dir = tempRuntimeDir("gcm-plugin-init-webhook-degraded")
        let path = dir.join("gcm.json").toString()
        writeConfig(
            path,
            text: "{\"monitor\":{\"fullScanIntervalMinutes\":10,\"dryRun\":true,\"statePath\":\"${dir.join("state.json").toString()}\"},\"gitcode\":{\"baseUrl\":\"https://api.gitcode.com/api/v5\",\"token\":\"fake-token\",\"webhook\":{\"enabled\":true,\"bindHost\":\"127.0.0.1\",\"port\":18080,\"queueDir\":\"${dir.join("queue").toString()}\",\"endpoints\":[{\"id\":\"main\",\"path\":\"/webhooks/gitcode/main\"}]}}}"
        )
        let initResult = initializeGcmPlugin(ServiceInitializeRequest("1.0", configRef: path))
        @Expect(initResult.ok, true)
        @Expect(initResult.status, "capability_degraded")
        @Expect(initResult.diagnostic.contains("webhookReceiver.status=degraded"), true)
        @Expect(initResult.diagnostic.contains("missing_endpoint_secret"), true)
        let payload = gcmInitializeResponsePayload(initResult)
        @Expect(payload.contains("\"webhookReceiverStatus\":\"degraded\""), true)
        @Expect(payload.contains("missing_endpoint_secret"), true)
        @Expect(payload.contains("fake-token"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func pluginMainRejectsInvalidConfigWithoutWaitingForStdin(): Unit {
        let path = tempConfigPath("gcm-plugin-main")
        @Expect(gcmPluginMain(["--config", "/tmp/missing-gcm-plugin-main.json"]), 2)
        if (exists(Path(path))) { remove(Path(path)) }
    }

    @TestCase
    public func stdioProtocolFixturesDecodeValidFramesAndRejectNoiseLine(): Unit {
        let initLine = readFixture("test/fixtures/service_plugin/stdio_protocol/valid_initialize.jsonl")
        let scanLine = readFixture("test/fixtures/service_plugin/stdio_protocol/valid_scan_response.jsonl")
        let noisy = readFixture("test/fixtures/service_plugin/stdio_protocol/noisy_stdout_before_response.txt").split("\n")
        let initFrame = decodeServiceFrame(initLine)
        @Expect(initFrame.ok, true)
        @Expect(initFrame.frame.method, "initialize")
        @Expect(initFrame.frame.payload.contains("\"capabilities\""), true)
        let scanFrame = decodeServiceFrame(scanLine)
        @Expect(scanFrame.ok, true)
        @Expect(scanFrame.frame.method, "invokeCapability")
        @Expect(scanFrame.frame.capabilityId, "gitcode.monitor.scan_once")
        @Expect(scanFrame.frame.correlationId, "corr-scan-1")
        @Expect(noisy.size, 3)
        @Expect(decodeServiceFrame(noisy[0]).ok, true)
        @Expect(decodeServiceFrame(noisy[1]).ok, false)
        @Expect(decodeServiceFrame(noisy[1]).errorKind, "invalid_json")
        @Expect(decodeServiceFrame(noisy[2]).ok, true)
        @Expect(initLine.contains("Authorization"), false)
        @Expect(scanLine.contains("/Users/"), false)
        @Expect(readFixture("test/fixtures/service_plugin/stdio_protocol/noisy_stdout_before_response.txt").contains("fake-token"), false)
    }

    @TestCase
    public func pluginStdioWriterWritesOnlyEncodedFrames(): Unit {
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        writer.writeFrame(ServiceFrame("response", "initialize", GCM_SERVICE_PLUGIN_ID, method: "initialize", payload: "{\"ok\":true,\"status\":\"ok\"}"))
        writer.writeFrame(ServiceFrame("response", "stop-1", GCM_SERVICE_PLUGIN_ID, method: "stop", correlationId: "corr-stop", payload: "{\"ok\":true,\"status\":\"stopped\"}"))
        @Expect(sink.lines.size, 2)
        for (line in sink.lines) {
            @Expect(line.contains("\n"), false)
            @Expect(line.startsWith("{"), true)
            @Expect(decodeServiceFrame(line).ok, true)
        }
    }

    @TestCase
    public func pluginModeRuntimeUsesCapturedHttpSenderWhenLoggerCannotBeRedirected(): Unit {
        let config = defaultConfig()
        @Expect(configuredHttpTransport(config), "native")
        let runtime = RuntimeContainer(config, pluginStdioMode: true)
        @Expect(runtime.httpTransportKind, "curl")
    }

    @TestCase
    public func p1u001RuntimeInitializationWritesLeaseWithoutStartingWatchdogWorker(): Unit {
        // T-P1-U-001
        let dir = tempRuntimeDir("gcm-p1-u001-lease-only")
        let leasePath = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-p1-u001", 101, 202, "127.0.0.1", 19091, 1000, 1000, "running", "")

        @Expect(writeGcmPluginLease(leasePath, lease).ok, true)
        let loaded = readGcmPluginLease(leasePath)
        @Expect(loaded.ok, true)
        @Expect(loaded.lease.state, "running")
        @Expect(loaded.lease.lastHeartbeatMs, 1000)

        let runtimeSource = readFixture("src/plugin_runtime.cj")
        @Expect(runtimeSource.contains("GcmPluginWatchdogRuntime"), false)
        @Expect(runtimeSource.contains("watchdog.start()"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1u002RuntimeStopMarksLeaseStoppedWithoutWatchdogStopDependency(): Unit {
        // T-P1-U-002
        let dir = tempRuntimeDir("gcm-p1-u002-stop-lease")
        let leasePath = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-p1-u002", 101, 202, "127.0.0.1", 19092, 1000, 1000, "running", "parent_lost")

        @Expect(writeGcmPluginLease(leasePath, lease).ok, true)
        @Expect(markGcmPluginLeaseStopped(leasePath, nowMs: 2000).ok, true)
        let stopped = readGcmPluginLease(leasePath)
        @Expect(stopped.ok, true)
        @Expect(stopped.lease.state, "stopped")
        @Expect(stopped.lease.lastHeartbeatMs, 2000)
        @Expect(stopped.lease.orphanReason, "")

        let runtimeSource = readFixture("src/plugin_runtime.cj")
        @Expect(runtimeSource.contains("watchdog.stop()"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1b001MissingLeaseEnvironmentKeepsBasicCapabilities(): Unit {
        // T-P1-B-001
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        let leaseFromEnv = buildGcmPluginLeaseFromEnv(config, 1000)
        @Expect(leaseFromEnv.isNone(), true)

        let initResult = buildGcmPluginInitializeResult(config)
        @Expect(initResult.ok, true)
        @Expect(arrayContains(requiredGitCodeMonitorCapabilityIds(), "gitcode.monitor.status"), true)
        @Expect(arrayContains(requiredGitCodeMonitorCapabilityIds(), "gitcode.monitor.scan_once"), true)
        @Expect(arrayContains(requiredGitCodeMonitorCapabilityIds(), "gitcode.monitor.orphan_detected"), true)
    }

    @TestCase
    public func p1b002LeaseWriteFailureDoesNotBreakStdioProtocol(): Unit {
        // T-P1-B-002
        let dir = tempRuntimeDir("gcm-p1-b002-lease-write-failed")
        let badParent = dir.join("lease-parent-file")
        File.writeTo(badParent, "not-a-directory".toArray())
        let badLeasePath = badParent.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-p1-b002", 101, 202, "127.0.0.1", 19093, 1000, 1000, "running", "")
        let writeFailed = writeGcmPluginLease(badLeasePath, lease)
        @Expect(writeFailed.ok, false)
        @Expect(writeFailed.status, "lease_write_failed")

        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = dir.join("state.json").toString()
        config.webhook = WebhookReceiverConfig(enabled: false, queueDir: dir.join("queue").toString())
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        let statusFrame = ServiceFrame("request", "status-p1-b002", GCM_SERVICE_PLUGIN_ID, method: "invokeCapability", capabilityId: "gitcode.monitor.status", correlationId: "corr-p1-b002-status", payload: "{}")
        let stopFrame = ServiceFrame("request", "stop-p1-b002", GCM_SERVICE_PLUGIN_ID, method: "stop", correlationId: "corr-p1-b002-stop", payload: "{}")
        let out = handleGcmPluginInputLinesForTest([encodeServiceFrame(statusFrame).trimAscii(), encodeServiceFrame(stopFrame).trimAscii()], config, runtime, state)

        @Expect(out.size, 2)
        @Expect(decodeServiceFrame(out[0]).ok, true)
        @Expect(decodeServiceFrame(out[0]).frame.correlationId, "corr-p1-b002-status")
        @Expect(decodeServiceFrame(out[1]).ok, true)
        @Expect(decodeServiceFrame(out[1]).frame.correlationId, "corr-p1-b002-stop")
        @Expect(out[0].contains("lease_write_failed"), false)
        @Expect(out[1].contains("lease_write_failed"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1n001StopOrEofShutdownMarksLeaseStoppedAndStopsRuntimes(): Unit {
        // T-P1-N-001
        let dir = tempRuntimeDir("gcm-p1-n001-stop-eof")
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = dir.join("state.json").toString()
        config.webhook = WebhookReceiverConfig(enabled: false, queueDir: dir.join("queue").toString())
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        let queue = WebhookQueue(config.webhook.queueDir)
        let listener = WebhookHttpServerRuntime(config, queue)
        let _ = listener.start()
        let processorLoop = WebhookProcessorLoopRuntime(config, runtime, state, queue)
        processorLoop.start()
        let leasePath = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-p1-n001", 101, 202, "127.0.0.1", 19094, 1000, 1000, "running", "")
        @Expect(writeGcmPluginLease(leasePath, lease).ok, true)

        let stopFrame = ServiceFrame("request", "stop-p1-n001", GCM_SERVICE_PLUGIN_ID, method: "stop", correlationId: "corr-p1-n001-stop", payload: "{}")
        let handled = handleGcmPluginInputLineWithJobs(encodeServiceFrame(stopFrame).trimAscii(), config, runtime, state, GcmScanJobStore(maxConcurrent: 1))
        @Expect(handled.shouldStop, true)

        let _ = runtime.store.save(state)
        @Expect(markGcmPluginLeaseStopped(leasePath, nowMs: 2000).ok, true)
        processorLoop.stop()
        listener.stop()

        @Expect(exists(Path(config.statePath)), true)
        @Expect(readGcmPluginLease(leasePath).lease.state, "stopped")
        let processorStatus = processorLoop.snapshot().processorStatus
        @Expect(processorStatus == "disabled" || processorStatus == "stopped", true)
        let listenerStatus = listener.snapshot().listenerStatus
        @Expect(listenerStatus == "disabled" || listenerStatus == "stopped", true)
        let runtimeSource = readFixture("src/plugin_runtime.cj")
        @Expect(runtimeSource.contains("watchdog.stop()"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p1u003PluginStdioUsesFileBackedStdinInsteadOfConsoleReader(): Unit {
        // T-P1-U-003
        let runtimeSource = readFixture("src/plugin_runtime.cj")
        @Expect(runtimeSource.contains("getStdIn"), false)
        @Expect(runtimeSource.contains("ConsoleReader"), false)
        @Expect(runtimeSource.contains("METIS_SERVICE_PLUGIN_STDIN_PATH"), true)
        @Expect(runtimeSource.contains("File(gcmPluginStdinPath(), OpenMode.Read)"), true)
        @Expect(runtimeSource.contains("StringReader<File>"), true)
        @Expect(runtimeSource.contains("GcmPluginLeaseHeartbeatRuntime"), true)
    }

    @TestCase
    public func p1u004PluginStdioStartsLeaseHeartbeatWithoutWatchdogRuntime(): Unit {
        // T-P1-U-004
        let runtimeSource = readFixture("src/plugin_runtime.cj")
        let heartbeatSource = readFixture("src/plugin_lease_heartbeat.cj")
        @Expect(runtimeSource.contains("GcmPluginLeaseHeartbeatRuntime"), true)
        @Expect(runtimeSource.contains("heartbeatRuntime"), true)
        @Expect(runtimeSource.contains("GcmPluginWatchdogRuntime"), false)
        @Expect(heartbeatSource.contains("parentPid"), false)
        @Expect(heartbeatSource.contains("orphan_detected"), false)
        @Expect(heartbeatSource.contains("gcmPluginLeaseHeartbeatOnce"), true)
    }

    @TestCase
    public func p2u001OrphanCapabilityRemainsAsHistoricalDiagnosticCompatibility(): Unit {
        // T-P2-U-001
        let records = buildGitCodeMonitorCapabilityDeclarations()
        var orphanDescription = ""
        for (record in records) {
            if (record.capabilityId == "gitcode.monitor.orphan_detected") {
                orphanDescription = record.description
            }
        }
        @Expect(orphanDescription.isEmpty(), false)
        @Expect(orphanDescription.contains("historical"), true)
        @Expect(orphanDescription.contains("diagnostic"), true)
        @Expect(orphanDescription.contains("no longer"), true)
        @Expect(orphanDescription.contains("built-in watchdog"), true)
        @Expect(buildGitCodeMonitorServicePluginManifest().contains("gitcode.monitor.orphan_detected"), true)
        @Expect(validateGitCodeMonitorCapabilitySet(records).ok, true)
    }

    @TestCase
    public func p2n001ProductionIdleStdioPathDoesNotEmitOrphanFrame(): Unit {
        // T-P2-N-001
        let dir = tempRuntimeDir("gcm-p2-n001-no-orphan")
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = dir.join("state.json").toString()
        config.webhook = WebhookReceiverConfig(enabled: false, queueDir: dir.join("queue").toString())
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        let statusFrame = ServiceFrame("request", "status-p2-n001", GCM_SERVICE_PLUGIN_ID, method: "invokeCapability", capabilityId: "gitcode.monitor.status", correlationId: "corr-p2-n001-status", payload: "{}")
        let stopFrame = ServiceFrame("request", "stop-p2-n001", GCM_SERVICE_PLUGIN_ID, method: "stop", correlationId: "corr-p2-n001-stop", payload: "{}")
        let out = handleGcmPluginInputLinesForTest([encodeServiceFrame(statusFrame).trimAscii(), encodeServiceFrame(stopFrame).trimAscii()], config, runtime, state)

        @Expect(out.size, 2)
        for (line in out) {
            @Expect(line.contains("gitcode.monitor.orphan_detected"), false)
            @Expect(line.contains("orphan_detected"), false)
        }
        let runtimeSource = readFixture("src/plugin_runtime.cj")
        @Expect(runtimeSource.contains("gcmPluginOrphanDetectedFrame("), false)
        @Expect(runtimeSource.contains("GcmPluginWatchdogRuntime"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func configResolutionSecretSummaryAndValidationAreExplicit(): Unit {
        @Expect(resolveGcmPluginConfig("").ok, false)
        let config = defaultConfig()
        config.gitCodeToken = "fake-token"
        config.mcpServiceToken = "metis-token"
        config.fullScanIntervalMinutes = 10
        let secret = summarizeGcmSecretState(config)
        @Expect(secret.gitCodeAuth, "present")
        @Expect(secret.mcpAuth, "present")
        let summary = summarizeGcmPluginModeConfig(config).text
        @Expect(summary.contains("fake-token"), false)
        @Expect(summary.contains("legacyNotify"), false)
        @Expect(summary.contains("telegram"), false)
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
        @Expect(status.summary.contains("baselineScopes=0"), true)
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
    public func scanPayloadRejectsStringBooleanArrayAndOversizePayloads(): Unit {
        @Expect(scanResponsePayloadFor("{\"offlineFixture\":true}").contains("\"status\":\"ok\""), true)
        @Expect(scanResponsePayloadFor("{\"offlineFixture\":\"true\"}").contains("\"status\":\"invalid_payload\""), true)
        @Expect(scanResponsePayloadFor("[]").contains("\"status\":\"invalid_payload\""), true)
        @Expect(scanResponsePayloadFor("{\"overlap\":\"true\"}").contains("\"status\":\"invalid_payload\""), true)

        let filler = StringBuilder()
        for (_ in 0..16386) { filler.append("x") }
        let oversize = "{\"offlineFixture\":true,\"pad\":\"${filler.toString()}\"}"
        @Expect(scanResponsePayloadFor(oversize).contains("\"status\":\"invalid_payload\""), true)
    }

    @TestCase
    public func writebackPayloadParsesEscapedStringsAndBooleansStructurally(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.autoReply = true
        config.dryRun = false
        config.writebackScope.allowedRepos = ["Cangjie/community"]
        let writer = FakeCommentWriter()
        let runtime = GcmRuntime(config, writer: writer)
        let draft = "line one\nline two \"quoted\""
        let payload = "{" +
            "\"eventId\":\"e1\"," +
            "\"repo\":\"Cangjie/community\"," +
            "\"kind\":\"issue\"," +
            "\"number\":\"1\"," +
            "\"url\":\"https://gitcode.com/Cangjie/community/issues/1\"," +
            "\"draft\":\"${jsonEscape(draft)}\"," +
            "\"safety\":\"approved\"," +
            "\"needsHumanReview\":false," +
            "\"duplicate\":false" +
            "}"
        let applied = handleGcmWritebackApplyResult(payload, runtime)
        @Expect(applied.ok, true)
        @Expect(applied.writerCalled, true)
        @Expect(writer.written.size, 1)
        @Expect(writer.written[0].contains("line two \"quoted\""), true)
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
    public func pluginLoopKeepsFakeNetworkWarningsInsideResponseFrames(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempConfigPath("gcm-plugin-warning-state")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        let warning = "2026-05-30T00:54:06.196142+08:00 WARN [HttpEngine1#connect] TLS handshake error, the connection is closed."
        fakeSender.nextResponse = HttpResponseSpec(599, body: warning)
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let scanFrame = ServiceFrame(
            "request",
            "scan-warning",
            GCM_SERVICE_PLUGIN_ID,
            method: "invokeCapability",
            capabilityId: "gitcode.monitor.scan_once",
            correlationId: "corr-warning",
            payload: "{}"
        )
        let out = handleGcmPluginInputLinesForTest([encodeServiceFrame(scanFrame).trimAscii()], config, runtime, state)
        @Expect(out.size, 1)
        @Expect(out[0] != warning, true)
        @Expect(out[0].startsWith("{"), true)
        @Expect(decodeServiceFrame(out[0]).ok, true)
        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
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
        config.writebackScope.allowedRepos = ["Cangjie/community"]
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "safe", safety: "rejected"), config).reason, "safety_rejected")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "safe", needsHumanReview: true), config).reason, "needs_human_review")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "safe", duplicate: true), config).reason, "duplicate")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "token=secret"), config).reason, "secret_detected")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "/Users/name/file"), config).reason, "local_path_detected")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, ""), config).reason, "draft_empty")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("e1", "Cangjie/community", "issue", "1", request.url, "safe", parseStatus: "draft_too_large"), config).reason, "draft_too_large")
        // DRAFT-M4-U-001
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("draft-m4-u-001", "Cangjie/community", "issue", "1", request.url, "{\"tool\":\"functions._answer_\",\"reason\":\"x\"}", safety: "approved"), config).reason, "draft_invalid_tool_json")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("draft-m4-u-002", "Cangjie/community", "issue", "1", request.url, "{\"reason\":\"_answer_\"}", safety: "approved"), config).reason, "draft_invalid_tool_json")
        // DRAFT-M4-B-001
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("draft-m4-b-001", "Cangjie/community", "issue", "1", request.url, "[\"x\"]", safety: "approved"), config).reason, "draft_raw_json")
        // DRAFT-M4-N-001
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("draft-m4-n-001", "Cangjie/community", "issue", "1", request.url, "{\"result\":\"x\"}", safety: "approved"), config).reason, "draft_raw_json")
        // DRAFT-M4-N-002
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("draft-m4-n-002", "Cangjie/community", "issue", "1", request.url, "auto-reply by gitcodemonitor", safety: "approved"), config).reason, "draft_forbidden_marker")
        // DRAFT-M4-P-001
        @Expect(evaluateGcmAutoReplyGate(request, config).reason, "allow_write")
    }

    @TestCase
    public func autoReplyGateUsesWritebackScopeForOrgAllowDenyAndUnsafeDrafts(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.autoReply = true
        config.dryRun = false
        config.writebackScope.allowedOrgs = ["cangjie"]
        let request = GcmWritebackRequest("wb-scope-p2-pos-002", "Cangjie/community", "issue", "1", "https://gitcode.com/Cangjie/community/issues/1", "safe draft", safety: "approved")
        @Expect(evaluateGcmAutoReplyGate(request, config).allowed, true)
        @Expect(evaluateGcmAutoReplyGate(request, config).reason, "allow_write")

        config.writebackScope.deniedRepos = ["Cangjie/community"]
        let denied = evaluateGcmAutoReplyGate(request, config)
        @Expect(denied.allowed, false)
        @Expect(denied.reason, "repo_denied_by_writeback_scope")

        config.writebackScope.deniedRepos = []
        let otherOrg = GcmWritebackRequest("wb-scope-p4-bnd-001", "CangjieSig/community", "issue", "1", request.url, "safe draft", safety: "approved")
        @Expect(evaluateGcmAutoReplyGate(otherOrg, config).reason, "repo_not_allowlisted")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("wb-scope-p4-neg-001", "Cangjie/community", "issue", "1", request.url, "safe draft", safety: "rejected"), config).reason, "safety_rejected")
        @Expect(evaluateGcmAutoReplyGate(GcmWritebackRequest("wb-scope-p4-neg-002", "Cangjie/community", "issue", "1", request.url, "Authorization: Bearer secret", safety: "approved"), config).reason, "secret_detected")
    }

    @TestCase
    public func writebackApplyUsesFakeWriterOnlyWhenGateAllows(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.autoReply = true
        config.dryRun = false
        config.writebackScope.allowedRepos = ["Cangjie/community"]
        let writer = FakeCommentWriter()
        let runtime = GcmRuntime(config, writer: writer)
        let payload = "{\"eventId\":\"e1\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"1\",\"url\":\"https://gitcode.com/Cangjie/community/issues/1\",\"draft\":\"safe draft\",\"safety\":\"approved\"}"
        let applied = handleGcmWritebackApplyResult(payload, runtime)
        @Expect(applied.ok, true)
        @Expect(applied.writerCalled, true)
        @Expect(applied.posted, true)
        @Expect(writer.written.size, 1)
        @Expect(writer.written[0].contains(SELF_MARKER), false)

        let blocked = handleGcmWritebackApplyResult(payload.replace("\"approved\"", "\"rejected\""), runtime)
        @Expect(blocked.writerCalled, false)
        @Expect(blocked.decision.reason, "safety_rejected")
    }

    @TestCase
    public func p0p2WritebackBodyIsNaturalAndPostedResultRecordsLedger(): Unit {
        // T-P0-U-001, T-P2-U-001, T-P7-E2E-003
        let dir = tempRuntimeDir("gcm-p2-writeback-runtime-ledger")
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = dir.join("state.json").toString()
        config.autoReply = true
        config.dryRun = false
        config.writebackScope.allowedRepos = ["Cangjie/community"]
        let writer = FakeCommentWriter()
        let runtime = GcmRuntime(config, writer: writer)
        let payload = "{\"eventId\":\"source-event-runtime\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"4\",\"url\":\"https://gitcode.com/Cangjie/community/issues/4\",\"draft\":\"natural reply body\",\"safety\":\"approved\"}"

        let applied = handleGcmWritebackApplyResult(payload, runtime)

        @Expect(applied.ok, true)
        @Expect(applied.posted, true)
        @Expect(writer.written.size, 1)
        @Expect(writer.written[0].contains("auto-reply"), false)
        @Expect(writer.written[0].contains("auto reply"), false)
        @Expect(writer.written[0].contains("automatic reply"), false)
        @Expect(writer.written[0].toAsciiLower().contains("gitcodemonitor"), false)
        @Expect(writer.written[0].contains("generated-by"), false)
        @Expect(writer.written[0].contains("bot attribution"), false)
        @Expect(writer.written[0].contains("<!--"), false)
        let ledgerPath = writebackLedgerPathForConfig(config)
        @Expect(exists(Path(ledgerPath)), true)
        let ledgerText = String.fromUtf8(File.readFrom(Path(ledgerPath)))
        @Expect(ledgerText.contains("source-event-runtime"), true)
        @Expect(ledgerText.contains("natural reply body"), false)
        @Expect(ledgerText.contains("auto-reply"), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p0NoProductionWriteHelperCanAppendSelfMarker(): Unit {
        // T-P0-U-001 regression: only read-compatible marker helpers may remain.
        let source = readFixture("src/plugin_runtime.cj")
        @Expect(source.contains("func appendGcmSelfMarker"), false)
        @Expect(source.contains("body + \"\\n\\n\" + SELF_MARKER"), false)
        @Expect(source.contains("func hasGcmSelfMarker"), true)
    }

    @TestCase
    public func p2WritebackLedgerAndAuditRedactSecretReplyUrls(): Unit {
        // T-P2-U-001, T-P3-U-001
        let dir = tempRuntimeDir("gcm-p2-secret-reply-url")
        let config = defaultConfig()
        config.statePath = dir.join("state.json").toString()
        let secretUrl = "https://gitcode.com/Cangjie/community/issues/4#note_1?access_token=secret-token"
        let ledgerPath = writebackLedgerPathForConfig(config)

        @Expect(recordWriteback(ledgerPath, "Cangjie/community", "issue", "4", secretUrl, "safe body", "source-secret", nowMs: 1000).ok, true)
        let ledgerText = String.fromUtf8(File.readFrom(Path(ledgerPath)))
        @Expect(ledgerText.contains("secret-token"), false)
        @Expect(ledgerText.contains("access_token"), false)
        @Expect(ledgerText.contains(secretUrl), false)

        let audit = buildGcmWritebackAudit(GcmWritebackRequest("source-secret", "Cangjie/community", "issue", "4", "https://gitcode.com/Cangjie/community/issues/4", "safe body"), GcmWritebackDecision(true, "posted"), replyUrl: secretUrl)
        let host = MetisHostClient()
        let emitted = emitGcmWritebackAudit(audit, host)
        @Expect(emitted.ok, true)
        @Expect(emitted.frame.payload.contains("secret-token"), false)
        @Expect(emitted.frame.payload.contains("access_token"), false)
        @Expect(emitted.frame.payload.contains(secretUrl), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func writebackApplyResultHonorsOrgScopeDeniedReposAndLegacyAllowlist(): Unit {
        let payload = "{\"eventId\":\"wb-scope-p4-e2e\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"1\",\"url\":\"https://gitcode.com/Cangjie/community/issues/1\",\"draft\":\"safe draft\",\"safety\":\"approved\"}"

        let orgConfig = defaultConfig()
        orgConfig.fullScanIntervalMinutes = 10
        orgConfig.autoReply = true
        orgConfig.dryRun = false
        orgConfig.writebackScope.allowedOrgs = ["cangjie"]
        let orgWriter = FakeCommentWriter()
        let orgRuntime = GcmRuntime(orgConfig, writer: orgWriter)
        let orgApplied = handleGcmWritebackApplyResult(payload, orgRuntime)
        @Expect(orgApplied.writerCalled, true)
        @Expect(orgApplied.posted, true)
        @Expect(orgWriter.written.size, 1)

        let deniedConfig = defaultConfig()
        deniedConfig.fullScanIntervalMinutes = 10
        deniedConfig.autoReply = true
        deniedConfig.dryRun = false
        deniedConfig.writebackScope.allowedOrgs = ["cangjie"]
        deniedConfig.writebackScope.deniedRepos = ["Cangjie/community"]
        let deniedWriter = FakeCommentWriter()
        let deniedRuntime = GcmRuntime(deniedConfig, writer: deniedWriter)
        let deniedApplied = handleGcmWritebackApplyResult(payload, deniedRuntime)
        @Expect(deniedApplied.writerCalled, false)
        @Expect(deniedApplied.decision.reason, "repo_denied_by_writeback_scope")
        @Expect(deniedWriter.written.size, 0)

        let legacyConfig = defaultConfig()
        legacyConfig.fullScanIntervalMinutes = 10
        legacyConfig.autoReply = true
        legacyConfig.dryRun = false
        legacyConfig.repoAllowlist = ["Cangjie/community"]
        let legacyApplied = handleGcmWritebackApplyResult(payload, GcmRuntime(legacyConfig))
        @Expect(legacyApplied.writerCalled, false)
        @Expect(legacyApplied.decision.reason, "repo_not_allowlisted")

        let otherOrgConfig = defaultConfig()
        otherOrgConfig.fullScanIntervalMinutes = 10
        otherOrgConfig.autoReply = true
        otherOrgConfig.dryRun = false
        otherOrgConfig.writebackScope.allowedOrgs = ["cangjie-sig"]
        let otherOrgApplied = handleGcmWritebackApplyResult(payload, GcmRuntime(otherOrgConfig))
        @Expect(otherOrgApplied.writerCalled, false)
        @Expect(otherOrgApplied.decision.reason, "repo_not_allowlisted")

        let rejected = handleGcmWritebackApplyResult(payload.replace("\"approved\"", "\"rejected\""), GcmRuntime(orgConfig))
        @Expect(rejected.writerCalled, false)
        @Expect(rejected.decision.reason, "safety_rejected")

        let secret = handleGcmWritebackApplyResult(payload.replace("safe draft", "Authorization: Bearer secret"), GcmRuntime(orgConfig))
        @Expect(secret.writerCalled, false)
        @Expect(secret.decision.reason, "secret_detected")
    }

    @TestCase
    public func writebackHelpersBuildRequestsMarkerAndAuditsWithoutSecrets(): Unit {
        let request = GcmWritebackRequest("e2", "Cangjie/stdx", "pr", "2", "https://gitcode.com/Cangjie/stdx/pulls/2", "draft", teamLeaderMentions: ["@alice"], codeownerMentions: ["@bob"])
        let write = buildGitCodeCommentWriteRequest(request)
        @Expect(write.credentialScope, "gcm-internal")
        @Expect(write.body.contains(SELF_MARKER), false)
        @Expect(hasGcmSelfMarker(write.body), false)
        @Expect(write.body.contains("@alice，@bob"), true)
        let audit = buildGcmWritebackAudit(request, GcmWritebackDecision(false, "dry_run"))
        @Expect(audit.bodyHash.startsWith("payload-"), true)
        let host = MetisHostClient()
        let emitted = emitGcmWritebackAudit(audit, host)
        @Expect(emitted.ok, true)
        @Expect(emitted.frame.capabilityId, "gitcode.writeback.audit")
        @Expect(emitted.frame.payload.contains("draft"), false)

        let client = GitCodeApiClient(baseUrl: "https://gitcode.example/api/v5")
        let prPost = client.postCommentRequest(GitCodeEvent("e-pr", "Cangjie", "stdx", "pr", "2", "", "", "", ""), write.body)
        @Expect(prPost.url, "https://gitcode.example/api/v5/repos/Cangjie/stdx/pulls/2/comments")
        @Expect(prPost.body.contains(SELF_MARKER), false)
        let issuePost = client.postCommentRequest(GitCodeEvent("e-issue", "Cangjie", "stdx", "issue", "3", "", "", "", ""), "body")
        @Expect(issuePost.url, "https://gitcode.example/api/v5/repos/Cangjie/stdx/issues/3/comments")
        @Expect(issuePost.body.contains(SELF_MARKER), false)
    }

    @TestCase
    public func maintainerMentionBuildersCoverNaturalFooterAndNotificationPlan(): Unit {
        let sanitized = sanitizeMentionList(["alice", "@Bob", "@alice", "@bad:name", "", "@carol.dev"])
        @Expect(sanitized.size, 3)
        @Expect(sanitized[0], "@alice")
        @Expect(sanitized[1], "@Bob")
        @Expect(sanitized[2], "@carol.dev")

        let teamOnly = buildMaintainerMentionSentence("T-WRITEBACK-001", "issue", teamLeaderMentions: ["@alice", "@bob"])
        @Expect(teamOnly.sentence.contains("@alice，@bob"), true)
        @Expect(teamOnly.sentence.endsWith("。"), true)
        @Expect(teamOnly.sentence.contains("---"), false)
        @Expect(teamOnly.sentence.contains("@Team Leader:"), false)
        @Expect(teamOnly.sentence.contains("@Codeowner:"), false)
        @Expect(teamOnly.sentence.contains("auto-reply"), false)
        @Expect(teamOnly.sentence.contains("gitcodemonitor"), false)
        @Expect(teamOnly.sentence.contains("<!--"), false)

        let mixed = buildMaintainerMentionSentence("T-WRITEBACK-002", "pr", teamLeaderMentions: ["@alice"], codeownerMentions: ["@carol", "@dave", "@alice"])
        @Expect(mixed.mentions.size, 3)
        @Expect(mixed.sentence.contains("@alice，@carol，@dave"), true)

        let invalid = buildMaintainerMentionSentence("T-WRITEBACK-003", "issue", teamLeaderMentions: ["bad:name"], codeownerMentions: ["@bad/name"])
        @Expect(invalid.sentence, "")
        @Expect(invalid.diagnostics[0], "maintainer_mention_unavailable")

        let appended = appendMaintainerMentionSentence("分析结果  \n", teamOnly.sentence)
        @Expect(appended.appended, true)
        @Expect(appended.body.contains("\n\n"), false)
        @Expect(appended.body.endsWith(teamOnly.sentence), true)
        let dedup = appendMaintainerMentionSentence(appended.body, teamOnly.sentence)
        @Expect(dedup.appended, false)
        @Expect(dedup.diagnostics[0], "maintainer_mention_already_present")

        let mentionOnly = buildMaintainerNotificationPlan(["@alice"], emails: [], emailNotificationEnabled: false)
        @Expect(mentionOnly.mentionPlan.size, 1)
        @Expect(mentionOnly.emailPlan.size, 0)
        @Expect(mentionOnly.emailNotificationStatus, "email_disabled")
        let emailReady = buildMaintainerNotificationPlan(["@alice"], emails: ["alice@example.com"], emailNotificationEnabled: true)
        @Expect(emailReady.emailPlan.size, 1)
        @Expect(emailReady.emailNotificationStatus, "ready")
        let emailInvalid = buildMaintainerNotificationPlan(["@alice"], emails: ["bad email"], emailNotificationEnabled: true)
        @Expect(emailInvalid.emailPlan.size, 0)
        @Expect(emailInvalid.emailNotificationStatus, "email_unavailable")
        @Expect(emailInvalid.diagnostics[0], "invalid_email")
    }

    @TestCase
    public func writebackApplyResultCoversGeneratedReplyV1GatesAndStructuredResponse(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.autoReply = true
        config.dryRun = false
        config.writebackScope.allowedRepos = ["Cangjie/community"]
        let writer = FakeCommentWriter()
        let runtime = GcmRuntime(config, writer: writer)
        let payload = "{" +
            "\"contractVersion\":\"gcm-metis-gitcode-review-v1\"," +
            "\"generatedReply\":{\"eventId\":\"e-generated\",\"repo\":\"Cangjie/community\",\"kind\":\"pr\",\"number\":\"8\",\"url\":\"https://gitcode.com/Cangjie/community/pulls/8\",\"draft\":\"初步看没有发现阻塞问题。\",\"safety\":\"approved\",\"needsHumanReview\":false}," +
            "\"reviewRequest\":{\"maintainers\":{\"teamLeaders\":[\"@alice\"],\"codeowners\":[{\"mention\":\"@carol\"},{\"mention\":\"@alice\"}]}}" +
            "}"
        let applied = handleGcmWritebackApplyResult(payload, runtime)
        @Expect(applied.ok, true)
        @Expect(applied.writerCalled, true)
        @Expect(applied.posted, true)
        @Expect(applied.maintainerMentionAppended, true)
        @Expect(applied.teamLeaderCount, 1)
        @Expect(applied.codeownerCount, 2)
        @Expect(writer.written[0].contains("@alice，@carol"), true)
        @Expect(writer.written[0].contains("auto-reply"), false)
        @Expect(writer.written[0].contains("gitcodemonitor"), false)
        @Expect(writer.written[0].contains("<!--"), false)

        // DRAFT-M4-U-001
        let toolJson = handleGcmWritebackApplyResult(payload.replace("初步看没有发现阻塞问题。", "{\\\"tool\\\":\\\"functions._answer_\\\",\\\"reason\\\":\\\"x\\\"}"), GcmRuntime(config))
        @Expect(toolJson.writerCalled, false)
        @Expect(toolJson.decision.reason, "draft_invalid_tool_json")
        // DRAFT-M4-B-001
        let rawArrayJson = handleGcmWritebackApplyResult(payload.replace("初步看没有发现阻塞问题。", "[\\\"x\\\"]"), GcmRuntime(config))
        @Expect(rawArrayJson.writerCalled, false)
        @Expect(rawArrayJson.decision.reason, "draft_raw_json")
        // DRAFT-M4-N-001
        let rawObjectJson = handleGcmWritebackApplyResult(payload.replace("初步看没有发现阻塞问题。", "{\\\"result\\\":\\\"x\\\"}"), GcmRuntime(config))
        @Expect(rawObjectJson.writerCalled, false)
        @Expect(rawObjectJson.decision.reason, "draft_raw_json")
        // DRAFT-M4-N-002
        let forbiddenMarker = handleGcmWritebackApplyResult(payload.replace("初步看没有发现阻塞问题。", "auto-reply by gitcodemonitor"), GcmRuntime(config))
        @Expect(forbiddenMarker.writerCalled, false)
        @Expect(forbiddenMarker.decision.reason, "draft_forbidden_marker")

        let human = handleGcmWritebackApplyResult(payload.replace("\"needsHumanReview\":false", "\"needsHumanReview\":true"), GcmRuntime(config))
        @Expect(human.writerCalled, false)
        @Expect(human.decision.reason, "needs_human_review")
        let rejected = handleGcmWritebackApplyResult(payload.replace("\"approved\"", "\"rejected\""), GcmRuntime(config))
        @Expect(rejected.writerCalled, false)
        @Expect(rejected.decision.reason, "safety_rejected")
        let secret = handleGcmWritebackApplyResult(payload.replace("初步看没有发现阻塞问题。", "token=secret"), GcmRuntime(config))
        @Expect(secret.writerCalled, false)
        @Expect(secret.decision.reason, "secret_detected")
        let localPath = handleGcmWritebackApplyResult(payload.replace("初步看没有发现阻塞问题。", "/Users/alice/project/file.cj"), GcmRuntime(config))
        @Expect(localPath.writerCalled, false)
        @Expect(localPath.decision.reason, "local_path_detected")
        let empty = handleGcmWritebackApplyResult(payload.replace("初步看没有发现阻塞问题。", ""), GcmRuntime(config))
        @Expect(empty.writerCalled, false)
        @Expect(empty.decision.reason, "draft_empty")

        let dry = defaultConfig()
        dry.fullScanIntervalMinutes = 10
        dry.autoReply = true
        dry.dryRun = true
        dry.writebackScope.allowedRepos = ["Cangjie/community"]
        @Expect(handleGcmWritebackApplyResult(payload, GcmRuntime(dry)).decision.reason, "dry_run")
        let disabled = defaultConfig()
        disabled.fullScanIntervalMinutes = 10
        disabled.autoReply = false
        disabled.dryRun = false
        disabled.writebackScope.allowedRepos = ["Cangjie/community"]
        @Expect(handleGcmWritebackApplyResult(payload, GcmRuntime(disabled)).decision.reason, "auto_reply_disabled")

        let apiWriter = FakeCommentWriter()
        apiWriter.nextStatus = "gitcode_api_forbidden"
        let apiRuntime = GcmRuntime(config, writer: apiWriter)
        let forbidden = handleGcmWritebackApplyResult(payload, apiRuntime)
        @Expect(forbidden.writerCalled, true)
        @Expect(forbidden.posted, false)
        @Expect(forbidden.decision.reason, "gitcode_api_forbidden")
        @Expect(forbidden.retryable, false)

        let big = StringBuilder()
        for (_ in 0..33000) { big.append("x") }
        let tooLarge = handleGcmWritebackApplyResult(payload.replace("初步看没有发现阻塞问题。", big.toString()), GcmRuntime(config))
        @Expect(tooLarge.writerCalled, false)
        @Expect(tooLarge.decision.reason, "draft_too_large")
        let malformed = handleGcmWritebackApplyResult("{not-json", GcmRuntime(config))
        @Expect(malformed.ok, false)
        @Expect(malformed.writerCalled, false)
        @Expect(malformed.decision.reason, "invalid_payload")
    }

    @TestCase
    public func writebackResponseFrameAndWebhookDiagnosticsExposeNewCounters(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.autoReply = true
        config.dryRun = false
        config.writebackScope.allowedOrgs = ["cangjie"]
        config.writebackScope.allowedRepos = ["Cangjie/compiler"]
        config.writebackScope.deniedRepos = ["Cangjie/experimental", "Cangjie/playground"]
        config.repoAllowlist = ["Cangjie/community"]
        let runtime = RuntimeContainer(config)
        let state = MonitorState()
        state.addAudit(AuditRecord("corp", status: "record_only", reason: "corporate_author"))
        state.addAudit(AuditRecord("accepted", status: "accepted"))
        state.addAudit(AuditRecord("posted", status: "writeback_posted"))
        state.addAudit(AuditRecord("skipped", status: "writeback_skipped", reason: "dry_run"))
        state.addAudit(AuditRecord("mention", status: "maintainer_mention_skipped", reason: "maintainer_mention_unavailable"))
        let status = handleGcmStatusCapability("{}", GcmRuntime(config, state: state))
        @Expect(status.summary.contains("recordOnly=1"), true)
        @Expect(status.summary.contains("accepted=1"), true)
        @Expect(status.summary.contains("writebackPosted=1"), true)
        @Expect(status.summary.contains("maintainerMentionSkipped=1"), true)
        @Expect(status.summary.contains("allowedOrgs=1"), true)
        @Expect(status.summary.contains("allowedRepos=1"), true)
        @Expect(status.summary.contains("deniedRepos=2"), true)
        @Expect(status.summary.contains("legacyRepoAllowlist=1"), true)

        let payload = webhookStatusPayload(config, WebhookQueue(config.webhook.queueDir), state: Some<MonitorState>(state))
        @Expect(payload.contains("\"recordOnlyCount\":1"), true)
        @Expect(payload.contains("\"acceptedCount\":1"), true)
        @Expect(payload.contains("\"writebackPostedCount\":1"), true)
        @Expect(payload.contains("\"writebackSkippedCount\":1"), true)
        @Expect(payload.contains("\"maintainerMentionSkippedCount\":1"), true)
        @Expect(payload.contains("token="), false)

        let frame = ServiceFrame(
            "request",
            "writeback-frame",
            GCM_SERVICE_PLUGIN_ID,
            method: "invokeCapability",
            capabilityId: "gitcode.writeback.apply_result",
            correlationId: "corr-writeback",
            payload: "{\"eventId\":\"e-frame\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"1\",\"url\":\"https://gitcode.com/Cangjie/community/issues/1\",\"draft\":\"safe\",\"safety\":\"approved\",\"teamLeaders\":[\"@alice\"]}"
        )
        let handled = handleGcmPluginInputLine(encodeServiceFrame(frame).trimAscii(), config, runtime, state)
        @Expect(handled.frame.payload.contains("\"writerCalled\":true"), true)
        @Expect(handled.frame.payload.contains("\"maintainerMentionAppended\":true"), true)
        @Expect(handled.frame.payload.contains("\"teamLeaderCount\":1"), true)
    }

    @TestCase
    public func writebackApplyResultUsesRuntimeWriterHttpSenderAndPersistsState(): Unit {
        // T-ROOT-004, T-WRITER-006, T-WRITER-008
        let dir = tempRuntimeDir("gcm-plugin-writeback-real-writer")
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.autoReply = true
        config.dryRun = false
        config.statePath = dir.join("state.json").toString()
        config.gitCodeBaseUrl = "https://gitcode.example/api/v5"
        config.writebackScope.allowedRepos = ["Cangjie/community"]
        let sender = FakeHttpSender()
        sender.nextResponse = HttpResponseSpec(201, body: "{\"html_url\":\"https://gitcode.com/Cangjie/community/issues/3#note_9\"}")
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let frame = ServiceFrame(
            "request",
            "writeback-real-writer",
            GCM_SERVICE_PLUGIN_ID,
            method: "invokeCapability",
            capabilityId: "gitcode.writeback.apply_result",
            correlationId: "corr-writeback-real-writer",
            payload: "{\"eventId\":\"real-writer-e1\",\"repo\":\"Cangjie/community\",\"kind\":\"issue\",\"number\":\"3\",\"url\":\"https://gitcode.com/Cangjie/community/issues/3\",\"draft\":\"safe draft\",\"safety\":\"approved\",\"needsHumanReview\":false}"
        )

        let handled = handleGcmPluginInputLineWithJobs(encodeServiceFrame(frame).trimAscii(), config, runtime, state, GcmScanJobStore(maxConcurrent: 1))

        @Expect(handled.ok, true)
        @Expect(handled.frame.payload.contains("\"posted\":true"), true)
        @Expect(sender.requests.size, 1)
        @Expect(sender.requests[0].method, "POST")
        @Expect(sender.requests[0].url, "https://gitcode.example/api/v5/repos/Cangjie/community/issues/3/comments")
        @Expect(sender.requests[0].body.contains("safe draft"), true)
        @Expect(state.hasReply("real-writer-e1"), true)
        @Expect(exists(Path(config.statePath)), true)
        @Expect(String.fromUtf8(File.readFrom(Path(config.statePath))).contains("writeback_posted"), true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func writebackScopeSummaryAndPluginModeValidationUseScopeDiagnostics(): Unit {
        let config = defaultConfig()
        config.gitCodeToken = "token-secret"
        config.gitCodeCookie = "cookie-secret"
        config.writebackScope.allowedOrgs = ["cangjie", "cangjie-sig", "cangjie-tpc"]
        config.writebackScope.allowedRepos = ["Cangjie/community"]
        config.writebackScope.deniedRepos = ["Cangjie/experimental", "Cangjie/playground"]
        let summary = writebackScopeSummary(config)
        @Expect(summary.contains("allowedOrgs=3 allowedRepos=1 deniedRepos=2"), true)
        @Expect(summary.contains("legacyRepoAllowlist=0"), true)
        @Expect(summary.contains("token-secret"), false)
        @Expect(summary.contains("cookie-secret"), false)

        let liveNoAllow = defaultConfig()
        liveNoAllow.fullScanIntervalMinutes = 10
        liveNoAllow.autoReply = true
        liveNoAllow.dryRun = false
        let validation = validateGcmPluginModeConfig(liveNoAllow)
        @Expect(validation.ok, false)
        @Expect(joinDiagnostics(validation.diagnostics).contains("writebackScope has no allowed orgs or repos"), true)
        @Expect(joinDiagnostics(validation.diagnostics).contains("repoAllowlist required"), false)

        let denyOnly = defaultConfig()
        denyOnly.fullScanIntervalMinutes = 10
        denyOnly.autoReply = true
        denyOnly.dryRun = false
        denyOnly.writebackScope.deniedRepos = ["Cangjie/community"]
        @Expect(joinDiagnostics(validateGcmPluginModeConfig(denyOnly).diagnostics).contains("writebackScope has no allowed orgs or repos"), true)

        let invalid = defaultConfig()
        invalid.fullScanIntervalMinutes = 10
        invalid.writebackScope.allowedOrgs = ["Cangjie/community"]
        @Expect(joinDiagnostics(validateGcmPluginModeConfig(invalid).diagnostics).contains("writebackScope invalid org scope: Cangjie/community"), true)
    }

    @TestCase
    public func deletedNotificationAndMcpDiagnosticModesStayOutOfPrimaryPath(): Unit {
        let config = defaultConfig()
        let summary = summarizeGcmPluginModeConfig(config).text
        @Expect(summary.contains("legacyNotify"), false)
        @Expect(summary.contains("feishu"), false)
        @Expect(summary.contains("telegram"), false)
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
