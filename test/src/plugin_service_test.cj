package gitcodemonitor

import std.collection.ArrayList
import std.fs.{File, Path, exists}
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

@Test
public class GitCodeMonitorPluginServiceTest {
    private func readFirstExisting(paths: Array<String>): String {
        for (path in paths) {
            if (exists(Path(path))) {
                return String.fromUtf8(File.readFrom(Path(path))).trimAscii()
            }
        }
        ""
    }

    private func jsonStringArray(value: JsonValue): Array<String> {
        let out = ArrayList<String>()
        for (item in value.asArray().getItems()) {
            out.add(item.asString().getValue())
        }
        out.toArray()
    }

    @TestCase
    public func buildGitCodeMonitorCapabilityDeclarationsContainsTwentyOneRecords(): Unit {
        let records = buildGitCodeMonitorCapabilityDeclarations()
        @Expect(records.size, 21)
        let check = validateGitCodeMonitorCapabilitySet(records)
        @Expect(check.ok, true)
        @Expect(check.missingCapabilityIds.size, 0)
        @Expect(records[0].capabilityId, "gitcode.monitor.status")
        @Expect(records[0].kind, "controlAction")
        @Expect(records[0].direction, "metis-to-gcm")
        @Expect(records[2].capabilityId, "gitcode.monitor.job_status")
        @Expect(records[3].capabilityId, "gitcode.monitor.cancel_job")
        @Expect(records[4].capabilityId, "gitcode.webhook.status")
        @Expect(records[10].capabilityId, "gitcode.webhook.reconcile_events")
        @Expect(records[12].capabilityId, "gitcode.monitor.scan_completed")
        @Expect(records[17].capabilityId, "gitcode.agent.draft_request")
        @Expect(records[17].requiredHostApis[0], "host.agent.invoke")
        @Expect(records[18].capabilityId, "gitcode.notification.generated_reply")
        @Expect(records[18].requiredHostApis[0], "host.notification.publish")
    }

    @TestCase
    public func validateGitCodeMonitorCapabilitySetReportsMissingRecordAndAllowsExperimental(): Unit {
        let records = buildGitCodeMonitorCapabilityDeclarations()
        records.remove(at: 19)
        records.add(ServiceCapabilityRecord("gitcode.experimental.trace", "event", direction: "gcm-to-metis"))
        let check = validateGitCodeMonitorCapabilitySet(records)
        @Expect(check.ok, false)
        @Expect(check.missingCapabilityIds.size, 1)
        @Expect(check.missingCapabilityIds[0], "gitcode.writeback.apply_result")
        @Expect(check.diagnostics[0].contains("gitcode.writeback.apply_result"), true)
    }

    @TestCase
    public func validateGitCodeMonitorCapabilitySetMarksMissingHostApiDegraded(): Unit {
        let records = buildGitCodeMonitorCapabilityDeclarations()
        records.remove(at: 18)
        records.add(ServiceCapabilityRecord("gitcode.notification.generated_reply", "notificationTopic"))
        let check = validateGitCodeMonitorCapabilitySet(records)
        @Expect(check.ok, true)
        @Expect(check.degradedCapabilityIds.size, 1)
        @Expect(check.degradedCapabilityIds[0], "gitcode.notification.generated_reply")
    }

    @TestCase
    public func manifestContainsServiceSchemaAndTwentyOneCapabilitiesWithoutSecrets(): Unit {
        let manifest = buildGitCodeMonitorServicePluginManifest()
        let root = JsonValue.fromStr(manifest).asObject()
        @Expect(root.get("schema").getOrThrow().asString().getValue(), "metis.servicePlugin.v1")
        @Expect(root.get("pluginId").getOrThrow().asString().getValue(), "gitcode-monitor")
        @Expect(root.get("kind").getOrThrow().asString().getValue(), "service")
        @Expect(root.get("capabilityDeclarations").getOrThrow().asArray().getItems().size, 21)
        @Expect(manifest.contains("gitcode.monitor.scan_once"), true)
        @Expect(manifest.contains("gitcode.webhook.status"), true)
        @Expect(manifest.contains("gitcode.webhook.reconcile_events"), true)
        @Expect(manifest.contains("gitcode.monitor.job_status"), true)
        @Expect(manifest.contains("gitcode.monitor.scan_completed"), true)
        @Expect(manifest.contains("gitcode.writeback.audit"), true)
        @Expect(manifest.contains("token"), false)
        @Expect(manifest.contains("cookie"), false)
        @Expect(manifest.contains("appSecret"), false)
        @Expect(manifest.contains("/Users/"), false)
    }

