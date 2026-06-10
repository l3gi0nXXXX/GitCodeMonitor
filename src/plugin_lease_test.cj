package gitcodemonitor

import std.fs.{Directory, File, Path, exists, remove}
import std.time.*
import std.unittest.testmacro.*

@Test
public class GitCodeMonitorPluginLeaseTest {
    private func tempDir(name: String): Path {
        let dir = Path("/tmp").join("${name}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}")
        Directory.create(dir, recursive: true)
        dir
    }

    @TestCase
    public func oprU002LeaseRoundtripMarkRemoveAndStaleClassification(): Unit {
        // GCM-LISTENER-N-001
        let dir = tempDir("gcm-lease-u002")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(
            GCM_SERVICE_PLUGIN_ID,
            "session-u002",
            1001,
            2002,
            "127.0.0.1",
            19081,
            10000,
            10000,
            "running",
            ""
        )
        @Expect(writeGcmPluginLease(path, lease).ok, true)
        let loaded = readGcmPluginLease(path)
        @Expect(loaded.ok, true)
        @Expect(loaded.lease.pluginId, GCM_SERVICE_PLUGIN_ID)
        @Expect(loaded.lease.sessionId, "session-u002")
        @Expect(loaded.lease.pid, 1001)
        @Expect(loaded.lease.parentPid, 2002)
        @Expect(loaded.lease.bindHost, "127.0.0.1")
        @Expect(loaded.lease.port, 19081)
        @Expect(loaded.lease.state, "running")

        let fresh = classifyGcmPluginLease(loaded.lease, 15000, heartbeatTtlMs: 10000)
        @Expect(fresh.status, "running")
        let stale = classifyGcmPluginLease(loaded.lease, 25001, heartbeatTtlMs: 10000)
        @Expect(stale.status, "stale")

        @Expect(markGcmPluginLeaseStopped(path, nowMs: 26000).ok, true)
        @Expect(readGcmPluginLease(path).lease.state, "stopped")
        @Expect(removeGcmPluginLease(path).ok, true)
        @Expect(exists(Path(path)), false)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p2u002LeaseBaseRecordSemanticsStayStable(): Unit {
        // T-P2-U-002
        let dir = tempDir("gcm-p2-u002-lease-semantics")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(
            GCM_SERVICE_PLUGIN_ID,
            "session-p2-u002",
            3001,
            4002,
            "127.0.0.1",
            19095,
            11000,
            12000,
            "running",
            ""
        )

        @Expect(writeGcmPluginLease(path, lease).ok, true)
        let loaded = readGcmPluginLease(path)
        @Expect(loaded.ok, true)
        @Expect(loaded.lease.pluginId, GCM_SERVICE_PLUGIN_ID)
        @Expect(loaded.lease.sessionId, "session-p2-u002")
        @Expect(loaded.lease.pid, 3001)
        @Expect(loaded.lease.parentPid, 4002)
        @Expect(loaded.lease.bindHost, "127.0.0.1")
        @Expect(loaded.lease.port, 19095)
        @Expect(loaded.lease.startedAtMs, 11000)
        @Expect(loaded.lease.lastHeartbeatMs, 12000)
        @Expect(loaded.lease.state, "running")
        @Expect(loaded.lease.orphanReason, "")
        @Expect(classifyGcmPluginLease(loaded.lease, 12500, heartbeatTtlMs: 10000).status, "running")
        @Expect(markGcmPluginLeaseStopped(path, nowMs: 13000).ok, true)
        let stopped = readGcmPluginLease(path)
        @Expect(stopped.lease.state, "stopped")
        @Expect(stopped.lease.lastHeartbeatMs, 13000)
        @Expect(stopped.lease.orphanReason, "")
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func oprB002ClassifiesPidAndPortOwnerMismatchWithoutKill(): Unit {
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-b002", 1111, 2222, "127.0.0.1", 19082, 10000, 11000, "running", "")
        let missingPid = classifyGcmPluginOwner(lease, GcmPluginOwnerSnapshot(false, false, 0))
        @Expect(missingPid.status, "pid_missing")
        @Expect(missingPid.shouldKill, false)

        let mismatch = classifyGcmPluginOwner(lease, GcmPluginOwnerSnapshot(true, true, 3333))
        @Expect(mismatch.status, "port_owner_mismatch")
        @Expect(mismatch.shouldKill, false)

        let aligned = classifyGcmPluginOwner(lease, GcmPluginOwnerSnapshot(true, true, 1111))
        @Expect(aligned.status, "owner_aligned")
        @Expect(aligned.shouldKill, false)
    }

    @TestCase
    public func oprP002WatchdogTickUpdatesHeartbeatWhenParentAndStdinNormal(): Unit {
        // GCM-ORPHAN-U-001
        let dir = tempDir("gcm-lease-p002")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-p002", 101, 202, "127.0.0.1", 19083, 1000, 1000, "running", "")
        @Expect(writeGcmPluginLease(path, lease).ok, true)
        let context = GcmPluginWatchdogContext(path, lease, GcmPluginOwnerSnapshot(true, false, 0), forceOrphan: false)
        let tick = gcmPluginWatchdogTick(context, nowMs: 2000)
        @Expect(tick.orphanDetected, false)
        @Expect(tick.status, "heartbeat")
        let reloaded = readGcmPluginLease(path).lease
        @Expect(reloaded.lastHeartbeatMs, 2000)
        @Expect(reloaded.state, "running")
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func gcmOrphanB001SingleParentProbeFailureIsOnlySuspect(): Unit {
        // GCM-ORPHAN-B-001
        let dir = tempDir("gcm-orphan-b001")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-b001", 101, 202, "127.0.0.1", 19088, 1000, 1000, "running", "")
        @Expect(writeGcmPluginLease(path, lease).ok, true)

        let snapshot = GcmPluginOwnerSnapshot(false, false, 0, observedParentPid: 0, pidProbeStatus: "probe_unavailable", parentPidProbeStatus: "probe_unavailable")
        let tick = gcmPluginWatchdogTick(GcmPluginWatchdogContext(path, lease, snapshot, parentProbeFailureCount: 0, parentProbeFailureThreshold: 3), nowMs: 2000)

        @Expect(tick.orphanDetected, false)
        @Expect(tick.status, "parent_probe_suspect")
        @Expect(tick.reason, "probe_unavailable")
        let reloaded = readGcmPluginLease(path).lease
        @Expect(reloaded.state, "running")
        @Expect(reloaded.orphanReason, "")
        @Expect(reloaded.lastHeartbeatMs, 2000)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func gcmOrphanB002ObservedParentProbeUnavailableDoesNotCauseParentLost(): Unit {
        // GCM-ORPHAN-B-002
        let dir = tempDir("gcm-orphan-b002")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-b002-watchdog", 101, 202, "127.0.0.1", 19089, 1000, 1000, "running", "")
        @Expect(writeGcmPluginLease(path, lease).ok, true)

        let snapshot = GcmPluginOwnerSnapshot(true, false, 0, observedParentPid: 0, observedParentPidStatus: "probe_unavailable")
        let tick = gcmPluginWatchdogTick(GcmPluginWatchdogContext(path, lease, snapshot, parentProbeFailureCount: 0, parentProbeFailureThreshold: 3), nowMs: 2100)

        @Expect(tick.orphanDetected, false)
        @Expect(tick.status, "parent_probe_suspect")
        @Expect(tick.reason, "probe_unavailable")
        let reloaded = readGcmPluginLease(path).lease
        @Expect(reloaded.state, "running")
        @Expect(reloaded.orphanReason, "")
        @Expect(reloaded.lastHeartbeatMs, 2100)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func oprN002WatchdogMarksOrphanAndBuildsEventFrame(): Unit {
        let dir = tempDir("gcm-lease-n002")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-n002", 101, 202, "127.0.0.1", 19084, 1000, 1000, "running", "")
        @Expect(writeGcmPluginLease(path, lease).ok, true)
        let context = GcmPluginWatchdogContext(path, lease, GcmPluginOwnerSnapshot(false, false, 0), forceOrphan: true)
        let tick = gcmPluginWatchdogTick(context, nowMs: 3000)
        @Expect(tick.orphanDetected, true)
        @Expect(tick.status, "orphan_detected")
        @Expect(tick.reason, "test_injected_orphan")
        let reloaded = readGcmPluginLease(path).lease
        @Expect(reloaded.state, "orphan_detected")
        @Expect(reloaded.orphanReason, "test_injected_orphan")
        let frame = gcmPluginOrphanDetectedFrame(reloaded)
        @Expect(frame.frameType, "event")
        @Expect(frame.capabilityId, "gitcode.monitor.orphan_detected")
        @Expect(frame.payload.contains("\"sessionId\":\"session-n002\""), true)
        @Expect(frame.payload.contains("\"orphanReason\":\"test_injected_orphan\""), true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func gcmOrphanN001WrapperPpidMismatchDoesNotOrphanWhileParentProbeIsSuspect(): Unit {
        // GCM-ORPHAN-N-001
        let dir = tempDir("gcm-orphan-n001")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-n001", 101, 202, "127.0.0.1", 19085, 1000, 1000, "running", "")
        @Expect(writeGcmPluginLease(path, lease).ok, true)
        let context = GcmPluginWatchdogContext(path, lease, GcmPluginOwnerSnapshot(false, false, 0, observedParentPid: 303, parentPidProbeStatus: "probe_unavailable"), parentProbeFailureCount: 0, parentProbeFailureThreshold: 3, forceOrphan: false)
        let tick = gcmPluginWatchdogTick(context, nowMs: 4000)
        @Expect(tick.orphanDetected, false)
        @Expect(tick.status, "parent_probe_suspect")
        @Expect(tick.reason, "probe_unavailable")
        let reloaded = readGcmPluginLease(path).lease
        @Expect(reloaded.state, "running")
        @Expect(reloaded.orphanReason, "")
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func gcmOrphanP001ConfirmedParentMissingRequiresConsecutiveThreshold(): Unit {
        // GCM-ORPHAN-P-001
        let dir = tempDir("gcm-orphan-p001")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-p001", 101, 202, "127.0.0.1", 19090, 1000, 1000, "running", "")
        @Expect(writeGcmPluginLease(path, lease).ok, true)
        let missing = GcmPluginOwnerSnapshot(false, false, 0, observedParentPid: 0, parentPidProbeStatus: "pid_missing")

        let suspect = gcmPluginWatchdogTick(GcmPluginWatchdogContext(path, lease, missing, parentProbeFailureCount: 1, parentProbeFailureThreshold: 3), nowMs: 2000)
        @Expect(suspect.orphanDetected, false)
        @Expect(suspect.status, "parent_probe_suspect")
        @Expect(readGcmPluginLease(path).lease.state, "running")

        let confirmed = gcmPluginWatchdogTick(GcmPluginWatchdogContext(path, lease.withHeartbeat(2000), missing, parentProbeFailureCount: 2, parentProbeFailureThreshold: 3), nowMs: 3000)
        @Expect(confirmed.orphanDetected, true)
        @Expect(confirmed.status, "orphan_detected")
        @Expect(confirmed.reason, "parent_lost")
        let reloaded = readGcmPluginLease(path).lease
        @Expect(reloaded.state, "orphan_detected")
        @Expect(reloaded.orphanReason, "parent_lost")
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p5p6GcmWatchdogAndRuntimeFailClosedDiagnostics(): Unit {
        // T-P5-U-001, T-P5-B-001, T-P5-P-001, T-P5-N-001, T-P6-U-001, T-P6-B-001, T-P6-P-001, T-P6-N-001
        let dir = tempDir("gcm-p5-p6-watchdog")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-p5p6", 101, 202, "127.0.0.1", 19086, 1000, 1000, "running", "")
        @Expect(writeGcmPluginLease(path, lease).ok, true)
        let healthy = gcmPluginWatchdogTick(GcmPluginWatchdogContext(path, lease, GcmPluginOwnerSnapshot(true, false, 0)), nowMs: 2000)
        @Expect(healthy.orphanDetected, false)
        @Expect(healthy.status, "heartbeat")

        let badParent = dir.join("lease-parent-file")
        File.writeTo(badParent, "not-a-directory".toArray())
        let badLeasePath = badParent.join("lease.json").toString()
        let writeFailed = gcmPluginWatchdogTick(GcmPluginWatchdogContext(badLeasePath, lease, GcmPluginOwnerSnapshot(true, false, 0)), nowMs: 2100)
        @Expect(writeFailed.orphanDetected, false)
        @Expect(writeFailed.status.contains("lease"), true)

        let orphan = gcmPluginWatchdogTick(GcmPluginWatchdogContext(path, lease, GcmPluginOwnerSnapshot(false, false, 0, parentPidProbeStatus: "pid_missing"), parentProbeFailureCount: 2, parentProbeFailureThreshold: 3), nowMs: 3000)
        @Expect(orphan.orphanDetected, true)
        @Expect(orphan.reason, "parent_lost")
        let orphanedLease = readGcmPluginLease(path).lease
        let frame = gcmPluginOrphanDetectedFrame(orphanedLease)
        @Expect(frame.payload.contains("\"pluginId\":\"gitcode-monitor\""), true)
        @Expect(frame.payload.contains("\"sessionId\":\"session-p5p6\""), true)
        @Expect(frame.payload.contains("\"parentPid\":202"), true)
        @Expect(frame.payload.contains("\"bindHost\":\"127.0.0.1\""), true)
        @Expect(frame.payload.contains("\"port\":19086"), true)
        @Expect(frame.payload.contains("token"), false)
        @Expect(frame.payload.contains("/Users/"), false)

        let config = defaultConfig()
        config.webhook = WebhookReceiverConfig(enabled: false, queueDir: dir.join("queue").toString())
        let queue = WebhookQueue(config.webhook.queueDir)
        let loop = WebhookProcessorLoopRuntime(config, RuntimeContainer(config), MonitorState(), queue)
        loop.start()
        @Expect(loop.snapshot().processorStatus, "disabled")
        loop.stop()
        @Expect(loop.snapshot().processorStatus == "disabled" || loop.snapshot().processorStatus == "stopped", true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }

    @TestCase
    public func p6WatchdogOrphanHandlerEmitsFrameAndStopsRuntimesWithoutExit(): Unit {
        // T-P6-U-001, T-P6-P-001
        let dir = tempDir("gcm-p6-orphan-helper")
        let path = dir.join("lease.json").toString()
        let lease = GcmPluginLease(GCM_SERVICE_PLUGIN_ID, "session-helper", 101, 202, "127.0.0.1", 19087, 1000, 3000, "orphan_detected", "parent_lost")
        @Expect(writeGcmPluginLease(path, lease).ok, true)
        let config = defaultConfig()
        let port = 19100 + (DateTime.now().toUnixTimeStamp().toNanoseconds() % 1000)
        config.webhook = WebhookReceiverConfig(
            enabled: true,
            bindHost: "127.0.0.1",
            port: port,
            queueDir: dir.join("queue").toString(),
            endpoints: [WebhookEndpointConfig("main", "/webhooks/gitcode/main", token: "receiver-token")]
        )
        let queue = WebhookQueue(config.webhook.queueDir)
        let processor = WebhookProcessorLoopRuntime(config, RuntimeContainer(config), MonitorState(), queue)
        processor.start()
        let listener = WebhookHttpServerRuntime(config, queue)
        @Expect(listener.start().ok, true)
        sleep(Duration.millisecond * 20)
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)

        let handled = gcmPluginHandleOrphanForTest(path, writer, listener, processor)

        @Expect(handled.orphanHandled, true)
        @Expect(handled.frameEmitted, true)
        @Expect(sink.lines.size, 1)
        @Expect(decodeServiceFrame(sink.lines[0]).frame.capabilityId, "gitcode.monitor.orphan_detected")
        @Expect(processor.snapshot().processorStatus, "stopped")
        @Expect(handled.processorStopped, true)
        @Expect(handled.listenerStopped, true)
        @Expect(listener.snapshot().serveWorkerDone, true)
        @Expect(listener.snapshot().stopBounded, true)
        try { remove(dir, recursive: true) } catch (_: Exception) { () }
    }
}
