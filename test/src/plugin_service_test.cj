package gitcodemonitor

import std.collection.ArrayList
import std.unittest.testmacro.*
import stdx.encoding.json.JsonValue

@Test
public class GitCodeMonitorPluginServiceTest {
    @TestCase
    public func buildGitCodeMonitorCapabilityDeclarationsContainsEightRecords(): Unit {
        let records = buildGitCodeMonitorCapabilityDeclarations()
        @Expect(records.size, 8)
        let check = validateGitCodeMonitorCapabilitySet(records)
        @Expect(check.ok, true)
        @Expect(check.missingCapabilityIds.size, 0)
        @Expect(records[0].capabilityId, "gitcode.monitor.status")
        @Expect(records[0].kind, "controlAction")
        @Expect(records[0].direction, "metis-to-gcm")
        @Expect(records[4].capabilityId, "gitcode.agent.draft_request")
        @Expect(records[4].requiredHostApis[0], "host.agent.invoke")
        @Expect(records[5].capabilityId, "gitcode.notification.generated_reply")
        @Expect(records[5].requiredHostApis[0], "host.notification.publish")
    }

    @TestCase
    public func validateGitCodeMonitorCapabilitySetReportsMissingRecordAndAllowsExperimental(): Unit {
        let records = buildGitCodeMonitorCapabilityDeclarations()
        records.remove(at: 6)
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
        records.remove(at: 5)
        records.add(ServiceCapabilityRecord("gitcode.notification.generated_reply", "notificationTopic"))
        let check = validateGitCodeMonitorCapabilitySet(records)
        @Expect(check.ok, true)
        @Expect(check.degradedCapabilityIds.size, 1)
        @Expect(check.degradedCapabilityIds[0], "gitcode.notification.generated_reply")
    }

    @TestCase
    public func manifestContainsServiceSchemaAndEightCapabilitiesWithoutSecrets(): Unit {
        let manifest = buildGitCodeMonitorServicePluginManifest()
        let root = JsonValue.fromStr(manifest).asObject()
        @Expect(root.get("schema").getOrThrow().asString().getValue(), "metis.servicePlugin.v1")
        @Expect(root.get("pluginId").getOrThrow().asString().getValue(), "gitcode-monitor")
        @Expect(root.get("kind").getOrThrow().asString().getValue(), "service")
        @Expect(root.get("capabilityDeclarations").getOrThrow().asArray().getItems().size, 8)
        @Expect(manifest.contains("gitcode.monitor.scan_once"), true)
        @Expect(manifest.contains("gitcode.writeback.audit"), true)
        @Expect(manifest.contains("token"), false)
        @Expect(manifest.contains("cookie"), false)
        @Expect(manifest.contains("appSecret"), false)
        @Expect(manifest.contains("/Users/"), false)
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