    @TestCase
    public func generatedManifestUsesSkipBuildAndCheckedInEntryMatches(): Unit {
        let generated = JsonValue.fromStr(buildGitCodeMonitorServicePluginManifest()).asObject()
        let generatedEntry = generated.get("entry").getOrThrow().asObject()
        let generatedArgs = jsonStringArray(generatedEntry.get("args").getOrThrow())
        let expectedArgs = ["run", "--skip-build", "--name", "gitcodemonitor", "--run-args", "plugin-stdio"]
        @Expect(generatedEntry.get("command").getOrThrow().asString().getValue(), "cjpm")
        @Expect(generatedArgs.contains("--skip-build"), true)
        @Expect(generatedArgs.size, expectedArgs.size)
        for (i in 0..expectedArgs.size) {
            @Expect(generatedArgs[i], expectedArgs[i])
        }

        let checkedInText = readFirstExisting(["metis.service-plugin.json", "../metis.service-plugin.json"])
        @Expect(checkedInText.isEmpty(), false)
        let checkedIn = JsonValue.fromStr(checkedInText).asObject()
        let checkedInEntry = checkedIn.get("entry").getOrThrow().asObject()
        let checkedInArgs = jsonStringArray(checkedInEntry.get("args").getOrThrow())
        let checkedInCapabilities = checkedIn.get("capabilityDeclarations").getOrThrow().asArray().getItems()
        @Expect(checkedInEntry.get("command").getOrThrow().asString().getValue(), generatedEntry.get("command").getOrThrow().asString().getValue())
        @Expect(checkedInArgs.size, generatedArgs.size)
        @Expect(checkedInCapabilities.size, 21)
        for (i in 0..generatedArgs.size) {
            @Expect(checkedInArgs[i], generatedArgs[i])
        }
        @Expect(checkedInText.contains("gitcode.webhook.status"), true)
        @Expect(checkedInText.contains("gitcode.webhook.reconcile_events"), true)
        @Expect(checkedInText.contains("token"), false)
        @Expect(checkedInText.contains("Authorization"), false)
        @Expect(checkedInText.contains("/Users/"), false)
    }

    @TestCase
    public func stdioProtocolFixturesAreGoldenAndDoNotContainSecrets(): Unit {
        let initLine = readFirstExisting(["test/fixtures/service_plugin/stdio_protocol/valid_initialize.jsonl", "../test/fixtures/service_plugin/stdio_protocol/valid_initialize.jsonl", "fixtures/service_plugin/stdio_protocol/valid_initialize.jsonl"])
        let scanLine = readFirstExisting(["test/fixtures/service_plugin/stdio_protocol/valid_scan_response.jsonl", "../test/fixtures/service_plugin/stdio_protocol/valid_scan_response.jsonl", "fixtures/service_plugin/stdio_protocol/valid_scan_response.jsonl"])
        let noisy = readFirstExisting(["test/fixtures/service_plugin/stdio_protocol/noisy_stdout_before_response.txt", "../test/fixtures/service_plugin/stdio_protocol/noisy_stdout_before_response.txt", "fixtures/service_plugin/stdio_protocol/noisy_stdout_before_response.txt"])
        @Expect(initLine, "{\"type\":\"response\",\"frameId\":\"initialize\",\"serviceId\":\"gitcode-monitor\",\"method\":\"initialize\",\"payload\":{\"ok\":true,\"status\":\"ok\",\"capabilities\":21}}")
        @Expect(scanLine, "{\"type\":\"response\",\"frameId\":\"response-scan-1\",\"serviceId\":\"gitcode-monitor\",\"method\":\"invokeCapability\",\"capabilityId\":\"gitcode.monitor.scan_once\",\"correlationId\":\"corr-scan-1\",\"payload\":{\"ok\":true,\"status\":\"ok\",\"accepted\":0,\"ignored\":0,\"emitted\":0,\"stateSaved\":true}}")
        let noisyLines = noisy.split("\n")
        @Expect(noisyLines.size, 3)
        @Expect(decodeServiceFrame(noisyLines[0]).ok, true)
        @Expect(decodeServiceFrame(noisyLines[1]).ok, false)
        @Expect(decodeServiceFrame(noisyLines[1]).errorKind, "invalid_json")
        @Expect(decodeServiceFrame(noisyLines[2]).ok, true)
        @Expect(noisy.contains("Authorization"), false)
        @Expect(noisy.contains("cookie"), false)
        @Expect(noisy.contains("/Users/"), false)
    }

    @TestCase
    public func encodeDecodeServiceFrameRoundTripForCoreFrameTypes(): Unit {
        for (frameType in ["request", "response", "event", "audit", "heartbeat"]) {
            let frame = ServiceFrame(
                frameType,
                "frame-${frameType}",
                "gitcode-monitor",
                method: if (frameType == "request") { "invokeCapability" } else { "" },
                capabilityId: "gitcode.monitor.status",
                correlationId: "corr-${frameType}",
                payload: "{\"ok\":true,\"kind\":\"${frameType}\"}"
            )
            let encoded = encodeServiceFrame(frame)
            @Expect(encoded.contains("\n"), true)
            let decoded = decodeServiceFrame(encoded.trimAscii())
            @Expect(decoded.ok, true)
            @Expect(decoded.frame.frameType, frameType)
            @Expect(decoded.frame.frameId, "frame-${frameType}")
            @Expect(decoded.frame.serviceId, "gitcode-monitor")
            @Expect(decoded.frame.capabilityId, "gitcode.monitor.status")
            @Expect(decoded.frame.payload.contains("\"ok\""), true)
            @Expect(decoded.frame.payload.contains("true"), true)
        }
    }

    @TestCase
    public func decodeServiceFrameRejectsMalformedMissingOversizedAndUnknownMethod(): Unit {
        @Expect(decodeServiceFrame("{not-json").errorKind, "invalid_json")
        @Expect(decodeServiceFrame("{\"type\":\"request\",\"serviceId\":\"gitcode-monitor\"}").diagnostic.contains("frameId"), true)
        @Expect(decodeServiceFrame("{\"type\":\"request\",\"frameId\":\"f\",\"serviceId\":\"gitcode-monitor\",\"method\":\"unknown\"}").errorKind, "unknown_method")
        @Expect(decodeServiceFrame("{\"type\":\"request\",\"frameId\":\"f\",\"serviceId\":\"gitcode-monitor\"}\n{\"type\":\"event\"}").errorKind, "multiline_frame")
        @Expect(decodeServiceFrame("0123456789", maxBytes: 4).errorKind, "frame_too_large")
    }

    @TestCase
    public func correlateServiceFrameMatchesPendingRequest(): Unit {
        let pending = PendingFrameStore()
        pending.add("corr-1")
        let matched = correlateServiceFrame(ServiceFrame("response", "frame-2", "gitcode-monitor", correlationId: "corr-1"), pending)
        @Expect(matched.matched, true)
        @Expect(matched.correlationId, "corr-1")
        let duplicate = correlateServiceFrame(ServiceFrame("response", "frame-3", "gitcode-monitor", correlationId: "corr-1"), pending)
        @Expect(duplicate.matched, false)
        @Expect(duplicate.errorKind, "correlation_unknown")
    }

    @TestCase
    public func redactServicePayloadMasksKnownSecretPatternsAndLocalPaths(): Unit {
        let payload = "{\"repo\":\"cangjie/compiler\",\"token\":\"gitcode-secret\",\"cookie\":\"sid=cookie-secret\",\"Authorization\":\"Bearer auth-secret\",\"appSecret\":\"feishu-secret\",\"path\":\"/Users/name/private-index\"}"
        let redacted = redactServicePayload(payload)
        @Expect(redacted.text.contains("gitcode-secret"), false)
        @Expect(redacted.text.contains("cookie-secret"), false)
        @Expect(redacted.text.contains("auth-secret"), false)
        @Expect(redacted.text.contains("feishu-secret"), false)
        @Expect(redacted.text.contains("/Users/name"), false)
        @Expect(redacted.rawHash.contains("gitcode-secret"), false)
        @Expect(redacted.rawHash.startsWith("payload-"), true)
    }

    @TestCase
    public func redactServicePayloadPreservesOrdinaryPayloadAndTruncatesAtLimit(): Unit {
        let ordinary = "{\"repo\":\"cangjie/compiler\",\"url\":\"https://gitcode.com/cangjie/compiler/issues/1\",\"summary\":\"safe\"}"
        let kept = redactServicePayload(ordinary)
        @Expect(kept.text.contains("cangjie/compiler"), true)
        @Expect(kept.text.contains("https://gitcode.com/cangjie/compiler/issues/1"), true)
        let truncated = redactServicePayload("abcdef", policy: RedactionPolicy(maxPayloadBytes: 3))
        @Expect(truncated.truncated, true)
        @Expect(truncated.text.contains("abc"), true)
        @Expect(truncated.text.contains("def"), false)
        let unicode = redactServicePayload("仓颉abcdef", policy: RedactionPolicy(maxPayloadBytes: 2))
        @Expect(unicode.truncated, true)
        @Expect(unicode.text.contains("仓颉"), true)
    }

    @TestCase
    public func enforceServiceFrameLimitsAcceptsBoundaryAndRejectsOversizedPayload(): Unit {
        let frame = ServiceFrame("event", "f", "gitcode-monitor", capabilityId: "gitcode.event.accepted", payload: "12345")
        @Expect(enforceServiceFrameLimits(frame, limits: ServiceFrameLimits(maxPayloadBytes: 5)).ok, true)
        let tooLarge = enforceServiceFrameLimits(frame, limits: ServiceFrameLimits(maxPayloadBytes: 4))
        @Expect(tooLarge.ok, false)
        @Expect(tooLarge.rejected, true)
        @Expect(tooLarge.reason, "payload_too_large")
        @Expect(tooLarge.payloadHash.startsWith("payload-"), true)
    }
}
